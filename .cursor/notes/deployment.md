# Soundbored - Deployment Notes

## Docker

### Dockerfile
- Multi-stage build: Elixir 1.19-alpine
- Build stage: compiles deps, assets
- Runtime: includes ffmpeg (required for Nostrum audio)
- Exposes port 4000
- Entrypoint runs migrations then starts Phoenix

### docker-compose.yml
- Uses `christom/soundbored:latest` image (or build locally)
- Mounts volume for uploads + DB: `/app/priv/static/uploads`
- Reads `.env` for configuration
- Secret file for `SECRET_KEY_BASE_FILE`
- Runs as non-root user (9999:9999)

## Kubernetes Deployment

### Helm Chart Structure

```
helm/
├── Chart.yaml           # App metadata (soundbored v1.7.0)
├── values.yaml          # Configuration values
└── templates/
    ├── deployment.yaml  # Pod spec with env vars, probes, volumes
    ├── service.yaml     # ClusterIP service (port 80 → 4000)
    ├── ingress.yaml     # NGINX ingress with TLS
    └── pvc.yaml         # Persistent storage for uploads + SQLite
```

### CI/CD Pipeline (`.github/workflows/ci-cd.yml`)

1. **Test job**: Runs `mix format`, `mix credo`, `mix test`
2. **Build job**: Builds Docker image → pushes to `ghcr.io/borrmann-dev/soundbored`
3. **Deploy job**: SSH tunnel to K3s → Helm upgrade → rollout restart

### Pre-Deployment Setup

Create the Kubernetes secret with Discord credentials:

```bash
kubectl create namespace soundbored

kubectl create secret generic soundbored-secrets -n soundbored \
  --from-literal=DISCORD_TOKEN=your_bot_token \
  --from-literal=DISCORD_CLIENT_ID=your_client_id \
  --from-literal=DISCORD_CLIENT_SECRET=your_client_secret \
  --from-literal=SECRET_KEY_BASE=$(openssl rand -base64 48)
```

### GitHub Secrets Required

| Secret | Purpose |
|--------|---------|
| `PRIVATE_KEY` | SSH private key for K3s access |
| `PUBLIC_KEY` | SSH public key |
| `KUBE_CONFIG` | Base64-encoded kubeconfig |

### Discord OAuth Setup

Add redirect URL in Discord Developer Portal:
```
https://soundbored.k8s.borrmann.dev/auth/discord/callback
```

## Production Checklist

- [x] Helm chart configured for soundbored
- [x] CI/CD workflow with tests and deployment
- [x] PersistentVolumeClaim for uploads
- [ ] Create K8s namespace and secrets on cluster
- [ ] Configure DNS for ingress host
- [ ] Add Discord OAuth redirect URL

