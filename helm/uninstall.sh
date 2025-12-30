#!/bin/bash
set -e

NAMESPACE="soundbored"
RELEASE_NAME="soundbored"

echo "Uninstalling Soundbored..."

# Check if release exists
if helm status "$RELEASE_NAME" -n "$NAMESPACE" &> /dev/null; then
  helm uninstall "$RELEASE_NAME" --namespace "$NAMESPACE"
  echo "Helm release '$RELEASE_NAME' uninstalled."
else
  echo "Helm release '$RELEASE_NAME' not found in namespace '$NAMESPACE'."
fi

# Ask about PVC deletion
read -p "Delete PersistentVolumeClaim (uploads + database)? [y/N] " -n 1 -r
echo
if [[ $REPLY =~ ^[Yy]$ ]]; then
  kubectl delete pvc "${RELEASE_NAME}-uploads" -n "$NAMESPACE" --ignore-not-found
  echo "PVC deleted."
else
  echo "PVC retained. Data will persist for future installs."
fi

# Ask about namespace deletion
read -p "Delete namespace '$NAMESPACE'? [y/N] " -n 1 -r
echo
if [[ $REPLY =~ ^[Yy]$ ]]; then
  kubectl delete namespace "$NAMESPACE" --ignore-not-found
  echo "Namespace deleted."
else
  echo "Namespace retained."
fi

echo "Uninstall complete!"

