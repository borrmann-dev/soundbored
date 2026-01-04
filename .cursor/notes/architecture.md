# Soundbored - Architecture Notes

## OTP Supervision Tree

```
Soundboard.Supervisor (one_for_one)
├── SoundboardWeb.Telemetry          # Metrics
├── Phoenix.PubSub (Soundboard.PubSub)
├── SoundboardWeb.Presence           # User presence tracking
├── SoundboardWeb.Endpoint           # Bandit HTTP on port 4000
├── SoundboardWeb.AudioPlayer        # GenServer: voice playback
├── Soundboard.Repo                  # Ecto + SQLite
├── SoundboardWeb.DiscordHandler.State # GenServer: voice state cache
└── Nostrum.Bot                      # Discord gateway (disabled in test)
```

## Core Modules

### Domain Layer (`lib/soundboard/`)

| Module | Schema | Purpose |
|--------|--------|---------|
| `Sound` | `sounds` | filename, url, source_type, volume, tags, user |
| `Tag` | `tags` | name |
| `SoundTag` | `sounds_tags` | Many-to-many join table |
| `Accounts.User` | `users` | discord_id, username, avatar |
| `Accounts.ApiToken` | `api_tokens` | token_hash, user_id, label, revoked_at |
| `Accounts.ApiTokens` | - | Context: generate, verify, revoke tokens |
| `Favorites.Favorite` | `favorites` | user_id, sound_id (max 16 per user) |
| `Stats.Play` | `plays` | sound_name, user_id, inserted_at |
| `UserSoundSetting` | `user_sound_settings` | Per-user join/leave sound config |
| `Volume` | - | Percent ↔ decimal conversion helpers |

### Web Layer (`lib/soundboard_web/`)

| Module | Type | Purpose |
|--------|------|---------|
| `AudioPlayer` | GenServer | Manages Discord voice playback via Nostrum |
| `DiscordHandler` | Nostrum.Consumer | `!join`, `!leave`, auto-join, join/leave sounds |
| `DiscordHandler.State` | GenServer | Tracks user voice states |
| `SoundboardLive` | LiveView | Main UI: grid, search, upload, edit |
| `StatsLive` | LiveView | Stats dashboard with week picker |
| `FavoritesLive` | LiveView | Favorite sounds grid |
| `SettingsLive` | LiveView | API token management |
| `PresenceLive` | Macro | Mixin for presence tracking in LiveViews |
| `PresenceHandler` | Module | Presence utilities, color assignment |
| `UploadHandler` | Module | File upload logic (local + URL) |
| `FileHandler` | Module | File operations, save uploads |
| `FileFilter` | Module | Search/filter sounds |
| `TagHandler` | Module | Tag CRUD operations |

## Data Flow

### Sound Playback Flow

```
User clicks sound → SoundboardLive.handle_event("play")
    → AudioPlayer.play_sound(filename, username)
    → GenServer.cast(:play_sound)
    → resolve_and_cache_sound() [ETS cache or DB lookup]
    → ensure_voice_ready() [join if needed]
    → Voice.play(guild_id, path_or_url, :url, [volume: x])
    → track_play_if_needed() [Stats.track_play]
    → broadcast_success() [PubSub → all clients]
```

### Upload Flow

```
User opens upload modal → selects file or enters URL
    → validate (size, type) → LiveView progress
    → handle_event("upload") → UploadHandler.handle_upload()
    → Local: FileHandler.save_upload() → write to /priv/static/uploads/
    → URL: store URL directly in DB
    → Sound.changeset() → Repo.insert()
    → broadcast_file_added() → all clients update
```

### Auth Flow

```
User visits / → ensure_authenticated_user plug
    → No session? → redirect to /auth/discord
    → Discord OAuth → AuthController.callback
    → Upsert User in DB → set session[:user_id]
    → Redirect to original path or /
```

## Key Patterns

### 1. Sound Source Types

```elixir
# Local file (stored in /priv/static/uploads/)
%Sound{source_type: "local", filename: "sound.mp3", url: nil}

# Remote URL (streamed directly, not downloaded)
%Sound{source_type: "url", filename: "name.mp3", url: "https://..."}
```

### 2. ETS Sound Cache

`AudioPlayer` uses ETS (`:sound_meta_cache`) for fast lookups on hot path:

```elixir
# Cache structure
{sound_name, %{source_type: "local"|"url", input: path_or_url, volume: 0.0..1.5}}

# Invalidate on sound update/delete
AudioPlayer.invalidate_cache(sound_name)
```

### 3. PubSub Topics

| Topic | Events |
|-------|--------|
| `"soundboard"` | `:sound_played`, `:file_added`, `:file_deleted`, `:file_updated`, `:error`, `:stats_updated` |
| `"soundboard:presence"` | `presence_diff` |
| `"stats"` | `:stats_updated` |

### 4. Presence Tracking

```elixir
# In LiveView mount (via PresenceLive mixin)
Presence.track(self(), "soundboard:presence", socket.id, %{
  user: %{username: user.username, avatar: user.avatar, color: color},
  online_at: System.system_time(:second)
})
```

### 5. Join/Leave Sounds

Per-user sounds triggered by `DiscordHandler` on `VOICE_STATE_UPDATE`:

```elixir
# UserSoundSetting schema
%UserSoundSetting{user_id: 1, sound_id: 5, is_join_sound: true, is_leave_sound: false}

# Lookup
Sound.get_user_join_sound(user_id)  # Returns filename or nil
Sound.get_user_leave_sound(user_id)
```

### 6. API Token System

```elixir
# Generate (returns raw token once, stores hash)
{:ok, "sb_xxx...", %ApiToken{}} = ApiTokens.generate_token(user, %{label: "My App"})

# Verify (hashes input, compares to stored hash)
{:ok, user, token} = ApiTokens.verify_token("sb_xxx...")

# Revoke
:ok = ApiTokens.revoke_token(user, token_id)
```

## Database Schema

SQLite at `priv/static/uploads/soundboard_prod.db` (production).

```
sounds           (id, filename, url, source_type, description, volume, user_id, timestamps)
users            (id, discord_id, username, avatar, timestamps)
tags             (id, name, timestamps)
sounds_tags      (id, sound_id, tag_id)
user_sound_settings (id, user_id, sound_id, is_join_sound, is_leave_sound)
plays            (id, sound_name, user_id, inserted_at)
favorites        (id, user_id, sound_id, timestamps)
api_tokens       (id, user_id, token_hash, token, label, last_used_at, revoked_at, timestamps)
```

## Environment Variables

| Variable | Required | Default | Purpose |
|----------|----------|---------|---------|
| `DISCORD_TOKEN` | ✅ | - | Bot token for Discord gateway |
| `DISCORD_CLIENT_ID` | ✅ | - | OAuth client ID |
| `DISCORD_CLIENT_SECRET` | ✅ | - | OAuth client secret |
| `SECRET_KEY_BASE` | ✅ | - | Phoenix session encryption |
| `PHX_HOST` | ✅ | localhost | Hostname for URLs |
| `SCHEME` | ✅ | http | http or https |
| `PHX_SERVER` | ✅ | true | Must be true in production |
| `AUTO_JOIN` | ❌ | false | Auto-join voice channels |
| `BASIC_AUTH_USERNAME` | ❌ | - | HTTP basic auth (optional) |
| `BASIC_AUTH_PASSWORD` | ❌ | - | HTTP basic auth (optional) |

## LiveView Hooks (JavaScript)

| Hook | Purpose |
|------|---------|
| `LocalPlayer` | Browser-side audio playback with volume boost |
| `VolumeSlider` | Volume control with debounce |
| `TagInput` | Tag autocomplete |
| `SearchInput` | Debounced search |

## Testing Patterns

```elixir
# Create test user
user = insert_user()

# Authenticated LiveView test
{:ok, view, _html} = 
  conn
  |> log_in_user(user)
  |> live(~p"/")

# File upload mock
file_upload(lv, "#audio-form", [%{name: "test.mp3", content: "...", type: "audio/mpeg"}])
```
