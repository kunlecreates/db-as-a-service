#!/usr/bin/env bash

set -euo pipefail

# Cleanup Oracle Single Instance Database (SIDB) deployed by deploy-oracle-k8s.sh

NAMESPACE="${NAMESPACE:-oracle-system}"
SIDB_NAME="${SIDB_NAME:-oracledb}"
ADMIN_SECRET_NAME="${ADMIN_SECRET_NAME:-db-admin-secret}"
IMAGE_PULL_SECRET="${IMAGE_PULL_SECRET:-}" # optional
DELETE_PVCS="${DELETE_PVCS:-true}"
DELETE_SECRET="${DELETE_SECRET:-true}"      # admin password secret
DELETE_IMAGE_PULL_SECRET="${DELETE_IMAGE_PULL_SECRET:-true}" # image pull secret
DELETE_NAMESPACE="${DELETE_NAMESPACE:-true}"
DELETE_OPERATOR="${DELETE_OPERATOR:-true}"             # remove Oracle operator (cluster-scoped)
DELETE_CERT_MANAGER="${DELETE_CERT_MANAGER:-false}"    # remove cert-manager (set true if you installed it just for this)
# Optional: also remove the operator CRDs (cluster-scoped). OFF by default to avoid impacting shared clusters.
DELETE_CRDS="${DELETE_CRDS:-true}"

# Operator / cert-manager settings (mirror deploy script defaults)
OPERATOR_NAMESPACE="${OPERATOR_NAMESPACE:-oracle-database-operator-system}"
CERT_MANAGER_NAMESPACE="${CERT_MANAGER_NAMESPACE:-cert-manager-system}"
CERT_MANAGER_VERSION="${CERT_MANAGER_VERSION:-v1.19.1}"

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

helm_uninstall_if_present() {
  local release="$1" ns="$2"
  if command -v helm >/dev/null 2>&1; then
    if helm -n "$ns" status "$release" >/dev/null 2>&1; then
      echo "Helm release '$release' detected in namespace '$ns' — uninstalling..."
      helm -n "$ns" uninstall "$release" || true
    fi
  fi
}

wait_for_namespace_termination() {
  local ns="$1" timeout="${2:-120}"
  for i in $(seq 1 "$timeout"); do
    if ! "${KCTL[@]}" get ns "$ns" >/dev/null 2>&1; then
      return 0
    fi
    sleep 2
  done
  return 1
}

detect_kubectl
ensure_bin "${KCTL[@]}"

echo "Beginning cleanup for SIDB '$SIDB_NAME' in namespace '$NAMESPACE'"

# 0) Best-effort: delete ORDS resources that reference this DB to avoid finalizer blocks
if "${KCTL[@]}" -n "$NAMESPACE" get oraclerestdataservice.database.oracle.com >/dev/null 2>&1; then
  echo "Deleting ORDS resources (if any) before SIDB..."
  # If there are multiple ORDS, delete all in this namespace (most deployments have none)
  ords=$("${KCTL[@]}" -n "$NAMESPACE" get oraclerestdataservice -o name 2>/dev/null || true)
  if [[ -n "${ords}" ]]; then
    echo "Found ORDS: ${ords//$'\n'/, } — deleting..."
    # delete all ORDS in namespace (they refer to local SIDB typically)
    "${KCTL[@]}" -n "$NAMESPACE" delete ${ords} --ignore-not-found || true
  fi
fi

# 1) Scale down SIDB first for graceful shutdown
if "${KCTL[@]}" -n "$NAMESPACE" get singleinstancedatabase.database.oracle.com "$SIDB_NAME" >/dev/null 2>&1; then
  echo "Patching SIDB '$SIDB_NAME' replicas=0 for graceful shutdown..."
  "${KCTL[@]}" -n "$NAMESPACE" patch singleinstancedatabase "$SIDB_NAME" --type=merge -p '{"spec":{"replicas":0}}' || true
fi

echo "Waiting for database pods to terminate..."
for i in {1..60}; do
  # Try label first (app=<sidb_name>), fall back to name prefix grep
  pod_count=$("${KCTL[@]}" -n "$NAMESPACE" get pods -l app="$SIDB_NAME" --no-headers 2>/dev/null | wc -l | tr -d ' ')
  if [[ "$pod_count" == "0" ]]; then
    # Fallback by name prefix
    pod_count=$("${KCTL[@]}" -n "$NAMESPACE" get pods --no-headers 2>/dev/null | awk '{print $1}' | grep -c "^${SIDB_NAME}-" || true)
  fi
  if [[ "$pod_count" == "0" ]]; then
    break
  fi
  sleep 5
done

# 2) Delete the SIDB CR and wait for finalizer removal
echo "Deleting SingleInstanceDatabase '$SIDB_NAME'..."
"${KCTL[@]}" -n "$NAMESPACE" delete singleinstancedatabase.database.oracle.com "$SIDB_NAME" --ignore-not-found

echo "Waiting for SIDB resource to be fully removed..."
for i in {1..60}; do
  if ! "${KCTL[@]}" -n "$NAMESPACE" get singleinstancedatabase.database.oracle.com "$SIDB_NAME" >/dev/null 2>&1; then
    break
  fi
  sleep 5
done

# 3) Defensive: delete leftover services created by operator (if any)
echo "Deleting services created by the operator (if any)..."
"${KCTL[@]}" -n "$NAMESPACE" delete svc "${SIDB_NAME}" "${SIDB_NAME}-ext" --ignore-not-found || true

if [[ "$DELETE_PVCS" == "true" ]]; then
  echo "Deleting PVCs owned by '$SIDB_NAME'..."
  # Attempt label-based deletion first (if operator labels pvcs)
  if ! "${KCTL[@]}" -n "$NAMESPACE" delete pvc -l app="$SIDB_NAME" 2>/dev/null; then
    mapfile -t pvcs < <("${KCTL[@]}" -n "$NAMESPACE" get pvc -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' | grep "^${SIDB_NAME}-\|${SIDB_NAME}$" || true)
    if [[ ${#pvcs[@]} -gt 0 ]]; then
      "${KCTL[@]}" -n "$NAMESPACE" delete pvc "${pvcs[@]}"
    else
      echo "No PVCs matched '$SIDB_NAME'"
    fi
  fi
fi

if [[ "$DELETE_SECRET" == "true" ]]; then
  echo "Deleting admin password Secret '$ADMIN_SECRET_NAME'..."
  "${KCTL[@]}" -n "$NAMESPACE" delete secret "$ADMIN_SECRET_NAME" --ignore-not-found
fi

if [[ "$DELETE_IMAGE_PULL_SECRET" == "true" && -n "$IMAGE_PULL_SECRET" ]]; then
  echo "Deleting image pull secret '$IMAGE_PULL_SECRET'..."
  "${KCTL[@]}" -n "$NAMESPACE" delete secret "$IMAGE_PULL_SECRET" --ignore-not-found
fi

if [[ "$DELETE_NAMESPACE" == "true" ]]; then
  echo "Deleting namespace '$NAMESPACE'..."
  "${KCTL[@]}" delete ns "$NAMESPACE" --ignore-not-found
  wait_for_namespace_termination "$NAMESPACE" 180 || echo "Namespace '$NAMESPACE' still terminating; resources may be finalizing."
fi

# 4) Optional: remove operator (cluster-scoped) — do this last
if [[ "$DELETE_OPERATOR" == "true" ]]; then
  echo "Deleting Oracle Database Operator (cluster-scoped resources)..."
  "${KCTL[@]}" delete -f https://raw.githubusercontent.com/oracle/oracle-database-operator/main/oracle-database-operator.yaml --ignore-not-found || true
  "${KCTL[@]}" delete -f https://raw.githubusercontent.com/oracle/oracle-database-operator/main/rbac/cluster-role-binding.yaml --ignore-not-found || true
  # Best-effort: delete operator namespace if empty
  if "${KCTL[@]}" get ns "$OPERATOR_NAMESPACE" >/dev/null 2>&1; then
    echo "Deleting operator namespace '$OPERATOR_NAMESPACE' (if empty)..."
    "${KCTL[@]}" delete ns "$OPERATOR_NAMESPACE" --ignore-not-found || true
  fi

  # Optional: delete CRDs installed by the Oracle Database Operator
  if [[ "$DELETE_CRDS" == "true" ]]; then
    echo "Deleting Oracle Database Operator CRDs (group=database.oracle.com)..."
    # Safety note: This will remove CRDs cluster-wide; ensure no other namespaces still use them.
    # List CRDs in the oracle operator API group and delete them.
    mapfile -t oracle_crds < <("${KCTL[@]}" get crd -o name 2>/dev/null | grep -E '\\.database\\.oracle\\.com$' || true)
    if [[ ${#oracle_crds[@]} -gt 0 ]]; then
      echo "Found CRDs: ${oracle_crds[*]} — deleting..."
      "${KCTL[@]}" delete "${oracle_crds[@]}" --ignore-not-found || true
    else
      echo "No CRDs found for group 'database.oracle.com'"
    fi
  fi
fi

# 5) Optional: remove cert-manager if you installed it just for this (be cautious in shared clusters)
if [[ "$DELETE_CERT_MANAGER" == "true" ]]; then
  echo "Deleting cert-manager (be sure nothing else depends on it)..."
  # Prefer Helm uninstall if a release named 'cert-manager' exists, else delete manifest
  helm_uninstall_if_present cert-manager "$CERT_MANAGER_NAMESPACE"
  "${KCTL[@]}" delete -f "https://github.com/cert-manager/cert-manager/releases/download/${CERT_MANAGER_VERSION}/cert-manager.yaml" --ignore-not-found || true
  # Try to delete namespace if present
  if "${KCTL[@]}" get ns "$CERT_MANAGER_NAMESPACE" >/dev/null 2>&1; then
    "${KCTL[@]}" delete ns "$CERT_MANAGER_NAMESPACE" --ignore-not-found || true
  fi
fi

echo "Oracle cleanup complete."
