#!/usr/bin/env bash
# deploy-mssql-microk8s.sh
# Provision SQL Server 2022 in MicroK8s using Kubernetes manifests.
# - Namespace: mssql-system
# - Storage: PVC backed by MicroK8s hostpath (or custom StorageClass)
# - Service: ClusterIP (internal-only by default; use port-forward for ad-hoc external access)
# Based on Microsoft docs (kubectl): https://learn.microsoft.com/en-us/sql/linux/quickstart-sql-server-containers-azure?tabs=kubectl

set -euo pipefail

# Defaults (override via env vars before running)
NAMESPACE="${NAMESPACE:-mssql-system}"
APP_NAME="${APP_NAME:-mssql}"
IMAGE="${IMAGE:-mcr.microsoft.com/mssql/server:2022-latest}"
MSSQL_PID="${MSSQL_PID:-Developer}"             # Enterprise|Standard|Express|Developer
PVC_NAME="${PVC_NAME:-mssql-data}"
PVC_SIZE="${PVC_SIZE:-8Gi}"
STORAGE_CLASS="${STORAGE_CLASS:-}"              # empty -> use cluster default (MicroK8s: microk8s-hostpath)
MEM_REQUEST="${MEM_REQUEST:-2Gi}"
CPU_REQUEST="${CPU_REQUEST:-400m}"
MEM_LIMIT="${MEM_LIMIT:-2.5Gi}"
CPU_LIMIT="${CPU_LIMIT:-1000m}"
SERVICE_NAME="${SERVICE_NAME:-mssql-svc}"
REPLICAS="${REPLICAS:-1}"                       # Keep 1 for single instance

# Read password from MSSQL_SA_PASSWORD env or prompt securely
if [[ -z "${MSSQL_SA_PASSWORD:-}" ]]; then
  echo "Enter a strong admin password for the 'MSSQL SA' user."
  while true; do
    read -r -s -p "Enter MSSQL SA password: " MSSQL_SA_PASSWORD
    echo
    read -r -s -p "Confirm: " MSSQL_SA_PASSWORD_CONFIRM
    echo
    if [[ -z "${MSSQL_SA_PASSWORD}" ]]; then
      echo "Password cannot be empty. Try again."
      continue
    fi
    if [[ "${MSSQL_SA_PASSWORD}" != "${MSSQL_SA_PASSWORD_CONFIRM}" ]]; then
      echo "Passwords do not match. Try again."
      continue
    fi
    break
  done
    unset MSSQL_SA_PASSWORD_CONFIRM
else
  echo "Using MSSQL_SA_PASSWORD from environment (non-interactive)."
fi

# Determine the correct kubectl command based on the current context
detect_kubectl() {
  if microk8s kubectl config current-context 2>/dev/null | grep -q "microk8s"; then
      KCTL=(microk8s kubectl)
      echo "Using MicroK8s cluster"
  else
      KCTL=(kubectl)
      echo "Using standard Kubernetes cluster"
  fi
}

ensure_bin() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "Error: '$1' not found in PATH. Please install it and retry." >&2
    exit 1
  fi
}

detect_kubectl
ensure_bin "${KCTL[@]}"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# 1) Namespace
echo "Applying namespace manifest..."
sed "s/__NAMESPACE__/${NAMESPACE}/g" "$SCRIPT_DIR/00-namespace.yaml" | "${KCTL[@]}" apply -f -

# 2) Storage class advice & detection (non-fatal)
echo "Checking StorageClasses..."
if [[ -n "$STORAGE_CLASS" ]]; then
  if ! "${KCTL[@]}" get storageclass "$STORAGE_CLASS" >/dev/null 2>&1; then
    echo "ERROR: StorageClass '$STORAGE_CLASS' not found. Create/enable it or omit STORAGE_CLASS to use the cluster default." >&2
    exit 1
  fi
else
  DEFAULT_SC="$("${KCTL[@]}" get sc -o jsonpath='{range .items[?(@.metadata.annotations.storageclass\.kubernetes\.io/is-default-class=="true")]}{.metadata.name}{"\n"}{end}' || true)"
  if [[ -z "$DEFAULT_SC" ]]; then
    echo "WARNING: No default StorageClass detected. In MicroK8s, enable hostpath storage: 'microk8s enable hostpath-storage', or set STORAGE_CLASS explicitly."
  else
    echo "Detected default StorageClass: $DEFAULT_SC"
  fi
fi

# 3) Secret (do not commit actual password in files)
echo "Applying Secret..."
tmp_secret=$(mktemp)
sed -e "s#__MSSQL_SA_PASSWORD__#${MSSQL_SA_PASSWORD}#g" "$SCRIPT_DIR/10-secret.yaml" > "$tmp_secret"
"${KCTL[@]}" -n "$NAMESPACE" apply -f "$tmp_secret"
rm -f "$tmp_secret"

# 4) PVC (use explicit storageClass if provided, else remove the line to let default apply)
echo "Applying PVC..."
tmp_pvc=$(mktemp)
cp "$SCRIPT_DIR/20-pvc.yaml" "$tmp_pvc"
sed -i "s/__PVC_NAME__/${PVC_NAME}/g" "$tmp_pvc"
sed -i "s/__PVC_SIZE__/${PVC_SIZE}/g" "$tmp_pvc"
if [[ -n "$STORAGE_CLASS" ]]; then
  sed -i "s#__STORAGE_CLASS_NAME__#${STORAGE_CLASS}#g" "$tmp_pvc"
else
  # Remove the storageClassName line
  sed -i "/storageClassName:/d" "$tmp_pvc"
fi
"${KCTL[@]}" -n "$NAMESPACE" apply -f "$tmp_pvc"
rm -f "$tmp_pvc"

# 5) Headless Service for stable identity
echo "Applying headless Service..."
sed -e "s/__APP_NAME__/${APP_NAME}/g" "$SCRIPT_DIR/30-headless-svc.yaml" | "${KCTL[@]}" -n "$NAMESPACE" apply -f -

# 6) StatefulSet (single replica), fsGroup=10001, resource limits
echo "Applying StatefulSet..."
tmp_sts=$(mktemp)
cp "$SCRIPT_DIR/40-statefulset.yaml" "$tmp_sts"
sed -i "s#__APP_NAME__#${APP_NAME}#g" "$tmp_sts"
sed -i "s#__IMAGE__#${IMAGE}#g" "$tmp_sts"
sed -i "s#__MSSQL_PID__#${MSSQL_PID}#g" "$tmp_sts"
sed -i "s#__PVC_NAME__#${PVC_NAME}#g" "$tmp_sts"
sed -i "s#__MEM_REQUEST__#${MEM_REQUEST}#g" "$tmp_sts"
sed -i "s#__CPU_REQUEST__#${CPU_REQUEST}#g" "$tmp_sts"
sed -i "s#__MEM_LIMIT__#${MEM_LIMIT}#g" "$tmp_sts"
sed -i "s#__CPU_LIMIT__#${CPU_LIMIT}#g" "$tmp_sts"
# Update replicas only if different from default 1
if [[ "$REPLICAS" != "1" ]]; then
  sed -i -E "s/^(\s*replicas:\s*)1$/\1${REPLICAS}/" "$tmp_sts"
fi
"${KCTL[@]}" -n "$NAMESPACE" apply -f "$tmp_sts"
rm -f "$tmp_sts"

# 7) Service (ClusterIP)
echo "Applying Service (ClusterIP)..."
tmp_svc=$(mktemp)
cp "$SCRIPT_DIR/50-service.yaml" "$tmp_svc"
sed -i "s/__SERVICE_NAME__/${SERVICE_NAME}/g" "$tmp_svc"
sed -i "s/__APP_NAME__/${APP_NAME}/g" "$tmp_svc"
"${KCTL[@]}" -n "$NAMESPACE" apply -f "$tmp_svc"
rm -f "$tmp_svc"

# 8) Wait for readiness
echo "Waiting for StatefulSet to become ready..."
"${KCTL[@]}" -n "$NAMESPACE" rollout status statefulset/${APP_NAME} --timeout=600s

# 9) Summarize
CLUSTER_IP="$("${KCTL[@]}" -n "$NAMESPACE" get svc "${SERVICE_NAME}" -o jsonpath='{.spec.clusterIP}')"

echo "Deployment complete."
echo "Namespace: $NAMESPACE"
echo "App: $APP_NAME"
echo "Image: $IMAGE"
echo "PVC: $PVC_NAME (${PVC_SIZE})"
if [[ -n "$STORAGE_CLASS" ]]; then
  echo "StorageClass (explicit): $STORAGE_CLASS"
else
  echo "StorageClass: cluster default (e.g., microk8s-hostpath)"
fi
echo "Service: ${SERVICE_NAME}"
echo "  ClusterIP: ${CLUSTER_IP}:1433 (in-cluster)"
echo
echo "In-cluster connection examples:"
echo "  Host: ${SERVICE_NAME}.${NAMESPACE}.svc.cluster.local,1433"
echo "  Or:   ${APP_NAME}-0.${APP_NAME}-headless.${NAMESPACE}.svc.cluster.local,1433"
echo
echo "Notes:"
echo "  - If no default StorageClass, enable MicroK8s hostpath storage: 'microk8s enable hostpath-storage'"
echo "  - Keep replicas=1 unless using Always On/HA."
echo "  - For workstation access, use: kubectl -n $NAMESPACE port-forward svc/${SERVICE_NAME} 1433:1433"

# 10) Quick diagnostics if the pod is restarting or not healthy
pod_name=$("${KCTL[@]}" -n "$NAMESPACE" get pods -l app="$APP_NAME" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)
if [[ -n "$pod_name" ]]; then
  phase=$("${KCTL[@]}" -n "$NAMESPACE" get pod "$pod_name" -o jsonpath='{.status.phase}' 2>/dev/null || echo "")
  restarts=$("${KCTL[@]}" -n "$NAMESPACE" get pod "$pod_name" -o jsonpath='{.status.containerStatuses[0].restartCount}' 2>/dev/null || echo "0")
  if [[ "$phase" != "Running" || "${restarts}" != "0" ]]; then
    echo
    echo "Diagnostic: Pod $pod_name phase=$phase restarts=$restarts. Recent container logs (last 200 lines):"
    "${KCTL[@]}" -n "$NAMESPACE" logs "$pod_name" --tail=200 || true
    echo
    echo "Common causes and fixes:"
    echo "- SA password policy: ensure MSSQL_SA_PASSWORD meets SQL policy (>=8 chars, 3 of: upper/lower/digit/symbol)."
    echo "- Memory: SQL Server requires >= 2 GB. If the node is tight on memory, consider MEM_LIMIT=3Gi MEM_REQUEST=3Gi or free memory."
    echo "- Storage permissions: this manifest sets fsGroup=10001; if you changed it, ensure /var/opt/mssql is writable."
    echo "- Existing data: if reusing a PVC from an older run, the SA password env is ignored. Either use the original password or delete the PVC to reinitialize."
    echo "- Transient image issues: if a particular tag is unstable, try pinning IMAGE=mcr.microsoft.com/mssql/server:2022-CU<latest>-ubuntu-22.04"
  fi
fi
