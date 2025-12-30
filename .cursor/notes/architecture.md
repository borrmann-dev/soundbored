# Soundbored - Architecture Notes

## OTP Application Tree

```
Soundboard.Supervisor
├── SoundboardWeb.Telemetry
├── Phoenix.PubSub (Soundboard.PubSub)
├── SoundboardWeb.Presence
├── SoundboardWeb.Endpoint
├── SoundboardWeb.AudioPlayer (GenServer - audio playback)
├── Soundboard.Repo (Ecto + SQLite)
├── SoundboardWeb.DiscordHandler.State (GenServer - voice state tracking)
└── Nostrum.Bot (Discord gateway - not in test env)
```

## Core Modules

### Domain (`lib/soundboard/`)

| Module | Purpose |
|--------|---------|
| `Sound` | Ecto schema: filename, url, source_type, volume, tags, user |
| `Accounts.User` | Discord user (discord_id, username, avatar) |
| `Accounts.ApiToken(s)` | DB-backed API tokens per user |
| `Favorites` | User favorites context |
| `Stats` | Play tracking, recent plays, leaderboards |
| `Tag`, `SoundTag` | Many-to-many tagging system |
| `UserSoundSetting` | Per-user join/leave sound config |
| `Volume` | Volume conversion helpers (percent ↔ decimal) |

### Web (`lib/soundboard_web/`)

| Module | Purpose |
|--------|---------|
| `AudioPlayer` | GenServer for Discord voice playback via Nostrum |
| `DiscordHandler` | Nostrum consumer: !join, !leave commands, auto-join logic |
| `SoundboardLive` | Main LiveView: sound grid, search, tags, upload, edit |
| `StatsLive` | Stats dashboard with week picker |
| `SettingsLive` | API token management |
| `FavoritesLive` | Favorite sounds grid |
| `API.SoundController` | REST API: list sounds, play, stop |

### Key Patterns

1. **Sound Source Types**: `"local"` (file in uploads/) or `"url"` (remote audio)
2. **Audio Caching**: ETS cache (`:sound_meta_cache`) for fast playback lookups
3. **Presence**: Phoenix.Presence tracks online users via PubSub
4. **Auth Flow**: Discord OAuth → session → `fetch_current_user` plug → LiveView socket
5. **Join/Leave Sounds**: Triggered via `DiscordHandler` on voice state updates

## Database Schema

SQLite database at `priv/static/uploads/soundboard_prod.db` (prod) or `database.db` (dev).

Tables: `sounds`, `users`, `tags`, `sounds_tags`, `user_sound_settings`, `plays`, `favorites`, `api_tokens`

## PubSub Topics

- `"soundboard"` - Sound played events, file updates
- `"soundboard:presence"` - User presence tracking

