defmodule Soundboard.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application
  alias SoundboardWeb.Live.PresenceHandler
  require Logger

  @impl true
  def start(_type, _args) do
    Logger.info("Starting Soundboard Application")

    # Initialize presence handler state
    PresenceHandler.init()

    # Base children that always start
    base_children = [
      SoundboardWeb.Telemetry,
      {Phoenix.PubSub, name: Soundboard.PubSub},
      SoundboardWeb.Presence,
      SoundboardWeb.Endpoint,
      {SoundboardWeb.AudioPlayer, []},
      Soundboard.Repo,
      SoundboardWeb.DiscordHandler.State
    ]

    # Add Discord bot only if not in test and not explicitly disabled
    children =
      if should_start_discord_bot?() do
        Logger.info("Starting Discord bot...")
        # Configure the Nostrum bot with the new API
        bot_options = %{
          name: SoundboardBot,
          consumer: SoundboardWeb.DiscordHandler,
          intents: [:guilds, :guild_messages, :guild_voice_states, :message_content],
          wrapped_token: fn -> Application.fetch_env!(:soundboard, :discord_token) end
        }

        base_children ++ [{Nostrum.Bot, bot_options}]
      else
        Logger.info("Discord bot disabled (test env or DISABLE_DISCORD_BOT=true)")
        base_children
      end

    opts = [strategy: :one_for_one, name: Soundboard.Supervisor]
    Supervisor.start_link(children, opts)
  end

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  @impl true
  def config_change(changed, _new, removed) do
    SoundboardWeb.Endpoint.config_change(changed, removed)
    :ok
  end

  # Check if Discord bot should be started
  defp should_start_discord_bot? do
    not_test = Application.get_env(:soundboard, :env) != :test
    not_disabled = System.get_env("DISABLE_DISCORD_BOT") not in ["true", "1", "yes"]
    not_test and not_disabled
  end
end
