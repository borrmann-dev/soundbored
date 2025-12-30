# Soundbored - Project Notes Index

A self-hosted Discord soundboard app built with Phoenix/Elixir (forked from christomitov/soundbored).

## Project Overview

- **App**: `soundboard` (v1.7.0)
- **Framework**: Phoenix 1.8 + LiveView 1.1
- **Database**: SQLite (via Ecto + ecto_sqlite3)
- **Discord Bot**: Nostrum library
- **Styling**: Tailwind CSS + Heroicons
- **Auth**: Discord OAuth (Ueberauth)

## Key Directories

| Path | Purpose |
|------|---------|
| `lib/soundboard/` | Core domain: Sound, User, Favorites, Stats, Tags |
| `lib/soundboard_web/` | Phoenix web layer: LiveViews, Controllers, Components |
| `lib/soundboard_web/live/` | LiveViews: SoundboardLive, StatsLive, SettingsLive, FavoritesLive |
| `lib/soundboard_web/controllers/api/` | REST API (`sound_controller.ex`) |
| `assets/` | JS, CSS, Tailwind config |
| `config/` | Mix configs (dev, prod, test, runtime) |
| `priv/repo/migrations/` | Ecto migrations |
| `priv/static/uploads/` | Sound files + SQLite DB (in production) |
| `test/` | ExUnit tests mirroring lib structure |
| `.github/workflows/` | CI/CD pipeline (from k3s-demo - **needs updating**) |
| `helm/` | Kubernetes Helm chart (**needs updating for soundbored**) |

## Notes Files

- [architecture.md](architecture.md) - Core modules, OTP supervision tree, key patterns
- [deployment.md](deployment.md) - Docker, Helm, CI/CD configuration and required updates

## Quick Reference

### Commands
```bash
mix setup          # Install deps, setup DB, build assets
mix phx.server     # Start dev server at localhost:4000
mix test           # Run tests
mix credo          # Lint
mix format         # Format code
mix coveralls      # Coverage report
```

### Required Environment Variables
- `DISCORD_TOKEN` - Bot token
- `DISCORD_CLIENT_ID`, `DISCORD_CLIENT_SECRET` - OAuth
- `API_TOKEN` - REST API auth (legacy, prefer DB tokens)
- `SECRET_KEY_BASE` or `SECRET_KEY_BASE_FILE` - Session encryption
- `PHX_HOST`, `SCHEME` - URL config

### Key LiveView Routes
- `/` - Main soundboard (SoundboardLive)
- `/stats` - Play statistics (StatsLive)
- `/favorites` - User favorites (FavoritesLive)
- `/settings` - API tokens (SettingsLive)

## Forked Repo Notes

This repo was forked and `.github/` and `helm/` folders were added from a K3s CI/CD demo project. These need adaptation:

1. **Helm Chart** (`helm/`): References `k3s-ci-demo`, uses port 80 (should be 4000), missing env vars
2. **CI/CD** (`.github/workflows/ci-cd.yml`): Deploys to wrong namespace/app name, missing Elixir build step

See [deployment.md](deployment.md) for detailed migration checklist.
