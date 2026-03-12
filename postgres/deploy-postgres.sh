#!/usr/bin/env bash

set -euo pipefail

# PostgreSQL deploy script for Kubernetes (MicroK8s-friendly)
# - Installs/Upgrades Bitnami PostgreSQL (non-HA by default) via Helm in the namespace "postgres-system"
# - Service exposure: ClusterIP by default (recommended). Use port-forward or in-cluster DNS.
# - Creates a runtime Secret for credentials (never commit passwords)
# - Waits for readiness and prints connection info
# - Optional HA mode uses Bitnami postgresql-ha (Pgpool-II + Repmgr) with different values schema
#
# Requirements:
# - kubectl configured to point at your cluster
# - helm v3
#
# Usage examples:
#   bash postgres/deploy-postgres-k8s.sh
#   STORAGE_CLASS=microk8s-hostpath bash postgres/deploy-postgres-k8s.sh
#   # To upgrade with a new password, either delete the PV or enable passwordUpdateJob (see chart docs)
#   # Reproducibility: optionally pin a chart version with CHART_VERSION=16.4.2 or similar

NAMESPACE=${NAMESPACE:-postgres-system}
RELEASE=${RELEASE:-postgresql}
HA=${HA:-false}
CHART_REPO_NAME=${CHART_REPO_NAME:-bitnami}
CHART_REPO_URL=${CHART_REPO_URL:-https://charts.bitnami.com/bitnami}
# Default to OCI references; allow override via CHART_NAME env
if [[ -z "${CHART_NAME:-}" ]]; then
  if [[ "${HA}" == "true" ]]; then
    CHART_NAME="oci://registry-1.docker.io/bitnamicharts/postgresql-ha"
  else
    CHART_NAME="oci://registry-1.docker.io/bitnamicharts/postgresql"
  fi
fi
CHART_VERSION=${CHART_VERSION:-}
STORAGE_CLASS=${STORAGE_CLASS:-}
PVC_SIZE=${PVC_SIZE:-8Gi}

# Registry and image options (align with README)
IMAGE_REGISTRY=${IMAGE_REGISTRY:-}
ALLOW_INSECURE_IMAGES=${ALLOW_INSECURE_IMAGES:-false}
IMAGE_PULL_SECRETS=${IMAGE_PULL_SECRETS:-}
DOCKERHUB_SECRET_NAME=${DOCKERHUB_SECRET_NAME:-dockerhub-cred}
# If provided, a Docker Hub pull secret will be created and wired globally
DOCKERHUB_USERNAME=${DOCKERHUB_USERNAME:-}
DOCKERHUB_PASSWORD=${DOCKERHUB_PASSWORD:-}
DOCKERHUB_EMAIL=${DOCKERHUB_EMAIL:-}

# Optional image tag overrides (see README)
# HA-only
POSTGRESQL_REPMGR_IMAGE_TAG=${POSTGRESQL_REPMGR_IMAGE_TAG:-}
PGPOOL_IMAGE_TAG=${PGPOOL_IMAGE_TAG:-}
# Common (volumePermissions init)
OS_SHELL_IMAGE_TAG=${OS_SHELL_IMAGE_TAG:-}
# Non-HA only
POSTGRESQL_IMAGE_TAG=${POSTGRESQL_IMAGE_TAG:-}

# Optional resource requests/limits (non-HA primary or HA components)
# Non-HA chart keys: primary.resources.{requests,limits}
PRIMARY_CPU_REQUEST=${PRIMARY_CPU_REQUEST:-}
PRIMARY_MEM_REQUEST=${PRIMARY_MEM_REQUEST:-}
PRIMARY_CPU_LIMIT=${PRIMARY_CPU_LIMIT:-}
PRIMARY_MEM_LIMIT=${PRIMARY_MEM_LIMIT:-}

# HA chart keys: postgresql.resources / pgpool.resources
POSTGRESQL_CPU_REQUEST=${POSTGRESQL_CPU_REQUEST:-}
POSTGRESQL_MEM_REQUEST=${POSTGRESQL_MEM_REQUEST:-}
POSTGRESQL_CPU_LIMIT=${POSTGRESQL_CPU_LIMIT:-}
POSTGRESQL_MEM_LIMIT=${POSTGRESQL_MEM_LIMIT:-}
PGPOOL_CPU_REQUEST=${PGPOOL_CPU_REQUEST:-}
PGPOOL_MEM_REQUEST=${PGPOOL_MEM_REQUEST:-}
PGPOOL_CPU_LIMIT=${PGPOOL_CPU_LIMIT:-}
PGPOOL_MEM_LIMIT=${PGPOOL_MEM_LIMIT:-}

# volumePermissions init container resources (both charts)
VP_CPU_REQUEST=${VP_CPU_REQUEST:-}
VP_MEM_REQUEST=${VP_MEM_REQUEST:-}
VP_CPU_LIMIT=${VP_CPU_LIMIT:-}
VP_MEM_LIMIT=${VP_MEM_LIMIT:-}

# Service type: ClusterIP|NodePort|LoadBalancer (default: ClusterIP). Prefer ClusterIP for in-cluster access.
SERVICE_TYPE=${SERVICE_TYPE:-ClusterIP}

# Password handling: the script will prompt interactively for the admin password
# Alternatively, set POSTGRES_PASSWORD to run non-interactively

detect_kubectl() {
  if command -v microk8s >/dev/null 2>&1 && microk8s kubectl config current-context 2>/dev/null | grep -qi "microk8s"; then
    KCTL=(microk8s kubectl)
  else
    KCTL=(kubectl)
  fi
}

ensure_bin() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "Error: '$1' not found in PATH. Please install it and retry." >&2
    exit 1
  fi
}

ensure_helm_repo() {
  if ! helm repo list | awk '{print $1}' | grep -qx "$CHART_REPO_NAME"; then
    echo "Adding Helm repo $CHART_REPO_NAME -> $CHART_REPO_URL"
    helm repo add "$CHART_REPO_NAME" "$CHART_REPO_URL"
  fi
  echo "Updating Helm repos"
  helm repo update >/dev/null
}

ensure_namespace() {
  if ! "${KCTL[@]}" get ns "$NAMESPACE" >/dev/null 2>&1; then
    echo "Creating namespace $NAMESPACE"
    "${KCTL[@]}" create namespace "$NAMESPACE"
  fi
}

# Optionally create a Docker Hub registry secret and wire it globally
ensure_image_pull_secret() {
  if [[ -n "$DOCKERHUB_USERNAME" && -n "$DOCKERHUB_PASSWORD" ]]; then
    if ! "${KCTL[@]}" -n "$NAMESPACE" get secret "$DOCKERHUB_SECRET_NAME" >/dev/null 2>&1; then
      echo "Creating imagePullSecret '$DOCKERHUB_SECRET_NAME' for Docker Hub in $NAMESPACE"
      "${KCTL[@]}" -n "$NAMESPACE" create secret docker-registry "$DOCKERHUB_SECRET_NAME" \
        --docker-server="https://index.docker.io/v1/" \
        --docker-username="$DOCKERHUB_USERNAME" \
        --docker-password="$DOCKERHUB_PASSWORD" \
        ${DOCKERHUB_EMAIL:+--docker-email="$DOCKERHUB_EMAIL"}
    else
      echo "imagePullSecret '$DOCKERHUB_SECRET_NAME' already exists in $NAMESPACE"
    fi
    # If IMAGE_PULL_SECRETS not provided, default to the created secret
    if [[ -z "$IMAGE_PULL_SECRETS" ]]; then
      IMAGE_PULL_SECRETS="$DOCKERHUB_SECRET_NAME"
    fi
  fi
}

ensure_secret() {
  local secret_name=$1
  local password_value=$2
  local ha_mode=${3:-false}

  # Secret must contain key "postgres-password" (non-HA). For HA, also include "password" and "repmgr-password".
  if "${KCTL[@]}" -n "$NAMESPACE" get secret "$secret_name" >/dev/null 2>&1; then
    echo "Secret $secret_name already exists in $NAMESPACE. Leaving as-is."
  else
    echo "Creating Secret $secret_name in $NAMESPACE"
    if [[ "$ha_mode" == "true" ]]; then
      local repmgr_pw=${REPMGR_PASSWORD:-$password_value}
      # Include admin (postgres), default user (password), and repmgr credentials
      "${KCTL[@]}" -n "$NAMESPACE" create secret generic "$secret_name" \
        --from-literal=postgres-password="$password_value" \
        --from-literal=password="$password_value" \
        --from-literal=repmgr-password="$repmgr_pw"
    else
      "${KCTL[@]}" -n "$NAMESPACE" create secret generic "$secret_name" \
        --from-literal=postgres-password="$password_value"
    fi
  fi
}

wait_for_ready() {
  local ha_mode=${1:-false}
  echo "Waiting for PostgreSQL StatefulSet to be ready..."
  local sts=""
  # Try selector for non-HA chart
  sts=$("${KCTL[@]}" -n "$NAMESPACE" get sts -l app.kubernetes.io/instance="$RELEASE",app.kubernetes.io/name=postgresql -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)
  if [[ -z "${sts:-}" ]]; then
    # Try selector for HA chart (component=postgresql)
    sts=$("${KCTL[@]}" -n "$NAMESPACE" get sts -l app.kubernetes.io/instance="$RELEASE",app.kubernetes.io/component=postgresql -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)
  fi
  if [[ -z "${sts:-}" ]]; then
    echo "Could not find the PostgreSQL StatefulSet for release $RELEASE in $NAMESPACE" >&2
    exit 1
  fi
  "${KCTL[@]}" -n "$NAMESPACE" rollout status sts "$sts" --timeout=10m

  if [[ "$ha_mode" == "true" ]]; then
    echo "Waiting for Pgpool deployment to be ready (HA mode)..."
    local pgpool
    pgpool=$("${KCTL[@]}" -n "$NAMESPACE" get deploy -l app.kubernetes.io/instance="$RELEASE",app.kubernetes.io/component=pgpool -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)
    if [[ -n "${pgpool:-}" ]]; then
      "${KCTL[@]}" -n "$NAMESPACE" rollout status deploy "$pgpool" --timeout=10m
    else
      echo "Warning: Pgpool deployment not found via labels; continuing."
    fi
  fi
}

print_connection_info() {
  local ha_mode=${1:-false}
  local svc
  if [[ "$ha_mode" == "true" ]]; then
    svc="${RELEASE}-pgpool"
  else
    # Bitnami postgresql chart exposes the primary service as the release name
    # e.g., release "postgresql" -> service "postgresql"
    svc="${RELEASE}"
  fi
  local port
  # For ClusterIP, nodePort may be empty; report the service port instead
  port=$("${KCTL[@]}" -n "$NAMESPACE" get svc "$svc" -o jsonpath='{.spec.ports[0].port}')

  # Node IP (first node)
  local node_ip
  node_ip=$("${KCTL[@]}" get nodes -o jsonpath='{.items[0].status.addresses[?(@.type=="InternalIP")].address}')

  echo
  echo "PostgreSQL is ready. Connection options:"
  echo "- In-cluster DNS (ClusterIP): host=$svc.$NAMESPACE.svc.cluster.local port=$port user=postgres"
  echo "  Example (from a pod): PGPASSWORD=****** psql -h $svc.$NAMESPACE.svc.cluster.local -p $port -U postgres"
  echo "- Port-forward (from workstation): kubectl -n $NAMESPACE port-forward svc/$svc 5432:5432"
  echo "  Then: PGPASSWORD=****** psql -h 127.0.0.1 -p 5432 -U postgres"

  echo
  echo "To retrieve the admin password from the Secret later:"
  echo "  kubectl -n $NAMESPACE get secret ${SECRET_NAME:-postgresql-auth} -o jsonpath='{.data.postgres-password}' | base64 -d"
}

# HA enablement guidance (printed when SHOW_HA_GUIDANCE=true)
print_ha_guidance() {
  cat <<'EOF'
==================== PostgreSQL HA (Bitnami postgresql-ha) Guidance ====================
Current deployment is non-HA (single primary). To migrate or install HA later:

1. Verify image availability:
  - Ensure required HA images (postgresql-repmgr, pgpool, os-shell) are pullable.
  - If gated, obtain subscription credentials and create a pull secret:
    kubectl create secret docker-registry bitnami-secure-cred \
     --docker-server=REGISTRY_URL --docker-username=USER --docker-password=TOKEN -n postgres-system

2. Backup existing data (before switching):
  kubectl -n postgres-system exec sts/postgresql -- bash -c 'pg_dumpall -U postgres' > backup.sql

3. Prepare environment variables (example):
  export HA=true
  export CHART_NAME=oci://registry-1.docker.io/bitnamicharts/postgresql-ha
  export POSTGRES_PASSWORD='YourExistingPassword'   # must match secret or recreate it
  # Optional resource tuning:
  export POSTGRESQL_CPU_REQUEST=250m
  export POSTGRESQL_MEM_REQUEST=512Mi
  export PGPOOL_CPU_REQUEST=100m
  export PGPOOL_MEM_REQUEST=256Mi

4. Run upgrade (may require HELM_FORCE if immutable fields differ):
  HELM_FORCE=true ./postgres/deploy-postgres-k8s.sh

5. Validate:
  kubectl -n postgres-system get pods -l app.kubernetes.io/component=postgresql
  kubectl -n postgres-system get deploy -l app.kubernetes.io/component=pgpool

6. Connection through pgpool service:
  kubectl -n postgres-system port-forward svc/postgresql-pgpool 5432:5432
  PGPASSWORD=****** psql -h 127.0.0.1 -p 5432 -U postgres

Troubleshooting:
 - ImagePullBackOff (NotFound): confirm repository/tag & subscription.
 - CrashLoopBackOff: inspect logs (kubectl logs <pod> -c postgresql) & pgpool config.
 - Replication issues: check repmgr logs and ensure password keys in secret: postgres-password, password, repmgr-password.
========================================================================================
EOF
}

main() {
  ensure_bin "${KCTL[@]}"
  ensure_bin helm
  ensure_namespace
  # Optionally create Docker Hub pull secret
  ensure_image_pull_secret
  # For OCI charts, repo add/update is not required. Only ensure repo for non-OCI references.
  if [[ "$CHART_NAME" != oci://* ]]; then
    ensure_helm_repo
  fi

  # Prepare password (prompt interactively, do not accept via env or auto-generate)
  if [[ -z "${POSTGRES_PASSWORD:-}" ]]; then
    echo "Enter a strong admin password for the 'postgres' user."
    while true; do
      read -r -s -p "Password: " POSTGRES_PASSWORD
      echo
      read -r -s -p "Confirm: " POSTGRES_PASSWORD_CONFIRM
      echo
      if [[ -z "${POSTGRES_PASSWORD}" ]]; then
        echo "Password cannot be empty. Try again."
        continue
      fi
      if [[ "${POSTGRES_PASSWORD}" != "${POSTGRES_PASSWORD_CONFIRM}" ]]; then
        echo "Passwords do not match. Try again."
        continue
      fi
      break
    done
    unset POSTGRES_PASSWORD_CONFIRM
  else
    echo "Using POSTGRES_PASSWORD from environment (non-interactive)."
  fi

  # Create Secret with required key(s) for Bitnami chart
  SECRET_NAME=${SECRET_NAME:-postgresql-auth}
  ensure_secret "$SECRET_NAME" "$POSTGRES_PASSWORD" "$HA"

  # Helm values
  # - Use existing secret for auth
  # - Service type set appropriately (primary.service.type for non-HA, service.type for HA)
  # - Optionally set a storageClass
  # - Enable volumePermissions to fix PV ownership on some hostPath storage classes
  HELM_ARGS=(
    --namespace "$NAMESPACE"
    --create-namespace
  )

  if [[ "$HA" == "true" ]]; then
    HELM_ARGS+=(
      --set postgresql.existingSecret="$SECRET_NAME"
      --set service.type="$SERVICE_TYPE"
      --set volumePermissions.enabled=true
      --set persistence.size="$PVC_SIZE"
    )
    if [[ -n "$STORAGE_CLASS" ]]; then
      HELM_ARGS+=(--set persistence.storageClass="$STORAGE_CLASS")
    fi
    # Registry selection (HA chart keys)
    if [[ -n "$IMAGE_REGISTRY" ]]; then
      HELM_ARGS+=(
        --set global.imageRegistry="$IMAGE_REGISTRY"
        --set postgresql.image.registry="$IMAGE_REGISTRY"
        --set pgpool.image.registry="$IMAGE_REGISTRY"
        --set volumePermissions.image.registry="$IMAGE_REGISTRY"
      )
    fi
    # HA image tag overrides
    if [[ -n "$POSTGRESQL_REPMGR_IMAGE_TAG" ]]; then HELM_ARGS+=(--set postgresql.image.tag="$POSTGRESQL_REPMGR_IMAGE_TAG"); fi
    if [[ -n "$PGPOOL_IMAGE_TAG" ]]; then HELM_ARGS+=(--set pgpool.image.tag="$PGPOOL_IMAGE_TAG"); fi
    # HA resources
    if [[ -n "$POSTGRESQL_CPU_REQUEST" ]]; then HELM_ARGS+=(--set postgresql.resources.requests.cpu="$POSTGRESQL_CPU_REQUEST"); fi
    if [[ -n "$POSTGRESQL_MEM_REQUEST" ]]; then HELM_ARGS+=(--set postgresql.resources.requests.memory="$POSTGRESQL_MEM_REQUEST"); fi
    if [[ -n "$POSTGRESQL_CPU_LIMIT" ]]; then HELM_ARGS+=(--set postgresql.resources.limits.cpu="$POSTGRESQL_CPU_LIMIT"); fi
    if [[ -n "$POSTGRESQL_MEM_LIMIT" ]]; then HELM_ARGS+=(--set postgresql.resources.limits.memory="$POSTGRESQL_MEM_LIMIT"); fi
    if [[ -n "$PGPOOL_CPU_REQUEST" ]]; then HELM_ARGS+=(--set pgpool.resources.requests.cpu="$PGPOOL_CPU_REQUEST"); fi
    if [[ -n "$PGPOOL_MEM_REQUEST" ]]; then HELM_ARGS+=(--set pgpool.resources.requests.memory="$PGPOOL_MEM_REQUEST"); fi
    if [[ -n "$PGPOOL_CPU_LIMIT" ]]; then HELM_ARGS+=(--set pgpool.resources.limits.cpu="$PGPOOL_CPU_LIMIT"); fi
    if [[ -n "$PGPOOL_MEM_LIMIT" ]]; then HELM_ARGS+=(--set pgpool.resources.limits.memory="$PGPOOL_MEM_LIMIT"); fi
  else
    HELM_ARGS+=(
      --set auth.existingSecret="$SECRET_NAME"
      --set primary.service.type="$SERVICE_TYPE"
      --set volumePermissions.enabled=true
      --set primary.persistence.size="$PVC_SIZE"
    )
    if [[ -n "$STORAGE_CLASS" ]]; then
      HELM_ARGS+=(--set primary.persistence.storageClass="$STORAGE_CLASS")
    fi
    # Registry selection (non-HA chart keys)
    if [[ -n "$IMAGE_REGISTRY" ]]; then
      HELM_ARGS+=(
        --set global.imageRegistry="$IMAGE_REGISTRY"
        --set image.registry="$IMAGE_REGISTRY"
        --set volumePermissions.image.registry="$IMAGE_REGISTRY"
      )
    fi
    # Non-HA image tag override
    if [[ -n "$POSTGRESQL_IMAGE_TAG" ]]; then HELM_ARGS+=(--set image.tag="$POSTGRESQL_IMAGE_TAG"); fi
    # Non-HA resources
    if [[ -n "$PRIMARY_CPU_REQUEST" ]]; then HELM_ARGS+=(--set primary.resources.requests.cpu="$PRIMARY_CPU_REQUEST"); fi
    if [[ -n "$PRIMARY_MEM_REQUEST" ]]; then HELM_ARGS+=(--set primary.resources.requests.memory="$PRIMARY_MEM_REQUEST"); fi
    if [[ -n "$PRIMARY_CPU_LIMIT" ]]; then HELM_ARGS+=(--set primary.resources.limits.cpu="$PRIMARY_CPU_LIMIT"); fi
    if [[ -n "$PRIMARY_MEM_LIMIT" ]]; then HELM_ARGS+=(--set primary.resources.limits.memory="$PRIMARY_MEM_LIMIT"); fi
  fi

  # volumePermissions init container resources (shared)
  if [[ -n "$VP_CPU_REQUEST" ]]; then HELM_ARGS+=(--set volumePermissions.resources.requests.cpu="$VP_CPU_REQUEST"); fi
  if [[ -n "$VP_MEM_REQUEST" ]]; then HELM_ARGS+=(--set volumePermissions.resources.requests.memory="$VP_MEM_REQUEST"); fi
  if [[ -n "$VP_CPU_LIMIT" ]]; then HELM_ARGS+=(--set volumePermissions.resources.limits.cpu="$VP_CPU_LIMIT"); fi
  if [[ -n "$VP_MEM_LIMIT" ]]; then HELM_ARGS+=(--set volumePermissions.resources.limits.memory="$VP_MEM_LIMIT"); fi

  # volumePermissions image tag override
  if [[ -n "$OS_SHELL_IMAGE_TAG" ]]; then HELM_ARGS+=(--set volumePermissions.image.tag="$OS_SHELL_IMAGE_TAG"); fi

  # Global insecure image verification allowance
  if [[ "$ALLOW_INSECURE_IMAGES" == "true" ]]; then
    HELM_ARGS+=(--set global.security.allowInsecureImages=true)
  fi

  # Wire imagePullSecrets globally, if provided
  if [[ -n "$IMAGE_PULL_SECRETS" ]]; then
    IFS=',' read -r -a _ips_arr <<< "$IMAGE_PULL_SECRETS"
    for i in "${!_ips_arr[@]}"; do
      secret_name="${_ips_arr[$i]}"
      secret_name="${secret_name// /}"
      if [[ -n "$secret_name" ]]; then
        HELM_ARGS+=(--set "global.imagePullSecrets[$i]=$secret_name")
      fi
    done
    unset _ips_arr
  fi

  if [[ -n "$CHART_VERSION" ]]; then
    HELM_ARGS+=(--version "$CHART_VERSION")
  fi
  # Note: With ClusterIP (default), no nodePorts are configured. If you intentionally
  # set SERVICE_TYPE=NodePort, you may add a nodePort override at your own risk.

  echo "Installing/Upgrading $RELEASE using chart $CHART_NAME in $NAMESPACE..."
  helm upgrade --install "$RELEASE" "$CHART_NAME" "${HELM_ARGS[@]}"

  wait_for_ready "$HA"
  print_connection_info "$HA"

  if [[ "${SHOW_HA_GUIDANCE:-false}" == "true" && "$HA" != "true" ]]; then
    print_ha_guidance
  fi
}

detect_kubectl

main "$@"

exit 0
