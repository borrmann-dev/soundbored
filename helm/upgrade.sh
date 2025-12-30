#!/bin/bash
set -e

NAMESPACE="soundbored"
RELEASE_NAME="soundbored"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SECRETS_FILE="$SCRIPT_DIR/secrets.yaml"

echo "Upgrading Soundbored..."

# Create namespace if it doesn't exist
if ! kubectl get namespace "$NAMESPACE" &> /dev/null; then
  echo "Creating namespace '$NAMESPACE'..."
  kubectl create namespace "$NAMESPACE"
else
  echo "Namespace '$NAMESPACE' already exists."
fi

# Build helm args
HELM_ARGS=("$RELEASE_NAME" "$SCRIPT_DIR" --namespace "$NAMESPACE" --wait --timeout=5m)

# Auto-include secrets.yaml if it exists
if [[ -f "$SECRETS_FILE" ]]; then
  echo "Using secrets from $SECRETS_FILE"
  HELM_ARGS+=(-f "$SECRETS_FILE")
else
  echo "Warning: $SECRETS_FILE not found. Secrets will be empty!"
fi

# Upgrade Helm chart (additional args from command line)
helm upgrade "${HELM_ARGS[@]}" "$@"

# Restart deployment to pick up new image
echo "Restarting deployment..."
kubectl rollout restart deployment/"$RELEASE_NAME" -n "$NAMESPACE"
kubectl rollout status deployment/"$RELEASE_NAME" -n "$NAMESPACE" --timeout=300s

echo "Soundbored upgraded successfully!"
