# Oracle Database on Kubernetes (Oracle Database Operator)

This folder provisions an Oracle Single Instance Database (SIDB) using the Oracle Database Operator. It follows the same pattern as the other databases in this repo: manifests are templated and a deploy script injects runtime secrets and options.

## Prerequisites

- A working Kubernetes cluster (MicroK8s, minikube, kind, or any K8s)
- kubectl context pointing at the cluster
- Internet access to pull:
  - cert-manager manifests (unless already installed)
  - Oracle Database Operator manifests
  - Oracle Database container image (defaults to the Free edition from the Oracle Container Registry)
- Oracle Container Registry (OCR) license acceptance and credentials are required for image pulls. An image pull secret is mandatory; the deploy script will create or reuse it.

By default, the database is exposed internally via a ClusterIP Service. External access is not configured; use a port-forward for ad-hoc access, or configure an Ingress/LoadBalancer explicitly if required.

## Files

- `deploy-oracle-k8s.sh` — Deploys cert-manager (optional), the operator (idempotent unless skipped), creates the namespace/Secret/CR, enforces OCR pull secret, and waits for readiness.
- `00-namespace.yaml` — Namespace template.
- `10-secret.yaml` — Admin password Secret template (runtime-only).
- `20-sidb.yaml` — SingleInstanceDatabase CR template (internal ClusterIP; no NodePort listener).

## Quick start

1) Run the deploy script (Linux/macOS shell or WSL). The admin password will be prompted securely at runtime.

- `./deploy-oracle-k8s.sh`

Pre-flight note: OCR images require that you’ve accepted the license in the Oracle Container Registry and that you provide valid credentials. The script ensures an image pull secret exists and will prompt for credentials only if needed.

2) Set an admin password (optional; the script prompts securely). Avoid putting secrets in shell history in production.

   - Linux/macOS:
     - `export ORACLE_PWD='<strong-password>'`
   - Windows PowerShell:
     - `$Env:ORACLE_PWD = '<strong-password>'`

3) Optional: customize settings via env vars (defaults shown):

- `NAMESPACE=oracle-system`
- `SIDB_NAME=oracledb`
- `SID=ORCL1`
- `PDB_NAME=ORCLPDB1`
- `EDITION=free` (enterprise|standard|express|free) — when `free`, the script enforces `SID=FREE`, `PDB_NAME=FREEPDB1`, and `REPLICAS=1`.
- `IMAGE_PULL_FROM=container-registry.oracle.com/database/free:23.3.0`
- `IMAGE_PULL_SECRET=ocr-pull-secret` (mandatory for OCR images; the script creates it if missing)
- `OCI_REGISTRY_SERVER=container-registry.oracle.com`
- `OCI_REGISTRY_USERNAME` and `OCI_REGISTRY_PASSWORD` (or `DOCKER_CONFIG_JSON=/path/to/config.json`)
- `STORAGE_SIZE=50Gi`
- `STORAGE_CLASS=` (leave empty and the script will auto-detect and use the cluster's default StorageClass if available; if no default exists and you leave it empty, it will omit the field and you must provide a statically pre-provisioned PV that matches the claim)
- `ACCESS_MODE=ReadWriteOnce`
- (no NodePort by default)
- `REPLICAS=1`

cert-manager/operator install controls:

- `INSTALL_CERT_MANAGER=true` — install cert-manager if CRDs not found
- `CERT_MANAGER_METHOD=helm` — `helm` or `apply` (raw manifest)

## Connect & Provisioning Overview

Retrieve connect strings from the `SingleInstanceDatabase` status (external CDB and PDB endpoints):

```bash
kubectl -n oracle-system get singleinstancedatabase oracledb -o jsonpath='{.status.connectString}'
kubectl -n oracle-system get singleinstancedatabase oracledb -o jsonpath='{.status.pdbConnectString}'
```

Port-forward for local workstation access (replace PDB name for non-Free editions):

```bash
kubectl -n oracle-system port-forward svc/oracledb 1521:1521 &
sqlplus "sys/<PASSWORD>@127.0.0.1:1521/FREEPDB1 as sysdba"
```

In-pod (recommended) OS authentication avoids exposing the SYS password:

```bash
NAMESPACE=${NAMESPACE:-oracle-system}
SIDB_NAME=${SIDB_NAME:-oracledb}
# Resolve the DB pod behind the Service (more robust than label matching):
POD=$(kubectl -n "$NAMESPACE" get endpoints "$SIDB_NAME" -o jsonpath='{.subsets[0].addresses[0].targetRef.name}')
kubectl -n "$NAMESPACE" exec -it "$POD" -- bash -lc 'sqlplus / as sysdba'
```

Pre-check: PDB is open (READ WRITE)
```
PDB_NAME=${PDB_NAME:-FREEPDB1}
kubectl -n "$NAMESPACE" exec -i "$POD" -- sqlplus -s / as sysdba <<SQL
whenever sqlerror exit sql.sqlcode
set heading off feedback on pages 0
select name||' '||open_mode from v\$pdbs where name='${PDB_NAME}';
SQL
```
### Substitute a placeholder password at runtime (no file edits)

If your `schema.sql` contains a placeholder like `REPLACE_WITH_STRONG_PASSWORD_HERE`, substitute it safely in-memory and pipe to SQL*Plus without editing the file. Run this inside the DB pod or against a port-forward:

```bash
read -s -p "Enter app user password: " APP_PWD; echo
APP_PWD_ESC=$(printf '%s' "$APP_PWD" | sed -e 's/[&\/\\]/\\&/g')

read -s -p "Enter SYS password: " SYS_PWD; echo

# Replace ORCLPDB1 with your actual PDB (e.g., FREEPDB1 for Free edition)
sed "s/REPLACE_WITH_STRONG_PASSWORD_HERE/$APP_PWD_ESC/g" /tmp/schema.sql \
| sqlplus "sys/${SYS_PWD}@127.0.0.1:1521/ORCLPDB1 as sysdba"

unset APP_PWD APP_PWD_ESC SYS_PWD
```

### Alternative Methods

Port-forward & workstation schema apply (less secure; avoid storing SYS password in history):
```bash
kubectl -n oracle-system port-forward svc/oracledb 1521:1521 &
sqlplus "sys@127.0.0.1:1521/FREEPDB1 as sysdba" <<'SQL'
-- paste or @schema.sql
SQL
```

Stream security script without copying:
```bash
set +o history
read -s -p "App user password (USER_SVC_APP): " APP_PWD; echo
APP_PWD_ESC=${APP_PWD//\\/\\\\}; APP_PWD_ESC=${APP_PWD_ESC//\//\/}; APP_PWD_ESC=${APP_PWD_ESC//&/\&}
sed -f - db-schemas/oracle/user-service/security.sql <<SED | kubectl -n oracle-system exec -i "$POD" -- sqlplus / as sysdba
s/REPLACE_WITH_STRONG_PASSWORD_HERE/${APP_PWD_ESC}/g
SED
unset APP_PWD APP_PWD_ESC
set -o history
```

### Example Implementation: Hardened Stepwise Workflow (schema + security)

This sequence (Oracle Free, PDB `FREEPDB1`) safely creates an owning schema, applies objects, sets up a role, creates a least‑privilege app user, and verifies — without persisting secrets.

Assumptions: owner `USER_SVC`, app user `USER_SVC_APP`, role `USER_SVC_ROLE`, scripts in `db-schemas/oracle/user-service/`.

Environment defaults used below (override as needed):
```bash
NAMESPACE=${NAMESPACE:-oracle-system}
SIDB_NAME=${SIDB_NAME:-oracledb}
PDB_NAME=${PDB_NAME:-FREEPDB1}
# Resolve DB pod via Service endpoints (works across operator versions)
POD=$(kubectl -n "$NAMESPACE" get endpoints "$SIDB_NAME" -o jsonpath='{.subsets[0].addresses[0].targetRef.name}')
```

1. Copy scripts
```bash
# Optional: copy scripts into the pod if you prefer
# kubectl -n "$NAMESPACE" cp db-schemas/oracle/user-service/schema.sql  "$POD":/tmp/schema.sql
# kubectl -n "$NAMESPACE" cp db-schemas/oracle/user-service/security.sql "$POD":/tmp/security.sql
```

2. Create owner and apply schema
```bash
set +o history
read -s -p "Enter the schema Owner password (USER_SVC): " OWNER_PWD; echo

# Create (or unlock) the owning schema as SYS in the target PDB
kubectl -n "$NAMESPACE" exec -i "$POD" -- sqlplus -s / as sysdba <<SQL
WHENEVER SQLERROR EXIT SQL.SQLCODE
ALTER SESSION SET CONTAINER=${PDB_NAME};
DECLARE
  e_user_exists EXCEPTION;
  PRAGMA EXCEPTION_INIT(e_user_exists, -1920);
BEGIN
  EXECUTE IMMEDIATE 'CREATE USER USER_SVC IDENTIFIED BY "${OWNER_PWD}" DEFAULT TABLESPACE USERS QUOTA 200M ON USERS ACCOUNT UNLOCK';
EXCEPTION
  WHEN e_user_exists THEN
    EXECUTE IMMEDIATE 'ALTER USER USER_SVC IDENTIFIED BY "${OWNER_PWD}" ACCOUNT UNLOCK';
END;
/
GRANT CREATE SESSION, CREATE TABLE, CREATE SEQUENCE, CREATE TRIGGER, CREATE VIEW TO USER_SVC;
SQL

# Run as the owning user to create the DB objects from schema.sql
{
  echo "WHENEVER SQLERROR EXIT SQL.SQLCODE"
  cat db-schemas/oracle/user-service/schema.sql
} | kubectl -n "$NAMESPACE" exec -i "$POD" -- sqlplus -s "USER_SVC/${OWNER_PWD}@localhost:1521/${PDB_NAME}"

set -o history
```

3. Create role & grant CRUD
```bash
# Run as the owning application schema (e.g., USER_SVC) to create role and grant object privileges
kubectl -n "$NAMESPACE" exec -i "$POD" -- sqlplus -s "USER_SVC/${OWNER_PWD}@localhost:1521/${PDB_NAME}" <<'SQL'
WHENEVER SQLERROR EXIT SQL.SQLCODE
DECLARE
  e_exists EXCEPTION;
  PRAGMA EXCEPTION_INIT(e_exists,-1921);
BEGIN
  EXECUTE IMMEDIATE 'CREATE ROLE USER_SVC_ROLE';
EXCEPTION
  WHEN e_exists THEN NULL;
END;
/
GRANT SELECT, INSERT, UPDATE, DELETE ON USER_SVC.USERS                      TO USER_SVC_ROLE;
GRANT SELECT, INSERT, UPDATE, DELETE ON USER_SVC.ROLES                      TO USER_SVC_ROLE;
GRANT SELECT, INSERT, UPDATE, DELETE ON USER_SVC.USER_ROLES                 TO USER_SVC_ROLE;
GRANT SELECT, INSERT, UPDATE, DELETE ON USER_SVC.REFRESH_TOKENS             TO USER_SVC_ROLE;
GRANT SELECT, INSERT, UPDATE, DELETE ON USER_SVC.EMAIL_VERIFICATION_TOKENS  TO USER_SVC_ROLE;
GRANT SELECT, INSERT, UPDATE, DELETE ON USER_SVC.PASSWORD_RESET_TOKENS      TO USER_SVC_ROLE;
GRANT SELECT, INSERT, UPDATE, DELETE ON USER_SVC.LOGIN_AUDIT                TO USER_SVC_ROLE;
GRANT SELECT, INSERT, UPDATE, DELETE ON USER_SVC.DOMAIN_EVENTS              TO USER_SVC_ROLE;
SQL

# Now that role/object grants are done, clear the owner password
unset OWNER_PWD
```

4. Create app user (in‑memory password substitution)
```bash
# Run as a DBA to create the runtime user and assign only CREATE SESSION + role.

set +o history
read -s -p "Enter the App user password (USER_SVC_APP): " APP_PWD; echo
# APP_PWD_ESC=${APP_PWD//\\/\\\\}; APP_PWD_ESC=${APP_PWD_ESC//\//\/}; APP_PWD_ESC=${APP_PWD_ESC//&/\&}
APP_PWD_ESC=$(printf '%s' "$APP_PWD" | sed -e 's/[\/&]/\\&/g' -e 's/\\/\\\\/g')

{
  printf 'WHENEVER SQLERROR EXIT SQL.SQLCODE\n'
  printf 'ALTER SESSION SET CONTAINER=%s;\n' "$PDB_NAME"
  sed "s/REPLACE_WITH_STRONG_PASSWORD_HERE/${APP_PWD_ESC}/g" db-schemas/oracle/user-service/security.sql
  printf '\nEXIT;\n'
} | kubectl -n "$NAMESPACE" exec -i "$POD" -- sqlplus -s / as sysdba
unset APP_PWD APP_PWD_ESC
set -o history
```

5. Verify
```bash
kubectl -n "$NAMESPACE" exec -i "$POD" -- sqlplus -s / as sysdba <<SQL
WHENEVER SQLERROR EXIT SQL.SQLCODE
ALTER SESSION SET CONTAINER=${PDB_NAME};
COL USERNAME FOR A20
SELECT USERNAME, ACCOUNT_STATUS FROM DBA_USERS WHERE USERNAME IN ('USER_SVC','USER_SVC_APP');
SELECT GRANTEE, GRANTED_ROLE FROM DBA_ROLE_PRIVS WHERE GRANTEE='USER_SVC_APP';
SQL

set +o history; read -s -p "App user password (USER_SVC_APP): " APP_PWD; echo
kubectl -n "$NAMESPACE" exec -i "$POD" -- sqlplus -s "USER_SVC_APP/${APP_PWD}@localhost:1521/${PDB_NAME}" <<'SQL'
WHENEVER SQLERROR EXIT SQL.SQLCODE
SET HEADING OFF FEEDBACK OFF PAGES 0
SELECT COUNT(*) FROM USER_SVC.ROLES;
EXIT;
SQL
unset APP_PWD; set -o history
```

Helper script alternative (runs steps 2–5 automatically):
```bash
bash oracle/apply-user-service.sh
```

## Security Best Practices

- Avoid using `SYS`/`SYSTEM` for application connections; create a dedicated schema owner (e.g., `appuser`) and grant the minimal required privileges.
- Use strong passwords and rotate them; consider password profiles as appropriate.
- Prefer internal-only access (ClusterIP). If external access is required, consider Ingress/LoadBalancer and NetworkPolicies.
- Consider enabling TCPS and server-side wallets for encrypted/authenticated connections in production.
- Manage tablespace quotas for schema owners (e.g., `ALTER USER ... QUOTA ... ON ...`) to prevent runaway growth.

## Cleanup

Use the cleanup script for a clean uninstall in the correct order:

```bash
# Remove the DB, PVCs, admin secret, pull secret, and the application namespace
DELETE_PVCS=true \
DELETE_SECRET=true \
DELETE_IMAGE_PULL_SECRET=true IMAGE_PULL_SECRET=ocr-pull-secret \
DELETE_NAMESPACE=true \
bash oracle/cleanup-oracle-k8s.sh

# Optional (isolated clusters): also remove the operator and cert-manager
DELETE_OPERATOR=true \
DELETE_CERT_MANAGER=true \
CERT_MANAGER_VERSION=v1.19.1 \
bash oracle/cleanup-oracle-k8s.sh
```

Notes:
- By default, the cleanup removes the Oracle operator as well (cluster-scoped). Set `DELETE_OPERATOR=false` to keep it.
- Cert-manager is shared in many clusters; set `DELETE_CERT_MANAGER=true` only if you installed it specifically for this and nothing else depends on it. The script will attempt a Helm uninstall if a `cert-manager` release exists, otherwise it deletes the raw manifest for `CERT_MANAGER_VERSION` and removes the namespace.

## Notes

- Secrets are created at runtime by the script; no credentials are stored in the repo.
- For MicroK8s, the default hostpath / local-path storage class is auto-detected; set `STORAGE_CLASS` explicitly to override.
- OCR images always require a docker-registry Secret; the script will prompt/create if missing.
- Database bootstrap can take several minutes; the script waits up to ~20 minutes.

## Examples

- Install cert-manager via raw manifest and deploy Free edition with default pull secret name:

```bash
CERT_MANAGER_METHOD=apply CERT_MANAGER_VERSION=v1.19.1 ./deploy-oracle-k8s.sh
```

- Skip operator installation (already installed) and use a pre-created docker config JSON:

```bash
SKIP_OPERATOR_INSTALL=true DOCKER_CONFIG_JSON=$HOME/.docker/config.json ./deploy-oracle-k8s.sh
```

- Override operator namespace (if your cluster uses a different one):

```bash
OPERATOR_NAMESPACE=oracle-database-operator-system ./deploy-oracle-k8s.sh
```