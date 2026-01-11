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

### Audio Glitches / Dropouts / Speed Drift

**Root Cause:**
Nostrum v0.11.0-dev (master branch) erwartet **Opus-Frames**, nicht PCM! 

**WICHTIG**: `executable_args` existiert **NICHT** in Nostrum v0.11.0-dev! Die Optionen sind:
- `start_pos`, `duration`, `realtime` (default `true`), `volume`, `filter`

Wenn man versucht, FFmpeg mit nicht-existierenden Optionen zu konfigurieren, werden diese ignoriert, was zu inkonsistentem Verhalten führt.

**Lösung: Korrekte Nostrum v0.11.0-dev Konfiguration**

1. **Korrekte `play_options`:**
   ```elixir
   play_options = [
     volume: clamped_vol,
     realtime: true,  # Default ist true, explizit setzen für Klarheit
     filter: "aresample=48000, aformat=sample_fmts=s16:channel_layouts=stereo"
   ]
   ```
   - `filter` ist der einzige Weg, Audioformat in Nostrum zu fixieren
   - `realtime: true` verhindert, dass FFmpeg "so schnell wie möglich" produziert

2. **Stabiles Buffering:**
   - `audio_frames_per_burst: 20` (400ms Buffer) für bessere Stabilität
   - Default ist 10, aber 20 ist stabiler bei Netzwerk-Jitter und VM Docker Jitter
   - Nur `audio_frames_per_burst: 1` für ultra-kurze Sounds (< 200ms)

3. **URL-Sounds optimieren:**
   - **Problem**: URL-Sounds werden direkt gestreamt, was bei Netzwerk-Issues zu Glitches führt
   - **Lösung**: URL-Sounds sollten serverseitig runtergeladen/gecacht werden, dann lokal abgespielt
   - Aktuell: URL-Sounds werden direkt gestreamt (kann zu Dropouts führen)

4. **Monitoring reduzieren:**
   - Playback-Monitoring alle 2 Sekunden kann bei mehreren Sounds zu viel Last erzeugen
   - URL-Validation beim Playback entfernt (nur beim Caching, nicht beim Abspielen)

**Konfiguration:**
- `config/runtime.exs`, `config/dev.exs`, `config/prod.exs`: `audio_frames_per_burst: 20`
- `lib/soundboard_web/audio_player.ex`: `play_options` mit `filter`, `realtime: true`, `volume`

**Erwartetes Ergebnis:**
- Stabiler Tempo (kein Speed Drift)
- Keine Warble/Glitches
- Keine fehlenden Fragmente
- Keine zufälligen Stillephasen
- Keine Desynchronisation nach langem Playback

**TODO: URL-Sound Caching**
- URL-Sounds sollten beim Upload/Caching runtergeladen werden
- Dann lokal abspielen statt direkt zu streamen
- Das würde 80% der Dropouts bei URL-Sounds beseitigen

**Discord Voice Protocol:**
- Discord Voice verwendet **UDP** standardmäßig (nicht TCP)
- UDP bietet niedrigere Latenz, ist aber anfälliger für Paketverluste
- Das Protokoll wird automatisch von Nostrum/Discord bestimmt und kann nicht geändert werden
- Wenn UDP blockiert ist, kann Discord auf TCP zurückfallen (höhere Latenz)

**Netzwerk-Optimierungen:**
1. **Firewall**: Stelle sicher, dass UDP-Ports nicht blockiert sind
   - Discord Voice verwendet dynamische UDP-Ports (50000-65535)
   
2. **NAT/Firewall**: Für beste Performance:
   - UDP sollte nicht blockiert werden
   - NAT sollte UDP-Traffic korrekt weiterleiten

**Wenn UDP blockiert ist:**
- Discord fällt automatisch auf TCP zurück
- Höhere Latenz, aber stabilere Verbindung

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