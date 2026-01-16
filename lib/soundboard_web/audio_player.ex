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
    # Recover voice channel state from DiscordHandler if available
    recovered_state = recover_voice_channel_state(state)
    # Schedule periodic voice connection check
    schedule_voice_check()
    {:ok, recovered_state}
  end

  # Recover voice channel state after restart by checking with DiscordHandler
  defp recover_voice_channel_state(state) do
    # Skip recovery in test environment where Discord isn't initialized
    if Application.get_env(:soundboard, :env) == :test do
      state
    else
      case SoundboardWeb.DiscordHandler.get_current_voice_channel() do
        {guild_id, channel_id} when not is_nil(guild_id) and not is_nil(channel_id) ->
          Logger.info("Recovered voice channel state: Guild #{guild_id}, Channel #{channel_id}")

          %{state | voice_channel: {guild_id, channel_id}}

        _ ->
          Logger.debug("No voice channel to recover")
          state
      end
    end
  rescue
    error ->
      Logger.warning("Failed to recover voice channel state: #{inspect(error)}")
      state
  catch
    :exit, _ ->
      Logger.warning("DiscordHandler not available for voice channel recovery")
      state
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

    # Clear current_playback task if it exists
    new_state = %{state | current_playback: nil}

    broadcast_success("All sounds stopped", "System")
    {:noreply, new_state}
  end

  def handle_cast(:stop_sound, state) do
    Logger.info("Attempted to stop sounds but no voice channel connected")
    broadcast_error("Bot is not connected to a voice channel")
    # Clear current_playback even if no voice channel
    {:noreply, %{state | current_playback: nil}}
  end

  def handle_cast({:play_sound, _sound_name, _username}, %{voice_channel: nil} = state) do
    broadcast_error("Bot is not connected to a voice channel. Use !join in Discord first.")
    {:noreply, state}
  end

  def handle_cast(
        {:play_sound, sound_name, username},
        %{voice_channel: {guild_id, channel_id}} = state
      ) do
    # Check if a sound is already playing or a playback task is active
    # This ensures only one sound can play at a time with no queue
    is_playing = check_playing_with_retries(guild_id, 3, 50)
    has_active_task = state.current_playback != nil

    if is_playing or has_active_task do
      Logger.info(
        "Blocking sound #{sound_name} - another sound is already playing (Voice.playing?: #{is_playing}, has_task: #{has_active_task})"
      )

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
    # Set current_playback immediately to block other requests
    # This ensures no queue - if a sound is requested while another is playing, it's blocked
    case get_sound_path(sound_name) do
      {:ok, {path_or_url, volume}} ->
        # Mark playback as active immediately to block concurrent requests
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

    # Note: URL validation removed from playback path to reduce load
    # URL sounds should be downloaded/cached before playback for best stability
    # Current implementation streams directly from URL (can cause glitches on network issues)

    # Double-check voice state right before playback
    timestamp_before_state_check = System.monotonic_time(:millisecond)
    voice_ready = Voice.ready?(guild_id)
    voice_playing = Voice.playing?(guild_id)

    Logger.info(
      "Voice state check - Ready: #{voice_ready}, Playing: #{voice_playing}, Timestamp: #{timestamp_before_state_check}ms, Source: #{source_type}, Input: #{inspect(play_input)}"
    )

    # If something is still playing, abort - this should not happen if blocking works correctly
    # but we check here as a safety measure
    cond do
      voice_playing ->
        Logger.warning(
          "Audio still playing when task started - this should be blocked at GenServer level"
        )

        broadcast_error("Ein Sound wird bereits abgespielt. Bitte warten...")
        :error

      Voice.ready?(guild_id) ->
        # Final stabilization check right before playback
        # This ensures connection is absolutely ready
        execute_playback(
          guild_id,
          play_input,
          play_type,
          source_type,
          volume,
          sound_name,
          username
        )

      true ->
        Logger.error("Voice connection lost right before playback")
        broadcast_error("Voice-Verbindung verloren. Bitte erneut versuchen.")
        :error
    end
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
    # Increased stabilization delay for both sources to ensure connection is fully ready
    # This helps prevent glitches at the start of playback
    # Both local and URL sources benefit from this delay
    stabilization_delay = 200

    timestamp_before_delay = System.monotonic_time(:millisecond)

    Logger.info(
      "Using stabilization delay: #{stabilization_delay}ms for #{source_type} source - Voice ready before: #{Voice.ready?(guild_id)}, Playing: #{Voice.playing?(guild_id)}"
    )

    Process.sleep(stabilization_delay)

    timestamp_after_delay = System.monotonic_time(:millisecond)
    actual_delay = timestamp_after_delay - timestamp_before_delay

    # Additional pre-playback check to ensure voice connection is absolutely ready
    # This double-check helps prevent glitches from unstable connections
    voice_ready_after_delay = Voice.ready?(guild_id)
    voice_playing_after_delay = Voice.playing?(guild_id)

    if voice_ready_after_delay do
      Logger.info(
        "Voice ready after stabilization (delay: #{actual_delay}ms) - Ready: #{voice_ready_after_delay}, Playing: #{voice_playing_after_delay}"
      )
    else
      Logger.warning(
        "Voice not ready after stabilization (delay: #{actual_delay}ms), waiting additional 100ms... - Ready: #{voice_ready_after_delay}, Playing: #{voice_playing_after_delay}"
      )

      Process.sleep(100)

      voice_ready_after_extra = Voice.ready?(guild_id)
      voice_playing_after_extra = Voice.playing?(guild_id)

      Logger.info(
        "After extra wait - Ready: #{voice_ready_after_extra}, Playing: #{voice_playing_after_extra}"
      )
    end

    # Nostrum v0.11.0-dev (master branch) - correct configuration
    #
    # Important: executable_args does NOT exist in Nostrum v0.11.0-dev!
    # Valid options are: start_pos, duration, realtime (default true), volume, filter
    #
    # realtime: true (default) - FFmpeg outputs at real-time pace, not "as fast as possible"
    # This is usually correct to prevent FFmpeg from producing too fast
    #
    # filter: Use this to fix audio format (only way in Nostrum to control format)
    # aresample=48000: Resample to 48kHz (Discord requirement)
    # aformat=sample_fmts=s16:channel_layouts=stereo: 16-bit signed, stereo
    #
    # audio_frames_per_burst: 20 is more stable for network jitter and VM Docker jitter
    # 10 is default, 1 only for ultra-short sounds that sometimes get swallowed
    clamped_vol = clamp_volume(volume)

    # Correct play options for Nostrum v0.11.0-dev
    play_options = [
      volume: clamped_vol,
      realtime: true,
      filter: "aresample=48000, aformat=sample_fmts=s16:channel_layouts=stereo"
    ]

    # Log actual Nostrum config values to verify they're loaded
    actual_frames = Application.get_env(:nostrum, :audio_frames_per_burst, :not_set)
    actual_timeout = Application.get_env(:nostrum, :audio_timeout, :not_set)

    timestamp_before_play = System.monotonic_time(:millisecond)

    Logger.info(
      "Play options: #{inspect(play_options)} (source_type: #{source_type}, original_volume: #{volume})"
    )

    Logger.info(
      "Nostrum Config - frames_per_burst: #{inspect(actual_frames)} (20 recommended for stability), timeout: #{inspect(actual_timeout)}"
    )

    Logger.info(
      "Pre-playback state - Ready: #{Voice.ready?(guild_id)}, Playing: #{Voice.playing?(guild_id)}, Timestamp: #{timestamp_before_play}ms"
    )

    Logger.info(
      "Using Nostrum filter for audio format - realtime: true, filter: #{play_options[:filter]}"
    )

    # Keep track of attempts
    # Increased retries for both sources since glitches can occur with both
    max_retries = 5

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
    # Increased checks and delays for better reliability
    checks =
      for _ <- 1..7 do
        Process.sleep(50)
        Voice.ready?(guild_id)
      end

    # At least 6 out of 7 checks should pass (allows for minor fluctuations)
    # Stricter requirement for better reliability
    passing_checks = Enum.count(checks, & &1)
    passing_checks >= 6
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
    # Log detailed state before playback attempt
    voice_ready_before = Voice.ready?(guild_id)
    voice_playing_before = Voice.playing?(guild_id)
    timestamp_before = System.monotonic_time(:millisecond)

    Logger.info(
      "Voice.play attempt #{attempt + 1}/#{max_retries} - Ready: #{voice_ready_before}, Playing: #{voice_playing_before}, Input: #{inspect(play_input)}, Type: #{inspect(play_type)}"
    )

    case Voice.play(guild_id, play_input, play_type, play_options) do
      :ok ->
        timestamp_after = System.monotonic_time(:millisecond)
        play_duration = timestamp_after - timestamp_before
        voice_ready_after = Voice.ready?(guild_id)
        voice_playing_after = Voice.playing?(guild_id)

        Logger.info(
          "Voice.play succeeded for #{sound_name} (attempt #{attempt + 1}) - Duration: #{play_duration}ms, Ready: #{voice_ready_after}, Playing: #{voice_playing_after}, Volume: #{inspect(play_options[:volume])}"
        )

        # Monitoring disabled to reduce load - can cause jitter with multiple sounds
        # If needed, enable only for debugging or error cases
        # start_playback_monitoring(guild_id, sound_name)

        track_play_if_needed(sound_name, username)
        broadcast_success(sound_name, username)
        :ok

      {:error, "Audio already playing in voice channel."} ->
        timestamp_error = System.monotonic_time(:millisecond)

        Logger.warning(
          "Audio still playing on attempt #{attempt + 1}, stopping and retrying... - Ready: #{Voice.ready?(guild_id)}, Playing: #{Voice.playing?(guild_id)}, Timestamp: #{timestamp_error}ms"
        )

        # Force stop the current audio
        Voice.stop(guild_id)
        # Longer delay to ensure stop completes and connection stabilizes
        # Exponential backoff with longer delays: 200ms, 400ms, 600ms
        stop_delay = 200 * (attempt + 1)
        Logger.info("Waiting #{stop_delay}ms after stop before retry...")
        Process.sleep(stop_delay)

        # Verify stop completed before retrying
        voice_playing_after_stop = Voice.playing?(guild_id)
        voice_ready_after_stop = Voice.ready?(guild_id)
        timestamp_after_stop = System.monotonic_time(:millisecond)

        if voice_playing_after_stop do
          Logger.warning(
            "Audio still playing after stop (delay: #{stop_delay}ms), waiting longer... - Ready: #{voice_ready_after_stop}, Playing: #{voice_playing_after_stop}, Timestamp: #{timestamp_after_stop}ms"
          )

          Process.sleep(300)
          Voice.stop(guild_id)
          Process.sleep(200)

          voice_playing_after_extra = Voice.playing?(guild_id)
          voice_ready_after_extra = Voice.ready?(guild_id)

          Logger.info(
            "After extra stop wait - Ready: #{voice_ready_after_extra}, Playing: #{voice_playing_after_extra}"
          )
        else
          Logger.info(
            "Audio stopped successfully after #{stop_delay}ms - Ready: #{voice_ready_after_stop}, Playing: #{voice_playing_after_stop}"
          )
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
        timestamp_error = System.monotonic_time(:millisecond)
        voice_ready_on_error = Voice.ready?(guild_id)
        voice_playing_on_error = Voice.playing?(guild_id)

        Logger.error(
          "Voice.play failed: #{inspect(reason)} (attempt #{attempt + 1}/#{max_retries}) - Ready: #{voice_ready_on_error}, Playing: #{voice_playing_on_error}, Timestamp: #{timestamp_error}ms, Input: #{inspect(play_input)}"
        )

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
      [{^sound_name, %{source_type: "local", input: cached_path}}] ->
        # Use cached local file (either original local file or downloaded URL cache)
        Logger.info("Using cached local file: #{cached_path}")
        {cached_path, :url, "local"}

      [{^sound_name, %{source_type: "url", input: url}}] ->
        # Fallback: URL not yet cached, use direct streaming
        Logger.info("Using URL directly for remote sound (not yet cached): #{url}")
        {url, :url, "url"}

      _ ->
        # Not in cache, resolve and cache (will download URL sounds)
        resolve_and_prepare_play_input(sound_name, path_or_url)
    end
  end

  # Resolve sound path and prepare play input
  defp resolve_and_prepare_play_input(sound_name, path_or_url) do
    case get_sound_path(sound_name) do
      {:ok, {resolved_path, _volume}} ->
        determine_play_input_type(resolved_path)

      {:error, reason} ->
        Logger.error("Failed to resolve sound path: #{inspect(reason)}")
        # Fallback to original path_or_url
        {path_or_url, :url, "unknown"}
    end
  end

  # Determine if resolved path is URL or local file
  defp determine_play_input_type(resolved_path) do
    if String.starts_with?(resolved_path, "http://") or
         String.starts_with?(resolved_path, "https://") do
      Logger.info("Using URL directly (download in progress): #{resolved_path}")
      {resolved_path, :url, "url"}
    else
      Logger.info("Using resolved local file: #{resolved_path}")
      {resolved_path, :url, "local"}
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
        resolve_url_sound(sound_name, url, volume)

      %{source_type: "local", filename: filename, volume: volume} when is_binary(filename) ->
        resolve_local_sound(sound_name, filename, volume)

      sound ->
        Logger.error("Invalid sound configuration: #{inspect(sound)}")
        {:error, "Invalid sound configuration"}
    end
  end

  # Resolve and cache URL sound
  defp resolve_url_sound(sound_name, url, volume) do
    Logger.info("Found URL sound: #{url}")
    # Download and cache URL sound locally for stable playback
    case download_and_cache_url_sound(sound_name, url) do
      {:ok, local_path} ->
        cache_and_return_sound(sound_name, "local", local_path, volume)

      {:error, reason} ->
        Logger.error("Failed to download URL sound #{url}: #{inspect(reason)}")
        # Fallback to direct URL streaming if download fails
        cache_and_return_sound(sound_name, "url", url, volume)
    end
  end

  # Resolve and cache local sound
  defp resolve_local_sound(sound_name, filename, volume) do
    path = resolve_upload_path(filename)
    Logger.info("Resolved local file path: #{path}")

    if File.exists?(path) do
      cache_and_return_sound(sound_name, "local", path, volume)
    else
      Logger.error("Local file not found: #{path}")
      {:error, "Sound file not found at #{path}"}
    end
  end

  # Cache sound metadata and return result
  defp cache_and_return_sound(sound_name, source_type, input, volume) do
    meta = %{source_type: source_type, input: input, volume: volume || 1.0}
    cache_sound(sound_name, meta)
    {:ok, {input, meta.volume}}
  end

  @doc false
  # Download URL sound and cache it locally for stable playback
  # Called from UploadHandler for background downloads
  def download_and_cache_url_sound(_sound_name, url) do
    # Generate URL hash for cache lookup
    url_hash = :crypto.hash(:md5, url) |> Base.encode16(case: :lower) |> String.slice(0, 16)
    extension = url_file_extension(url) || ".mp3"

    # First, try to find existing cached file by hash (ignoring timestamp)
    case find_cached_file_by_hash(url_hash, extension) do
      {:found, existing_path} ->
        # Found existing cache, verify it's still valid
        case check_cache_validity(url, existing_path) do
          :valid ->
            Logger.info("URL sound already cached and valid: #{existing_path}")
            {:ok, existing_path}

          :needs_refresh ->
            Logger.info("Cached file outdated, re-downloading: #{existing_path}")
            # Delete old cache file and download fresh
            File.rm(existing_path)
            File.rm(existing_path <> ".etag")
            download_fresh_with_timestamp(url, url_hash, extension)
        end

      :not_found ->
        # No existing cache, download fresh
        download_fresh_with_timestamp(url, url_hash, extension)
    end
  end

  # Find existing cached file by hash (ignoring timestamp in filename)
  defp find_cached_file_by_hash(url_hash, extension) do
    # Get upload directory path
    upload_dir =
      if File.exists?("/app/priv/static/uploads") do
        "/app/priv/static/uploads"
      else
        priv_dir = :code.priv_dir(:soundboard)
        Path.join([priv_dir, "static/uploads"])
      end

    case File.ls(upload_dir) do
      {:ok, files} ->
        # Look for files matching pattern: url_{hash}_*.{ext}
        pattern = "url_#{url_hash}_"

        matching_file =
          Enum.find(files, fn file ->
            String.starts_with?(file, pattern) and String.ends_with?(file, extension)
          end)

        case matching_file do
          nil -> :not_found
          filename -> {:found, resolve_upload_path(filename)}
        end

      {:error, _} ->
        :not_found
    end
  end

  # Download fresh file with timestamp in filename
  # Also cleans up old versions with the same hash
  defp download_fresh_with_timestamp(url, url_hash, extension) do
    # Clean up old cache files with the same hash before downloading new one
    cleanup_old_cache_files(url_hash, extension)

    timestamp = System.system_time(:second)
    cache_filename = "url_#{url_hash}_#{timestamp}#{extension}"
    cache_path = resolve_upload_path(cache_filename)

    download_fresh(url, cache_path)
  end

  # Clean up old cache files with the same hash
  # This prevents accumulation of old cache files when URLs are re-downloaded
  defp cleanup_old_cache_files(url_hash, extension) do
    upload_dir =
      if File.exists?("/app/priv/static/uploads") do
        "/app/priv/static/uploads"
      else
        priv_dir = :code.priv_dir(:soundboard)
        Path.join([priv_dir, "static/uploads"])
      end

    pattern = "url_#{url_hash}_"

    case File.ls(upload_dir) do
      {:ok, files} ->
        # Find all files matching this hash pattern
        old_files =
          files
          |> Enum.filter(fn file ->
            String.starts_with?(file, pattern) and String.ends_with?(file, extension)
          end)
          |> Enum.map(fn filename ->
            file_path = resolve_upload_path(filename)
            etag_path = file_path <> ".etag"
            {file_path, etag_path}
          end)

        # Delete all old cache files (we're about to download a fresh one)
        Enum.each(old_files, fn {file_path, etag_path} ->
          File.rm(file_path)
          File.rm(etag_path)
          Logger.debug("Cleaned up old cache file: #{Path.basename(file_path)}")
        end)

      {:error, _} ->
        :ok
    end
  end

  # Download fresh file (used for first-time download or cache refresh)
  defp download_fresh(url, cache_path) do
    # Download in background to avoid blocking
    Task.start(fn ->
      Logger.info("Downloading URL sound to cache: #{url} -> #{cache_path}")

      try do
        download_url_to_file(url, cache_path)
      rescue
        error ->
          Logger.error("Background download task crashed: #{inspect(error)}")
      catch
        :exit, reason ->
          Logger.error("Background download task exited: #{inspect(reason)}")
      end
    end)

    # For first-time access, try to download synchronously with timeout
    # If it takes too long, fall back to streaming
    try do
      case download_url_to_file(url, cache_path, timeout: 10_000) do
        :ok ->
          Logger.info("URL sound cached successfully: #{cache_path}")
          {:ok, cache_path}

        {:error, :timeout} ->
          Logger.warning("URL download timeout, will use streaming for now")
          {:error, :timeout}

        {:error, reason} ->
          Logger.warning("URL download failed: #{inspect(reason)}, will use streaming")
          {:error, reason}
      end
    rescue
      error ->
        Logger.error("URL download crashed: #{inspect(error)}, will use streaming")
        {:error, inspect(error)}
    catch
      :exit, reason ->
        Logger.error("URL download exited: #{inspect(reason)}, will use streaming")
        {:error, inspect(reason)}
    end
  end

  # Check if cached file is still valid by comparing ETag header
  # ETag is the most reliable way to detect content changes
  defp check_cache_validity(url, cache_path) do
    # Check server headers to see if file changed
    case HTTPoison.head(url, [], follow_redirect: true, timeout: 5_000) do
      {:ok, %HTTPoison.Response{status_code: 200, headers: headers}} ->
        validate_etag(headers, cache_path)

      {:ok, %HTTPoison.Response{status_code: status}} ->
        Logger.warning("HEAD request failed with status #{status}, assuming cache valid")
        :valid

      {:error, reason} ->
        # Network error, assume cache is valid to avoid unnecessary downloads
        Logger.warning("HEAD request failed: #{inspect(reason)}, assuming cache valid")
        :valid
    end
  end

  # Validate ETag header against cached ETag
  defp validate_etag(headers, cache_path) do
    etag = get_header(headers, "etag")

    if etag != nil do
      compare_etag(etag, cache_path)
    else
      # No ETag available, assume cache is valid (conservative approach)
      :valid
    end
  end

  # Compare server ETag with cached ETag
  defp compare_etag(etag, cache_path) do
    etag_file = cache_path <> ".etag"
    cached_etag = read_cached_etag(etag_file)

    if cached_etag == etag do
      :valid
    else
      # ETag changed, update and mark for refresh
      File.write(etag_file, etag)
      Logger.info("ETag changed (#{cached_etag} -> #{etag}), cache needs refresh")
      :needs_refresh
    end
  end

  # Read cached ETag from file
  defp read_cached_etag(etag_file) do
    if File.exists?(etag_file), do: File.read!(etag_file) |> String.trim(), else: nil
  end

  # Helper to get header value (case-insensitive)
  defp get_header(headers, key) do
    key_lower = String.downcase(key)
    Enum.find_value(headers, fn {k, v} -> if String.downcase(k) == key_lower, do: v end)
  end

  # Save ETag to file for future cache validation
  defp save_etag_if_available(dest_path, response) do
    etag = get_header(response.headers, "etag")

    if etag != nil do
      etag_file = dest_path <> ".etag"
      File.write(etag_file, etag)
      Logger.debug("Saved ETag for cache validation: #{etag_file}")
    end
  end

  # Download URL to local file
  defp download_url_to_file(url, dest_path, opts \\ []) do
    timeout = Keyword.get(opts, :timeout, 30_000)
    # Trim URL to prevent parsing errors from leading/trailing whitespace
    trimmed_url = String.trim(url)

    # Validate URL format before attempting download
    if String.starts_with?(trimmed_url, ["http://", "https://"]) do
      perform_http_download(trimmed_url, dest_path, timeout)
    else
      Logger.error("Invalid URL format: #{inspect(trimmed_url)}")
      {:error, "Invalid URL format"}
    end
  end

  # Perform the actual HTTP download
  defp perform_http_download(trimmed_url, dest_path, timeout) do
    case HTTPoison.get(trimmed_url, [], recv_timeout: timeout, follow_redirect: true) do
      {:ok, %HTTPoison.Response{status_code: 200, body: body} = response} ->
        write_downloaded_file(dest_path, body, response)

      {:ok, %HTTPoison.Response{status_code: status}} ->
        Logger.error("URL returned non-200 status: #{status}")
        {:error, "HTTP #{status}"}

      {:error, %HTTPoison.Error{reason: :timeout}} ->
        {:error, :timeout}

      {:error, %HTTPoison.Error{reason: reason}} ->
        Logger.error("HTTP request failed: #{inspect(reason)}")
        {:error, reason}
    end
  end

  # Write downloaded file to disk
  defp write_downloaded_file(dest_path, body, response) do
    # Ensure directory exists
    File.mkdir_p!(Path.dirname(dest_path))

    case File.write(dest_path, body) do
      :ok ->
        Logger.info("Downloaded URL sound to: #{dest_path} (#{byte_size(body)} bytes)")
        # Save ETag if available for future cache validation
        save_etag_if_available(dest_path, response)
        :ok

      {:error, reason} ->
        Logger.error("Failed to write cached file: #{inspect(reason)}")
        {:error, reason}
    end
  end

  # Extract file extension from URL (same logic as UploadHandler)
  defp url_file_extension(url) when is_binary(url) do
    # Try to get extension from URL path
    case URI.parse(url) do
      %URI{path: path} when is_binary(path) ->
        ext = Path.extname(path)

        if ext in ~w(.mp3 .wav .ogg .m4a .flac .aac) do
          ext
        else
          # Default to .mp3 if no extension found
          ".mp3"
        end

      _ ->
        ".mp3"
    end
  end

  defp url_file_extension(_), do: ".mp3"

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
  Also cleans up cached files for URL sounds if they exist.
  """
  def invalidate_cache(sound_name) when is_binary(sound_name) do
    ensure_sound_cache()

    # Check if there's a cached file for this sound
    case :ets.lookup(:sound_meta_cache, sound_name) do
      [{^sound_name, %{source_type: "local", input: cached_path}}] ->
        # Check if this is a URL cache file (starts with "url_")
        if String.starts_with?(Path.basename(cached_path), "url_") do
          # Try to delete cached file and ETag file (ignore errors if files don't exist)
          File.rm(cached_path)
          File.rm(cached_path <> ".etag")
          Logger.info("Deleted cached URL file and ETag: #{cached_path}")
        end

      _ ->
        :ok
    end

    :ets.delete(:sound_meta_cache, sound_name)
    :ok
  end

  def invalidate_cache(_), do: :ok

  defp cache_sound(sound_name, meta) do
    :ets.insert(:sound_meta_cache, {sound_name, meta})
  end
end
