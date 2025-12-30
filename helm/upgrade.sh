#!/bin/bash
set -e

NAMESPACE="soundbored"
RELEASE_NAME="soundbored"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "Upgrading Soundbored..."

# Create namespace if it doesn't exist
if ! kubectl get namespace "$NAMESPACE" &> /dev/null; then
  echo "Creating namespace '$NAMESPACE'..."
  kubectl create namespace "$NAMESPACE"
else
  echo "Namespace '$NAMESPACE' already exists."
fi

# Upgrade Helm chart
helm upgrade "$RELEASE_NAME" "$SCRIPT_DIR" \
  --namespace "$NAMESPACE" \
  --wait \
  --timeout=5m \
  "$@"

# Restart deployment to pick up new image
echo "Restarting deployment..."
kubectl rollout restart deployment/"$RELEASE_NAME" -n "$NAMESPACE"
kubectl rollout status deployment/"$RELEASE_NAME" -n "$NAMESPACE" --timeout=300s

echo "Soundbored upgraded successfully!"

