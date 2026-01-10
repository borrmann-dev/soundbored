# Soundbored - Deployment Notes

## Docker

- **Image**: `ghcr.io/borrmann-dev/soundbored:latest`
- **Base**: Elixir 1.19-alpine + ffmpeg
- **Port**: 4000
- **Volume**: `/app/priv/static/uploads` (sounds + SQLite DB)

### Local Docker

```bash
docker compose up
# Uses .env for configuration
```

## Helm Chart (K3s)

### Structure

```
helm/
├── Chart.yaml           # App metadata (v1.7.0)
├── values.yaml          # Non-sensitive config
├── secrets.yaml         # Sensitive config (gitignored!)
├── secrets.yaml.example # Template
├── install.sh           # Install script
├── upgrade.sh           # Upgrade + restart
├── uninstall.sh         # Uninstall (prompts for PVC/NS deletion)
└── templates/
    ├── deployment.yaml  # Pod spec, probes, volumes
    ├── service.yaml     # ClusterIP (80 → 4000)
    ├── ingress.yaml     # NGINX ingress + TLS
    ├── pvc.yaml         # PersistentVolumeClaim (30Gi, longhorn)
    └── secret.yaml      # K8s Secret from values
```

### Install/Upgrade

```bash
# 1. Create secrets
cp helm/secrets.yaml.example helm/secrets.yaml
# Edit with your values

# 2. Install
./helm/install.sh

# 3. Upgrade (after changes)
./helm/upgrade.sh
```

### Secrets Configuration

```yaml
# helm/secrets.yaml
secrets:
  DISCORD_TOKEN: "bot-token"
  DISCORD_CLIENT_ID: "client-id"
  DISCORD_CLIENT_SECRET: "client-secret"
  SECRET_KEY_BASE: "openssl rand -base64 48"
  # Optional:
  BASIC_AUTH_USERNAME: "admin"
  BASIC_AUTH_PASSWORD: "password"
```

### PVC Management

**Storage**: Uses `longhorn` StorageClass (supports volume expansion).

```bash
# Check PVC status
kubectl get pvc -n soundbored

# Longhorn UI: https://longhorn.k8s.borrmann.dev
```

## CI/CD Pipeline

### Workflow (`.github/workflows/ci-cd.yml`)

1. **Test**: `mix format`, `mix credo`, `mix test`
2. **Build**: Docker build → push to GHCR
3. **Deploy**: SSH tunnel → Helm upgrade → rollout restart

### Triggers

- Push to `main`/`master` (excluding: `helm/`, `.github/`, `.cursor/`, `AGENTS.md`, `README.md`)
- Pull requests

### GitHub Secrets Required

| Secret | Purpose | How to Create |
|--------|---------|---------------|
| `PRIVATE_KEY` | SSH private key | `~/.ssh/id_ed25519` content |
| `PUBLIC_KEY` | SSH public key | `~/.ssh/id_ed25519.pub` content |
| `KUBE_CONFIG` | Base64 kubeconfig | `cat ~/.kube/config \| base64 -w0` |
| `DISCORD_TOKEN` | Discord bot token | From Discord Developer Portal |
| `DISCORD_CLIENT_ID` | OAuth client ID | From Discord Developer Portal |
| `DISCORD_CLIENT_SECRET` | OAuth client secret | From Discord Developer Portal |
| `SECRET_KEY_BASE` | Phoenix secret | `openssl rand -base64 48` |

## Discord Bot Setup

### 1. Create Application

1. Go to [Discord Developer Portal](https://discord.com/developers/applications)
2. Click "New Application"
3. Name it (e.g., "Soundbored")

### 2. Configure Bot

1. Go to **Bot** section
2. Click "Reset Token" → Copy token → `DISCORD_TOKEN`
3. Enable **Privileged Gateway Intents**:
   - ✅ PRESENCE INTENT
   - ✅ SERVER MEMBERS INTENT
   - ✅ MESSAGE CONTENT INTENT

### 3. Configure OAuth2

1. Go to **OAuth2** → **General**
2. Copy **Client ID** → `DISCORD_CLIENT_ID`
3. Copy/Reset **Client Secret** → `DISCORD_CLIENT_SECRET`
4. Add **Redirect URL**:
   ```
   https://soundbored.k8s.borrmann.dev/auth/discord/callback
   ```

### 4. Invite Bot to Server

1. Go to **OAuth2** → **URL Generator**
2. Select **Guild Install**
3. Scope: `bot`
4. Permissions:
   - Send Messages
   - Read Message History
   - View Channels
   - Connect
   - Speak
5. Open generated URL → Select server → Authorize

## Troubleshooting

### "Disallowed intent(s)" Error

```
Shard websocket closed (errno 4014, reason "Disallowed intent(s).")
```

**Fix**: Enable all 3 Privileged Gateway Intents in Discord Developer Portal → Bot

### "Invalid redirect_uri" OAuth Error

**Fix**: Add exact callback URL in Discord Developer Portal → OAuth2 → Redirects:
```
https://soundbored.k8s.borrmann.dev/auth/discord/callback
```

### Bot Not Joining Voice

1. Check bot has Connect + Speak permissions
2. Check `AUTO_JOIN=true` if you want auto-join
3. Use `!join` command in Discord

### Audio Dropouts / Network Issues

**Discord Voice Protocol:**
- Discord Voice verwendet **UDP** standardmäßig (nicht TCP)
- UDP bietet niedrigere Latenz, ist aber anfälliger für Paketverluste
- Das Protokoll wird automatisch von Nostrum/Discord bestimmt und kann nicht geändert werden
- Wenn UDP blockiert ist, kann Discord auf TCP zurückfallen (höhere Latenz)

**Netzwerk-Optimierungen:**
1. **Firewall**: Stelle sicher, dass UDP-Ports nicht blockiert sind
   - Discord Voice verwendet dynamische UDP-Ports (50000-65535)
   - Keine festen Ports, daher schwer zu konfigurieren
   
2. **NAT/Firewall**: Für beste Performance:
   - UDP sollte nicht blockiert werden
   - NAT sollte UDP-Traffic korrekt weiterleiten
   - Keine aggressive UDP-Timeout-Konfiguration

3. **System-Level**: 
   - Netzwerk-Buffer können erhöht werden (OS-abhängig)
   - QoS/Priorität für UDP-Traffic setzen (falls möglich)

4. **Application-Level** (bereits implementiert):
   - `audio_frames_per_burst: 10` (200ms Buffer) - kompensiert Paketverluste
   - Längere Timeouts und Stabilisierungsverzögerungen
   - Mehrfache Verbindungsvalidierung

**Wenn UDP blockiert ist:**
- Discord fällt automatisch auf TCP zurück
- Höhere Latenz, aber stabilere Verbindung
- Keine Konfiguration nötig - passiert automatisch

### Check Logs

```bash
kubectl logs -n soundbored deployment/soundbored --tail=100
kubectl logs -n soundbored deployment/soundbored -f  # Follow
```

### Restart Pod

```bash
kubectl rollout restart deployment/soundbored -n soundbored
kubectl rollout status deployment/soundbored -n soundbored
```

### Shell into Pod

```bash
kubectl exec -it -n soundbored deployment/soundbored -- /bin/sh
```

### Database Issues

```bash
# SQLite is at /app/priv/static/uploads/soundboard_prod.db
kubectl exec -n soundbored <pod> -- cat /app/priv/static/uploads/soundboard_prod.db > backup.db
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
4. Update Helm secrets and redeploy

### API Token Security

- Tokens are hashed (SHA-256) before storage
- Raw token shown only once on creation
- Tokens can be revoked via Settings page
- `last_used_at` tracked for audit