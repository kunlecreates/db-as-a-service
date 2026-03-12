#!/usr/bin/env bash
# deploy-mysql-k8s.sh
# Provision a MySQL InnoDBCluster (MySQL 8+) in Kubernetes using the MySQL Operator.
# - Namespace: mysql-system
# - Service: ClusterIP (default, internal-only). Override SERVICE_TYPE if external access is explicitly required.
# - Passwords are injected at runtime; never committed to files
# Docs:
#   - Intro: https://dev.mysql.com/doc/mysql-operator/en/mysql-operator-introduction.html
#   - Install operator (Helm): https://dev.mysql.com/doc/mysql-operator/en/mysql-operator-installation-helm.html
#   - Simple kubectl deploy: https://dev.mysql.com/doc/mysql-operator/en/mysql-operator-innodbcluster-simple-kubectl.html
#   - CR properties: https://dev.mysql.com/doc/mysql-operator/en/mysql-operator-properties.html
#   - Services: https://dev.mysql.com/doc/mysql-operator/en/mysql-operator-innodbcluster-service.html

set -euo pipefail

# Defaults (override via env)
NAMESPACE="${NAMESPACE:-mysql-system}"
CLUSTER_NAME="${CLUSTER_NAME:-mysql}"
SECRET_NAME="${SECRET_NAME:-${CLUSTER_NAME}-cluster-secret}"
INSTANCES="${INSTANCES:-1}"
ROUTER_INSTANCES="${ROUTER_INSTANCES:-1}"
MYSQL_VERSION="${MYSQL_VERSION:-8.4.0}"
# Backup PVC settings (used by backupProfiles in 20-innodbcluster.yaml and 25-backup-pvc.yaml)
PVC_NAME="${PVC_NAME:-mysql-backups}"
STORAGE_SIZE="${STORAGE_SIZE:-8Gi}"
STORAGE_CLASS="${STORAGE_CLASS:-}"           # empty -> use default StorageClass
# Optional dedicated backup storage overrides
BACKUP_PROFILE_NAME="${BACKUP_PROFILE_NAME:-pvc-backups}"
SERVICE_TYPE="${SERVICE_TYPE:-ClusterIP}"     # ClusterIP|NodePort|LoadBalancer (default ClusterIP recommended)

# Root credentials (prompt if not provided)
MYSQL_ROOT_USER="${MYSQL_ROOT_USER:-root}"
MYSQL_ROOT_HOST="${MYSQL_ROOT_HOST:-%}"
if [[ -z "${MYSQL_ROOT_PASSWORD:-}" ]]; then
  read -r -s -p "Enter MySQL root password: " MYSQL_ROOT_PASSWORD
  echo
fi

# Detect kubectl context (microk8s vs vanilla)
detect_kubectl() {
  if command -v microk8s >/dev/null 2>&1; then
    if microk8s kubectl config current-context 2>/dev/null | grep -q "microk8s"; then
      KCTL=(microk8s kubectl)
      return
    fi
  fi
  KCTL=(kubectl)
}

ensure_bin() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "Error: '$1' not found in PATH. Please install it and retry." >&2
    exit 1
  fi
}

detect_kubectl
ensure_bin "${KCTL[@]}"
ensure_bin helm

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# --- Operator install helper (Helm-only; namespace: mysql-operator-system) ---
ensure_operator_ready() {
  # Helm is required (validated above); no manifest fallback
  local desired_ns="mysql-operator-system"
  local chart_version="${OPERATOR_CHART_VERSION:-2.1.9}"
  local image_tag="${OPERATOR_IMAGE_TAG:-8.4.0-2.1.3}"

  echo "Ensuring MySQL Operator via Helm (upgrade --install) in namespace '$desired_ns' with image tag '$image_tag'..."
  helm repo add mysql-operator https://mysql.github.io/mysql-operator/ >/dev/null 2>&1 || true
  helm repo update >/dev/null 2>&1 || true
  helm upgrade --install mysql-operator mysql-operator/mysql-operator -n "$desired_ns" --version "$chart_version" \
    --set image.tag="$image_tag" --create-namespace || return 1

  echo "Waiting for mysql-operator deployment to be ready in namespace '$desired_ns'..."
  "${KCTL[@]}" -n "$desired_ns" rollout status deploy/mysql-operator --timeout=300s || return 1
  return 0
}

echo "Applying namespace manifest..."
sed "s/__NAMESPACE__/${NAMESPACE}/g" "$SCRIPT_DIR/00-namespace.yaml" | "${KCTL[@]}" apply -f -

if ! ensure_operator_ready; then
  echo "ERROR: MySQL Operator installation failed or is not ready. Aborting." >&2
  exit 1
fi

echo "Applying Secret with root credentials..."
tmp_secret=$(mktemp)
sed -e "s#__SECRET_NAME__#${SECRET_NAME}#g" \
    -e "s#__MYSQL_ROOT_USER__#${MYSQL_ROOT_USER}#g" \
    -e "s#__MYSQL_ROOT_HOST__#${MYSQL_ROOT_HOST}#g" \
    -e "s#__MYSQL_ROOT_PASSWORD__#${MYSQL_ROOT_PASSWORD}#g" \
    "$SCRIPT_DIR/10-secret.yaml" > "$tmp_secret"
"${KCTL[@]}" -n "$NAMESPACE" apply -f "$tmp_secret"
rm -f "$tmp_secret"

# Create/Apply the backup PVC referenced by the InnoDBCluster's backupProfiles
echo "Applying backup PVC manifest..."
tmp_pvc=$(mktemp)
cp "$SCRIPT_DIR/25-backup-pvc.yaml" "$tmp_pvc"
sed -i "s#__PVC_NAME__#${PVC_NAME}#g" "$tmp_pvc"
sed -i "s#__STORAGE_SIZE__#${STORAGE_SIZE}#g" "$tmp_pvc"
if [[ -n "$STORAGE_CLASS" ]]; then
  sed -i "s#__STORAGE_CLASS_NAME__#${STORAGE_CLASS}#g" "$tmp_pvc"
else
  sed -i "/storageClassName:/d" "$tmp_pvc"
fi
"${KCTL[@]}" -n "$NAMESPACE" apply -f "$tmp_pvc"
rm -f "$tmp_pvc"

echo "Applying InnoDBCluster manifest..."
tmp_ic=$(mktemp)
cp "$SCRIPT_DIR/20-innodbcluster.yaml" "$tmp_ic"
sed -i "s#__CLUSTER_NAME__#${CLUSTER_NAME}#g" "$tmp_ic"
sed -i "s#__SECRET_NAME__#${SECRET_NAME}#g" "$tmp_ic"
sed -i "s#__MYSQL_VERSION__#${MYSQL_VERSION}#g" "$tmp_ic"
sed -i "s#__STORAGE_SIZE__#${STORAGE_SIZE}#g" "$tmp_ic"
sed -i "s#__SERVICE_TYPE__#${SERVICE_TYPE}#g" "$tmp_ic"
sed -i "s#__BACKUP_PROFILE_NAME__#${BACKUP_PROFILE_NAME}#g" "$tmp_ic"
sed -i "s#__PVC_NAME__#${PVC_NAME}#g" "$tmp_ic"
if [[ "$INSTANCES" != "1" ]]; then
  sed -i -E "s/^(\s*instances:\s*)1(\s*# SERVERS)$/\1${INSTANCES}\2/" "$tmp_ic"
fi
if [[ "$ROUTER_INSTANCES" != "1" ]]; then
  sed -i -E "s/^(\s*instances:\s*)1(\s*# ROUTER_INSTANCES)$/\1${ROUTER_INSTANCES}\2/" "$tmp_ic"
fi
"${KCTL[@]}" -n "$NAMESPACE" apply -f "$tmp_ic"
rm -f "$tmp_ic"

# Wait for Cluster ONLINE status
echo "Waiting for InnoDBCluster to become ONLINE..."
deadline=$((SECONDS + 600)) # 10 minutes
while true; do
  # Prefer new status path; fall back to legacy
  status=$("${KCTL[@]}" -n "$NAMESPACE" get innodbcluster "$CLUSTER_NAME" -o jsonpath='{.status.cluster.status}' 2>/dev/null || echo "")
  if [[ -z "$status" ]]; then
    status=$("${KCTL[@]}" -n "$NAMESPACE" get innodbcluster "$CLUSTER_NAME" -o jsonpath='{.status.status}' 2>/dev/null || echo "")
  fi
  if [[ "$status" == "ONLINE" ]]; then
    echo "InnoDBCluster is ONLINE."
    break
  fi
  if (( SECONDS > deadline )); then
    echo "ERROR: Timeout waiting for InnoDBCluster to become ONLINE. Current status: $status" >&2
    exit 1
  fi
  echo "Status: ${status:-PENDING}. Waiting..."
  sleep 10
done

# Summarize Service endpoints
echo "\nConnection information:"
if "${KCTL[@]}" -n "$NAMESPACE" get svc "$CLUSTER_NAME" >/dev/null 2>&1; then
  type=$("${KCTL[@]}" -n "$NAMESPACE" get svc "$CLUSTER_NAME" -o jsonpath='{.spec.type}' 2>/dev/null || echo "")
  echo "  Service: $CLUSTER_NAME (router/frontdoor) type=${type:-unknown}"
fi
if "${KCTL[@]}" -n "$NAMESPACE" get svc "${CLUSTER_NAME}-instances" >/dev/null 2>&1; then
  type=$("${KCTL[@]}" -n "$NAMESPACE" get svc "${CLUSTER_NAME}-instances" -o jsonpath='{.spec.type}' 2>/dev/null || echo "")
  echo "  Service: ${CLUSTER_NAME}-instances (headless) type=${type:-unknown}"
fi

echo "\nDone."
