#!/usr/bin/env bash
set -euo pipefail

# Seed product_service DB with 01-seed.sql
# Usage:
#   NAMESPACE=postgres-system ./seed-postgres.sh

NAMESPACE="${NAMESPACE:-postgres-system}"
SERVICE_NAME="${SERVICE_NAME:-postgresql}"
POD_NAME="${POD_NAME:-}"
DB_NAME="${DB_NAME:-product_svc}"
SECRET_NAME="${SECRET_NAME:-postgresql-auth}"
SECRET_KEY="${SECRET_KEY:-postgres-password}"
SEED_FILE="${SEED_FILE:-../db-schemas/postgres/product-service/01-seed.sql}"

if [[ ! -f "$SEED_FILE" ]]; then
  echo "[error] Seed file not found: $SEED_FILE" >&2
  exit 1
fi

echo "[info] Resolving Postgres pod in namespace $NAMESPACE"
if [[ -z "$POD_NAME" ]]; then
  POD_NAME=$(kubectl -n "$NAMESPACE" get endpoints "$SERVICE_NAME" -o jsonpath='{.subsets[0].addresses[0].targetRef.name}' 2>/dev/null || true)
fi
if [[ -z "$POD_NAME" ]]; then
  POD_NAME=$(kubectl -n "$NAMESPACE" get pods -l app.kubernetes.io/name=postgresql -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)
fi
if [[ -z "$POD_NAME" ]]; then
  POD_NAME="postgresql-0"
fi
echo "[info] Using pod: $POD_NAME"

# Fetch password from secret if available
PGPWD=$(kubectl -n "$NAMESPACE" get secret "$SECRET_NAME" -o jsonpath="{.data.$SECRET_KEY}" 2>/dev/null | base64 --decode 2>/dev/null || true)
if [[ -z "$PGPWD" ]]; then
  echo "[warn] Could not fetch Postgres password from secret $SECRET_NAME; attempting psql without PGPASSWORD"
fi

echo "[step] Copying seed file to pod"
kubectl -n "$NAMESPACE" cp "$SEED_FILE" "$POD_NAME":/tmp/seed_postgres.sql

# Snapshot existing rows for comparison (before)
echo "[step] Snapshotting existing product rows (before)"
SKUS=('APPLE001' 'BANANA001' 'MILK001' 'BREAD001' 'EGGS001' 'CHEESE001' 'ORANGE001' 'CEREAL001' 'YOGURT001' 'BUTTER001')
SKUS_LIST=$(printf "'%s'," "${SKUS[@]}" | sed 's/,$//')
PROD_BEFORE_FILE=$(mktemp)
INV_BEFORE_FILE=$(mktemp)
if [[ -n "$PGPWD" ]]; then
  kubectl -n "$NAMESPACE" exec -i "$POD_NAME" -- env PGPASSWORD="$PGPWD" psql -U postgres -d "$DB_NAME" -tA -F $'\t' -c "SELECT sku, name, price_cents, attributes::text, is_active FROM product_svc.products WHERE sku IN ($SKUS_LIST) ORDER BY sku;" > "$PROD_BEFORE_FILE"
  kubectl -n "$NAMESPACE" exec -i "$POD_NAME" -- env PGPASSWORD="$PGPWD" psql -U postgres -d "$DB_NAME" -tA -F $'\t' -c "SELECT p.sku, pi.quantity FROM product_svc.product_inventory pi JOIN product_svc.products p ON p.id=pi.product_id WHERE p.sku IN ($SKUS_LIST) ORDER BY p.sku;" > "$INV_BEFORE_FILE"
else
  kubectl -n "$NAMESPACE" exec -i "$POD_NAME" -- psql -U postgres -d "$DB_NAME" -tA -F $'\t' -c "SELECT sku, name, price_cents, attributes::text, is_active FROM product_svc.products WHERE sku IN ($SKUS_LIST) ORDER BY sku;" > "$PROD_BEFORE_FILE"
  kubectl -n "$NAMESPACE" exec -i "$POD_NAME" -- psql -U postgres -d "$DB_NAME" -tA -F $'\t' -c "SELECT p.sku, pi.quantity FROM product_svc.product_inventory pi JOIN product_svc.products p ON p.id=pi.product_id WHERE p.sku IN ($SKUS_LIST) ORDER BY p.sku;" > "$INV_BEFORE_FILE"
fi

echo "[step] Applying seeds to database $DB_NAME"
if [[ -n "$PGPWD" ]]; then
  kubectl -n "$NAMESPACE" exec -i "$POD_NAME" -- env PGPASSWORD="$PGPWD" psql -U postgres -d "$DB_NAME" -v ON_ERROR_STOP=1 -f /tmp/seed_postgres.sql
else
  kubectl -n "$NAMESPACE" exec -i "$POD_NAME" -- psql -U postgres -d "$DB_NAME" -v ON_ERROR_STOP=1 -f /tmp/seed_postgres.sql
fi

echo "[step] Cleaning up"
kubectl -n "$NAMESPACE" exec -i "$POD_NAME" -- rm -f /tmp/seed_postgres.sql || true

echo "[success] Postgres seeds applied to $DB_NAME"


# Verification: ensure 10 products and 10 inventory rows were inserted
echo "[step] Verifying Postgres seed results (secure)"
SKUS=('APPLE001' 'BANANA001' 'MILK001' 'BREAD001' 'EGGS001' 'CHEESE001' 'ORANGE001' 'CEREAL001' 'YOGURT001' 'BUTTER001')
SKUS_LIST=$(printf "'%s'," "${SKUS[@]}" | sed 's/,$//')
if [[ -n "$PGPWD" ]]; then
  prod_cnt=$(kubectl -n "$NAMESPACE" exec -i "$POD_NAME" -- env PGPASSWORD="$PGPWD" psql -U postgres -d "$DB_NAME" -tAc "SELECT COUNT(*) FROM product_svc.products WHERE sku IN ($SKUS_LIST);")
  inv_cnt=$(kubectl -n "$NAMESPACE" exec -i "$POD_NAME" -- env PGPASSWORD="$PGPWD" psql -U postgres -d "$DB_NAME" -tAc "SELECT COUNT(*) FROM product_svc.product_inventory WHERE product_id IN (SELECT id FROM product_svc.products WHERE sku IN ($SKUS_LIST));")
else
  prod_cnt=$(kubectl -n "$NAMESPACE" exec -i "$POD_NAME" -- psql -U postgres -d "$DB_NAME" -tAc "SELECT COUNT(*) FROM product_svc.products WHERE sku IN ($SKUS_LIST);")
  inv_cnt=$(kubectl -n "$NAMESPACE" exec -i "$POD_NAME" -- psql -U postgres -d "$DB_NAME" -tAc "SELECT COUNT(*) FROM product_svc.product_inventory WHERE product_id IN (SELECT id FROM product_svc.products WHERE sku IN ($SKUS_LIST));")
fi

prod_cnt=$(echo "$prod_cnt" | tr -dc '0-9')
inv_cnt=$(echo "$inv_cnt" | tr -dc '0-9')

echo "[verify] products=$prod_cnt expected=10, inventory_rows=$inv_cnt expected=10"
if [[ "$prod_cnt" -lt 10 || "$inv_cnt" -lt 10 ]]; then
  echo "[error] Postgres verification failed: counts below expected" >&2
  exit 2
fi

echo "[success] Postgres verification passed."

# Snapshot after and compute inserts/updates
PROD_AFTER_FILE=$(mktemp)
INV_AFTER_FILE=$(mktemp)
if [[ -n "$PGPWD" ]]; then
  kubectl -n "$NAMESPACE" exec -i "$POD_NAME" -- env PGPASSWORD="$PGPWD" psql -U postgres -d "$DB_NAME" -tA -F $'\t' -c "SELECT sku, name, price_cents, attributes::text, is_active FROM product_svc.products WHERE sku IN ($SKUS_LIST) ORDER BY sku;" > "$PROD_AFTER_FILE"
  kubectl -n "$NAMESPACE" exec -i "$POD_NAME" -- env PGPASSWORD="$PGPWD" psql -U postgres -d "$DB_NAME" -tA -F $'\t' -c "SELECT p.sku, pi.quantity FROM product_svc.product_inventory pi JOIN product_svc.products p ON p.id=pi.product_id WHERE p.sku IN ($SKUS_LIST) ORDER BY p.sku;" > "$INV_AFTER_FILE"
else
  kubectl -n "$NAMESPACE" exec -i "$POD_NAME" -- psql -U postgres -d "$DB_NAME" -tA -F $'\t' -c "SELECT sku, name, price_cents, attributes::text, is_active FROM product_svc.products WHERE sku IN ($SKUS_LIST) ORDER BY sku;" > "$PROD_AFTER_FILE"
  kubectl -n "$NAMESPACE" exec -i "$POD_NAME" -- psql -U postgres -d "$DB_NAME" -tA -F $'\t' -c "SELECT p.sku, pi.quantity FROM product_svc.product_inventory pi JOIN product_svc.products p ON p.id=pi.product_id WHERE p.sku IN ($SKUS_LIST) ORDER BY p.sku;" > "$INV_AFTER_FILE"
fi

echo "[step] Results — products inserted/updated"
awk -F"\t" '{print $1}' "$PROD_BEFORE_FILE" | sort > /tmp/_prod_before_skus
awk -F"\t" '{print $1}' "$PROD_AFTER_FILE" | sort > /tmp/_prod_after_skus
echo "Inserted SKUs:"; comm -23 /tmp/_prod_after_skus /tmp/_prod_before_skus || true
echo "Updated SKUs:";
awk -F"\t" 'NR==FNR{a[$1]=$0; next} { if($1 in a && a[$1]!= $0) print $1 }' "$PROD_BEFORE_FILE" "$PROD_AFTER_FILE" || true

echo "[step] Results — inventory inserted/updated"
awk -F"\t" '{print $1}' "$INV_BEFORE_FILE" | sort > /tmp/_inv_before_skus
awk -F"\t" '{print $1}' "$INV_AFTER_FILE" | sort > /tmp/_inv_after_skus
echo "Inserted inventory SKUs:"; comm -23 /tmp/_inv_after_skus /tmp/_inv_before_skus || true
echo "Updated inventory SKUs:";
awk -F"\t" 'NR==FNR{a[$1]=$0; next} { if($1 in a && a[$1]!= $0) print $1 }' "$INV_BEFORE_FILE" "$INV_AFTER_FILE" || true

# cleanup tmp files
rm -f "$PROD_BEFORE_FILE" "$INV_BEFORE_FILE" "$PROD_AFTER_FILE" "$INV_AFTER_FILE" /tmp/_prod_before_skus /tmp/_prod_after_skus /tmp/_inv_before_skus /tmp/_inv_after_skus || true
