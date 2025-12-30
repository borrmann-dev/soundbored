# Soundbored - Project Notes Index

A self-hosted Discord soundboard app built with Phoenix/Elixir (forked from christomitov/soundbored).

## Project Overview

- **App**: `soundboard` (v1.7.0)
- **Framework**: Phoenix 1.8 + LiveView 1.1
- **Database**: SQLite (via Ecto + ecto_sqlite3)
- **Discord Bot**: Nostrum library
- **Styling**: Tailwind CSS + Heroicons
- **Auth**: Discord OAuth (Ueberauth)
- **Deployment**: Kubernetes (K3s) via Helm + GitHub Actions CI/CD

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
| `.github/workflows/` | CI/CD pipeline |
| `helm/` | Kubernetes Helm chart |

## Notes Files

- [architecture.md](architecture.md) - Core modules, OTP supervision tree, key patterns
- [deployment.md](deployment.md) - Docker, Helm, CI/CD, troubleshooting

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

### Helm Scripts
```bash
./helm/install.sh    # Install (auto-uses secrets.yaml)
./helm/upgrade.sh    # Upgrade + restart pods
./helm/uninstall.sh  # Uninstall (prompts for PVC/namespace deletion)
```

### Key LiveView Routes
- `/` - Main soundboard (SoundboardLive)
- `/stats` - Play statistics (StatsLive)
- `/favorites` - User favorites (FavoritesLive)
- `/settings` - API tokens (SettingsLive)

### Discord Bot Commands
- `!join` - Bot joins your voice channel
- `!leave` - Bot leaves voice channel
