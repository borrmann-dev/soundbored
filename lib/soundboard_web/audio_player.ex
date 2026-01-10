defmodule SoundboardWeb.AudioPlayer do
  @moduledoc """
  Handles the audio playback.
  """
  use GenServer
  require Logger
  alias HTTPoison
  alias Nostrum.Voice
  alias Soundboard.Accounts.User
  alias Soundboard.Sound

  # System users that don't need play tracking
  @system_users ["System", "API User"]

  defmodule State do
    @moduledoc """
    The state of the audio player.
    """
    defstruct [:voice_channel, :current_playback]
  end

  # Client API
  def start_link(_opts) do
    Logger.info("Starting AudioPlayer GenServer")
    GenServer.start_link(__MODULE__, %State{}, name: __MODULE__)
  end

  def play_sound(sound_name, username) do
    Logger.info("Received play_sound request for: #{sound_name} from #{username}")
    GenServer.cast(__MODULE__, {:play_sound, sound_name, username})
  end

  def stop_sound do
    Logger.info("Stopping all sounds")
    GenServer.cast(__MODULE__, :stop_sound)
  end

  def set_voice_channel(guild_id, channel_id) do
    Logger.info("Setting voice channel - Guild: #{guild_id}, Channel: #{channel_id}")
    GenServer.cast(__MODULE__, {:set_voice_channel, guild_id, channel_id})
  end

  def current_voice_channel do
    GenServer.call(__MODULE__, :get_voice_channel)
  rescue
    _ -> nil
  end

  # Server Callbacks
  @impl true
  def init(state) do
    Logger.info("Initializing AudioPlayer with state: #{inspect(state)}")
    # Create a fast in-memory cache for sound metadata
    ensure_sound_cache()
    # Schedule periodic voice connection check
    schedule_voice_check()
    {:ok, state}
  end

  @impl true
  def handle_cast({:set_voice_channel, guild_id, channel_id}, state) do
    # Handle nil values properly - set to nil instead of {nil, nil}
    voice_channel =
      if is_nil(guild_id) or is_nil(channel_id) do
        nil
      else
        {guild_id, channel_id}
      end

    {:noreply, %{state | voice_channel: voice_channel}}
  end

  def handle_cast(:stop_sound, %{voice_channel: {guild_id, _channel_id}} = state) do
    Logger.info("Stopping all sounds in guild: #{guild_id}")
    Voice.stop(guild_id)
    broadcast_success("All sounds stopped", "System")
    {:noreply, state}
  end

  def handle_cast(:stop_sound, state) do
    Logger.info("Attempted to stop sounds but no voice channel connected")
    broadcast_error("Bot is not connected to a voice channel")
    {:noreply, state}
  end

  def handle_cast({:play_sound, _sound_name, _username}, %{voice_channel: nil} = state) do
    broadcast_error("Bot is not connected to a voice channel. Use !join in Discord first.")
    {:noreply, state}
  end

  def handle_cast(
        {:play_sound, sound_name, username},
        %{voice_channel: {guild_id, channel_id}} = state
      ) do
    # More thorough check: wait a bit and check multiple times
    # This prevents race conditions where audio just finished
    if check_playing_with_retries(guild_id, 3, 50) do
      Logger.info("Blocking sound #{sound_name} - another sound is already playing")
      broadcast_error("Ein Sound wird bereits abgespielt. Bitte warten...")
      {:noreply, state}
    else
      start_sound_playback(state, guild_id, channel_id, sound_name, username)
    end
  end

  # Check if audio is playing with multiple retries to avoid race conditions
  defp check_playing_with_retries(guild_id, retries_left, delay_ms) when retries_left > 0 do
    if Voice.playing?(guild_id) do
      true
    else
      Process.sleep(delay_ms)
      check_playing_with_retries(guild_id, retries_left - 1, delay_ms)
    end
  end

  defp check_playing_with_retries(_guild_id, 0, _delay_ms), do: false

  defp start_sound_playback(state, guild_id, channel_id, sound_name, username) do
    case get_sound_path(sound_name) do
      {:ok, {path_or_url, volume}} ->
        task =
          Task.async(fn ->
            play_sound_task(guild_id, channel_id, sound_name, path_or_url, volume, username)
          end)

        {:noreply, %{state | current_playback: task}}

      {:error, reason} ->
        broadcast_error(reason)
        {:noreply, state}
    end
  end

  @impl true
  def handle_call(:get_voice_channel, _from, state) do
    {:reply, state.voice_channel, state}
  end

  @impl true
  def handle_info({:play_delayed_sound, sound}, state) do
    Logger.info("Playing delayed join sound: #{sound}")
    # Play the sound as System user
    handle_cast({:play_sound, sound, "System"}, state)
  end

  @impl true
  def handle_info(:check_voice_connection, state) do
    # Check and maintain voice connection health
    new_state =
      case state.voice_channel do
        {guild_id, channel_id} when not is_nil(guild_id) and not is_nil(channel_id) ->
          if Voice.ready?(guild_id) do
            Logger.debug("Voice connection healthy for guild #{guild_id}")
            state
          else
            Logger.warning(
              "Voice connection not ready for guild #{guild_id}, attempting to rejoin"
            )

            # Wrap in try-catch to handle potential errors
            try do
              Voice.join_channel(guild_id, channel_id)
              state
            rescue
              error ->
                Logger.error("Failed to rejoin voice channel: #{inspect(error)}")
                # Clear the voice channel if we can't rejoin
                %{state | voice_channel: nil}
            end
          end

        _ ->
          Logger.debug("No voice channel set")
          state
      end

    # Schedule next check
    schedule_voice_check()
    {:noreply, new_state}
  end

  @impl true
  def handle_info({ref, _result}, %{current_playback: %Task{ref: ref}} = state) do
    Process.demonitor(ref, [:flush])
    {:noreply, %{state | current_playback: nil}}
  end

  @impl true
  def handle_info(
        {:DOWN, ref, :process, _pid, reason},
        %{current_playback: %Task{ref: ref}} = state
      ) do
    Logger.error("Playback task crashed: #{inspect(reason)}")
    {:noreply, %{state | current_playback: nil}}
  end

  @impl true
  def handle_info(_, state), do: {:noreply, state}

  # Helper function to check if a username is a system user
  defp system_user?(username), do: username in @system_users

  defp play_sound_task(guild_id, channel_id, sound_name, path_or_url, volume, username) do
    with :ok <- ensure_voice_connection(guild_id, channel_id),
         :ok <- validate_voice_ready(guild_id),
         :ok <- stabilize_and_validate(guild_id) do
      play_sound_with_connection(guild_id, sound_name, path_or_url, volume, username)
    else
      {:error, message} ->
        Logger.error(message)
        broadcast_error(message)
        :error
    end
  end

  defp ensure_voice_connection(guild_id, channel_id) do
    if ensure_voice_ready(guild_id, channel_id) do
      :ok
    else
      {:error, "Fehler beim Verbinden zum Voice-Kanal"}
    end
  end

  defp validate_voice_ready(guild_id) do
    if Voice.ready?(guild_id) do
      :ok
    else
      {:error, "Voice-Verbindung nicht bereit"}
    end
  end

  defp stabilize_and_validate(guild_id) do
    # Longer delay to ensure connection is fully stabilized before playback
    # This helps prevent dropouts at the start of audio
    # Increased delay gives Discord more time to establish stable connection
    # Additional delay for maximum stability
    Process.sleep(200)

    # Final check before proceeding
    if Voice.ready?(guild_id) do
      :ok
    else
      {:error, "Voice-Verbindung instabil. Bitte erneut versuchen."}
    end
  end

  defp play_sound_with_connection(guild_id, sound_name, path_or_url, volume, username) do
    # Pre-validate voice connection state before attempting playback
    if validate_voice_state(guild_id) do
      do_play_sound_with_connection(guild_id, sound_name, path_or_url, volume, username)
    else
      Logger.error("Voice connection not in valid state for playback")
      broadcast_error("Voice-Verbindung nicht bereit. Bitte erneut versuchen.")
      :error
    end
  end

  defp do_play_sound_with_connection(guild_id, sound_name, path_or_url, volume, username) do
    {play_input, play_type, source_type} = prepare_play_input(sound_name, path_or_url)

    Logger.info(
      "Calling Voice.play with guild_id: #{guild_id}, input: #{play_input}, type: #{play_type}, volume: #{volume}, source_type: #{source_type}"
    )

    # For URL-based sounds, validate URL accessibility before playback
    # This helps prevent glitches from network issues
    # Run validation in background to avoid blocking playback
    validate_url_in_background(source_type, play_input)

    # Double-check voice state right before playback
    voice_ready = Voice.ready?(guild_id)
    voice_playing = Voice.playing?(guild_id)
    Logger.info("Voice ready: #{voice_ready}, Playing: #{voice_playing}")

    # If something is still playing, wait longer to ensure clean transition
    wait_for_previous_playback(guild_id, voice_playing)

    # Final stabilization check right before playback
    # This ensures connection is absolutely ready
    if Voice.ready?(guild_id) do
      execute_playback(guild_id, play_input, play_type, source_type, volume, sound_name, username)
    else
      Logger.error("Voice connection lost right before playback")
      broadcast_error("Voice-Verbindung verloren. Bitte erneut versuchen.")
      :error
    end
  end

  defp validate_url_in_background("url", play_input) do
    spawn(fn -> handle_url_validation(play_input) end)
  end

  defp validate_url_in_background(_source_type, _play_input), do: :ok

  defp handle_url_validation(play_input) do
    case validate_url_accessibility(play_input) do
      :ok ->
        Logger.info("URL validated and accessible: #{play_input}")

      {:error, reason} ->
        Logger.warning("URL validation failed: #{reason}, but playback may still work")
    end
  end

  defp wait_for_previous_playback(_guild_id, false), do: :ok

  defp wait_for_previous_playback(guild_id, true) do
    Logger.warning("Audio still playing, waiting for completion...")
    wait_for_playback_completion(guild_id, 20, 150)
    # Additional stabilization delay after previous playback ends
    Process.sleep(100)
  end

  defp execute_playback(
         guild_id,
         play_input,
         play_type,
         source_type,
         volume,
         sound_name,
         username
       ) do
    # For URL-based sounds, use longer delays to allow network connection to stabilize
    # URL streaming requires network handshake which can cause initial glitches
    stabilization_delay = if source_type == "url", do: 300, else: 100

    Logger.info("Using stabilization delay: #{stabilization_delay}ms for #{source_type} source")

    Process.sleep(stabilization_delay)

    # Disable ffmpeg realtime processing to avoid `-re` pacing.
    # Nostrum already paces via bursts; `-re` can cause latency buildup
    # and slower cleanup of ffmpeg processes over time.
    # Additional options for stability:
    # - realtime: false prevents ffmpeg from pacing (Nostrum handles it)
    # - Higher buffer (15 frames) compensates for network jitter
    # - volume: clamp_volume ensures volume is in valid range (0.0-1.5)
    #   Note: Nostrum's volume parameter should work for both local and URL sources
    clamped_vol = clamp_volume(volume)

    play_options = [
      volume: clamped_vol,
      realtime: false
    ]

    Logger.info(
      "Play options: #{inspect(play_options)} (source_type: #{source_type}, original_volume: #{volume})"
    )

    # Keep track of attempts
    # For URL sources, use more retries due to network instability
    max_retries = if source_type == "url", do: 5, else: 3

    play_with_retries(
      guild_id,
      play_input,
      play_type,
      play_options,
      sound_name,
      username,
      0,
      max_retries
    )
  end

  # Validate that voice connection is in a good state for playback
  defp validate_voice_state(guild_id) do
    # Check multiple times with longer delays to ensure stability
    # More thorough checking prevents dropouts from unstable connections
    checks =
      for _ <- 1..5 do
        Process.sleep(30)
        Voice.ready?(guild_id)
      end

    # At least 4 out of 5 checks should pass (allows for minor fluctuations)
    passing_checks = Enum.count(checks, & &1)
    passing_checks >= 4
  end

  # Wait for current playback to complete with timeout
  defp wait_for_playback_completion(guild_id, max_attempts, delay_ms) when max_attempts > 0 do
    if Voice.playing?(guild_id) do
      Process.sleep(delay_ms)
      wait_for_playback_completion(guild_id, max_attempts - 1, delay_ms)
    else
      Logger.info("Previous playback completed")
      :ok
    end
  end

  defp wait_for_playback_completion(_guild_id, 0, _delay_ms) do
    Logger.warning("Timeout waiting for playback to complete")
    :timeout
  end

  defp play_with_retries(
         guild_id,
         play_input,
         play_type,
         play_options,
         sound_name,
         username,
         attempt,
         max_retries
       )
       when attempt < max_retries do
    case Voice.play(guild_id, play_input, play_type, play_options) do
      :ok ->
        Logger.info(
          "Voice.play succeeded for #{sound_name} (attempt #{attempt + 1}) with volume: #{inspect(play_options[:volume])}"
        )

        # Start monitoring connection health during playback
        # This helps detect and potentially recover from mid-playback issues
        start_playback_monitoring(guild_id, sound_name)

        track_play_if_needed(sound_name, username)
        broadcast_success(sound_name, username)
        :ok

      {:error, "Audio already playing in voice channel."} ->
        Logger.warning("Audio still playing on attempt #{attempt + 1}, stopping and retrying...")
        # Force stop the current audio
        Voice.stop(guild_id)
        # Longer delay to ensure stop completes and connection stabilizes
        # Exponential backoff with longer delays: 200ms, 400ms, 600ms
        stop_delay = 200 * (attempt + 1)
        Process.sleep(stop_delay)

        # Verify stop completed before retrying
        if Voice.playing?(guild_id) do
          Logger.warning("Audio still playing after stop, waiting longer...")
          Process.sleep(300)
          Voice.stop(guild_id)
          Process.sleep(200)
        end

        play_with_retries(
          guild_id,
          play_input,
          play_type,
          play_options,
          sound_name,
          username,
          attempt + 1,
          max_retries
        )

      {:error, "Must be connected to voice channel to play audio."} ->
        Logger.error("Voice connection lost, attempting to reconnect...")

        handle_voice_reconnect(
          guild_id,
          play_input,
          play_type,
          play_options,
          sound_name,
          username,
          attempt,
          max_retries
        )

      {:error, reason} ->
        Logger.error("Voice.play failed: #{inspect(reason)} (attempt #{attempt + 1})")

        # Try to recover from specific error types
        recovered = attempt_recovery(guild_id, reason, attempt)

        if recovered and attempt < 2 do
          Logger.info("Recovery successful, retrying playback...")
          Process.sleep(100)

          play_with_retries(
            guild_id,
            play_input,
            play_type,
            play_options,
            sound_name,
            username,
            attempt + 1,
            max_retries
          )
        else
          broadcast_error("Fehler beim Abspielen: #{reason}")
          :error
        end
    end
  end

  defp play_with_retries(
         _guild_id,
         _play_input,
         _play_type,
         _play_options,
         sound_name,
         _username,
         attempt,
         max_retries
       ) do
    Logger.error(
      "Exceeded max retries (#{max_retries}) for playing #{sound_name} (attempted #{attempt} times)"
    )

    broadcast_error("Fehler beim Abspielen nach mehreren Versuchen")
    :error
  end

  # Validate URL accessibility before playback (non-blocking)
  # This helps prevent glitches from network issues with URL-based sounds
  # Note: This runs in background and doesn't block playback
  defp validate_url_accessibility(url) when is_binary(url) do
    # Use HTTPoison to check if URL is accessible
    # Only check HEAD request to minimize overhead
    # Short timeout to avoid delaying playback
    case HTTPoison.head(url, [], timeout: 2000, recv_timeout: 2000) do
      {:ok, %{status_code: status}} when status in 200..399 ->
        :ok

      {:ok, %{status_code: status}} ->
        {:error, "URL returned status #{status}"}

      {:error, %{reason: reason}} ->
        {:error, "URL not accessible: #{inspect(reason)}"}
    end
  rescue
    error ->
      {:error, "URL validation error: #{inspect(error)}"}
  catch
    :exit, reason ->
      {:error, "URL validation timeout: #{inspect(reason)}"}
  end

  defp validate_url_accessibility(_), do: {:error, "Invalid URL"}

  defp handle_voice_reconnect(
         guild_id,
         play_input,
         play_type,
         play_options,
         sound_name,
         username,
         attempt,
         max_retries
       ) do
    # Get the channel from state
    case GenServer.call(__MODULE__, :get_voice_channel) do
      {^guild_id, channel_id} ->
        Logger.info("Rejoining voice channel #{channel_id}")

        # Voice.join_channel returns :ok or crashes (no_return)
        try do
          Voice.join_channel(guild_id, channel_id)
          # Wait longer for connection to fully establish before retrying playback
          # Verify connection is ready before attempting to play
          if verify_connection_with_retries(guild_id, 3, 100) do
            play_with_retries(
              guild_id,
              play_input,
              play_type,
              play_options,
              sound_name,
              username,
              attempt + 1,
              max_retries
            )
          else
            Logger.error("Failed to establish voice connection after rejoin")
            broadcast_error("Failed to reconnect to voice channel")
            :error
          end
        rescue
          error ->
            Logger.error("Failed to rejoin voice channel: #{inspect(error)}")
            broadcast_error("Failed to reconnect to voice channel")
            :error
        end

      _ ->
        Logger.error("No voice channel info available")
        broadcast_error("Voice channel not configured")
        :error
    end
  end

  # Removed unused wait_for_audio_to_finish/2 to keep compile clean and hot path lean

  defp schedule_voice_check do
    # Check voice connection every 15 seconds for better reliability
    Process.send_after(self(), :check_voice_connection, 15_000)
  end

  # Ensure ETS table exists (idempotent)
  defp ensure_sound_cache do
    case :ets.info(:sound_meta_cache) do
      :undefined ->
        :ets.new(:sound_meta_cache, [:set, :named_table, :public, read_concurrency: true])

      _ ->
        :ok
    end
  end

  defp prepare_play_input(sound_name, path_or_url) do
    # Prefer cached metadata to avoid DB on hot path
    case :ets.lookup(:sound_meta_cache, sound_name) do
      [{^sound_name, %{source_type: "url"}}] ->
        Logger.info("Using URL directly for remote sound (cached)")
        {path_or_url, :url, "url"}

      [{^sound_name, %{source_type: "local"}}] ->
        Logger.info("Using raw path for local file with :url type (cached)")
        {path_or_url, :url, "local"}

      _ ->
        sound = Soundboard.Repo.get_by(Sound, filename: sound_name)
        Logger.info("Playing sound (uncached): #{inspect(sound)}")
        Logger.info("Original path/URL: #{path_or_url}")

        case sound do
          %{source_type: "url"} ->
            Logger.info("Using URL directly for remote sound")
            {path_or_url, :url, "url"}

          %{source_type: "local"} ->
            Logger.info("Using raw path for local file with :url type")
            {path_or_url, :url, "local"}

          _ ->
            Logger.warning("Unknown source type, defaulting to raw path with :url type")
            {path_or_url, :url, "unknown"}
        end
    end
  end

  defp track_play_if_needed(sound_name, username) do
    if system_user?(username) do
      Logger.info("Skipping play tracking for system user: #{username}")
    else
      case Soundboard.Repo.get_by(User, username: username) do
        %{id: user_id} -> Soundboard.Stats.track_play(sound_name, user_id)
        nil -> Logger.warning("Could not find user_id for #{username}")
      end
    end
  end

  defp ensure_voice_ready(guild_id, channel_id) do
    if Voice.ready?(guild_id) do
      Logger.info("Voice connection ready for guild #{guild_id}")
      true
    else
      Logger.info("Voice not ready, attempting to join channel #{channel_id}")
      join_and_verify_channel(guild_id, channel_id)
    end
  end

  defp join_and_verify_channel(guild_id, channel_id) do
    # Voice.join_channel returns :ok or crashes (no_return)
    # Using rescue to handle potential crashes
    Voice.join_channel(guild_id, channel_id)

    # Wait a bit longer and check multiple times for more reliable connection
    # Discord voice connections can take a moment to fully establish
    verify_connection_with_retries(guild_id, 3, 50)
  rescue
    error ->
      Logger.error("Failed to join voice channel: #{inspect(error)}")
      false
  end

  defp verify_connection_with_retries(guild_id, retries_left, delay_ms) when retries_left > 0 do
    Process.sleep(delay_ms)

    if Voice.ready?(guild_id) do
      # Double-check: verify it stays ready for a moment
      Process.sleep(50)

      if Voice.ready?(guild_id) do
        Logger.info("Successfully connected to voice channel (verified stable)")
        true
      else
        Logger.warning("Connection became unstable, retrying...")
        verify_connection_with_retries(guild_id, retries_left - 1, delay_ms)
      end
    else
      verify_connection_with_retries(guild_id, retries_left - 1, delay_ms)
    end
  end

  defp verify_connection_with_retries(_guild_id, 0, _delay_ms) do
    Logger.error("Voice connection not ready after multiple verification attempts")
    false
  end

  defp broadcast_success(sound_name, username) do
    Phoenix.PubSub.broadcast(
      Soundboard.PubSub,
      "soundboard",
      {:sound_played, %{filename: sound_name, played_by: username}}
    )
  end

  defp broadcast_error(message) do
    Phoenix.PubSub.broadcast(
      Soundboard.PubSub,
      "soundboard",
      {:error, message}
    )
  end

  defp clamp_volume(value) when is_number(value) do
    value
    |> max(0.0)
    |> min(1.5)
    |> Float.round(4)
  end

  defp clamp_volume(_), do: 1.0

  # Monitor voice connection health during active playback
  # This helps detect connection issues that might cause glitches
  defp start_playback_monitoring(guild_id, sound_name) do
    # Spawn a monitoring process that checks connection health
    # every 2 seconds while audio is playing
    spawn(fn ->
      monitor_playback_connection(guild_id, sound_name, 0)
    end)
  end

  defp monitor_playback_connection(guild_id, sound_name, check_count) do
    # Stop monitoring after 30 checks (60 seconds) or if playback stopped
    if check_count < 30 and Voice.playing?(guild_id) do
      Process.sleep(2000)

      # Check if connection is still healthy
      if Voice.ready?(guild_id) do
        # Connection is healthy, continue monitoring
        monitor_playback_connection(guild_id, sound_name, check_count + 1)
      else
        # Connection lost during playback - log warning
        Logger.warning(
          "Voice connection lost during playback of #{sound_name} (check #{check_count + 1})"
        )

        # Try to continue monitoring in case it recovers
        monitor_playback_connection(guild_id, sound_name, check_count + 1)
      end
    else
      # Monitoring complete or playback stopped
      if check_count >= 30 do
        Logger.debug("Playback monitoring completed for #{sound_name}")
      end
    end
  end

  # Attempt to recover from specific error conditions
  defp attempt_recovery(guild_id, reason, attempt) when attempt < 2 do
    cond do
      # Connection issues - try to re-establish
      String.contains?(to_string(reason), "connected") or
          String.contains?(to_string(reason), "connection") ->
        Logger.info("Attempting to recover from connection error...")
        # Small delay then check if ready
        Process.sleep(200)

        if Voice.ready?(guild_id) do
          true
        else
          # Try to stop and re-check
          try do
            Voice.stop(guild_id)
            Process.sleep(100)
            Voice.ready?(guild_id)
          rescue
            _ -> false
          end
        end

      # Timeout or processing errors - just wait and retry
      String.contains?(to_string(reason), "timeout") or
          String.contains?(to_string(reason), "process") ->
        Logger.info("Waiting after timeout/process error...")
        Process.sleep(300)
        Voice.ready?(guild_id)

      # Unknown errors - minimal recovery attempt
      true ->
        false
    end
  end

  defp attempt_recovery(_guild_id, _reason, _attempt), do: false

  defp get_sound_path(sound_name) do
    Logger.info("Getting sound path for: #{sound_name}")
    ensure_sound_cache()

    case lookup_cached_sound(sound_name) do
      {:hit, {_type, input, volume}} -> {:ok, {input, volume}}
      :miss -> resolve_and_cache_sound(sound_name)
    end
  end

  defp lookup_cached_sound(sound_name) do
    case :ets.lookup(:sound_meta_cache, sound_name) do
      [{^sound_name, %{source_type: source, input: input, volume: volume}}] ->
        Logger.info(
          "Found sound in cache: #{inspect(%{source_type: source, input: input, volume: volume})}"
        )

        {:hit, {source, input, volume}}

      _ ->
        :miss
    end
  end

  defp resolve_and_cache_sound(sound_name) do
    case Soundboard.Repo.get_by(Sound, filename: sound_name) do
      nil ->
        Logger.error("Sound not found in database: #{sound_name}")
        {:error, "Sound not found"}

      %{source_type: "url", url: url, volume: volume} when is_binary(url) ->
        Logger.info("Found URL sound: #{url}")
        meta = %{source_type: "url", input: url, volume: volume || 1.0}
        cache_sound(sound_name, meta)
        {:ok, {meta.input, meta.volume}}

      %{source_type: "local", filename: filename, volume: volume} when is_binary(filename) ->
        path = resolve_upload_path(filename)
        Logger.info("Resolved local file path: #{path}")

        if File.exists?(path) do
          meta = %{source_type: "local", input: path, volume: volume || 1.0}
          cache_sound(sound_name, meta)
          {:ok, {meta.input, meta.volume}}
        else
          Logger.error("Local file not found: #{path}")
          {:error, "Sound file not found at #{path}"}
        end

      sound ->
        Logger.error("Invalid sound configuration: #{inspect(sound)}")
        {:error, "Invalid sound configuration"}
    end
  end

  defp resolve_upload_path(filename) do
    if File.exists?("/app/priv/static/uploads") do
      "/app/priv/static/uploads/#{filename}"
    else
      priv_dir = :code.priv_dir(:soundboard)
      Path.join([priv_dir, "static/uploads", filename])
    end
  end

  @doc """
  Removes any cached metadata for the given `sound_name` so future plays use fresh data.
  """
  def invalidate_cache(sound_name) when is_binary(sound_name) do
    ensure_sound_cache()
    :ets.delete(:sound_meta_cache, sound_name)
    :ok
  end

  def invalidate_cache(_), do: :ok

  defp cache_sound(sound_name, meta) do
    :ets.insert(:sound_meta_cache, {sound_name, meta})
  end
end
