#!/usr/bin/env bash
set -euo pipefail

# Seed Oracle USER_SVC schema with 01-seed.sql
# Usage:
#   NAMESPACE=oracle-system OWNER_USER=USER_SVC PDB_NAME=FREEPDB1 ./seed-oracle.sh

NAMESPACE="${NAMESPACE:-oracle-system}"
SIDB_NAME="${SIDB_NAME:-oracledb}"
PDB_NAME="${PDB_NAME:-FREEPDB1}"
OWNER_USER="${OWNER_USER:-USER_SVC}"
SEED_FILE="${SEED_FILE:-../db-schemas/oracle/user-service/01-seed.sql}"

if [[ ! -f "$SEED_FILE" ]]; then
  echo "[error] Seed file not found: $SEED_FILE" >&2
  exit 1
fi

echo "[info] Resolving Oracle pod in namespace $NAMESPACE"
POD=$(kubectl -n "$NAMESPACE" get endpoints "$SIDB_NAME" -o jsonpath='{.subsets[0].addresses[0].targetRef.name}' 2>/dev/null || true)
if [[ -z "$POD" ]]; then
  POD=$(kubectl -n "$NAMESPACE" get pods -l app="$SIDB_NAME" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)
fi
if [[ -z "$POD" ]]; then
  POD=$(kubectl -n "$NAMESPACE" get pods -l app=oracledb -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)
fi
if [[ -z "$POD" ]]; then
  echo "[error] Unable to resolve Oracle DB pod (checked endpoints and labels)." >&2
  exit 1
fi
echo "[info] Using pod: $POD"

echo "[step] Copying seed file to pod"
kubectl -n "$NAMESPACE" cp "$SEED_FILE" "$POD":/tmp/seed_oracle.sql

# Snapshot users before seeding
echo "[step] Snapshotting existing users (before)"
USR_BEFORE_FILE=$(mktemp)
kubectl -n "$NAMESPACE" exec -i "$POD" -- sqlplus -s / as sysdba <<SQL > "$USR_BEFORE_FILE"
WHENEVER SQLERROR EXIT SQL.SQLCODE
ALTER SESSION SET CONTAINER=${PDB_NAME};
ALTER SESSION SET CURRENT_SCHEMA=${OWNER_USER};
SET HEADING OFF FEEDBACK OFF PAGES 0 LINESIZE 32767
SELECT EMAIL || CHR(9) || NVL(FULL_NAME,'') || CHR(9) || NVL(TO_CHAR(IS_ACTIVE),'') || CHR(9) || NVL(PASSWORD_HASH,'') FROM USERS WHERE EMAIL IN ('test-admin@shopease.com','admin@shopease.com','shop-user@shopease.com','alice@trial.com','bob@trial.com','carol@trial.com') ORDER BY EMAIL;
EXIT
SQL


echo "[step] Executing seed as SYSDBA (sets CURRENT_SCHEMA to $OWNER_USER)"
kubectl -n "$NAMESPACE" exec -i "$POD" -- sqlplus -s / as sysdba <<SQL
WHENEVER SQLERROR EXIT SQL.SQLCODE
ALTER SESSION SET CONTAINER=${PDB_NAME};
ALTER SESSION SET CURRENT_SCHEMA=${OWNER_USER};
@/tmp/seed_oracle.sql
EXIT
SQL

echo "[step] Cleaning up"
kubectl -n "$NAMESPACE" exec -i "$POD" -- rm -f /tmp/seed_oracle.sql || true

echo "[success] Oracle seeds applied into schema ${OWNER_USER} in PDB ${PDB_NAME}"

# Verification: check seeded users and admin role assignments
echo "[step] Verifying Oracle seed results (secure)"
USER_EMAILS=(
  'test-admin@shopease.com' 'admin@shopease.com' 'shop-user@shopease.com' 'alice@trial.com' 'bob@trial.com' 'carol@trial.com'
)
EMAIL_LIST=$(printf "'%s'," "${USER_EMAILS[@]}" | sed 's/,$//')
expected_users=${#USER_EMAILS[@]}

# Get a single numeric value from sqlplus output (first numeric token)
user_cnt=$(kubectl -n "$NAMESPACE" exec -i "$POD" -- sqlplus -s / as sysdba <<SQL 2>/dev/null | awk '{ gsub(/[^0-9]/,"",$0); if(length($0)>0){print $0; exit} }'
ALTER SESSION SET CONTAINER=${PDB_NAME};
ALTER SESSION SET CURRENT_SCHEMA=${OWNER_USER};
SET HEADING OFF FEEDBACK OFF PAGES 0
SELECT COUNT(*) FROM USERS WHERE EMAIL IN ($EMAIL_LIST);
EXIT
SQL
)

admin_role_cnt=$(kubectl -n "$NAMESPACE" exec -i "$POD" -- sqlplus -s / as sysdba <<SQL 2>/dev/null | awk '{ gsub(/[^0-9]/,"",$0); if(length($0)>0){print $0; exit} }'
ALTER SESSION SET CONTAINER=${PDB_NAME};
ALTER SESSION SET CURRENT_SCHEMA=${OWNER_USER};
SET HEADING OFF FEEDBACK OFF PAGES 0
SELECT COUNT(*) FROM USER_ROLES ur JOIN ROLES r ON ur.ROLE_ID = r.ID JOIN USERS u ON ur.USER_ID = u.ID WHERE r.NAME='admin' AND u.EMAIL IN ($EMAIL_LIST);
EXIT
SQL
)

echo "[verify] users=$user_cnt expected=$expected_users, admin_mappings=$admin_role_cnt expected>=2"
if [[ "$user_cnt" -lt $expected_users || "$admin_role_cnt" -lt 2 ]]; then
  echo "[error] Oracle verification failed: missing seeded users or admin role assignments" >&2
  exit 3
fi

echo "[success] Oracle verification passed."

# Print seeded user emails (shows which rows are present)
echo "[step] Listing seeded user emails present in ${OWNER_USER}"
kubectl -n "$NAMESPACE" exec -i "$POD" -- sqlplus -s / as sysdba <<SQL
WHENEVER SQLERROR EXIT SQL.SQLCODE
ALTER SESSION SET CONTAINER=${PDB_NAME};
ALTER SESSION SET CURRENT_SCHEMA=${OWNER_USER};
SET SERVEROUTPUT ON SIZE 1000000
SET HEADING OFF FEEDBACK OFF PAGES 0
BEGIN
  FOR r IN (SELECT EMAIL FROM USERS WHERE EMAIL IN (${EMAIL_LIST}) ORDER BY EMAIL) LOOP
    DBMS_OUTPUT.PUT_LINE(r.EMAIL);
  END LOOP;
END;
/ 
EXIT
SQL

# Snapshot users after seeding and compute inserted/updated
USR_AFTER_FILE=$(mktemp)
kubectl -n "$NAMESPACE" exec -i "$POD" -- sqlplus -s / as sysdba <<SQL > "$USR_AFTER_FILE"
WHENEVER SQLERROR EXIT SQL.SQLCODE
ALTER SESSION SET CONTAINER=${PDB_NAME};
ALTER SESSION SET CURRENT_SCHEMA=${OWNER_USER};
SET HEADING OFF FEEDBACK OFF PAGES 0 LINESIZE 32767
SELECT EMAIL || CHR(9) || NVL(FULL_NAME,'') || CHR(9) || NVL(TO_CHAR(IS_ACTIVE),'') || CHR(9) || NVL(PASSWORD_HASH,'') FROM USERS WHERE EMAIL IN ('test-admin@shopease.com','admin@shopease.com','shop-user@shopease.com','alice@trial.com','bob@trial.com','carol@trial.com') ORDER BY EMAIL;
EXIT
SQL

echo "[step] Oracle seed results — inserted vs updated"
awk -F"\t" '{print $1}' "$USR_BEFORE_FILE" | sort > /tmp/_usr_before
awk -F"\t" '{print $1}' "$USR_AFTER_FILE" | sort > /tmp/_usr_after
echo "Inserted emails:"; comm -23 /tmp/_usr_after /tmp/_usr_before || true
echo "Updated emails:";
awk -F"\t" 'NR==FNR{a[$1]=$0; next} { if($1 in a && a[$1]!= $0) print $1 }' "$USR_BEFORE_FILE" "$USR_AFTER_FILE" || true

rm -f "$USR_BEFORE_FILE" "$USR_AFTER_FILE" /tmp/_usr_before /tmp/_usr_after || true


