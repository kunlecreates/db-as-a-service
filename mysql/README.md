# MySQL 8 InnoDBCluster on Kubernetes (mysql-system)

This folder provisions a MySQL InnoDBCluster (MySQL 8+) using Oracle's MySQL Operator for Kubernetes.

- Workload: InnoDBCluster (StatefulSet + Router managed by the Operator)
- Workload Namespace: `mysql-system`
- Operator Namespace: `mysql-operator-system`
- Service: ClusterIP for the primary entry Service (backed by MySQL Router)
- Storage: PVC per server via `datadirVolumeClaimTemplate`
- Secrets: Root credentials are injected at runtime; never committed

References:
- Introduction: https://dev.mysql.com/doc/mysql-operator/en/mysql-operator-introduction.html
- Install Operator (Helm): https://dev.mysql.com/doc/mysql-operator/en/mysql-operator-installation-helm.html
- Simple kubectl deploy: https://dev.mysql.com/doc/mysql-operator/en/mysql-operator-innodbcluster-simple-kubectl.html
- CR properties: https://dev.mysql.com/doc/mysql-operator/en/mysql-operator-properties.html
- Service explanation: https://dev.mysql.com/doc/mysql-operator/en/mysql-operator-innodbcluster-service.html

## Files
- `00-namespace.yaml` – Namespace template.
- `10-secret.yaml` – Secret template with `rootUser`, `rootHost`, `rootPassword` (filled by script at runtime).
- `20-innodbcluster.yaml` – InnoDBCluster CR template (service type is templated; defaults to ClusterIP), storage template, MySQL version.
- `25-backup-pvc.yaml` – PVC template for backups; referenced by the cluster `backupProfiles`.
- `30-mysqlbackup.yaml` – Template for on-demand backups using the configured backup profile.
- `deploy-mysql-k8s.sh` – Bash script that templates and applies all resources, ensures the Operator is installed via Helm, and waits for ONLINE status.
- `cleanup-mysql-k8s.sh` – Bash script to uninstall the instance (and optionally the Operator + CRDs for full cleanup).

## Prerequisites
- A Kubernetes cluster reachable by `kubectl` (or MicroK8s via `microk8s kubectl`).
- Helm is required. The deploy script installs/updates the MySQL Operator Helm chart in namespace `mysql-operator-system`.
  - Chart version is pinned by `OPERATOR_CHART_VERSION` (default `2.1.9`).
  - Operator image tag is pinned by `OPERATOR_IMAGE_TAG` (default `8.4.0-2.1.3`).
- A default StorageClass, or set `STORAGE_CLASS` explicitly when running the script.

## Configure and Run (Linux shell)
```bash
# Option A: Prompt for root password
bash mysql/deploy-mysql-k8s.sh

# Option B: Provide variables inline (recommended MySQL 8.4 with current pinned operator)
MYSQL_ROOT_PASSWORD='YourStrong!Passw0rd' \
NAMESPACE='mysql-system' \
CLUSTER_NAME='mysql' \
INSTANCES=1 \
ROUTER_INSTANCES=1 \
MYSQL_VERSION='8.4.0' \
STORAGE_SIZE='8Gi' \
STORAGE_CLASS='' \
SERVICE_TYPE='ClusterIP' \
bash mysql/deploy-mysql-k8s.sh
```

Notes:
- `SERVICE_TYPE` can be `ClusterIP` (default here), `NodePort`, or `LoadBalancer`.
- If `STORAGE_CLASS` is empty, the cluster default is used. For MicroK8s, enable hostpath storage (`microk8s enable hostpath-storage`) or use a distributed CSI for multi-node.
- Operator namespace is fixed to `mysql-operator-system`.
- You can override operator versions via `OPERATOR_CHART_VERSION` and `OPERATOR_IMAGE_TAG` env vars.

### Backups
- The cluster defines a `backupProfiles` entry that uses a PVC (`25-backup-pvc.yaml`).
- With some provisioners (e.g., local-path with `WaitForFirstConsumer`), the backup PVC may stay `Pending` until first use.
  - Options:
    - Set `STORAGE_CLASS` to one that binds immediately.
    - Create a matching PV for the backup PVC.
    - Trigger a one-off backup to cause binding.

Triggering an on-demand backup (example):
```bash
# Set names to match your deployment
export NAMESPACE=mysql-system
export CLUSTER_NAME=mysql
export BACKUP_PROFILE_NAME=pvc-backups
export BACKUP_JOB_NAME=backup-now

# Apply the backup CR (30-mysqlbackup.yaml uses placeholders)
sed -e "s#__CLUSTER_NAME__#${CLUSTER_NAME}#g" \
    -e "s#__BACKUP_PROFILE_NAME__#${BACKUP_PROFILE_NAME}#g" \
    -e "s#__BACKUP_JOB_NAME__#${BACKUP_JOB_NAME}#g" \
    mysql/30-mysqlbackup.yaml | kubectl -n ${NAMESPACE} apply -f -
```

## Connect
- In-cluster DNS (recommended): `mysql.mysql-system.svc.cluster.local:6446` (MySQL Router read/write port) or `3306` if configured.
- Workstation access (temporary):
  ```bash
  kubectl -n mysql-system port-forward svc/mysql 3306:6446
  # then in another terminal
  mysql -h 127.0.0.1 -P 3306 -u root -p
  ```
- MySQL Shell from a helper pod (no local client needed):
  ```bash
  kubectl run --rm -it myshell --image=container-registry.oracle.com/mysql/community-operator -- mysqlsh root@mysql --sql
  # enter the root password when prompted
  ```

## Deploy a database schema

You can load a schema from your workstation (Linux/macOS/WSL) via a port-forward, or from inside the cluster. Root is fine for bootstrapping; for apps, create a dedicated user with least privilege.

Option A — Port-forward to the read-write port and apply locally:

```bash
# Forward local 3306 to the router RW targetPort (often 6446)
kubectl -n mysql-system port-forward svc/mysql 3306:6446

# In another terminal:
mysql -h 127.0.0.1 -P 3306 -u root -p < ./schema.sql
```

Option B — Run a temporary MySQL client pod (no local client needed):

```bash
# Start a throwaway MySQL client pod and run the schema from stdin against in-cluster DNS
kubectl run --rm -i --tty mysql-client --image=mysql:8 --restart=Never -- \
  bash -lc 'cat >/tmp/schema.sql; mysql -h mysql.mysql-system.svc.cluster.local -P 6446 -u root -p < /tmp/schema.sql'
# Paste your schema, then Ctrl-D to send EOF when prompted for the password
```

Place the `security.sql` file into a MySQL server pod (so the hardened examples can read `/tmp/security.sql`):

```bash
# Identify a server pod (e.g., mysql-0)
kubectl -n mysql-system get pods -l app.kubernetes.io/name=mysql

# Copy security.sql into /tmp/security.sql
kubectl -n mysql-system cp db-schemas/mysql/product-service/security.sql mysql-0:/tmp/security.sql

# (Optional) Copy schema.sql as a standalone file
kubectl -n mysql-system cp db-schemas/mysql/product-service/schema.sql mysql-0:/tmp/schema.sql
```

### Substitute a placeholder password at runtime (no file edits)

If your `security.sql` includes a placeholder like `REPLACE_WITH_STRONG_PASSWORD_HERE`, substitute it safely in-memory and pipe to `mysql` without committing secrets. Run this in a MySQL pod shell (or any client pod) with access to the server:

```bash
read -s -p "Enter app user password: " APP_PWD; echo
APP_PWD_ESC=$(printf '%s' "$APP_PWD" | sed -e 's/[&\/\\]/\\&/g')

read -s -p "Enter admin password (root): " MYSQL_ROOT_PWD; echo

# If inside a server pod: localhost:3306 is typical. With Router: mysql:6446.
sed "s/REPLACE_WITH_STRONG_PASSWORD_HERE/$APP_PWD_ESC/g" /tmp/security.sql \
| mysql -h 127.0.0.1 -P 3306 -u root -p"$MYSQL_ROOT_PWD"

unset APP_PWD APP_PWD_ESC MYSQL_ROOT_PWD
```

### Advanced: hardened runtime substitution (bash-only, no argv/env secrets)

This approach avoids putting any secret in command arguments and does not require Python. It escapes the password in bash and feeds a tiny sed script via stdin while allowing `mysql` to prompt for the admin password.

Best attempt (prompt for root password):

```bash
set +o history
read -s -p "Enter app user password (product_app): " APP_PWD; echo
APP_PWD_ESC=${APP_PWD//\\/\\\\}; APP_PWD_ESC=${APP_PWD_ESC//\//\\/}; APP_PWD_ESC=${APP_PWD_ESC//&/\\&}

# Inside a server pod, 127.0.0.1:3306 is typical. With Router, use mysql:6446.
sed -f - /tmp/security.sql <<SED | mysql -h 127.0.0.1 -P 3306 -u root -p
s/REPLACE_WITH_STRONG_PASSWORD_HERE/${APP_PWD_ESC}/g
SED

unset APP_PWD APP_PWD_ESC
set -o history
```

Fallback (if your mysql build won’t prompt with redirected stdin):

```bash
set +o history
read -s -p "Enter app user password (product_app): " APP_PWD; echo
APP_PWD_ESC=${APP_PWD//\\/\\\\}; APP_PWD_ESC=${APP_PWD_ESC//\//\\/}; APP_PWD_ESC=${APP_PWD_ESC//&/\\&}
read -s -p "Enter admin password (root): " MYSQL_ROOT_PWD; echo

MYSQL_PWD="$MYSQL_ROOT_PWD" sed -f - /tmp/security.sql <<SED | mysql -h 127.0.0.1 -P 3306 -u root
s/REPLACE_WITH_STRONG_PASSWORD_HERE/${APP_PWD_ESC}/g
SED

unset APP_PWD APP_PWD_ESC MYSQL_ROOT_PWD MYSQL_PWD
set -o history
```

Alternative: stream locally without copying a file into the pod (one‑off)

If you’d rather not copy `security.sql` into the pod, you can stream it directly from your workstation into a server pod. This variant keeps secrets out of command-line arguments and uses a short‑lived env var only if prompting fails.

```bash
set +o history
read -s -p "Enter app user password (product_app): " APP_PWD; echo
# Escape for sed replacement (\, /, &)
APP_PWD_ESC=${APP_PWD//\\/\\\\}; APP_PWD_ESC=${APP_PWD_ESC//\//\\/}; APP_PWD_ESC=${APP_PWD_ESC//&/\&}
read -s -p "Enter root password (root): " MYSQL_ROOT_PWD; echo

MYSQL_PWD="$MYSQL_ROOT_PWD" sed -f - db-schemas/mysql/product-service/security.sql <<SED \
  | kubectl -n mysql-system exec -i mysql-0 -- mysql -h 127.0.0.1 -P 3306 -u root
s/REPLACE_WITH_STRONG_PASSWORD_HERE/${APP_PWD_ESC}/g
SED

unset APP_PWD APP_PWD_ESC MYSQL_ROOT_PWD MYSQL_PWD
set -o history
```

Security notes
- Avoid passing admin passwords as `-pMyPwd` on the command line; let `mysql` prompt when possible. If prompting fails, use a short‑lived `MYSQL_PWD` only for that process and unset it. Keep history disabled during the block and re‑enable after.

Creating an application user (example):

```bash
# Using port-forward:
kubectl -n mysql-system port-forward svc/mysql 3306:6446 &
PF_PID=$!
sleep 2

mysql -h 127.0.0.1 -P 3306 -u root -p <<'SQL'
CREATE DATABASE appdb;
CREATE USER appuser IDENTIFIED BY 'Str0ngPwd!';
GRANT SELECT, INSERT, UPDATE, DELETE ON appdb.* TO appuser;
FLUSH PRIVILEGES;
SQL

# Load your schema as the application user (adjust schema path)
mysql -h 127.0.0.1 -P 3306 -u appuser -p appdb < ./schema.sql

kill $PF_PID
```

## Cleanup

## Recommended: stepwise, hardened workflow (ready to run)

These steps stream SQL into the cluster, keep secrets in-memory only, and are easy to re-run. They assume defaults from this repo:
- Namespace: `mysql-system`
- Cluster name: `mysql`
- Secret: `mysql-cluster-secret` (created by the deploy script)
- Server pod: `mysql-0`

1) Ensure the database exists (idempotent)

```bash
ROOT_PWD=$(kubectl -n mysql-system get secret mysql-cluster-secret -o jsonpath='{.data.rootPassword}' | base64 --decode)
kubectl -n mysql-system exec -i mysql-0 -- env MYSQL_PWD="$ROOT_PWD" \
  mysql --ssl-mode=REQUIRED -h 127.0.0.1 -P 3306 -u root -e \
  "CREATE DATABASE IF NOT EXISTS product_svc CHARACTER SET utf8mb4 COLLATE utf8mb4_0900_ai_ci;"
unset ROOT_PWD
```

2) Apply the schema into the database

```bash
ROOT_PWD=$(kubectl -n mysql-system get secret mysql-cluster-secret -o jsonpath='{.data.rootPassword}' | base64 --decode)
cat db-schemas/mysql/product-service/schema.sql \
  | kubectl -n mysql-system exec -i mysql-0 -- env MYSQL_PWD="$ROOT_PWD" \
    mysql --ssl-mode=REQUIRED -h 127.0.0.1 -P 3306 -u root product_svc
unset ROOT_PWD
```

3) Apply security with in-memory substitution (no secrets written to disk)

```bash
set +o history
read -s -p "Enter app user password (product_app): " APP_PWD; echo
# Escape for sed replacement (\, /, &)
APP_PWD_ESC=${APP_PWD//\\/\\\\}; APP_PWD_ESC=${APP_PWD_ESC//\//\/}; APP_PWD_ESC=${APP_PWD_ESC//&/\&}

ROOT_PWD=$(kubectl -n mysql-system get secret mysql-cluster-secret -o jsonpath='{.data.rootPassword}' | base64 --decode)
sed "s/REPLACE_WITH_STRONG_PASSWORD_HERE/${APP_PWD_ESC}/g" db-schemas/mysql/product-service/security.sql \
  | kubectl -n mysql-system exec -i mysql-0 -- env MYSQL_PWD="$ROOT_PWD" \
    mysql --ssl-mode=REQUIRED -h 127.0.0.1 -P 3306 -u root

unset APP_PWD APP_PWD_ESC ROOT_PWD
set -o history
```

4) Verify results

```bash
ROOT_PWD=$(kubectl -n mysql-system get secret mysql-cluster-secret -o jsonpath='{.data.rootPassword}' | base64 --decode)
kubectl -n mysql-system exec -i mysql-0 -- env MYSQL_PWD="$ROOT_PWD" \
  mysql --ssl-mode=REQUIRED -h 127.0.0.1 -P 3306 -u root -N -e "\
    SELECT SCHEMA_NAME FROM INFORMATION_SCHEMA.SCHEMATA WHERE SCHEMA_NAME='product_svc';\n\
    SELECT User, Host FROM mysql.user WHERE User='product_app';\n\
    SHOW GRANTS FOR 'product_app'@'%';\n\
  "
unset ROOT_PWD
```

Notes
- If you customized the cluster or secret name, adjust `mysql-cluster-secret` and `mysql-0` accordingly.
- `--ssl-mode=REQUIRED` aligns with `REQUIRE SSL` in `security.sql` and the operator’s default `tlsUseSelfSigned: true`.
- Prefer in-pod execution for reliability. When using the Router service, target `mysql.mysql-system.svc.cluster.local:6446` instead of `127.0.0.1:3306`.


Use the cleanup script for a safe, ordered uninstall.

Instance uninstall (remove instance artifacts; add flags to remove PVCs/secrets):
```bash
export NAMESPACE=mysql-system
export CLUSTER_NAME=mysql
# Optional flags
export DELETE_PVCS=true
export DELETE_SECRET=true
bash mysql/cleanup-mysql-k8s.sh
```

Full uninstall (instance + operator + CRDs + namespaces):
```bash
export FULL_UNINSTALL=true
bash mysql/cleanup-mysql-k8s.sh
```

## Troubleshooting
- If the Operator pod crashloops with an SSL error like: “CA cert does not include key usage extension”, pin the operator image via `OPERATOR_IMAGE_TAG=8.4.0-2.1.3` (this is the default in the script).
- If the backup PVC remains `Pending`, set `STORAGE_CLASS` to a provisioner that binds immediately, create a matching PV, or trigger a MySQLBackup to bind it.

## Security Best Practices
- Use a strong root password and limit `rootHost` (default `%` is open).
- Create application users with least privilege; avoid using root from applications.
- For production, consider TLS settings beyond `tlsUseSelfSigned: true` and a distributed storage backend.


