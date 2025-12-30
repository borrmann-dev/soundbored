# Soundbored - Deployment Notes

## Docker

- **Image**: `ghcr.io/borrmann-dev/soundbored` (or `christom/soundbored`)
- **Base**: Elixir 1.19-alpine with ffmpeg
- **Port**: 4000
- **Volume**: `/app/priv/static/uploads` (sounds + SQLite DB)

## Helm Chart

### Structure
```
helm/
├── Chart.yaml           # App metadata
├── values.yaml          # Non-sensitive config
├── secrets.yaml         # Sensitive config (gitignored!)
├── secrets.yaml.example # Template for secrets
├── install.sh           # Install script (auto-uses secrets.yaml)
├── upgrade.sh           # Upgrade script
├── uninstall.sh         # Uninstall script
└── templates/
    ├── deployment.yaml  # Pod spec with env vars, probes, volumes
    ├── service.yaml     # ClusterIP service (port 80 → 4000)
    ├── ingress.yaml     # NGINX ingress with TLS
    ├── pvc.yaml         # PersistentVolumeClaim (local-path, 5Gi)
    └── secret.yaml      # Kubernetes Secret from values
```

### Install/Upgrade
```bash
# Copy and fill secrets
cp helm/secrets.yaml.example helm/secrets.yaml
# Edit helm/secrets.yaml with your values

# Install (auto-detects secrets.yaml)
./helm/install.sh

# Upgrade
./helm/upgrade.sh
```

### Required Secrets (in `helm/secrets.yaml`)
```yaml
secrets:
  DISCORD_TOKEN: "bot-token-from-discord-portal"
  DISCORD_CLIENT_ID: "oauth-client-id"
  DISCORD_CLIENT_SECRET: "oauth-client-secret"
  SECRET_KEY_BASE: "generate-with-openssl-rand-base64-48"
  BASIC_AUTH_USERNAME: ""  # optional
  BASIC_AUTH_PASSWORD: ""  # optional
```

## CI/CD Pipeline

### Workflow (`.github/workflows/ci-cd.yml`)
1. **Test job**: `mix format`, `mix credo`, `mix test`
2. **Build job**: Docker build → push to GHCR
3. **Deploy job**: SSH tunnel → Helm upgrade (currently commented out)

### GitHub Secrets Required
| Secret | Purpose |
|--------|---------|
| `PRIVATE_KEY` | SSH private key for K3s access |
| `PUBLIC_KEY` | SSH public key |
| `KUBE_CONFIG` | Base64-encoded kubeconfig |

## Discord Setup

### 1. Create Application
1. Go to [Discord Developer Portal](https://discord.com/developers/applications)
2. Create New Application

### 2. Configure Bot
1. Go to **Bot** section
2. Copy **Token** → `DISCORD_TOKEN`
3. Enable **Privileged Gateway Intents**:
   - ✅ PRESENCE INTENT
   - ✅ SERVER MEMBERS INTENT
   - ✅ MESSAGE CONTENT INTENT

### 3. Configure OAuth2
1. Go to **OAuth2** section
2. Copy **Client ID** → `DISCORD_CLIENT_ID`
3. Copy **Client Secret** → `DISCORD_CLIENT_SECRET`
4. Add **Redirect URL**: `https://soundbored.k8s.borrmann.dev/auth/discord/callback`

### 4. Invite Bot to Server
1. Go to **OAuth2** → **URL Generator**
2. Select **Guild Install**
3. Scope: `bot`
4. Permissions: `Send Messages`, `Read Message History`, `View Channels`, `Connect`, `Speak`
5. Open generated URL → Select server → Authorize

## Troubleshooting

### "Disallowed intent(s)" Error
```
Shard websocket closed (errno 4014, reason "Disallowed intent(s).")
```
**Fix**: Enable all 3 Privileged Gateway Intents in Discord Developer Portal → Bot

### "Invalid redirect_uri" OAuth Error
**Fix**: Add exact callback URL to Discord Developer Portal → OAuth2 → Redirects:
```
https://soundbored.k8s.borrmann.dev/auth/discord/callback
```

### SECRET_KEY_BASE Missing
**Fix**: Ensure `helm/secrets.yaml` has `SECRET_KEY_BASE` set and was included during install:
```bash
./helm/upgrade.sh  # Auto-includes secrets.yaml
```

### Check Logs
```bash
kubectl logs -n soundbored deployment/soundbored --tail=100
kubectl logs -n soundbored deployment/soundbored | head -50  # Startup logs
```

### Restart Pod
```bash
kubectl rollout restart deployment/soundbored -n soundbored
```

## Security Notes

### Never Commit Secrets!
- `helm/secrets.yaml` is in `.gitignore`
- GitHub push protection blocks Discord tokens
- If secrets are exposed: **regenerate immediately**

### Regenerate Secrets
1. **Discord Token**: Developer Portal → Bot → Reset Token
2. **Client Secret**: Developer Portal → OAuth2 → Reset Secret
3. **SECRET_KEY_BASE**: `openssl rand -base64 48`
