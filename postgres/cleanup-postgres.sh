#!/usr/bin/env bash

set -euo pipefail

# Cleanup script for Bitnami PostgreSQL deployment
# Removes the Helm release and optionally PVCs, Secret, and Namespace.

NAMESPACE=${NAMESPACE:-postgres-system}
RELEASE=${RELEASE:-postgresql}
SECRET_NAME=${SECRET_NAME:-postgresql-auth}
DELETE_PVCS=${DELETE_PVCS:-true}
DELETE_SECRET=${DELETE_SECRET:-true}
DELETE_NAMESPACE=${DELETE_NAMESPACE:-true}

detect_kubectl() {
  if command -v microk8s >/dev/null 2>&1 && microk8s kubectl config current-context 2>/dev/null | grep -qi microk8s; then
    KCTL=(microk8s kubectl)
  else
    KCTL=(kubectl)
  fi
}

ensure_bin() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "Error: '$1' not found in PATH" >&2
    exit 1
  fi
}

detect_kubectl
ensure_bin helm
ensure_bin "${KCTL[@]}"

echo "Uninstalling Helm release '$RELEASE' from namespace '$NAMESPACE'..."
if helm -n "$NAMESPACE" status "$RELEASE" >/dev/null 2>&1; then
  helm -n "$NAMESPACE" uninstall "$RELEASE" || true
else
  echo "Helm release not found; skipping uninstall."
fi

if [[ "$DELETE_PVCS" == "true" ]]; then
  echo "Deleting PVCs labeled with the release..."
  "${KCTL[@]}" -n "$NAMESPACE" delete pvc -l app.kubernetes.io/instance="$RELEASE",app.kubernetes.io/name=postgresql || true
fi

if [[ "$DELETE_SECRET" == "true" ]]; then
  echo "Deleting Secret '$SECRET_NAME'..."
  "${KCTL[@]}" -n "$NAMESPACE" delete secret "$SECRET_NAME" --ignore-not-found
fi

if [[ "$DELETE_NAMESPACE" == "true" ]]; then
  echo "Deleting namespace '$NAMESPACE'..."
  "${KCTL[@]}" delete ns "$NAMESPACE" --ignore-not-found
fi

echo "PostgreSQL cleanup complete."
