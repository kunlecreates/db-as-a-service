# PostgreSQL on MicroK8s (Bitnami Helm, OCI by default)

This deploys PostgreSQL using the official Bitnami Helm charts in the namespace `postgres-system`, with an internal-only Kubernetes `ClusterIP` Service for in-cluster access. By default we use OCI chart references; you can toggle HA mode to use `postgresql-ha` (Pgpool-II + Repmgr).

No credentials are committed to the repo. The script creates a runtime `Secret` with the admin password for the `postgres` user.

## What this sets up
 - Namespace: `postgres-system`
 - Helm release: `postgresql`
 - Chart (default): `oci://registry-1.docker.io/bitnamicharts/postgresql`
 - HA toggle: `HA=true` switches to `oci://registry-1.docker.io/bitnamicharts/postgresql-ha` (includes Pgpool-II + Repmgr)
 - Service type: `ClusterIP` (internal only; prefer port-forward for workstation access)
 - Persistent storage (default 8Gi); configurable storage class
 - Init volume permissions fix (helps with MicroK8s hostPath PVs)

## Prerequisites
- A working Kubernetes cluster (MicroK8s recommended) and `kubectl` configured
- `helm` v3
- On Windows, run the script with WSL (Ubuntu), Git Bash, or a similar bash environment

## Deploy
Run the script; it will prompt you interactively (hidden input + confirmation) for the admin password.
- bash:
  - `bash postgres/deploy-postgres-k8s.sh`
- PowerShell:
  - ``bash postgres/deploy-postgres-k8s.sh``

The script will:
- Create the namespace if missing (`postgres-system`)
- Create a Secret `postgresql-auth` with key(s):
  - non-HA: `postgres-password`
  - HA: `postgres-password`, `password`, and `repmgr-password` (the same value unless `REPMGR_PASSWORD` is set)
- Install/upgrade the Bitnami chart (OCI by default; set `CHART_NAME` to override; optionally pin `CHART_VERSION`)
- Wait for the StatefulSet to be ready
- Print connection information (ClusterIP and service DNS)

Retrieve the admin password later (if needed):
- `kubectl -n postgres-system get secret postgresql-auth -o jsonpath='{.data.postgres-password}' | base64 -d`


## Options
- HA mode: `HA=true bash postgres/deploy-postgres-k8s.sh`
- Service type: `SERVICE_TYPE=LoadBalancer|NodePort|ClusterIP` (default `ClusterIP`)
- Pin chart version: `CHART_VERSION=x.y.z`
- Override chart reference: `CHART_NAME=oci://...` or `CHART_NAME=bitnami/postgresql` (non-OCI; repo add/update will be performed)

### Resource requests/limits
You can set resource requests and limits via environment variables to avoid relying on chart presets.

- Non-HA (postgresql chart):
  - `PRIMARY_CPU_REQUEST`, `PRIMARY_MEM_REQUEST`
  - `PRIMARY_CPU_LIMIT`, `PRIMARY_MEM_LIMIT`
- HA (postgresql-ha chart):
  - PostgreSQL pods: `POSTGRESQL_CPU_REQUEST`, `POSTGRESQL_MEM_REQUEST`, `POSTGRESQL_CPU_LIMIT`, `POSTGRESQL_MEM_LIMIT`
  - Pgpool pods: `PGPOOL_CPU_REQUEST`, `PGPOOL_MEM_REQUEST`, `PGPOOL_CPU_LIMIT`, `PGPOOL_MEM_LIMIT`
- Both charts (volumePermissions init container):
  - `VP_CPU_REQUEST`, `VP_MEM_REQUEST`, `VP_CPU_LIMIT`, `VP_MEM_LIMIT`

Example (non-HA):
```
PRIMARY_CPU_REQUEST=250m \
PRIMARY_MEM_REQUEST=512Mi \
VP_CPU_REQUEST=50m \
VP_MEM_REQUEST=64Mi \
bash postgres/deploy-postgres-k8s.sh
```

Example (HA):
```
HA=true \
POSTGRESQL_CPU_REQUEST=250m \
POSTGRESQL_MEM_REQUEST=512Mi \
PGPOOL_CPU_REQUEST=100m \
PGPOOL_MEM_REQUEST=256Mi \
bash postgres/deploy-postgres-k8s.sh
```

### Registry and image pull settings
- Use Docker Hub credentials to avoid anonymous rate limits or 401s:
  - `DOCKERHUB_USERNAME=... DOCKERHUB_PASSWORD=...`
  - Optional: `DOCKERHUB_EMAIL=...` and `DOCKERHUB_SECRET_NAME=dockerhub-cred` (default)
  - The script will create a docker-registry Secret in the namespace and wire it globally via `global.imagePullSecrets`.
- Set a global image registry if you need to switch (default stays on Docker Hub):
  - `IMAGE_REGISTRY=docker.io` (default) or `IMAGE_REGISTRY=ghcr.io`
- If you hit image verification issues with newer chart versions, allow insecure image verification:
  - `ALLOW_INSECURE_IMAGES=true` (sets `global.security.allowInsecureImages=true`)

Tip: To print a short HA migration checklist when deploying non-HA, set `SHOW_HA_GUIDANCE=true`.

### Pinning image tags (Docker Hub)
Recent Bitnami updates can prune older Debian-based tags on Docker Hub. If a default tag is missing, pin working tags via env vars:

- HA mode (postgresql-ha):
  - `POSTGRESQL_REPMGR_IMAGE_TAG` → overrides `postgresql.image.tag`
  - `PGPOOL_IMAGE_TAG` → overrides `pgpool.image.tag`
- Both modes (init container):
  - `OS_SHELL_IMAGE_TAG` → overrides `volumePermissions.image.tag`
- Non-HA mode (postgresql chart):
  - `POSTGRESQL_IMAGE_TAG` → overrides `image.tag`

Suggested known-good tags on Docker Hub at the time of writing:
- `PGPOOL_IMAGE_TAG=4.6.3-debian-12-r6`
- `POSTGRESQL_REPMGR_IMAGE_TAG=17.6.0-debian-12-r2`
- `OS_SHELL_IMAGE_TAG=12-debian-12-r54`

Example (HA):
```
HA=true \
PGPOOL_IMAGE_TAG=4.6.3-debian-12-r6 \
POSTGRESQL_REPMGR_IMAGE_TAG=17.6.0-debian-12-r2 \
OS_SHELL_IMAGE_TAG=12-debian-12-r54 \
DOCKERHUB_USERNAME=... DOCKERHUB_PASSWORD=... \
bash postgres/deploy-postgres-k8s.sh
```

### Troubleshooting image pulls
- Error: `unexpected media type text/html ... not found` when pulling from Docker Hub
  - Cause: The requested tag may have been pruned on Docker Hub, or a proxy/rate-limit returns HTML instead of the Docker Registry API response.
  - Fix:
    - Provide Docker Hub credentials (see above), and
    - Pin tags using the env vars listed in “Pinning image tags”. Start with the suggested tags.
    - Optionally, set `IMAGE_REGISTRY=ghcr.io` to pull from GitHub Container Registry instead of Docker Hub.

## Connect
Port-forward (workstation access):
- non-HA service: `svc/postgresql`
- HA service (Pgpool): `svc/postgresql-pgpool`

Examples:
- kubectl -n postgres-system port-forward svc/postgresql 5432:5432
- kubectl -n postgres-system port-forward svc/postgresql-pgpool 5432:5432
- Then: `PGPASSWORD=****** psql -h 127.0.0.1 -p 5432 -U postgres`

Deploy a database schema
Use `psql` to apply SQL scripts via a port-forward.
- kubectl -n postgres-system port-forward svc/postgresql 5432:5432
- PGPASSWORD=****** psql -h 127.0.0.1 -p 5432 -U postgres -d postgres -f ./schema.sql

Place the `security.sql` file into the PostgreSQL pod (so the hardened examples can read `/tmp/security.sql`):

```bash
# Get pod(s) for the release
kubectl -n postgres-system get pods -l app.kubernetes.io/name=postgresql

# Copy security.sql into the first pod (adjust pod name if different)
kubectl -n postgres-system cp db-schemas/postgres/product-service/security.sql postgresql-0:/tmp/security.sql

# (Optional) Copy schema.sql as a standalone file
kubectl -n postgres-system cp db-schemas/postgres/product-service/schema.sql postgresql-0:/tmp/schema.sql
```

### Substitute a placeholder password at runtime (no file edits)

If you have a script like `schema.sql` that contains a placeholder like `REPLACE_WITH_STRONG_PASSWORD_HERE`, substitute it safely in-memory and pipe to `psql`. Run this inside a Postgres pod or from your workstation via port-forward:

```bash
read -s -p "Enter app user password: " APP_PWD; echo
APP_PWD_ESC=$(printf '%s' "$APP_PWD" | sed -e 's/[&\/\\]/\\&/g')

read -s -p "Enter admin password (postgres): " PGPASSWORD; echo
export PGPASSWORD

sed "s/REPLACE_WITH_STRONG_PASSWORD_HERE/$APP_PWD_ESC/g" /tmp/security.sql \
| psql -h 127.0.0.1 -p 5432 -U postgres -d postgres -v ON_ERROR_STOP=1

unset APP_PWD APP_PWD_ESC PGPASSWORD
```

### Advanced: hardened runtime substitution (bash-only, no argv/env secrets)

Use a bash-only approach to escape the password and feed a sed script via stdin so `psql` can still prompt on the TTY; no Python required.

Best (prompt for admin password):

```bash
set +o history
read -s -p "Enter app user password (product_app): " APP_PWD; echo
APP_PWD_ESC=${APP_PWD//\\/\\\\}; APP_PWD_ESC=${APP_PWD_ESC//\//\\/}; APP_PWD_ESC=${APP_PWD_ESC//&/\\&}

sed -f - /tmp/security.sql <<SED | psql -h 127.0.0.1 -p 5432 -U postgres -d postgres -v ON_ERROR_STOP=1
s/REPLACE_WITH_STRONG_PASSWORD_HERE/${APP_PWD_ESC}/g
SED

unset APP_PWD APP_PWD_ESC
set -o history
```

Fallback (short‑lived env var if prompting isn’t available):

```bash
set +o history
read -s -p "Enter app user password (product_app): " APP_PWD; echo
APP_PWD_ESC=${APP_PWD//\\/\\\\}; APP_PWD_ESC=${APP_PWD_ESC//\//\\/}; APP_PWD_ESC=${APP_PWD_ESC//&/\\&}
read -s -p "Enter admin password (postgres): " PGADMIN_PWD; echo

PGPASSWORD="$PGADMIN_PWD" sed -f - /tmp/security.sql <<SED | psql -h 127.0.0.1 -p 5432 -U postgres -d postgres -v ON_ERROR_STOP=1
s/REPLACE_WITH_STRONG_PASSWORD_HERE/${APP_PWD_ESC}/g
SED

unset APP_PWD APP_PWD_ESC PGADMIN_PWD PGPASSWORD
set -o history
```

Alternative: stream locally without copying a file into the pod (one‑off)

If you prefer not to copy `security.sql` into the pod, stream it from your workstation directly into `psql` running in the pod.

```bash
set +o history
read -s -p "Enter app user password (product_app): " APP_PWD; echo
# Escape for sed replacement (\, /, &)
APP_PWD_ESC=${APP_PWD//\\/\\\\}; APP_PWD_ESC=${APP_PWD_ESC//\//\\/}; APP_PWD_ESC=${APP_PWD_ESC//&/\&}
read -s -p "Enter admin password (postgres): " PGADMIN_PWD; echo

PGPASSWORD="$PGADMIN_PWD" sed -f - db-schemas/postgres/product-service/security.sql <<SED \
  | kubectl -n postgres-system exec -i postgresql-0 -- psql -h 127.0.0.1 -p 5432 -U postgres -d postgres -v ON_ERROR_STOP=1
s/REPLACE_WITH_STRONG_PASSWORD_HERE/${APP_PWD_ESC}/g
SED

unset APP_PWD APP_PWD_ESC PGADMIN_PWD PGPASSWORD
set -o history
```

Security notes
- Avoid embedding admin passwords on the command line; let `psql` prompt, or use a short‑lived `PGPASSWORD` only when necessary and unset it promptly. Keep history disabled during the block and re‑enable after.

> Tip: Create a dedicated application database and user with least privileges, for example:

### Example Implementation

The following commands were run and verified in-cluster during testing. They use the in-cluster Secret (`postgresql-auth`) to obtain the admin password only in-memory and stream SQL without writing secrets to disk. These steps are idempotent and give clear failure points for debugging.

1) Ensure the target database exists (creates it if missing)

```bash
# Decode admin password from the chart-created Secret (in-memory only)
# PG_PWD=$(kubectl -n postgres-system get secret postgresql-auth -o jsonpath='{.data.postgres-password}' | base64 --decode)

# Create the database if it does not exist (idempotent)
kubectl -n postgres-system exec -i postgresql-0 -- \
  env PGPASSWORD="$(kubectl -n postgres-system get secret postgresql-auth -o jsonpath='{.data.postgres-password}' | base64 --decode)" \
  psql -U postgres -c ON_ERROR_STOP=1 <<'EOF'
DO
$$
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM pg_database WHERE datname = 'product_svc'
    ) THEN
        EXECUTE $cmd$
            CREATE DATABASE product_svc
              WITH OWNER = postgres
                   ENCODING = 'UTF8'
                   LC_COLLATE = 'en_US.utf8'
                   LC_CTYPE = 'en_US.utf8'
                   TEMPLATE = template0;
        $cmd$;
    END IF;
END
$$;
EOF

# unset PG_PWD
```

2) Apply the schema into the created database

```bash
kubectl -n postgres-system exec -i postgresql-0 -- \
  env PGPASSWORD="$(kubectl -n postgres-system get secret postgresql-auth -o jsonpath='{.data.postgres-password}' | base64 --decode)" \
  psql -U postgres -d product_svc -v ON_ERROR_STOP=1 \
  < db-schemas/postgres/product-service/schema.sql
```

3) Apply the security script with in‑memory substitution (no secrets written to disk)

```bash
set +o history
read -s -p "Enter app user password (product_app): " APP_PWD; echo
# Escape for sed replacement (\, /, &)
#APP_PWD_ESC=${APP_PWD//\\/\\\\}; APP_PWD_ESC=${APP_PWD_ESC//\//\\/}; APP_PWD_ESC=${APP_PWD_ESC//&/\\&}
APP_PWD_ESC=$(printf '%s' "$APP_PWD" | sed -e 's/[\/&]/\\&/g' -e 's/\\/\\\\/g')

sed "s|REPLACE_WITH_STRONG_PASSWORD_HERE|${APP_PWD_ESC}|g" \
  db-schemas/postgres/product-service/security.sql \
  | kubectl -n postgres-system exec -i postgresql-0 -- \
      env PGPASSWORD="$(kubectl -n postgres-system get secret postgresql-auth -o jsonpath='{.data.postgres-password}' | base64 --decode)" \
      psql -U postgres -d product_svc -v ON_ERROR_STOP=1

unset APP_PWD
set -o history
```

4) Verify results (confirm schema and objects)

```bash
# List schemas and confirm `product_svc` exists
# PG_PWD=$(kubectl -n postgres-system get secret postgresql-auth -o jsonpath='{.data.postgres-password}' | base64 --decode)

kubectl -n postgres-system exec -i postgresql-0 -- \
  env PGPASSWORD="$(kubectl -n postgres-system get secret postgresql-auth -o jsonpath='{.data.postgres-password}' | base64 --decode)" \
  psql -U postgres -d product_svc -c "\\dn"

# List schema-qualified tables (shows tables created under schema `product_svc`)
kubectl -n postgres-system exec -i postgresql-0 -- \
  env PGPASSWORD="$(kubectl -n postgres-system get secret postgresql-auth -o jsonpath='{.data.postgres-password}' | base64 --decode)" \
  psql -U postgres -d product_svc -c "\\dt product_svc.*"

# Show table definitions for verification (example)
kubectl -n postgres-system exec -i postgresql-0 -- \
  env PGPASSWORD="$(kubectl -n postgres-system get secret postgresql-auth -o jsonpath='{.data.postgres-password}' | base64 --decode)" \
  psql -U postgres -d product_svc -c "\\d product_svc.products"

# List roles and confirm app roles were created
kubectl -n postgres-system exec -i postgresql-0 -- \
  env PGPASSWORD="$(kubectl -n postgres-system get secret postgresql-auth -o jsonpath='{.data.postgres-password}' | base64 --decode)" \
  psql -U postgres -d product_svc -c "\\du"

# unset PG_PWD
```

Notes:
- The schema objects in this project are created under the `product_svc` schema; `\dt` without qualifiers will not show them unless `product_svc` is in `search_path`.
- Secrets were decoded only in the shell that executed these commands and were unset immediately after use. Avoid copying secrets to files or committing them.
- If you prefer not to decode the Secret automatically, prompt for the admin password and set `PGPASSWORD` locally instead.

Helper script alternative (runs steps 1–4 automatically):
```bash
bash postgres/apply-product-service.sh
```

## Uninstall / Cleanup
-- Remove the release (data remains due to PVC):
  - ```helm -n postgres-system uninstall postgresql```
-- Optionally delete PVCs to reclaim storage (this deletes data):
  - ```kubectl -n postgres-system delete pvc -l app.kubernetes.io/instance=postgresql,app.kubernetes.io/name=postgresql```
-- Remove namespace (if no longer needed):
  - ```kubectl delete ns postgres-system```

## Notes
- Never commit actual passwords. They’re injected at runtime via a Kubernetes Secret.
- The chart runs as non-root and we enable `volumePermissions` to avoid PV permission issues on MicroK8s hostPath storage.
- If you also want a custom database and user provisioned by the chart, you can set `auth.username`, `auth.password`, and `auth.database` via Helm values. If you continue to use `auth.existingSecret`, include the `password` key in the Secret as well (non-HA).
- This script prompts for the admin password by default; you can also set it non-interactively via `POSTGRES_PASSWORD` environment variable.

