# Soundbored

> **Fork of [christomitov/soundbored](https://github.com/christomitov/soundbored)** - Original project with 230+ stars ⭐

A self-hosted Discord soundboard for playing sounds in voice channels. Unlimited sounds, no cost, full control.

This fork adds Kubernetes/Helm deployment support and CI/CD via GitHub Actions.

<img width="1468" alt="Soundbored Screenshot" src="https://github.com/user-attachments/assets/4a504100-5ef9-47bc-b406-35b67837e116" />

## Features

- 🎵 Upload and play sounds in Discord voice channels
- 🏷️ Tag-based organization and search
- ⭐ Personal favorites per user
- 📊 Play statistics and leaderboards
- 🔔 Join/leave sounds per user
- 🔐 Discord OAuth authentication
- 🌐 REST API for external integrations
- 👥 Multi-user support

## Quick Start

### Option 1: Docker (Simplest)

```bash
# 1. Create environment file
cp .env.example .env
# Edit .env with your Discord credentials

# 2. Run container
docker run -d -p 4000:4000 --env-file ./.env ghcr.io/borrmann-dev/soundbored
```

### Option 2: Kubernetes with Helm

```bash
# 1. Clone and configure secrets
cp helm/secrets.yaml.example helm/secrets.yaml
# Edit helm/secrets.yaml with your Discord credentials

# 2. Install
./helm/install.sh

# 3. Upgrade (after changes)
./helm/upgrade.sh

# 4. Uninstall
./helm/uninstall.sh
```

## Discord Setup

### 1. Create Discord Application

1. Go to [Discord Developer Portal](https://discord.com/developers/applications)
2. Click **New Application** and give it a name

### 2. Configure Bot

1. Go to **Bot** section
2. Click **Reset Token** and copy the token → `DISCORD_TOKEN`
3. Enable **Privileged Gateway Intents**:
   - ✅ **PRESENCE INTENT**
   - ✅ **SERVER MEMBERS INTENT**
   - ✅ **MESSAGE CONTENT INTENT**

### 3. Configure OAuth2

1. Go to **OAuth2** section
2. Copy **Client ID** → `DISCORD_CLIENT_ID`
3. Click **Reset Secret** and copy → `DISCORD_CLIENT_SECRET`
4. Add **Redirect URL**:
   - Local: `http://localhost:4000/auth/discord/callback`
   - Production: `https://your-domain.com/auth/discord/callback`

### 4. Invite Bot to Server

1. Go to **OAuth2** → **URL Generator**
2. Select **Guild Install**
3. Scope: `bot`
4. Bot Permissions:
   - ✅ Send Messages
   - ✅ Read Message History
   - ✅ View Channels
   - ✅ Connect
   - ✅ Speak
5. Copy URL → Open in browser → Select server → Authorize

## Usage

### Bot Commands

| Command | Action |
|---------|--------|
| `!join` | Bot joins your voice channel |
| `!leave` | Bot leaves voice channel |

### Web Interface

1. Visit your Soundbored URL
2. Login with Discord
3. Upload sounds (MP3, WAV, OGG, M4A up to 25MB)
4. Click any sound to play in Discord voice channel

### Features

- **Search**: Filter sounds by name
- **Tags**: Click tags to filter, add tags to organize
- **Favorites**: Star sounds for quick access at `/favorites`
- **Stats**: View play statistics at `/stats`
- **Settings**: Manage API tokens at `/settings`
- **Random**: Play a random sound (respects current filters)
- **Stop**: Stop all playing sounds

## Environment Variables

| Variable | Required | Description |
|----------|----------|-------------|
| `DISCORD_TOKEN` | ✅ | Bot token from Discord Developer Portal |
| `DISCORD_CLIENT_ID` | ✅ | OAuth Client ID |
| `DISCORD_CLIENT_SECRET` | ✅ | OAuth Client Secret |
| `SECRET_KEY_BASE` | ✅ | Session encryption key (`openssl rand -base64 48`) |
| `PHX_HOST` | ✅ | Your domain (e.g., `soundbored.example.com`) |
| `SCHEME` | ✅ | `http` or `https` |
| `PHX_SERVER` | ✅ | Set to `true` in production |
| `AUTO_JOIN` | ❌ | `true` to auto-join voice channels |
| `BASIC_AUTH_USERNAME` | ❌ | HTTP basic auth username |
| `BASIC_AUTH_PASSWORD` | ❌ | HTTP basic auth password |

## Deployment Options

### Docker Compose

```bash
docker compose up -d
```

Uses `.env` file for configuration. Volume mounts for persistent storage.

### Kubernetes (Helm)

The `helm/` directory contains a complete Helm chart:

```
helm/
├── values.yaml          # Configuration
├── secrets.yaml         # Secrets (gitignored!)
├── secrets.yaml.example # Secrets template
├── install.sh           # Install script
├── upgrade.sh           # Upgrade script
├── uninstall.sh         # Uninstall script
└── templates/           # K8s manifests
```

**Prerequisites:**
- Kubernetes cluster with NGINX Ingress
- cert-manager for TLS (optional)
- `local-path` storage class

**Installation:**

```bash
# Configure secrets
cp helm/secrets.yaml.example helm/secrets.yaml
vim helm/secrets.yaml

# Install (auto-detects secrets.yaml)
./helm/install.sh

# Check status
kubectl get pods -n soundbored
kubectl logs -n soundbored deployment/soundbored
```

### CI/CD (GitHub Actions)

The `.github/workflows/ci-cd.yml` pipeline:

1. Runs tests (`mix format`, `mix credo`, `mix test`)
2. Builds Docker image → pushes to GHCR
3. Deploys to Kubernetes via Helm (optional, currently commented out)

Required GitHub Secrets for deployment:
- `PRIVATE_KEY` / `PUBLIC_KEY` - SSH keys for K8s access
- `KUBE_CONFIG` - Base64-encoded kubeconfig

## Local Development

```bash
# Setup
mix setup

# Run server
mix phx.server

# Run tests
mix test

# Lint
mix credo --strict
mix format
```

## API

Trigger sounds programmatically:

```bash
# List sounds
curl https://your-domain.com/api/sounds \
  -H "Authorization: Bearer YOUR_API_TOKEN"

# Play sound
curl -X POST https://your-domain.com/api/sounds/123/play \
  -H "Authorization: Bearer YOUR_API_TOKEN"

# Stop all sounds
curl -X POST https://your-domain.com/api/sounds/stop \
  -H "Authorization: Bearer YOUR_API_TOKEN"
```

Generate API tokens in the web UI at `/settings`.

## Troubleshooting

### "Disallowed intent(s)" Error

Enable all 3 **Privileged Gateway Intents** in Discord Developer Portal → Bot.

### "Invalid redirect_uri" OAuth Error

Add the exact callback URL to Discord Developer Portal → OAuth2 → Redirects:
```
https://your-domain.com/auth/discord/callback
```

### Bot doesn't respond to !join

1. Check bot has required permissions on the server
2. Check MESSAGE CONTENT intent is enabled
3. Check logs: `kubectl logs -n soundbored deployment/soundbored`

### Sounds don't play

1. Ensure bot joined voice channel (`!join`)
2. Check bot has Connect + Speak permissions
3. Check ffmpeg is installed (included in Docker image)

## Credits

This project is a fork of [christomitov/soundbored](https://github.com/christomitov/soundbored) by [@christomitov](https://github.com/christomitov).

**Original features by upstream:**
- Phoenix/Elixir soundboard application
- Discord bot integration via Nostrum
- Web UI with LiveView
- Tags, favorites, statistics
- REST API

**Added in this fork:**
- Kubernetes Helm chart
- GitHub Actions CI/CD pipeline
- Automated deployment scripts

## License

MIT
