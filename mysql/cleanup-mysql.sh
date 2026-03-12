#!/usr/bin/env bash

set -euo pipefail

# Cleanup MySQL InnoDBCluster instance deployed by deploy-mysql-k8s.sh

NAMESPACE="${NAMESPACE:-mysql-system}"
CLUSTER_NAME="${CLUSTER_NAME:-mysql}"
SECRET_NAME="${SECRET_NAME:-${CLUSTER_NAME}-cluster-secret}"
PVC_NAME="${PVC_NAME:-mysql-backups}"
DELETE_PVCS="${DELETE_PVCS:-false}"
DELETE_SECRET="${DELETE_SECRET:-false}"
DELETE_NAMESPACE="${DELETE_NAMESPACE:-false}"
# Operator uninstall (installed by deploy-mysql-k8s.sh)
OPERATOR_NS="${OPERATOR_NS:-mysql-operator-system}"
OPERATOR_RELEASE="${OPERATOR_RELEASE:-mysql-operator}"
DELETE_OPERATOR="${DELETE_OPERATOR:-false}"
DELETE_OPERATOR_CRDS="${DELETE_OPERATOR_CRDS:-false}"
DELETE_OPERATOR_NAMESPACE="${DELETE_OPERATOR_NAMESPACE:-false}"

# Optional convenience: FULL_UNINSTALL=true toggles all deletions
FULL_UNINSTALL="${FULL_UNINSTALL:-false}"
if [[ "$FULL_UNINSTALL" == "true" ]]; then
  DELETE_PVCS="true"
  DELETE_SECRET="true"
  DELETE_NAMESPACE="true"
  DELETE_OPERATOR="true"
  DELETE_OPERATOR_CRDS="true"
  DELETE_OPERATOR_NAMESPACE="true"
fi

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

# If operator uninstall requested, ensure Helm is available
if [[ "$DELETE_OPERATOR" == "true" ]]; then
  if command -v helm >/dev/null 2>&1; then
    :
  else
    echo "Error: Helm is required to uninstall the operator release. Please install Helm or unset DELETE_OPERATOR." >&2
    exit 1
  fi
fi

echo "Cleaning MySQL instance '$CLUSTER_NAME' in namespace '$NAMESPACE'..."

# 0) Delete MySQLBackup resources first to avoid dangling PVC usage
if ${KCTL[@]} -n "$NAMESPACE" api-resources --namespaced=true --verbs=list -o name 2>/dev/null | grep -q '^mysqlbackups.mysql.oracle.com$'; then
  echo "Deleting MySQLBackup resources (if any)..."
  # Prefer label selector; fall back to deleting all backups in namespace
  if ! ${KCTL[@]} -n "$NAMESPACE" delete mysqlbackup -l mysql.oracle.com/cluster="$CLUSTER_NAME" --ignore-not-found --wait=true 2>/dev/null; then
    ${KCTL[@]} -n "$NAMESPACE" get mysqlbackup --no-headers 2>/dev/null | awk 'NR>0{print $1}' | \
      xargs -r ${KCTL[@]} -n "$NAMESPACE" delete mysqlbackup --ignore-not-found --wait=true || true
  fi
fi

echo "Deleting InnoDBCluster '$CLUSTER_NAME'..."
# Only attempt CR deletion if CRD exists; otherwise skip gracefully
if ${KCTL[@]} api-resources -o name 2>/dev/null | grep -q '^innodbclusters.mysql.oracle.com$'; then
  "${KCTL[@]}" -n "$NAMESPACE" delete innodbcluster "$CLUSTER_NAME" --ignore-not-found || true
else
  echo "InnodbCluster CRD not found; skipping CR deletion and proceeding with namespaced resource cleanup."
fi

echo "Waiting for MySQL pods to terminate..."
for i in {1..90}; do
  pods=$("${KCTL[@]}" -n "$NAMESPACE" get pods -l mysql.oracle.com/cluster="$CLUSTER_NAME" --no-headers 2>/dev/null | wc -l | tr -d ' ')
  # Fallback if label selector not present
  if [[ "$pods" == "0" ]]; then
    pods=$("${KCTL[@]}" -n "$NAMESPACE" get pods --no-headers 2>/dev/null | grep -c "$CLUSTER_NAME" || true)
  fi
  if [[ "${pods}" == "0" ]]; then
    break
  fi
  sleep 5
done

echo "Deleting Services (router/frontdoor and headless) if present..."
"${KCTL[@]}" -n "$NAMESPACE" delete svc "$CLUSTER_NAME" "$CLUSTER_NAME-instances" --ignore-not-found || true

if [[ "$DELETE_PVCS" == "true" ]]; then
  echo "Attempting to delete PVCs related to '$CLUSTER_NAME'..."
  # Try label-based deletion first
  if ! "${KCTL[@]}" -n "$NAMESPACE" delete pvc -l mysql.oracle.com/cluster="$CLUSTER_NAME" 2>/dev/null; then
    # Fallback: name pattern match
    mapfile -t pvcs < <("${KCTL[@]}" -n "$NAMESPACE" get pvc -o name | grep "$CLUSTER_NAME" || true)
    if [[ ${#pvcs[@]} -gt 0 ]]; then
      "${KCTL[@]}" -n "$NAMESPACE" delete "${pvcs[@]}"
    else
      echo "No PVCs matched '$CLUSTER_NAME'"
    fi
  fi
  # Explicitly delete backup PVC if it exists
  "${KCTL[@]}" -n "$NAMESPACE" delete pvc "$PVC_NAME" --ignore-not-found || true
fi

if [[ "$DELETE_SECRET" == "true" ]]; then
  echo "Deleting Secrets related to '$CLUSTER_NAME'..."
  # Cluster secret (user credentials)
  "${KCTL[@]}" -n "$NAMESPACE" delete secret "$SECRET_NAME" --ignore-not-found || true
  # Router and other operator-created secrets (best-effort)
  "${KCTL[@]}" -n "$NAMESPACE" delete secret "${CLUSTER_NAME}-router" "${CLUSTER_NAME}-privsecrets" "${CLUSTER_NAME}-backup" --ignore-not-found || true
fi

# Delete any leftover configmaps owned by the instance (best-effort)
"${KCTL[@]}" -n "$NAMESPACE" get cm -l app.kubernetes.io/instance="$CLUSTER_NAME" -o name 2>/dev/null | \
  xargs -r "${KCTL[@]}" -n "$NAMESPACE" delete --ignore-not-found || true

if [[ "$DELETE_NAMESPACE" == "true" ]]; then
  echo "Deleting namespace '$NAMESPACE'..."
  "${KCTL[@]}" delete ns "$NAMESPACE" --ignore-not-found
fi

echo "MySQL cleanup complete. Remaining resources in namespace '$NAMESPACE':"
"${KCTL[@]}" -n "$NAMESPACE" get all,pvc,cm,secret 2>/dev/null || true

# --- Operator uninstall (optional) ---
if [[ "$DELETE_OPERATOR" == "true" ]]; then
  echo "Uninstalling MySQL Operator Helm release '$OPERATOR_RELEASE' from namespace '$OPERATOR_NS'..."
  if helm -n "$OPERATOR_NS" status "$OPERATOR_RELEASE" >/dev/null 2>&1; then
    helm -n "$OPERATOR_NS" uninstall "$OPERATOR_RELEASE" --wait || true
  else
    echo "Helm release '$OPERATOR_RELEASE' not found in namespace '$OPERATOR_NS' (skipping)."
  fi

  if [[ "$DELETE_OPERATOR_CRDS" == "true" ]]; then
    echo "Deleting MySQL Operator CRDs (and Kopf CRDs, if present)..."
    for crd in innodbclusters.mysql.oracle.com mysqlbackups.mysql.oracle.com clusterkopfpeerings.zalando.org kopfpeerings.zalando.org; do
      "${KCTL[@]}" delete crd "$crd" --wait=true --ignore-not-found || true
    done
  fi

  echo "Cleaning up cluster-scoped RBAC potentially left by the operator..."
  "${KCTL[@]}" delete clusterrole mysql-operator mysql-sidecar --ignore-not-found || true
  "${KCTL[@]}" delete clusterrolebinding mysql-operator mysql-sidecar-rb --ignore-not-found || true

  if [[ "$DELETE_OPERATOR_NAMESPACE" == "true" ]]; then
    echo "Deleting operator namespace '$OPERATOR_NS'..."
    "${KCTL[@]}" delete ns "$OPERATOR_NS" --ignore-not-found || true
  fi

  echo "Operator uninstall complete. Remaining operator-related CRDs and releases:"
  "${KCTL[@]}" get crd | grep -E "mysql\.oracle\.com|zalando\.org" || echo "No MySQL/Kopf CRDs remain"
  if command -v helm >/dev/null 2>&1; then
    helm ls -A | grep "$OPERATOR_RELEASE" || echo "No Helm release $OPERATOR_RELEASE remains"
  fi
fi
