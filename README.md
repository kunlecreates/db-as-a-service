# ShopEase DBaaS for Kubernetes

> **Database-as-a-Service implementation for enterprise microservices applications**
>
> Production-grade Kubernetes deployments for SQL Server 2022, PostgreSQL 17,
> Oracle Database 23c Free, and MySQL 8 InnoDBCluster — with automated provisioning,
> least-privilege security, and a complete schema lifecycle for the ShopEase
> e-commerce platform.

[![Kubernetes](https://img.shields.io/badge/Kubernetes-1.28%2B-326CE5?logo=kubernetes&logoColor=white)](https://kubernetes.io/)
[![SQL Server](https://img.shields.io/badge/SQL%20Server-2022-CC2927?logo=microsoftsqlserver&logoColor=white)](mssql/)
[![PostgreSQL](https://img.shields.io/badge/PostgreSQL-17-4169E1?logo=postgresql&logoColor=white)](postgres/)
[![Oracle DB](https://img.shields.io/badge/Oracle%20DB-23c%20Free-F80000?logo=oracle&logoColor=white)](oracle/)
[![MySQL](https://img.shields.io/badge/MySQL-8.4-4479A1?logo=mysql&logoColor=white)](mysql/)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](#license)

---

## Table of Contents

- [Overview](#overview)
- [Architecture](#architecture)
- [Repository Structure](#repository-structure)
- [Example Implementation — ShopEase](#example-implementation--shopease)
  - [Service-to-Datastore Mapping](#service-to-datastore-mapping)
  - [Schema Highlights](#schema-highlights)
  - [Security Model](#security-model)
- [Prerequisites](#prerequisites)
- [Quick Start](#quick-start)
- [Datastores](#datastores)
  - [SQL Server 2022 — Order Service](#sql-server-2022--order-service)
  - [PostgreSQL 17 — Product Service](#postgresql-17--product-service)
  - [Oracle Database 23c Free — User Service](#oracle-database-23c-free--user-service)
  - [MySQL 8 InnoDBCluster — Product Service \(Alternative\)](#mysql-8-innodbcluster--product-service-alternative)
- [Schema and Seed Loading](#schema-and-seed-loading)
- [Security Principles](#security-principles)
- [Configuration Reference](#configuration-reference)
- [Cleanup](#cleanup)
- [Contributing](#contributing)
- [License](#license)

---

## Overview

This repository provides **Database-as-a-Service (DBaaS) provisioning** for cloud-native
microservices applications running on Kubernetes. It packages four production-grade
relational database engines — each deployed using its canonical, operator-driven or
Helm-managed method — into repeatable, namespace-isolated units that can be provisioned,
schema-loaded, seeded, and torn down with a single command.

**What this repository delivers:**

- Kubernetes manifests and deploy scripts for **SQL Server 2022**, **PostgreSQL 17**,
  **Oracle Database 23c Free**, and **MySQL 8 InnoDBCluster**
- A consistent _deploy → schema-load → seed → cleanup_ lifecycle for every engine
- **Security-first by design** — no committed credentials, dedicated least-privilege
  application users per service, and `ClusterIP`-only exposure by default
- A concrete, real-world reference implementation — the **ShopEase** enterprise
  e-commerce platform — demonstrating how each engine is matched to a specific
  microservice workload

**Companion schemas:** The `../db-schemas/` directory (sibling to this folder) contains
bounded-context SQL schemas, security provisioning scripts, seed data, and rollback
scripts for each ShopEase service.

---

## Architecture

```text
 ┌──────────────────────────────────────────────────────────────────────────┐
 │                    ShopEase Enterprise Microservices                     │
 ├────────────────────────┬──────────────────────┬──────────────────────────┤
 │      user-service      │   product-service    │      order-service       │
 │  auth · RBAC · tokens  │  catalogue · SKUs ·  │  carts · orders ·        │
 │  refresh · login audit │  inventory · search  │  payments                │
 └───────────┬────────────┴──────────┬───────────┴────────────┬─────────────┘
             │                       │                        │
             ▼                       ▼                        ▼
 ┌───────────────────┐   ┌───────────────────┐   ┌────────────────────────┐
 │  Oracle DB 23c    │   │   PostgreSQL 17   │   │   SQL Server 2022      │
 │  Free Edition     │   │   Bitnami Helm    │   │   StatefulSet          │
 │  oracle-system    │   │   postgres-system │   │   mssql-system         │
 │  Port: 1521       │   │   Port: 5432      │   │   Port: 1433           │
 └───────────────────┘   └──────────┬────────┘   └────────────────────────┘
                               (or alternate)
                          ┌─────────▼─────────┐
                          │    MySQL 8.4      │
                          │   InnoDBCluster   │
                          │   mysql-system    │
                          │  Port: 6446 (RW)  │
                          └───────────────────┘
```

Cross-service data references use **opaque string keys** (`user_ref`, `product_ref`) —
no foreign key constraints cross service boundaries. Services communicate via APIs and
events; each database enforces consistency strictly within its own bounded context.

---

## Repository Structure

```text
db-services/
├── mssql/                          # SQL Server 2022 — order-service
│   ├── 00-namespace.yaml
│   ├── 10-secret.yaml              # Secret template (credentials injected at runtime)
│   ├── 20-pvc.yaml
│   ├── 30-headless-svc.yaml
│   ├── 40-statefulset.yaml
│   ├── 50-service.yaml
│   ├── deploy-mssql.sh             # Provision the instance
│   ├── load-mssql-schemas.sh       # Apply schema + security + verify
│   ├── cleanup-mssql.sh
│   └── README.md
│
├── mysql/                          # MySQL 8.4 InnoDBCluster — product-service (alternative)
│   ├── 00-namespace.yaml
│   ├── 10-secret.yaml
│   ├── 20-innodbcluster.yaml
│   ├── 25-backup-pvc.yaml
│   ├── 30-mysqlbackup.yaml
│   ├── deploy-mysql.sh             # Provision via MySQL Operator (Helm)
│   ├── cleanup-mysql.sh
│   └── README.md
│
├── oracle/                         # Oracle DB 23c Free — user-service
│   ├── 00-namespace.yaml
│   ├── 10-secret.yaml
│   ├── 20-sidb.yaml                # SingleInstanceDatabase Custom Resource
│   ├── deploy-oracle.sh            # Provision via Oracle Database Operator
│   ├── load-oracle-schemas.sh
│   ├── seed-oracle.sh
│   ├── cleanup-oracle.sh
│   └── README.md
│
├── postgres/                       # PostgreSQL 17 — product-service
│   ├── deploy-postgres.sh          # Provision via Bitnami Helm chart
│   ├── load-postgres-schemas.sh
│   ├── seed-postgres.sh
│   ├── cleanup-postgres.sh
│   └── README.md
│
└── README.md                       # This file
```

---

## Example Implementation — ShopEase

The datastores in this repository are purpose-built for **ShopEase**, an enterprise
e-commerce platform composed of three independently deployable microservices. Each
service owns its data exclusively and uses the database engine best suited to its
workload, following the **database-per-service** pattern.

### Service-to-Datastore Mapping

| Service | Database Engine | Namespace | Deployment Method | Application Schema |
|---|---|---|---|---|
| `user-service` | Oracle DB 23c Free | `oracle-system` | Oracle DB Operator + SIDB CR | `USER_SVC` schema in `FREEPDB1` |
| `product-service` | PostgreSQL 17 | `postgres-system` | Bitnami Helm chart | `product_svc` schema |
| `product-service` _(alt)_ | MySQL 8.4 InnoDBCluster | `mysql-system` | MySQL Operator (Helm) | `product_svc` database |
| `order-service` | SQL Server 2022 | `mssql-system` | Kubernetes StatefulSet | `order_svc` schema |

### Schema Highlights

#### user-service → Oracle Database 23c Free

Manages all identity, authentication, and authorisation for the platform.

| Table | Purpose |
|---|---|
| `users` | Core user records — email, bcrypt password hash, active flag |
| `roles` | Named authority levels (e.g. `customer`, `admin`) |
| `user_roles` | Many-to-many user ↔ role assignments |
| `refresh_tokens` | JWT refresh token lifecycle — token hash, expiry, revocation timestamp |
| `email_verification_tokens` | One-time email verification tokens (stored as hashes) |
| `password_reset_tokens` | Secure password-reset tokens (stored as hashes) |
| `login_audit` | Every authentication attempt — IP address, user agent, success or failure |
| `domain_events` | Transactional outbox for domain events (CLOB with `IS JSON` constraint) |

**Design notes:**
- All token values are stored as **hashes** — raw secrets are never persisted.
- `login_audit` supports security incident investigation without requiring external
  log aggregation infrastructure.
- Baseline roles (`customer`, `admin`) are seeded idempotently using a `MERGE` statement.

#### product-service → PostgreSQL 17 / MySQL 8.4

Manages the product catalogue, inventory, and stock movement audit trail.

| Table | Purpose |
|---|---|
| `products` | SKU catalogue — name, description, flexible JSON `attributes`, `price_cents` |
| `categories` | Product taxonomy with `is_active` flag |
| `product_categories` | Many-to-many product ↔ category join table |
| `product_inventory` | Current stock level and reserved quantity per product |
| `stock_movements` | Immutable audit log of every inventory change (delta, reason, context) |

**Design notes:**
- Monetary values are stored as **integer cents** (`price_cents BIGINT`) to eliminate
  floating-point rounding errors across currencies.
- The `attributes` column (`JSONB` in PostgreSQL, `JSON` in MySQL) captures per-product
  flexible metadata — size, colour, unit — without requiring schema migrations.
- Full-text search is first-class: PostgreSQL maintains a `search_vector` (`TSVECTOR`)
  column updated automatically by a `BEFORE INSERT OR UPDATE` trigger; MySQL uses a
  `FULLTEXT` index on `name` and `description`.
- Seed data ships 10 grocery products with initial inventory, inserted idempotently via
  `ON CONFLICT DO UPDATE` (PostgreSQL) and upsert-safe patterns (MySQL).

#### order-service → SQL Server 2022

Manages the complete shopping and fulfilment lifecycle.

| Table | Purpose |
|---|---|
| `carts` | Shopping session tied to `user_ref` — lifecycle: `OPEN` → `CHECKED_OUT` → `ABANDONED` |
| `cart_items` | Line items in a cart — product ref, quantity, unit price snapshot |
| `orders` | Confirmed purchase — status lifecycle, shipping address snapshot, payment metadata |
| `order_items` | Immutable line items on a confirmed order |
| `payments` | Payment attempt records — provider, status, amount, external gateway reference |

**Design notes:**
- The **shipping address is snapshotted** onto `orders` at checkout time — later profile
  address changes never retroactively alter historical orders.
- Payment columns store only **display-safe metadata** (`payment_last4`, `payment_brand`,
  `payment_method_type`) — no card numbers or CVVs are persisted (PCI DSS scope reduction).
- All monetary amounts use **integer cents** with an explicit `currency NCHAR(3)` column.
- The `order_svc` SQL Server schema qualifier enforces the service boundary at the
  database level; the app user is granted CRUD on `SCHEMA::order_svc` only.

### Security Model

Each service is issued a **dedicated least-privilege runtime identity**. The application
never connects as an admin or migration account at runtime.

| Service | DB Role | DB User / Login | Permissions |
|---|---|---|---|
| `order-service` | `order_service_role` | `order_app` (login: `order_app_login`) | `SELECT, INSERT, UPDATE, DELETE ON SCHEMA::order_svc` |
| `product-service` (PG) | `product_service_role` | `product_app` | `SELECT, INSERT, UPDATE, DELETE` on all tables in `product_svc` |
| `product-service` (MySQL) | `product_service_role` | `product_app@%` | `SELECT, INSERT, UPDATE, DELETE ON product_svc.*` + `REQUIRE SSL` |
| `user-service` (Oracle) | `USER_SVC_ROLE` | `USER_SVC_APP` | Object-level CRUD on `USER_SVC`-owned tables + `CREATE SESSION` only |

> Schema migrations use a separate, time-bound migration account.
> Runtime application users have **no DDL rights** (`CREATE`, `ALTER`, `DROP`).

Security scripts in `../db-schemas/` contain a `REPLACE_WITH_STRONG_PASSWORD_HERE`
placeholder that is substituted at provisioning time using an in-memory `sed` pipeline —
passwords never touch disk, Git history, or command-line argument lists.

---

## Prerequisites

| Requirement | Minimum Version | Notes |
|---|---|---|
| `kubectl` or `microk8s kubectl` | 1.28+ | Must point at a running cluster |
| `helm` | v3.x | PostgreSQL (Bitnami), MySQL Operator, Oracle cert-manager |
| `bash` | 4.x | All deploy, schema-load, and cleanup scripts |
| A default `StorageClass` | — | For dynamic PVC provisioning; override via `STORAGE_CLASS` env var |
| Oracle Container Registry account | — | Required for Oracle image pulls — accept the license at [container-registry.oracle.com](https://container-registry.oracle.com) |

**MicroK8s users** — enable the required add-ons before deploying any engine:

```bash
microk8s enable hostpath-storage dns
```

---

## Quick Start

Each database engine deploys with a single script invocation. Admin credentials are
prompted interactively — no secrets are stored in files or committed to source control.

```bash
# SQL Server 2022 — order-service
bash mssql/deploy-mssql.sh

# PostgreSQL 17 — product-service
bash postgres/deploy-postgres.sh

# Oracle DB 23c Free — user-service (requires Oracle Container Registry credentials)
bash oracle/deploy-oracle.sh

# MySQL 8 InnoDBCluster — product-service (alternative)
bash mysql/deploy-mysql.sh
```

After provisioning, apply the ShopEase schemas and seed data:

```bash
# SQL Server: create database, apply schema, configure least-privilege access, verify
bash mssql/load-mssql-schemas.sh

# PostgreSQL: apply schema, then load seed data
bash postgres/load-postgres-schemas.sh
bash postgres/seed-postgres.sh

# Oracle: apply schema and security, then seed baseline roles
bash oracle/load-oracle-schemas.sh
bash oracle/seed-oracle.sh
```

> Each engine's `README.md` contains full configuration options, inline environment
> variable overrides, and troubleshooting guidance.

---

## Datastores

### SQL Server 2022 — Order Service

| Setting | Value |
|---|---|
| Namespace | `mssql-system` |
| Workload | `StatefulSet` (1 replica) |
| Image | `mcr.microsoft.com/mssql/server:2022-latest` |
| In-cluster DNS | `mssql-svc.mssql-system.svc.cluster.local:1433` |
| Pod DNS (headless) | `mssql-0.mssql-headless.mssql-system.svc.cluster.local:1433` |
| Edition | `Developer` (override: `MSSQL_PID`) |
| Default PVC | 8 Gi (override: `PVC_SIZE`) |

**Workstation access via port-forward:**

```bash
kubectl -n mssql-system port-forward svc/mssql-svc 1433:1433
/opt/mssql-tools18/bin/sqlcmd -C -S 127.0.0.1 -U sa -P '<password>'
```

Full documentation: [mssql/README.md](mssql/README.md)

---

### PostgreSQL 17 — Product Service

| Setting | Value |
|---|---|
| Namespace | `postgres-system` |
| Helm Release | `postgresql` |
| Workload | `StatefulSet` (Bitnami chart) |
| Chart | `oci://registry-1.docker.io/bitnamicharts/postgresql` |
| In-cluster DNS | `postgresql.postgres-system.svc.cluster.local:5432` |
| HA Mode | `HA=true` enables `postgresql-ha` (Pgpool-II + Repmgr) |
| Default PVC | 8 Gi (override: `PVC_SIZE`) |

**Workstation access via port-forward:**

```bash
kubectl -n postgres-system port-forward svc/postgresql 5432:5432
PGPASSWORD=<password> psql -h 127.0.0.1 -p 5432 -U postgres
```

Full documentation: [postgres/README.md](postgres/README.md)

---

### Oracle Database 23c Free — User Service

| Setting | Value |
|---|---|
| Namespace | `oracle-system` |
| Workload | `SingleInstanceDatabase` CR (via Oracle Database Operator) |
| Image | `container-registry.oracle.com/database/free:23.3.0` |
| In-cluster DNS | `oracledb.oracle-system.svc.cluster.local:1521` |
| CDB SID | `FREE` |
| PDB | `FREEPDB1` |
| Image Pull Secret | `ocr-pull-secret` (mandatory — accept OCR license before first pull) |
| Default PVC | 50 Gi (override: `STORAGE_SIZE`) |

**Workstation access via port-forward:**

```bash
kubectl -n oracle-system port-forward svc/oracledb 1521:1521
sqlplus "sys/<password>@127.0.0.1:1521/FREEPDB1 as sysdba"
```

Full documentation: [oracle/README.md](oracle/README.md)

---

### MySQL 8 InnoDBCluster — Product Service (Alternative)

| Setting | Value |
|---|---|
| Namespace | `mysql-system` |
| Operator Namespace | `mysql-operator-system` |
| Workload | `InnoDBCluster` (StatefulSet + Router managed by MySQL Operator) |
| MySQL Version | `8.4.0` (override: `MYSQL_VERSION`) |
| In-cluster DNS (RW) | `mysql.mysql-system.svc.cluster.local:6446` |
| Operator Chart | `mysql-operator` v2.1.9 (pinnable via `OPERATOR_CHART_VERSION`) |
| Default PVC | 8 Gi (override: `STORAGE_SIZE`) |

**Workstation access via port-forward:**

```bash
kubectl -n mysql-system port-forward svc/mysql 3306:6446
mysql -h 127.0.0.1 -P 3306 -u root -p
```

Full documentation: [mysql/README.md](mysql/README.md)

---

## Schema and Seed Loading

All SQL scripts live in the companion `../db-schemas/` directory. Helper scripts in each
engine subdirectory handle `kubectl exec` routing, in-memory password substitution, and
post-apply verification.

### Script Inventory

| Engine | Schema | Security | Seed | Rollback |
|---|---|---|---|---|
| SQL Server | `db-schemas/mssql/order-service/schema.sql` | `security.sql` | `01-seed.sql` | `02-rollback.sql` |
| PostgreSQL | `db-schemas/postgres/product-service/schema.sql` | `security.sql` | `01-seed.sql` | `02-rollback.sql` |
| Oracle | `db-schemas/oracle/user-service/schema.sql` | `security.sql` | `01-seed.sql` | `02-rollback.sql` |
| MySQL _(alt)_ | `db-schemas/mysql/product-service/schema.sql` | `security.sql` | — | — |

### In-Memory Password Substitution

Security scripts contain a `REPLACE_WITH_STRONG_PASSWORD_HERE` placeholder. The helper
scripts substitute it safely using a `sed` pipeline driven by `read -s`, so no secret
ever touches disk, Git, or command-line argument lists:

```bash
# Conceptual pattern — each engine's README.md has a fully hardened, engine-specific version
read -s -p "Enter app user password: " APP_PWD; echo
sed "s/REPLACE_WITH_STRONG_PASSWORD_HERE/${APP_PWD}/g" path/to/security.sql \
  | <db-client-command>
unset APP_PWD
```

The `load-mssql-schemas.sh`, `load-oracle-schemas.sh`, and `load-postgres-schemas.sh`
helper scripts automate this workflow end-to-end, fetching the SA/admin password
directly from the Kubernetes `Secret` object via `kubectl get secret ... | base64 --decode`.

---

## Security Principles

| Principle | Implementation |
|---|---|
| **No committed secrets** | `.gitignore` excludes `.env*` files; credentials are injected at runtime into Kubernetes `Secret` objects |
| **Least-privilege runtime identity** | Each service connects as a dedicated app user with CRUD-only permissions and no DDL rights |
| **Namespace isolation** | One Kubernetes namespace per engine: `mssql-system`, `mysql-system`, `oracle-system`, `postgres-system` |
| **ClusterIP by default** | No database port is reachable outside the cluster without an explicit `SERVICE_TYPE` override |
| **In-memory secret substitution** | `sed` pipelines substitute password placeholders at runtime — nothing is written to disk or shell history |
| **SSL enforcement** | PostgreSQL security script recommends `scram-sha-256` + SSL in `pg_hba.conf`; MySQL app user created with `REQUIRE SSL` |
| **No cross-service foreign keys** | External-reference columns (`user_ref`, `product_ref`) are plain strings — no FK constraints cross service boundaries |
| **Authentication audit logging** | Oracle `login_audit` captures every authentication attempt including IP address, user agent, and outcome |
| **Password hashing** | `users.password_hash` stores only bcrypt hashes — plaintext passwords are never persisted |

---

## Configuration Reference

All deploy scripts accept environment variable overrides. Common variables shared across
all engines:

| Variable | Default | Applies To | Description |
|---|---|---|---|
| `NAMESPACE` | engine-specific | All | Kubernetes namespace for the deployment |
| `STORAGE_CLASS` | cluster default | All | StorageClass name for PVC provisioning |
| `PVC_SIZE` / `STORAGE_SIZE` | `8Gi` | All | PVC capacity (Oracle default: `50Gi`) |
| `SERVICE_TYPE` | `ClusterIP` | All | `ClusterIP` \| `NodePort` \| `LoadBalancer` |
| `INSTANCES` | `1` | MySQL, Oracle | Replica or instance count |
| `MSSQL_PID` | `Developer` | SQL Server | SQL Server edition token |
| `MYSQL_VERSION` | `8.4.0` | MySQL | MySQL server version |
| `EDITION` | `free` | Oracle | `free` \| `enterprise` \| `standard` \| `express` |
| `HA` | `false` | PostgreSQL | `true` enables `postgresql-ha` (Pgpool-II + Repmgr) |
| `CHART_VERSION` | latest | MySQL, PostgreSQL | Pin a specific Helm chart version |
| `IMAGE_PULL_SECRET` | `ocr-pull-secret` | Oracle | Docker registry secret name for OCR |

Engine-specific variables (resource requests and limits, image tags, registry credentials,
and backup settings) are documented in each subdirectory `README.md`.

---

## Cleanup

Each engine provides a cleanup script that removes all Kubernetes resources. PVCs,
Secrets, and namespaces are deleted by default.

```bash
bash mssql/cleanup-mssql.sh
bash postgres/cleanup-postgres.sh
bash oracle/cleanup-oracle.sh
bash mysql/cleanup-mysql.sh
```

> **Warning:** These scripts permanently delete persistent volumes and all database data
> within them. Ensure backups exist before running against any environment holding live
> data. Each cleanup script exposes `DELETE_PVCS`, `DELETE_SECRET`, and `DELETE_NAMESPACE`
> flags for selective teardown.

---

## Contributing

1. Fork the repository and create a descriptively named feature branch.
2. Follow established conventions:
   - Kubernetes manifests use the `NN-resource-name.yaml` numbered-prefix scheme.
   - Scripts follow the `deploy-*.sh` / `cleanup-*.sh` / `load-*-schemas.sh` naming pattern.
   - All shell scripts must include `set -euo pipefail`.
3. **Never commit credentials**, `.env` files, or materialised `Secret` manifests —
   the root `.gitignore` enforces this for common credential file patterns.
4. Open a pull request with a clear description of the changes and the engine(s) affected.

---

## License

This project is licensed under the [MIT License](https://opensource.org/licenses/MIT).
