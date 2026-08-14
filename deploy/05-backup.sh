#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# Back up everything a learner could lose:
#   1. the Postgres database  (flows, credentials, chat history)
#   2. the Azure Files share  (uploaded documents)
#   3. deploy.env             (the key that decrypts the credentials)
#
# Postgres Flexible Server already takes automatic daily backups with 7-day
# point-in-time restore. This script gives you an *portable* copy you can keep
# off-Azure or restore into a different subscription.
#
# Requires: pg_dump (brew install libpq) and azcopy, or it falls back to
# `az storage file download-batch` for the share.
#
# Usage:  ./05-backup.sh [output-dir]     (default: ./backups)
# ---------------------------------------------------------------------------
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/00-config.sh"
az account set --subscription "$SUBSCRIPTION_ID"

OUT_ROOT="${1:-$SCRIPT_DIR/backups}"
STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
OUT="$OUT_ROOT/$STAMP"
mkdir -p "$OUT"

PG_HOST="${PG_SERVER_NAME}.postgres.database.azure.com"

# --- 1. Database ----------------------------------------------------------
echo "==> Allowing this machine through the Postgres firewall"
MY_IP="$(curl -s -4 https://ifconfig.me)"
az postgres flexible-server firewall-rule create \
  -g "$RESOURCE_GROUP" -n "$PG_SERVER_NAME" \
  --rule-name "backup-$(echo "$MY_IP" | tr '.' '-')" \
  --start-ip-address "$MY_IP" --end-ip-address "$MY_IP" -o none 2>/dev/null || true

echo "==> Dumping database -> $OUT/flowise.dump"
PGPASSWORD="$PG_ADMIN_PASSWORD" pg_dump \
  --host="$PG_HOST" --username="$PG_ADMIN_USER" --dbname="$PG_DB_NAME" \
  --format=custom --no-owner --no-acl \
  --file="$OUT/flowise.dump"

# --- 2. Uploaded files ----------------------------------------------------
echo "==> Downloading file share -> $OUT/files/"
mkdir -p "$OUT/files"
STORAGE_KEY="$(az storage account keys list -g "$RESOURCE_GROUP" \
  -n "$STORAGE_ACCOUNT" --query '[0].value' -o tsv)"
az storage file download-batch \
  --account-name "$STORAGE_ACCOUNT" --account-key "$STORAGE_KEY" \
  --source "$FILE_SHARE_NAME" --destination "$OUT/files" -o none

# --- 3. Secrets -----------------------------------------------------------
echo "==> Copying deploy.env (contains the credential encryption key)"
cp "$ENV_FILE" "$OUT/deploy.env"
chmod 600 "$OUT/deploy.env"

cat > "$OUT/RESTORE.md" <<EOF
# Restoring this backup

Taken $STAMP from $APP_NAME.

1. Provision a fresh stack, but BEFORE running 01-provision.sh copy this
   deploy.env over deploy/deploy.env. That reuses the same encryption key and
   Postgres password, so saved credentials remain decryptable.

2. Restore the database:
     PGPASSWORD='<PG_ADMIN_PASSWORD from deploy.env>' pg_restore \\
       --host=<new-server>.postgres.database.azure.com \\
       --username=$PG_ADMIN_USER --dbname=$PG_DB_NAME \\
       --clean --if-exists --no-owner --no-acl flowise.dump

3. Upload the files back to the new share:
     az storage file upload-batch --account-name <new-storage-account> \\
       --account-key <key> --destination $FILE_SHARE_NAME --source ./files

4. Restart the web app.
EOF

echo
echo "Backup complete: $OUT"
du -sh "$OUT"
