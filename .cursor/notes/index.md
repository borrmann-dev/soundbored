# Soundbored - Project Notes Index

A self-hosted Discord soundboard app built with Phoenix/Elixir.

## Tech Stack

| Layer | Technology |
|-------|------------|
| Backend | Elixir 1.19, Phoenix 1.8, LiveView 1.1 |
| Database | SQLite (ecto_sqlite3) |
| Discord | Nostrum (bot + voice) |
| Auth | Discord OAuth (Ueberauth) |
| Styling | Tailwind CSS 3.4, Heroicons |
| Server | Bandit (HTTP adapter) |
| Audio | ffmpeg (transcoding) |
| Deploy | Docker, K3s, Helm, GitHub Actions |

## Directory Structure

```
lib/
├── soundboard/                    # Core domain logic
│   ├── application.ex             # OTP supervisor tree
│   ├── repo.ex                    # Ecto repo
│   ├── sound.ex                   # Sound schema + queries
│   ├── tag.ex, sound_tag.ex       # Tagging system
│   ├── favorites.ex               # Favorites context
│   ├── stats.ex                   # Play statistics
│   ├── volume.ex                  # Volume helpers
│   ├── user_sound_setting.ex      # Join/leave sounds
│   └── accounts/
│       ├── user.ex                # Discord user schema
│       ├── api_token.ex           # Token schema
│       └── api_tokens.ex          # Token context
│
├── soundboard_web/                # Phoenix web layer
│   ├── endpoint.ex                # HTTP endpoint
│   ├── router.ex                  # Routes + auth pipelines
│   ├── audio_player.ex            # GenServer: Discord voice playback
│   ├── discord_handler.ex         # Nostrum consumer: commands + events
│   ├── presence.ex                # Phoenix.Presence
│   ├── live/
│   │   ├── soundboard_live.ex     # Main soundboard LiveView
│   │   ├── stats_live.ex          # Statistics page
│   │   ├── favorites_live.ex      # Favorites page
│   │   ├── settings_live.ex       # API tokens page
│   │   ├── presence_live.ex       # Presence mixin
│   │   ├── presence_handler.ex    # Presence utilities
│   │   ├── upload_handler.ex      # File upload logic
│   │   ├── file_handler.ex        # File operations
│   │   ├── file_filter.ex         # Search/filter logic
│   │   └── tag_handler.ex         # Tag management
│   ├── controllers/
│   │   ├── auth_controller.ex     # OAuth callbacks
│   │   ├── upload_controller.ex   # Static file serving
│   │   └── api/sound_controller.ex # REST API
│   ├── components/
│   │   ├── core_components.ex     # Shared UI components
│   │   ├── layouts.ex             # Layout module
│   │   └── soundboard/            # Feature components
│   │       ├── edit_modal.ex
│   │       ├── delete_modal.ex
│   │       ├── upload_modal.ex
│   │       ├── volume_control.ex
│   │       └── tag_components.ex
│   └── plugs/
│       ├── basic_auth.ex          # HTTP basic auth
│       └── api_auth.ex            # Bearer token auth
│
assets/
├── js/
│   ├── app.js                     # Main JS + LiveView hooks
│   └── hooks/local_player.js      # Browser audio playback
├── css/app.css                    # Tailwind styles
└── tailwind.config.js

helm/                              # Kubernetes deployment
├── templates/                     # K8s manifests
├── values.yaml                    # Config
├── secrets.yaml                   # Secrets (gitignored)
└── *.sh                           # Helper scripts
```

## Notes Files

- [architecture.md](architecture.md) - OTP tree, modules, data flow, patterns
- [deployment.md](deployment.md) - Docker, Helm, CI/CD, Discord setup, troubleshooting

## Quick Commands

```bash
# Development
mix setup              # Install deps, DB, assets
mix phx.server         # Start at localhost:4000
iex -S mix phx.server  # Start with IEx shell

# Testing
mix test               # Run all tests
mix test path:line     # Run specific test
mix coveralls.html     # Coverage report

# Code Quality
mix format             # Format code
mix credo --strict     # Lint

# Helm (K3s)
./helm/install.sh      # Install chart
./helm/upgrade.sh      # Upgrade + restart
./helm/uninstall.sh    # Uninstall
```

## Routes

| Path | LiveView/Controller | Purpose |
|------|---------------------|---------|
| `/` | SoundboardLive | Main sound grid |
| `/stats` | StatsLive | Play statistics |
| `/favorites` | FavoritesLive | User favorites |
| `/settings` | SettingsLive | API tokens |
| `/auth/discord` | AuthController | OAuth start |
| `/auth/discord/callback` | AuthController | OAuth callback |
| `/api/sounds` | SoundController | REST API |
| `/uploads/*` | UploadController | Static files |

## API Endpoints

```bash
# List sounds
curl -H "Authorization: Bearer sb_xxx" https://host/api/sounds

# Play sound
curl -X POST -H "Authorization: Bearer sb_xxx" https://host/api/sounds/123/play

# Stop playback
curl -X POST -H "Authorization: Bearer sb_xxx" https://host/api/sounds/stop
```

## Discord Commands

| Command | Description |
|---------|-------------|
| `!join` | Bot joins your voice channel |
| `!leave` | Bot leaves voice channel |
