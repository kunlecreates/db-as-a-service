#!/usr/bin/env bash
# deploy-oracle-k8s.sh
# Provision an Oracle Single Instance Database (SIDB) via Oracle Database Operator in Kubernetes.
# - Namespace: oracle-system (default)
# - Exposure: ClusterIP by default (no external NodePort)
# - Storage: dynamic PVC via storageClass (optional) or cluster default
# - Secrets: admin password injected at runtime (never committed)

set -euo pipefail

# ---------------------------
# Defaults (override via env)
# ---------------------------
NAMESPACE="${NAMESPACE:-oracle-system}"
SIDB_NAME="${SIDB_NAME:-oracledb}"
SID="${SID:-ORCL1}"
EDITION="${EDITION:-free}"               # enterprise|standard|express|free
PDB_NAME="${PDB_NAME:-ORCLPDB1}"
IMAGE_PULL_FROM="${IMAGE_PULL_FROM:-container-registry.oracle.com/database/free:23.3.0}"
# Image pull secret is always required; default name if not provided.
IMAGE_PULL_SECRET="${IMAGE_PULL_SECRET:-ocr-pull-secret}"  # name of docker-registry secret, empty to skip
# OCI credentials will be prompted later only if the secret does not already exist
# in the target namespace and no DOCKER_CONFIG_JSON is provided.

OCI_REGISTRY_SERVER="${OCI_REGISTRY_SERVER:-container-registry.oracle.com}"
OCI_REGISTRY_USERNAME="${OCI_REGISTRY_USERNAME:-}"
OCI_REGISTRY_PASSWORD="${OCI_REGISTRY_PASSWORD:-}"
OCI_REGISTRY_EMAIL="${OCI_REGISTRY_EMAIL:-}"

STORAGE_SIZE="${STORAGE_SIZE:-8Gi}"
STORAGE_CLASS="${STORAGE_CLASS:-}"         # empty -> auto-detect cluster default (dynamic) or leave unset (static PV required)
ACCESS_MODE="${ACCESS_MODE:-ReadWriteOnce}" # ReadWriteOnce|ReadWriteMany
REPLICAS="${REPLICAS:-1}"

# Operator install controls
INSTALL_CERT_MANAGER="${INSTALL_CERT_MANAGER:-true}"  # set false to skip auto-install
CERT_MANAGER_NAMESPACE="${CERT_MANAGER_NAMESPACE:-cert-manager-system}"
CERT_MANAGER_VERSION="${CERT_MANAGER_VERSION:-v1.19.1}"
# Method to install cert-manager: helm | apply (raw manifest)
CERT_MANAGER_METHOD="${CERT_MANAGER_METHOD:-helm}"

# Oracle Database Operator namespace (system components)
OPERATOR_NAMESPACE="${OPERATOR_NAMESPACE:-oracle-database-operator-system}"

# Option to skip operator installation entirely (assumes already present)
SKIP_OPERATOR_INSTALL="${SKIP_OPERATOR_INSTALL:-false}"

# Admin password (SYS/SYSTEM/PDBADMIN) from env ORACLE_PWD or prompt securely

if [[ -z "${ORACLE_PWD:-}" ]]; then
  echo "Prompting a strong Oracle admin password (used for SYS/SYSTEM/PDBADMIN)."
  while true; do
    read -r -s -p "Enter Oracle admin password: " ORACLE_PWD
    echo
    read -r -s -p "Confirm: " ORACLE_PWD_CONFIRM
    echo
    if [[ -z "${ORACLE_PWD}" ]]; then
      echo "Password cannot be empty. Try again."
      continue
    fi
    if [[ "${ORACLE_PWD}" != "${ORACLE_PWD_CONFIRM}" ]]; then
      echo "Passwords do not match. Try again."
      continue
    fi
    break
  done
    unset ORACLE_PWD_CONFIRM
else
  echo "Using ORACLE_PWD from environment (non-interactive)."
fi

# ---------------------------
# Utilities
# ---------------------------
log() { echo "[oracle] $*"; }

detect_kubectl() {
  if command -v microk8s >/dev/null 2>&1 && microk8s kubectl config current-context 2>/dev/null | grep -qi "microk8s"; then
    KCTL=(microk8s kubectl)
    log "Using MicroK8s kubectl"
  else
    KCTL=(kubectl)
    log "Using standard kubectl"
  fi
}

ensure_bin() {
  if ! command -v "$1" >/dev/null 2>&1; then
    log "ERROR: '$1' is required to install cert-manager via chart but was not found in PATH."
    log "Please install '$1' or set INSTALL_CERT_MANAGER=false to skip automatic installation."
    exit 1
  fi
}

helm_repo_add_jetstack() {
  helm repo add jetstack https://charts.jetstack.io --force-update
  helm repo update
}

install_chart() {
  # usage: install_chart <release> <chart> <namespace> [extra helm args...]
  local release="$1"; shift
  local chart="$1"; shift
  local ns="$1"; shift
  if ! helm -n "$ns" status "$release" >/dev/null 2>&1; then
    log "Installing helm chart: release=$release chart=$chart ns=$ns"
    helm upgrade --install "$release" "$chart" -n "$ns" --create-namespace "$@"
  else
    log "Helm release $release already present in namespace $ns; skipping install"
  fi
}

is_cert_manager_installed() {
  # detect via CRDs to avoid duplicate installs in a different namespace
  if "${KCTL[@]}" get crd certificates.cert-manager.io >/dev/null 2>&1; then
    return 0
  fi
  return 1
}

ensure_image_pull_secret() {
  if "${KCTL[@]}" -n "$NAMESPACE" get secret "$IMAGE_PULL_SECRET" >/dev/null 2>&1; then
    log "Image pull secret '$IMAGE_PULL_SECRET' already exists in namespace $NAMESPACE; reusing."
    return 0
  fi
  if [[ -n "${DOCKER_CONFIG_JSON:-}" && -f "${DOCKER_CONFIG_JSON}" ]]; then
    log "Creating image pull secret from docker config json: $DOCKER_CONFIG_JSON"
    "${KCTL[@]}" -n "$NAMESPACE" create secret generic "$IMAGE_PULL_SECRET" \
      --type=kubernetes.io/dockerconfigjson \
      --from-file=.dockerconfigjson="$DOCKER_CONFIG_JSON"
    return 0
  fi
  # Interactive prompt for OCI credentials only now (secret absent & no docker config)
  if [[ -z "$OCI_REGISTRY_USERNAME" ]]; then
    read -r -p "Enter OCI registry username: " OCI_REGISTRY_USERNAME
  fi
  if [[ -z "$OCI_REGISTRY_PASSWORD" ]]; then
    read -r -s -p "Enter OCI registry password: " OCI_REGISTRY_PASSWORD
    echo
  fi
  if [[ -z "$OCI_REGISTRY_EMAIL" ]]; then
    read -r -p "Enter OCI registry email (optional): " OCI_REGISTRY_EMAIL
  fi
  if [[ -z "$OCI_REGISTRY_USERNAME" || -z "$OCI_REGISTRY_PASSWORD" ]]; then
    log "ERROR: OCI_REGISTRY_USERNAME and OCI_REGISTRY_PASSWORD are required (or provide DOCKER_CONFIG_JSON) to create image pull secret '$IMAGE_PULL_SECRET'."
    exit 1
  fi
  log "Creating docker-registry secret '$IMAGE_PULL_SECRET' for server $OCI_REGISTRY_SERVER"
  "${KCTL[@]}" -n "$NAMESPACE" create secret docker-registry "$IMAGE_PULL_SECRET" \
    --docker-server="$OCI_REGISTRY_SERVER" \
    --docker-username="$OCI_REGISTRY_USERNAME" \
    --docker-password="$OCI_REGISTRY_PASSWORD" \
    ${OCI_REGISTRY_EMAIL:+--docker-email="$OCI_REGISTRY_EMAIL"}
}

wait_for_operator() {
  local ns="${OPERATOR_NAMESPACE}"
  log "Waiting for Oracle Database Operator to be ready in namespace: $ns"
  # wait up to ~5 minutes
  for i in {1..60}; do
    if "${KCTL[@]}" get deploy -n "$ns" oracle-database-operator-controller-manager >/dev/null 2>&1; then
      if "${KCTL[@]}" -n "$ns" rollout status deploy/oracle-database-operator-controller-manager --timeout=30s >/dev/null 2>&1; then
        log "Operator is ready"
        return 0
      fi
    fi
    sleep 5
  done
  log "WARNING: Operator may not be fully ready yet; continuing."
}

wait_for_sidb_healthy() {
  local name="$1" ns="$2"
  log "Waiting for SingleInstanceDatabase/$name to become Healthy..."
  # up to 20 minutes (oracle DB bootstrap can take a while)
  local end=$((SECONDS + 1200))
  while (( SECONDS < end )); do
    local status
    status=$("${KCTL[@]}" -n "$ns" get singleinstancedatabase "$name" -o jsonpath='{.status.status}' 2>/dev/null || true)
    if [[ "$status" == "Healthy" ]]; then
      log "Database is Healthy"
      return 0
    fi
    sleep 15
  done
  log "WARNING: Timed out waiting for database to become Healthy. Current status: $("${KCTL[@]}" -n "$ns" get singleinstancedatabase "$name" -o jsonpath='{.status.status}' 2>/dev/null || echo unknown)"
}

detect_kubectl
ensure_bin "${KCTL[@]}"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# Enforce required values for Free edition
if [[ "${EDITION}" == "free" ]]; then
  SID="FREE"
  PDB_NAME="FREEPDB1"
  REPLICAS=1
  # Override image for free edition to known working tag (Oracle samples use :latest and prebuiltDB true)
  IMAGE_PULL_FROM="${IMAGE_PULL_FROM_FREE_OVERRIDE:-container-registry.oracle.com/database/free:latest}"
  log "Free edition selected; enforcing SID=${SID}, PDB_NAME=${PDB_NAME}, image=${IMAGE_PULL_FROM} (prebuiltDB=true)"
fi

# ---------------------------
# Install operator (if needed)
# ---------------------------
log "Pre-flight: Oracle Container Registry images require license acceptance and valid credentials for $OCI_REGISTRY_SERVER. Ensure network connectivity before proceeding."

# cert-manager (required for webhooks)
if [[ "$INSTALL_CERT_MANAGER" == "true" ]]; then
  if is_cert_manager_installed; then
    log "cert-manager CRDs found; assuming cert-manager is installed. Skipping installation."
  else
    if [[ "$CERT_MANAGER_METHOD" == "helm" ]]; then
      ensure_bin helm
      helm_repo_add_jetstack
      if helm list -n "$CERT_MANAGER_NAMESPACE" | grep -q cert-manager; then
        log "cert-manager is already installed in namespace $CERT_MANAGER_NAMESPACE. Skipping installation."
      else
        install_chart cert-manager jetstack/cert-manager "$CERT_MANAGER_NAMESPACE" \
          --version "$CERT_MANAGER_VERSION" \
          --set crds.enabled=true
      fi
    else
      # Apply raw manifest from GitHub release
      log "Installing cert-manager via raw manifest (method=apply) version=$CERT_MANAGER_VERSION"
      "${KCTL[@]}" apply -f "https://github.com/cert-manager/cert-manager/releases/download/${CERT_MANAGER_VERSION}/cert-manager.yaml"
    fi
  fi
else
  log "Skipping cert-manager installation per INSTALL_CERT_MANAGER=false"
fi

# Oracle operator RBAC + deployment (idempotent apply unless skipped)
if [[ "$SKIP_OPERATOR_INSTALL" != "true" ]]; then
  log "Applying Oracle operator RBAC (cluster-role-binding) ..."
  "${KCTL[@]}" apply -f https://raw.githubusercontent.com/oracle/oracle-database-operator/main/rbac/cluster-role-binding.yaml
  log "Applying Oracle operator deployment (idempotent) ..."
  "${KCTL[@]}" apply -f https://raw.githubusercontent.com/oracle/oracle-database-operator/main/oracle-database-operator.yaml
else
  log "Skipping operator installation per SKIP_OPERATOR_INSTALL=true"
fi

wait_for_operator

# ---------------------------
# Namespace
# ---------------------------
log "Creating/ensuring namespace: $NAMESPACE"
sed "s/__NAMESPACE__/${NAMESPACE}/g" "$SCRIPT_DIR/00-namespace.yaml" | "${KCTL[@]}" apply -f -

# ---------------------------
# Secret (admin password)
# ---------------------------
ADMIN_SECRET_NAME="db-admin-secret"
log "Creating admin password Secret in namespace $NAMESPACE"
tmp_secret=$(mktemp)
sed -e "s#__ADMIN_SECRET_NAME__#${ADMIN_SECRET_NAME}#g" \
    -e "s#__ORACLE_PWD__#${ORACLE_PWD}#g" \
    "$SCRIPT_DIR/10-secret.yaml" > "$tmp_secret"
"${KCTL[@]}" -n "$NAMESPACE" apply -f "$tmp_secret"
rm -f "$tmp_secret"

# ---------------------------
# Ensure image pull secret (if requested)
# ---------------------------
ensure_image_pull_secret

# ---------------------------
# Apply SingleInstanceDatabase CR
# ---------------------------
log "Applying SingleInstanceDatabase ($SIDB_NAME) ..."
tmp_sidb=$(mktemp)
cp "$SCRIPT_DIR/20-sidb.yaml" "$tmp_sidb"
sed -i "s#__NAMESPACE__#${NAMESPACE}#g" "$tmp_sidb"
sed -i "s#__SIDB_NAME__#${SIDB_NAME}#g" "$tmp_sidb"
sed -i "s#__SID__#${SID}#g" "$tmp_sidb"
sed -i "s#__EDITION__#${EDITION}#g" "$tmp_sidb"
sed -i "s#__PDB_NAME__#${PDB_NAME}#g" "$tmp_sidb"
sed -i "s#__ADMIN_SECRET_NAME__#${ADMIN_SECRET_NAME}#g" "$tmp_sidb"
sed -i "s#__IMAGE_PULL_FROM__#${IMAGE_PULL_FROM}#g" "$tmp_sidb"
sed -i "s#__IMAGE_PULL_SECRET__#${IMAGE_PULL_SECRET}#g" "$tmp_sidb"
sed -i "s#__STORAGE_SIZE__#${STORAGE_SIZE}#g" "$tmp_sidb"
# Enable prebuiltDB for free edition automatically (faster startup, matches Oracle samples)
if [[ "${EDITION}" == "free" ]]; then
  sed -i "s/prebuiltDB: false/prebuiltDB: true/" "$tmp_sidb"
fi
# Auto-detect default StorageClass if none provided (dynamic provisioning). If none detected, leave line removed (static provisioning requires pre-created PV referenced via datafilesVolumeName— not presently templated here).
if [[ -z "$STORAGE_CLASS" ]]; then
  DEFAULT_SC=$("${KCTL[@]}" get sc -o jsonpath='{range .items[?(@.metadata.annotations.storageclass\.kubernetes\.io/is-default-class=="true")]}{.metadata.name}{end}' 2>/dev/null || true)
  if [[ -n "$DEFAULT_SC" ]]; then
    STORAGE_CLASS="$DEFAULT_SC"
    log "Detected default StorageClass '$STORAGE_CLASS'; using it for dynamic provisioning. Override with STORAGE_CLASS=... to change."
  else
    log "No default StorageClass detected; proceeding without storageClass (requires a statically pre-provisioned PV bound later)."
  fi
fi
if [[ -n "$STORAGE_CLASS" ]]; then
  sed -i "s#__STORAGE_CLASS_NAME__#${STORAGE_CLASS}#g" "$tmp_sidb"
else
  sed -i "/storageClass:/d" "$tmp_sidb"
fi
sed -i "s#__ACCESS_MODE__#${ACCESS_MODE}#g" "$tmp_sidb"

# replicas is integer; replace placeholder explicitly
sed -i "s#__REPLICAS__#${REPLICAS}#g" "$tmp_sidb"

"${KCTL[@]}" -n "$NAMESPACE" apply -f "$tmp_sidb"
rm -f "$tmp_sidb"

# ---------------------------
# Wait and summarize
# ---------------------------
wait_for_sidb_healthy "$SIDB_NAME" "$NAMESPACE" || true

# If pods are in ErrImagePull, abort with guidance (fallback removed; OCR image required)
if "${KCTL[@]}" -n "$NAMESPACE" get pods -l app=oracledb -o jsonpath='{.items[*].status.initContainerStatuses[*].state.waiting.reason}' 2>/dev/null | grep -q "ErrImagePull\|ImagePullBackOff"; then
  log "ERROR: Image pull failure detected for Oracle database pod(s)."
  log "Ensure: (1) IMAGE_PULL_SECRET exists and has valid credentials for $OCI_REGISTRY_SERVER, (2) you accepted Oracle Container Registry license, (3) network access is available."
  exit 1
fi

CONNECT_STR=$("${KCTL[@]}" -n "$NAMESPACE" get singleinstancedatabase "$SIDB_NAME" -o jsonpath='{.status.connectString}' 2>/dev/null || true)
PDB_CONNECT_STR=$("${KCTL[@]}" -n "$NAMESPACE" get singleinstancedatabase "$SIDB_NAME" -o jsonpath='{.status.pdbConnectString}' 2>/dev/null || true)
OEM_URL=$("${KCTL[@]}" -n "$NAMESPACE" get singleinstancedatabase "$SIDB_NAME" -o jsonpath='{.status.oemExpressUrl}' 2>/dev/null || true)

echo
echo "Deployment complete."
echo "Namespace:           $NAMESPACE"
echo "Resource name:       $SIDB_NAME"
echo "SID / PDB:           $SID / $PDB_NAME"
echo "Edition:             $EDITION"
echo "Image:               $IMAGE_PULL_FROM"
echo "Image pull secret:    $IMAGE_PULL_SECRET"
echo "Storage size:         $STORAGE_SIZE"
if [[ -n "$STORAGE_CLASS" ]]; then echo "StorageClass:         $STORAGE_CLASS"; else echo "StorageClass:         cluster default"; fi
echo "AccessMode:           $ACCESS_MODE"
echo "Service:              ClusterIP (internal only)"
echo "Replicas:             $REPLICAS"
echo
echo "Connect strings (once Healthy):"
echo "  CDB: $CONNECT_STR"
echo "  PDB: $PDB_CONNECT_STR"
if [[ -n "$OEM_URL" ]]; then echo "  OEM Express: $OEM_URL"; fi
echo
echo "Notes:"
echo "  - Operator install is cluster-scoped; cert-manager is required for webhooks."
echo "  - Oracle Container Registry images always require a docker-registry secret. Set IMAGE_PULL_SECRET/OCI_REGISTRY_* (or DOCKER_CONFIG_JSON) and ensure you've accepted the OCR image license."
echo "  - Password was injected at runtime via a Secret (not committed)."
echo "  - To remove: kubectl -n $NAMESPACE delete singleinstancedatabase.database.oracle.com $SIDB_NAME"
