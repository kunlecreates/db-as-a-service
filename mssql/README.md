# SQL Server 2022 on MicroK8s (mssql-system)

This folder provisions a single-instance SQL Server 2022 (Linux) in a MicroK8s cluster using Kubernetes manifests.

- Workload: StatefulSet (1 replica)
- Storage: PVC mounted at `/var/opt/mssql`
- Service: ClusterIP (internal-only; use port-forward for workstation access)
- Security: Pod-level `securityContext.fsGroup: 10001` per Microsoft guidance

References:
- Microsoft Learn (Kubernetes quickstart): https://learn.microsoft.com/en-us/sql/linux/quickstart-sql-server-containers-azure?tabs=kubectl

## Files
- `00-namespace.yaml` – Creates the `mssql-system` namespace (templated).
- `10-secret.yaml` – Secret template for `MSSQL_SA_PASSWORD` (populated by the script at runtime).
- `20-pvc.yaml` – PVC template; uses cluster default StorageClass unless `STORAGE_CLASS` is set.
- `30-headless-svc.yaml` – Headless Service for StatefulSet DNS identity.
- `40-statefulset.yaml` – SQL Server StatefulSet (fsGroup=10001, resource requests/limits, image, env vars).
- `50-service.yaml` – ClusterIP Service for SQL Server TDS port 1433.
- `deploy-mssql-microk8s.sh` – Bash script that templates and applies all manifests with MicroK8s.

## Prerequisites
- MicroK8s installed and running on Linux (or WSL2 with a Linux distribution).
- MicroK8s CLI available (`microk8s`).
- Recommended add-ons:
  - Storage: `microk8s enable hostpath-storage` (provides default StorageClass `microk8s-hostpath`).
  - DNS: `microk8s enable dns`.

If you use a multi-node MicroK8s cluster and want storage resilience across nodes, consider a distributed storage add-on (e.g., Longhorn, OpenEBS, or Rook/Ceph) and set `STORAGE_CLASS` accordingly.

## Configure and Run
Run from a Linux shell (WSL2, Git Bash on Windows with Linux tools, or any Linux host which can reach your MicroK8s):

```bash
# Option A: Prompt for SA password (Recommended. The SA password will be securely prompted when the script is ran. Never pass secrets as environment variable)
bash mssql/deploy-mssql-microk8s.sh

# Option B: Provide variables inline (Only for a development testing. The SA password secret could be stored in bash history)
MSSQL_SA_PASSWORD='YourStrong!Passw0rd' \
NAMESPACE='mssql-system' \
APP_NAME='mssql' \
IMAGE='mcr.microsoft.com/mssql/server:2022-latest' \
MSSQL_PID='Developer' \
PVC_NAME='mssql-data' \
PVC_SIZE='8Gi' \
STORAGE_CLASS='' \
SERVICE_NAME='mssql-svc' \
bash mssql/deploy-mssql-microk8s.sh
```

Notes:
- If `STORAGE_CLASS` is empty, the cluster default is used (MicroK8s usually `microk8s-hostpath`). If there is no default, enable hostpath storage or set `STORAGE_CLASS` to an existing class.
 

## Connect
- In-cluster DNS:
  - `mssql-svc.mssql-system.svc.cluster.local:1433` (ClusterIP service)
  - `mssql-0.mssql-headless.mssql-system.svc.cluster.local:1433` (pod DNS via headless service)

For workstation access, use a port-forward:
```bash
microk8s kubectl -n mssql-system port-forward svc/mssql-svc 1433:1433
```

Use `sqlcmd` (v18+ recommended):

```bash
/opt/mssql-tools18/bin/sqlcmd -S mssql-svc.mssql-system.svc.cluster.local -U sa -P 'YourStrong!Passw0rd'
```

## Deploy your database schema

You can load a schema from your workstation (Linux/macOS/WSL) using exec into the DB pod, or via a port-forward. Remember that using `sa` or `db_owner` is fine for bootstrapping a schema into the DB instance; but for apps, create a dedicated user with least privilege.

### Option 1: Exec into the SQL Server pod and run sqlcmd inside

```bash
# Get the pod name (look for the mssql pod, e.g., mssql-0)
microk8s kubectl -n mssql-system get pods

# Open a shell in the pod (replace mssql-0 with your actual pod)
microk8s kubectl -n mssql-system exec -it mssql-0 -- bash

# Inside the container, connect with sqlcmd (v18 tools are at this path)
/opt/mssql-tools18/bin/sqlcmd -S localhost -U sa -P 'YourStrong!Passw0rd'

# Example at the sqlcmd prompt:
# 1> CREATE DATABASE MyAppDb;
# 2> GO
# 1> USE MyAppDb;
# 2> GO
# ... paste your schema T-SQL here, end with GO ...
# 1> QUIT
```

Run a .sql file copied into the pod:

```bash
/opt/mssql-tools18/bin/sqlcmd -S localhost -U sa -P 'YourStrong!Passw0rd' -d MyAppDb -b -i /tmp/schema/init.sql
```

Copy a local schema directory into the pod and execute all scripts:

```bash
# From your project root where ./schema contains .sql files
microk8s kubectl -n mssql-system cp ./schema mssql-0:/tmp/schema

# Then inside the pod shell
for f in /tmp/schema/*.sql; do
  echo "Running $f"
  /opt/mssql-tools18/bin/sqlcmd -S localhost -U sa -P 'YourStrong!Passw0rd' -d MyAppDb -b -i "$f"
done
```

Place the security.sql file into the pod so the commands below can read /tmp/security.sql:

```bash
# From the repo root, copy the security script into the pod's /tmp
microk8s kubectl -n mssql-system cp db-schemas/mssql/order-service/security.sql mssql-0:/tmp/security.sql

# (Optional) If you also want schema.sql available as a single file
microk8s kubectl -n mssql-system cp db-schemas/mssql/order-service/schema.sql mssql-0:/tmp/schema.sql
```

Tip: Recent sqlcmd versions default to encrypted connections. If you hit a TLS-related error, add `-No` to make encryption optional.

#### Substitute a placeholder password at runtime (no file edits)

If your `security.sql` contains a placeholder like `REPLACE_WITH_STRONG_PASSWORD_HERE`, you can substitute it safely in-memory and pipe to `sqlcmd` without ever writing the real password to disk or Git. Run this inside the DB pod or against a port-forward:

```bash
# Prompt for the app user password (for the created login, e.g., order_app_login)
read -s -p "Enter app user password: " APP_PWD; echo
# Escape characters that sed replacement interprets
APP_PWD_ESC=$(printf '%s' "$APP_PWD" | sed -e 's/[&\/\\]/\\&/g')

# Prompt for admin password (e.g., sa)
read -s -p "Enter admin password (sa): " SA_PASSWORD; echo

# Replace placeholder on the fly and execute
sed "s/REPLACE_WITH_STRONG_PASSWORD_HERE/$APP_PWD_ESC/g" /tmp/security.sql \
| /opt/mssql-tools18/bin/sqlcmd -S localhost -U sa -P "$SA_PASSWORD" -b

unset APP_PWD APP_PWD_ESC SA_PASSWORD
```

#### Example Implementation

During testing the following stepwise approach proved reliable and easy to debug. It handles TLS/trust, server vs database context, GO/batch handling, and keeps secrets out of history and process argv by reading the SA password from the Kubernetes Secret only when needed.

Run these commands from your workstation (where `kubectl` is configured). They assume the pod is `mssql-0` in namespace `mssql-system` and that a Secret named `mssql` exists with key `MSSQL_SA_PASSWORD`.

1) Ensure the target database exists (creates it if missing)

```bash
#SA_PWD=$(kubectl -n mssql-system get secret mssql -o jsonpath='{.data.MSSQL_SA_PASSWORD}' | base64 --decode)

kubectl -n mssql-system exec -i mssql-0 -- \
env SQLCMDPASSWORD="$(kubectl -n mssql-system get secret mssql -o jsonpath='{.data.MSSQL_SA_PASSWORD}' | base64 --decode)" \
  /opt/mssql-tools18/bin/sqlcmd -C -S localhost -U sa -Q "IF DB_ID('order_svc') IS NULL BEGIN CREATE DATABASE order_svc; END"
 #unset SA_PWD
```

2) Apply the schema into the created database

```bash
#SA_PWD=$(kubectl -n mssql-system get secret mssql -o jsonpath='{.data.MSSQL_SA_PASSWORD}' | base64 --decode)
sed '' db-schemas/mssql/order-service/schema.sql \
  | kubectl -n mssql-system exec -i mssql-0 -- \
    env SQLCMDPASSWORD="$(kubectl -n mssql-system get secret mssql -o jsonpath='{.data.MSSQL_SA_PASSWORD}' | base64 --decode)" \
    /opt/mssql-tools18/bin/sqlcmd -C -S localhost -U sa -d order_svc -b
 # unset SA_PWD
```

3) Apply the security script with in‑memory substitution (no secrets written to disk)

```bash
set +o history
read -s -p "Enter app user password (order_app): " APP_PWD; echo
#APP_PWD_ESC=${APP_PWD//\\/\\\\}; APP_PWD_ESC=${APP_PWD_ESC//\//\\/}; APP_PWD_ESC=${APP_PWD//&/\\&}
APP_PWD_ESC=$(printf '%s' "$APP_PWD" | sed -e 's/[\/&]/\\&/g' -e 's/\\/\\\\/g')

# SA_PWD=$(kubectl -n mssql-system get secret mssql -o jsonpath='{.data.MSSQL_SA_PASSWORD}' | base64 --decode)
sed "s/REPLACE_WITH_STRONG_PASSWORD_HERE/${APP_PWD_ESC}/g" db-schemas/mssql/order-service/security.sql \
  | kubectl -n mssql-system exec -i mssql-0 -- \
    env SQLCMDPASSWORD="$(kubectl -n mssql-system get secret mssql -o jsonpath='{.data.MSSQL_SA_PASSWORD}' | base64 --decode)" \
    /opt/mssql-tools18/bin/sqlcmd -C -S localhost -U sa -d order_svc -b
unset APP_PWD APP_PWD_ESC # SA_PWD
set -o history
```

4) Verify results (confirm login and database)

```bash
# SA_PWD=$(kubectl -n mssql-system get secret mssql -o jsonpath='{.data.MSSQL_SA_PASSWORD}' | base64 --decode)
kubectl -n mssql-system exec -i mssql-0 -- \
env SQLCMDPASSWORD="$(kubectl -n mssql-system get secret mssql -o jsonpath='{.data.MSSQL_SA_PASSWORD}' | base64 --decode)" \
  /opt/mssql-tools18/bin/sqlcmd -C -S localhost -U sa -Q "SELECT name, type_desc FROM sys.server_principals WHERE name LIKE 'order_app%'; SELECT name FROM sys.databases WHERE name='order_svc';"
 # unset SA_PWD
```

Notes:
- `-C` trusts the server certificate (useful for self-signed in-cluster certs).
- The stepwise approach gives clear failure points (connection, create DB, apply schema, create login) and is easier to debug than a single large here-doc.

Helper script alternative (runs the four steps automatically):
```bash
bash mssql/apply-order-service.sh
```

### Option 2: Run schema from your workstation using port-forward (no shell in pod)

```bash
# Forward local port 1433 to the service's 1433
microk8s kubectl -n mssql-system port-forward svc/mssql-svc 1433:1433
```

In another terminal, run your scripts against `127.0.0.1,1433`:

```bash
sqlcmd -S 127.0.0.1 -U sa -P 'YourStrong!Passw0rd' -Q "SELECT @@VERSION"
# or
sqlcmd -S 127.0.0.1 -U sa -P 'YourStrong!Passw0rd' -d MyAppDb -b -i ./schema/init.sql
```

### Creating an application user (example)

For bootstrapping you may use the `sa` account, but applications should use a dedicated login with least privilege.

Create a database, a login, and a user mapped to that login, then grant only what’s needed. Example (Linux-first, using sqlcmd):

```bash
# Using a port-forward (127.0.0.1:1433) or in-pod sqlcmd, run:
sqlcmd -S 127.0.0.1 -U sa -P 'YourStrong!Passw0rd' -b -Q "CREATE DATABASE MyAppDb;"

# Create a SQL login at the server level
sqlcmd -S 127.0.0.1 -U sa -P 'YourStrong!Passw0rd' -b -Q "CREATE LOGIN appuser WITH PASSWORD='Str0ngPwd!';"

# Create a database user mapped to that login and grant minimal rights
sqlcmd -S 127.0.0.1 -U sa -P 'YourStrong!Passw0rd' -b -d MyAppDb -Q "CREATE USER appuser FOR LOGIN appuser;"

# For bootstrapping you might temporarily grant db_owner, then tighten later:
sqlcmd -S 127.0.0.1 -U sa -P 'YourStrong!Passw0rd' -b -d MyAppDb -Q "ALTER ROLE db_owner ADD MEMBER appuser;"

# Load your schema as the application user (preferred once permissions are right-sized)
sqlcmd -S 127.0.0.1 -U appuser -P 'Str0ngPwd!' -d MyAppDb -b -i ./schema/init.sql
```

Tips:
- Replace `db_owner` with specific roles/GRANTs once you know exactly what the app needs (for example, `db_datareader`, `db_datawriter`, and explicit EXECUTE on specific procedures).
- Rotate credentials and avoid embedding passwords in images or code.

## Cleanup
```bash
microk8s kubectl -n mssql-system delete statefulset mssql
microk8s kubectl -n mssql-system delete svc mssql-svc mssql-headless
microk8s kubectl -n mssql-system delete pvc mssql-data
microk8s kubectl -n mssql-system delete secret mssql
microk8s kubectl delete namespace mssql-system
```

## Security Best Practices
- After initial setup, create a new admin login and disable the `sa` account, per Microsoft guidance.
- Avoid enabling NodePort or LoadBalancer for the database unless there is a compelling, secured operational need; keep the default ClusterIP and use `kubectl port-forward` for ad‑hoc workstation access.
- Use a dedicated application login mapped to a database user with least privilege; avoid using `sa` or `db_owner` for application connections.
