#!/usr/bin/env bash

set -euo pipefail

# Cleanup SQL Server manifests deployed by deploy-mssql-microk8s.sh

NAMESPACE="${NAMESPACE:-mssql-system}"
APP_NAME="${APP_NAME:-mssql}"
SERVICE_NAME="${SERVICE_NAME:-mssql-svc}"
PVC_NAME="${PVC_NAME:-mssql-data}"
DELETE_PVCS="${DELETE_PVCS:-true}"
DELETE_SECRET="${DELETE_SECRET:-true}"
DELETE_NAMESPACE="${DELETE_NAMESPACE:-true}"

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
ensure_bin "${KCTL[@]}"

echo "Deleting Service '$SERVICE_NAME' (ClusterIP)..."
"${KCTL[@]}" -n "$NAMESPACE" delete svc "$SERVICE_NAME" --ignore-not-found

echo "Deleting headless Service '${APP_NAME}-headless'..."
"${KCTL[@]}" -n "$NAMESPACE" delete svc "${APP_NAME}-headless" --ignore-not-found

echo "Deleting StatefulSet '$APP_NAME'..."
"${KCTL[@]}" -n "$NAMESPACE" delete statefulset "$APP_NAME" --ignore-not-found

echo "Waiting for pods to terminate..."
for i in {1..60}; do
  pods=$("${KCTL[@]}" -n "$NAMESPACE" get pods -l app="$APP_NAME" --no-headers 2>/dev/null | wc -l | tr -d ' ')
  if [[ "${pods}" == "0" ]]; then
    break
  fi
  sleep 5
done

if [[ "$DELETE_PVCS" == "true" ]]; then
  echo "Deleting PVC '$PVC_NAME'..."
  "${KCTL[@]}" -n "$NAMESPACE" delete pvc "$PVC_NAME" --ignore-not-found
fi

if [[ "$DELETE_SECRET" == "true" ]]; then
  echo "Deleting Secret 'mssql'..."
  "${KCTL[@]}" -n "$NAMESPACE" delete secret mssql --ignore-not-found
fi

if [[ "$DELETE_NAMESPACE" == "true" ]]; then
  echo "Deleting namespace '$NAMESPACE'..."
  "${KCTL[@]}" delete ns "$NAMESPACE" --ignore-not-found
fi

echo "MSSQL cleanup complete."
