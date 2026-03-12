#!/usr/bin/env bash
set -euo pipefail

# Helper script: Provision order-service schema + security on SQL Server in Kubernetes
# Steps:
# 1) Create database if missing
# 2) Apply schema.sql into database
# 3) Apply security.sql with in-memory password substitution
# 4) Verify login/user and database

# Configurable environment
NAMESPACE="${NAMESPACE:-mssql-system}"
APP_NAME="${APP_NAME:-mssql}"
SERVICE_NAME="${SERVICE_NAME:-mssql-svc}"
POD_NAME="${POD_NAME:-}"
DB_NAME="${DB_NAME:-order_svc}"
SCHEMA_FILE="${SCHEMA_FILE:-db-schemas/mssql/order-service/schema.sql}"
SECURITY_FILE="${SECURITY_FILE:-db-schemas/mssql/order-service/security.sql}"
SA_SECRET_NAME="${SA_SECRET_NAME:-mssql}"
SA_SECRET_KEY="${SA_SECRET_KEY:-MSSQL_SA_PASSWORD}"
SQLCMD="/opt/mssql-tools18/bin/sqlcmd"

echo "[info] Target: ns=$NAMESPACE service=$SERVICE_NAME app=$APP_NAME db=$DB_NAME"

# Resolve pod via service endpoints first, then by label, then default to ${APP_NAME}-0
if [[ -z "$POD_NAME" ]]; then
  POD_NAME="$(kubectl -n "$NAMESPACE" get endpoints "$SERVICE_NAME" -o jsonpath='{.subsets[0].addresses[0].targetRef.name}' 2>/dev/null || true)"
fi
if [[ -z "$POD_NAME" ]]; then
  POD_NAME="$(kubectl -n "$NAMESPACE" get pods -l app="$APP_NAME" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)"
fi
if [[ -z "$POD_NAME" ]]; then
  POD_NAME="${APP_NAME}-0"
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

# Helper to fetch SA password from Secret on demand
sa_pwd_cmd=(kubectl -n "$NAMESPACE" get secret "$SA_SECRET_NAME" -o jsonpath="{.data.$SA_SECRET_KEY}")
SA_PWD_FETCH() {
  "${sa_pwd_cmd[@]}" | base64 --decode
}

echo "[step] Ensuring database exists: $DB_NAME"
kubectl -n "$NAMESPACE" exec -i "$POD_NAME" -- \
  env SQLCMDPASSWORD="$(SA_PWD_FETCH)" \
  "$SQLCMD" -C -S localhost -U sa -Q "IF DB_ID('$DB_NAME') IS NULL BEGIN CREATE DATABASE $DB_NAME; END"

echo "[step] Applying schema: $SCHEMA_FILE"
sed '' "$SCHEMA_FILE" | kubectl -n "$NAMESPACE" exec -i "$POD_NAME" -- \
  env SQLCMDPASSWORD="$(SA_PWD_FETCH)" \
  "$SQLCMD" -C -S localhost -U sa -d "$DB_NAME" -b

if [[ -z "${APP_PWD:-}" ]]; then
  set +o history || true
  while true; do
    read -r -s -p "Enter the App user password (order_app): " APP_PWD
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
  set -o history || true
else
  echo "[info] Using APP_PWD from environment (non-interactive)."
fi

echo "[step] Applying security: $SECURITY_FILE (in-memory substitution) for the least-privilege app user"
APP_PWD_ESC="$(printf '%s' "$APP_PWD" | sed -e 's/[\\/&]/\\&/g')"
sed "s/REPLACE_WITH_STRONG_PASSWORD_HERE/${APP_PWD_ESC}/g" "$SECURITY_FILE" \
  | kubectl -n "$NAMESPACE" exec -i "$POD_NAME" -- \
      env SQLCMDPASSWORD="$(SA_PWD_FETCH)" \
      "$SQLCMD" -C -S localhost -U sa -d "$DB_NAME" -b
unset APP_PWD APP_PWD_ESC || true

echo "[step] Verification"
kubectl -n "$NAMESPACE" exec -i "$POD_NAME" -- \
  env SQLCMDPASSWORD="$(SA_PWD_FETCH)" \
  "$SQLCMD" -C -S localhost -U sa -W -s ' | ' -Q "SELECT name AS user_login_name, type_desc FROM sys.server_principals WHERE name LIKE 'order_app%'; SELECT name AS database_name FROM sys.databases WHERE name='$DB_NAME';"
echo
echo

kubectl -n "$NAMESPACE" exec -i "$POD_NAME" -- \
  env SQLCMDPASSWORD="$(SA_PWD_FETCH)" \
  "$SQLCMD" -C -S localhost -U sa -d "$DB_NAME" -W -s ' | ' -Q "
SELECT
    dp.name AS principal_rolename,
    perm.permission_name AS permit,
    perm.state_desc AS state,
    s.name AS schema_name
FROM sys.database_permissions AS perm
JOIN sys.schemas AS s
    ON perm.major_id = s.schema_id
JOIN sys.database_principals AS dp
    ON perm.grantee_principal_id = dp.principal_id
WHERE perm.class_desc = 'SCHEMA'
ORDER BY dp.name, perm.permission_name;"

kubectl -n "$NAMESPACE" exec -i "$POD_NAME" -- \
  env SQLCMDPASSWORD="$(SA_PWD_FETCH)" \
  "$SQLCMD" -C -S localhost -U sa -d "$DB_NAME" -W -s ' | ' -Q "
SELECT
    sp.name AS login_name,
    dp.name AS database_user
FROM sys.server_principals sp
JOIN sys.database_principals dp
    ON sp.sid = dp.sid
WHERE sp.name = 'order_app_login';"

echo "[success] order-service schema + security applied to $DB_NAME"
exit 0
