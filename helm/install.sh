#!/bin/bash
set -e

NAMESPACE="soundbored"
RELEASE_NAME="soundbored"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "Installing Soundbored..."

# Create namespace if it doesn't exist
if ! kubectl get namespace "$NAMESPACE" &> /dev/null; then
  echo "Creating namespace '$NAMESPACE'..."
  kubectl create namespace "$NAMESPACE"
else
  echo "Namespace '$NAMESPACE' already exists."
fi

# Install Helm chart
helm install "$RELEASE_NAME" "$SCRIPT_DIR" \
  --namespace "$NAMESPACE" \
  --wait \
  --timeout=5m \
  "$@"

echo "Soundbored installed successfully!"
echo "Check status: kubectl get pods -n $NAMESPACE"

