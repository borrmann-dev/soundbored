#!/bin/bash
set -e

NAMESPACE="soundbored"
RELEASE_NAME="soundbored"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SECRETS_FILE="$SCRIPT_DIR/secrets.yaml"

echo "Installing Soundbored..."

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
  echo "Copy secrets.yaml.example to secrets.yaml and fill in values."
fi

# Install Helm chart (additional args from command line)
helm install "${HELM_ARGS[@]}" "$@"

echo "Soundbored installed successfully!"
echo "Check status: kubectl get pods -n $NAMESPACE"
