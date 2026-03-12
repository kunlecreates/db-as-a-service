#!/usr/bin/env bash
set -euo pipefail

# Helper script: Provision product-service schema + security on PostgreSQL in Kubernetes
# Steps:
# 1) Create database if missing
# 2) Apply schema.sql
# 3) Apply security.sql with in-memory password substitution
# 4) Verify

# Configurable environment
NAMESPACE="${NAMESPACE:-postgres-system}"
SERVICE_NAME="${SERVICE_NAME:-postgresql}"
POD_NAME="${POD_NAME:-}"
DB_NAME="${DB_NAME:-product_svc}"
SCHEMA_FILE="${SCHEMA_FILE:-db-schemas/postgres/product-service/schema.sql}"
SECURITY_FILE="${SECURITY_FILE:-db-schemas/postgres/product-service/security.sql}"
SECRET_NAME="${SECRET_NAME:-postgresql-auth}"
SECRET_KEY="${SECRET_KEY:-postgres-password}"
APP_PWD="${APP_PWD:-}"
DEBUG="${DEBUG:-0}"

echo "[info] Target: ns=$NAMESPACE service=$SERVICE_NAME db=$DB_NAME"

# Resolve pod via service endpoints first, then by label, then default to postgresql-0
if [[ -z "$POD_NAME" ]]; then
  POD_NAME="$(kubectl -n "$NAMESPACE" get endpoints "$SERVICE_NAME" -o jsonpath='{.subsets[0].addresses[0].targetRef.name}' 2>/dev/null || true)"
fi
if [[ -z "$POD_NAME" ]]; then
  POD_NAME="$(kubectl -n "$NAMESPACE" get pods -l app.kubernetes.io/name=postgresql -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)"
fi
if [[ -z "$POD_NAME" ]]; then
  POD_NAME="postgresql-0"
fi
echo "[info] Using pod: $POD_NAME"

if [[ ! -f "$SCHEMA_FILE" ]]; then
  echo "[error] Schema file not found: $SCHEMA_FILE" >&2
  exit 1
fi
if [[ ! -f "$SECURITY_FILE" ]]; then
  echo "[error] Security file not found: $SECURITY_FILE" >&2
  exit 1
fi

pg_pwd_cmd=(kubectl -n "$NAMESPACE" get secret "$SECRET_NAME" -o jsonpath="{.data.$SECRET_KEY}")
PG_PWD_FETCH() {
  "${pg_pwd_cmd[@]}" | base64 --decode
}

echo "[step] Ensuring database exists: $DB_NAME"
exists=$(kubectl -n "$NAMESPACE" exec -i "$POD_NAME" -- \
  env PGPASSWORD="$(PG_PWD_FETCH)" \
  psql -U postgres -tAc "SELECT 1 FROM pg_database WHERE datname='${DB_NAME}'" 2>/dev/null | tr -d '[:space:]') || exists=""
if [[ "$exists" != "1" ]]; then
  echo "[info] Creating database $DB_NAME"
  kubectl -n "$NAMESPACE" exec -i "$POD_NAME" -- \
    env PGPASSWORD="$(PG_PWD_FETCH)" \
    psql -U postgres -v ON_ERROR_STOP=1 -c "CREATE DATABASE ${DB_NAME} WITH OWNER = postgres ENCODING = 'UTF8' LC_COLLATE = 'en_US.utf8' LC_CTYPE = 'en_US.utf8' TEMPLATE = template0;"
else
  echo "[info] Database $DB_NAME already exists"
fi

echo "[step] Applying schema: $SCHEMA_FILE"
kubectl -n "$NAMESPACE" exec -i "$POD_NAME" -- \
  env PGPASSWORD="$(PG_PWD_FETCH)" \
  psql -U postgres -d "$DB_NAME" -v ON_ERROR_STOP=1 < "$SCHEMA_FILE"

set +o history || true
if [[ -z "$APP_PWD" ]]; then  
  while true; do
    read -r -s -p "Enter the App user password (product_app): " APP_PWD
    echo
    read -r -s -p "Confirm: " APP_PWD_CONFIRM
    echo
    if [[ -z "${APP_PWD}" ]]; then
      echo "Password cannot be empty. Try again."
      continue
    fi
    if [[ "${APP_PWD}" != "${APP_PWD_CONFIRM}" ]]; then
      echo "Passwords do not match. Try again."
      continue
    fi
    break
  done
  unset APP_PWD_CONFIRM
else
  echo "[info] Using APP_PWD from environment (non-interactive)."
fi
set -o history || true

echo "[step] Applying security: $SECURITY_FILE (in-memory substitution)"
APP_PWD_ESC="$(printf '%s' "$APP_PWD" | sed -e 's/[\\/&]/\\&/g')"
sed -e "s|REPLACE_WITH_STRONG_PASSWORD_HERE|${APP_PWD_ESC}|g" -e "s|ON DATABASE product_svc|ON DATABASE ${DB_NAME}|g" "$SECURITY_FILE" \
  | kubectl -n "$NAMESPACE" exec -i "$POD_NAME" -- \
      env PGPASSWORD="$(PG_PWD_FETCH)" \
      psql -U postgres -d "$DB_NAME" -v ON_ERROR_STOP=1
unset APP_PWD APP_PWD_ESC || true

echo "[step] Verification"
kubectl -n "$NAMESPACE" exec -i "$POD_NAME" -- \
  env PGPASSWORD="$(PG_PWD_FETCH)" \
  psql -U postgres -d "$DB_NAME" -c "\\dn"
kubectl -n "$NAMESPACE" exec -i "$POD_NAME" -- \
  env PGPASSWORD="$(PG_PWD_FETCH)" \
  psql -U postgres -d "$DB_NAME" -c "\\dt product_svc.*"
kubectl -n "$NAMESPACE" exec -i "$POD_NAME" -- \
  env PGPASSWORD="$(PG_PWD_FETCH)" \
  psql -U postgres -d "$DB_NAME" -c "\\du"

echo "[success] product-service schema + security applied to $DB_NAME"
exit 0
