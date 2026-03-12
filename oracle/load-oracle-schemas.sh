#!/usr/bin/env bash
set -euo pipefail

# Helper script: Provision user-service schema + security for Oracle SIDB (Free or other editions)
# Performs steps: create/ unlock owning user (USER_SVC), apply schema.sql, create role + grants,
# create least-privilege app user (USER_SVC_APP) via security.sql with in-memory password substitution, verify.
# Secrets are never written to disk; passwords are read with 'read -s'.

# Configurable environment (override before calling):
# Core targeting
NAMESPACE="${NAMESPACE:-oracle-system}"
SIDB_NAME="${SIDB_NAME:-oracledb}"
PDB_NAME="${PDB_NAME:-FREEPDB1}"
SCHEMA_FILE="${SCHEMA_FILE:-db-schemas/oracle/user-service/schema.sql}"
SECURITY_FILE="${SECURITY_FILE:-db-schemas/oracle/user-service/security.sql}"
OWNER_USER="${OWNER_USER:-USER_SVC}"
APP_USER="${APP_USER:-USER_SVC_APP}"
ROLE_NAME="${ROLE_NAME:-USER_SVC_ROLE}"

# Runtime credentials (leave empty to be prompted interactively)
OWNER_PWD="${OWNER_PWD:-}"
APP_PWD="${APP_PWD:-}"

# Behavior toggles
# - SKIP_SCHEMA_APPLY=1 to skip applying schema file even if missing tables
# - AUTO_SKIP_SCHEMA=1 to auto-skip schema apply when all expected tables exist (default)
# - FORCE_STRICT_SCHEMA=1 to abort on first SQL error during schema apply
# - DEBUG=1 to print command output instead of redirecting to /dev/null
SKIP_SCHEMA_APPLY="${SKIP_SCHEMA_APPLY:-0}"
AUTO_SKIP_SCHEMA="${AUTO_SKIP_SCHEMA:-1}"
FORCE_STRICT_SCHEMA="${FORCE_STRICT_SCHEMA:-0}"
DEBUG="${DEBUG:-0}"

echo "[info] Target: namespace=$NAMESPACE service=$SIDB_NAME pdb=$PDB_NAME"

# Resolve DB pod via Service endpoints (preferred; works across operator versions)
POD="$(kubectl -n "$NAMESPACE" get endpoints "$SIDB_NAME" -o jsonpath='{.subsets[0].addresses[0].targetRef.name}' 2>/dev/null || true)"
if [[ -z "$POD" ]]; then
  # Fallback: label selector (older template uses app=oracledb)
  POD="$(kubectl -n "$NAMESPACE" get pods -l app="$SIDB_NAME" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)"
fi
if [[ -z "$POD" ]]; then
  POD="$(kubectl -n "$NAMESPACE" get pods -l app=oracledb -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)"
fi
if [[ -z "$POD" ]]; then
  echo "[error] Unable to resolve Oracle DB pod (checked endpoints and labels)." >&2
  exit 1
fi
echo "[info] Using pod: $POD"

if [[ ! -f "$SCHEMA_FILE" ]]; then
  echo "[error] Schema file not found: $SCHEMA_FILE" >&2
  exit 1
fi
if [[ ! -f "$SECURITY_FILE" ]]; then
  echo "[error] Security file not found: $SECURITY_FILE" >&2
  exit 1
fi

if [[ -z "${OWNER_PWD:-}" ]]; then
  set +o history || true
  while true; do
    read -r -s -p "Enter the schema Owner password ($OWNER_USER): " OWNER_PWD
    echo
    read -r -s -p "Confirm: " OWNER_PWD_CONFIRM
    echo
    if [[ -z "${OWNER_PWD}" ]]; then
      echo "Password cannot be empty. Try again."
      continue
    fi
    if [[ "${OWNER_PWD}" != "${OWNER_PWD_CONFIRM}" ]]; then
      echo "Passwords do not match. Try again."
      continue
    fi
    break
  done
  unset OWNER_PWD_CONFIRM
  set -o history || true
else
  echo "[info] Using OWNER_PWD from environment (non-interactive)."
fi

echo "[step] Creating or unlocking schema owning user $OWNER_USER and granting object create privileges"
kubectl -n "$NAMESPACE" exec -i "$POD" -- sqlplus -s / as sysdba <<SQL
WHENEVER SQLERROR EXIT SQL.SQLCODE
ALTER SESSION SET CONTAINER=${PDB_NAME};
DECLARE
  e_user_exists EXCEPTION;
  PRAGMA EXCEPTION_INIT(e_user_exists, -1920);
BEGIN
  EXECUTE IMMEDIATE 'CREATE USER ${OWNER_USER} IDENTIFIED BY "${OWNER_PWD}" DEFAULT TABLESPACE USERS QUOTA 200M ON USERS ACCOUNT UNLOCK';
EXCEPTION
  WHEN e_user_exists THEN
    EXECUTE IMMEDIATE 'ALTER USER ${OWNER_USER} IDENTIFIED BY "${OWNER_PWD}" ACCOUNT UNLOCK';
END;
/
GRANT CREATE SESSION, CREATE TABLE, CREATE SEQUENCE, CREATE TRIGGER, CREATE VIEW TO ${OWNER_USER};
SQL

echo "[step] Applying schema objects as ${OWNER_USER}"
if [[ "${SKIP_SCHEMA_APPLY:-}" == 1 ]]; then
  echo "[info] SKIP_SCHEMA_APPLY=1 set; skipping schema file"
else
  if [[ "${AUTO_SKIP_SCHEMA:-1}" == 1 ]]; then
    # Check all expected tables
    expected=(USERS ROLES USER_ROLES REFRESH_TOKENS EMAIL_VERIFICATION_TOKENS PASSWORD_RESET_TOKENS LOGIN_AUDIT DOMAIN_EVENTS)
    missing=()
    for t in "${expected[@]}"; do
      cnt=$(kubectl -n "$NAMESPACE" exec -i "$POD" -- bash -lc "sqlplus -s /nolog <<'SQL'
CONNECT ${OWNER_USER}/\"${OWNER_PWD//"/\\"}\"@127.0.0.1:1521/${PDB_NAME}
SET HEADING OFF FEEDBACK OFF PAGES 0
SELECT COUNT(*) FROM user_tables WHERE table_name='${t}';
EXIT
SQL
" 2>/dev/null) || cnt=0
      cnt=$(echo "$cnt" | tr -dc '0-9')
      if [[ "$cnt" != 1 ]]; then missing+=("$t"); fi
    done
    if [[ ${#missing[@]} -eq 0 ]]; then
      echo "[info] All expected tables already exist; skipping schema apply (AUTO_SKIP_SCHEMA)."
      SKIP_SCHEMA_APPLY=1
    else
      echo "[info] Missing tables detected: ${missing[*]}; schema will be applied."
    fi
  fi
fi
if [[ "${SKIP_SCHEMA_APPLY:-0}" != 1 ]]; then
  OWNER_PWD_ESC=${OWNER_PWD//"/\\"}
  kubectl -n "$NAMESPACE" exec -i "$POD" -- bash -lc "sqlplus -s /nolog <<'SQL'
CONNECT ${OWNER_USER}/\"${OWNER_PWD_ESC}\"@127.0.0.1:1521/${PDB_NAME}
$( [[ "${FORCE_STRICT_SCHEMA}" == 1 ]] && echo "WHENEVER SQLERROR EXIT SQL.SQLCODE" )
$(sed '' "$SCHEMA_FILE")
EXIT
SQL
" $( [[ "${DEBUG:-}" == 1 ]] && echo || echo ">/dev/null" ) || {
    rc=$?
    if [[ $rc -eq 187 ]]; then
      echo "[warn] ORA-00955 (object exists) encountered; continuing."
    elif [[ $rc -eq 128 && "${FORCE_STRICT_SCHEMA}" != 1 ]]; then
      echo "[warn] ORA-01408 (index exists) encountered; continuing."
    else
      echo "[error] Schema apply failed with exit code $rc" >&2
      exit $rc
    fi
  }
fi

unset OWNER_PWD || true

echo "[step] Creating role ${ROLE_NAME} and granting CRUD on owned tables (SYS ownership)"
kubectl -n "$NAMESPACE" exec -i "$POD" -- bash -lc "sqlplus -s /nolog <<SQL
CONNECT / AS SYSDBA
ALTER SESSION SET CONTAINER=${PDB_NAME};
DECLARE
  e_exists EXCEPTION;
  PRAGMA EXCEPTION_INIT(e_exists,-1921);
BEGIN
  EXECUTE IMMEDIATE 'CREATE ROLE ${ROLE_NAME}';
EXCEPTION
  WHEN e_exists THEN NULL;
END;
/
BEGIN
  FOR r IN (
    SELECT table_name FROM user_tables WHERE table_name IN (
      'USERS','ROLES','USER_ROLES','REFRESH_TOKENS','EMAIL_VERIFICATION_TOKENS','PASSWORD_RESET_TOKENS','LOGIN_AUDIT','DOMAIN_EVENTS')
  ) LOOP
    BEGIN EXECUTE IMMEDIATE 'GRANT SELECT,INSERT,UPDATE,DELETE ON ${OWNER_USER}.'||r.table_name||' TO ${ROLE_NAME}'; EXCEPTION WHEN OTHERS THEN NULL; END;
  END LOOP;
END;
/
EXIT
SQL" $( [[ "${DEBUG:-}" == 1 ]] && echo || echo ">/dev/null" )

if [[ -z "${APP_PWD:-}" ]]; then
  set +o history || true
  while true; do
    read -r -s -p "Enter the App user password (${APP_USER}): " APP_PWD
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

echo "[step] Creating least-privilege app user ${APP_USER} (in-memory password substitution)"
APP_PWD_ESC="$(printf '%s' "$APP_PWD" | sed -e 's/[\\/&]/\\&/g')"
SEC_CONTENT="$(sed "s/REPLACE_WITH_STRONG_PASSWORD_HERE/${APP_PWD_ESC}/g" "$SECURITY_FILE")"
kubectl -n "$NAMESPACE" exec -i "$POD" -- bash -lc "sqlplus -s /nolog <<SQL
CONNECT / AS SYSDBA
ALTER SESSION SET CONTAINER=${PDB_NAME};
$SEC_CONTENT
EXIT
SQL" $( [[ "${DEBUG:-}" == 1 ]] && echo || echo ">/dev/null" )
unset APP_PWD APP_PWD_ESC SEC_CONTENT || true

echo "[step] Verification queries"
kubectl -n "$NAMESPACE" exec -i "$POD" -- sqlplus -s / as sysdba <<SQL
WHENEVER SQLERROR EXIT SQL.SQLCODE
ALTER SESSION SET CONTAINER=${PDB_NAME};
SET PAGES 0 FEEDBACK ON
SELECT USERNAME||' '||ACCOUNT_STATUS FROM DBA_USERS WHERE USERNAME IN ('${OWNER_USER}','${APP_USER}') ORDER BY 1;
SELECT GRANTEE||' -> '||GRANTED_ROLE FROM DBA_ROLE_PRIVS WHERE GRANTEE='${APP_USER}' ORDER BY 1;
SQL

# Assert: app user exists and has role; fail early if not
APP_EXISTS=$(kubectl -n "$NAMESPACE" exec -i "$POD" -- sqlplus -s / as sysdba <<SQL 2>/dev/null | tr -dc '0-9'
ALTER SESSION SET CONTAINER=${PDB_NAME};
SET HEADING OFF FEEDBACK OFF PAGES 0
SELECT COUNT(*) FROM DBA_USERS WHERE USERNAME='${APP_USER}';
EXIT
SQL
)
ROLE_GRANTED=$(kubectl -n "$NAMESPACE" exec -i "$POD" -- sqlplus -s / as sysdba <<SQL 2>/dev/null | tr -dc '0-9'
ALTER SESSION SET CONTAINER=${PDB_NAME};
SET HEADING OFF FEEDBACK OFF PAGES 0
SELECT COUNT(*) FROM DBA_ROLE_PRIVS WHERE GRANTEE='${APP_USER}' AND GRANTED_ROLE='${ROLE_NAME}';
EXIT
SQL
)
if [[ "$APP_EXISTS" != 1 ]]; then
  echo "[error] Verification failed: user ${APP_USER} does not exist in PDB ${PDB_NAME}." >&2
  exit 1
fi
if [[ "$ROLE_GRANTED" != 1 ]]; then
  echo "[error] Verification failed: role ${ROLE_NAME} not granted to ${APP_USER}." >&2
  exit 1
fi

echo "[success] user-service schema + security applied." 
echo "Connect as: ${APP_USER}@127.0.0.1:1521/${PDB_NAME}" 

exit 0