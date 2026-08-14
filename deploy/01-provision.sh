#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# Provision Flowise on Azure App Service (Linux container)
#   + PostgreSQL Flexible Server   -> flows, credentials, chat history
#   + Azure Files share            -> uploaded documents, logs
#   + pinned encryption key        -> saved credentials stay decryptable
#
# Safe to re-run: every step is create-if-missing.
# ---------------------------------------------------------------------------
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/00-config.sh"

say() { printf '\n\033[1;36m==> %s\033[0m\n' "$*"; }

say "Using subscription $SUBSCRIPTION_ID"
az account set --subscription "$SUBSCRIPTION_ID"

# --- 0. Resource group -----------------------------------------------------
say "Resource group: $RESOURCE_GROUP"
az group create -n "$RESOURCE_GROUP" -l "$LOCATION" -o none

# --- 1. Storage account + file share --------------------------------------
say "Storage account: $STORAGE_ACCOUNT"
if ! az storage account show -g "$RESOURCE_GROUP" -n "$STORAGE_ACCOUNT" -o none 2>/dev/null; then
  az storage account create \
    -g "$RESOURCE_GROUP" -n "$STORAGE_ACCOUNT" -l "$LOCATION" \
    --sku Standard_LRS --kind StorageV2 \
    --min-tls-version TLS1_2 --allow-blob-public-access false -o none
fi

STORAGE_KEY="$(az storage account keys list -g "$RESOURCE_GROUP" \
  -n "$STORAGE_ACCOUNT" --query '[0].value' -o tsv)"

say "File share: $FILE_SHARE_NAME (${FILE_SHARE_QUOTA_GB}GB)"
az storage share-rm create \
  -g "$RESOURCE_GROUP" --storage-account "$STORAGE_ACCOUNT" \
  -n "$FILE_SHARE_NAME" --quota "$FILE_SHARE_QUOTA_GB" -o none 2>/dev/null || true

# --- 2. PostgreSQL Flexible Server ----------------------------------------
say "PostgreSQL Flexible Server: $PG_SERVER_NAME"
if ! az postgres flexible-server show -g "$RESOURCE_GROUP" -n "$PG_SERVER_NAME" -o none 2>/dev/null; then
  az postgres flexible-server create \
    -g "$RESOURCE_GROUP" -n "$PG_SERVER_NAME" -l "$LOCATION" \
    --admin-user "$PG_ADMIN_USER" --admin-password "$PG_ADMIN_PASSWORD" \
    --sku-name "$PG_SKU" --tier "$PG_TIER" \
    --storage-size "$PG_STORAGE_GB" --version "$PG_VERSION" \
    --public-access 0.0.0.0 \
    --yes -o none
else
  echo "    already exists, skipping create"
fi

# az >= 2.89 no longer accepts --database-name on server create (it is now an
# elastic-cluster-only flag), so the database is created as its own step.
# NOTE: for `db create`, -n is the DATABASE name and -s is the server. Using
# -d here silently does nothing useful and Flowise then dies at startup with
# `database "flowise" does not exist`.
say "Database: $PG_DB_NAME"
if az postgres flexible-server db list -g "$RESOURCE_GROUP" -s "$PG_SERVER_NAME" \
     --query "[?name=='$PG_DB_NAME']" -o tsv | grep -q .; then
  echo "    already exists, skipping create"
else
  az postgres flexible-server db create \
    -g "$RESOURCE_GROUP" -s "$PG_SERVER_NAME" -n "$PG_DB_NAME" -o none
fi

PG_HOST="${PG_SERVER_NAME}.postgres.database.azure.com"

# Allow other Azure services (the App Service outbound IPs live here).
# NOTE: for firewall-rule, -s is the SERVER and -n is the RULE name.
az postgres flexible-server firewall-rule create \
  -g "$RESOURCE_GROUP" -s "$PG_SERVER_NAME" \
  -n AllowAzureServices \
  --start-ip-address 0.0.0.0 --end-ip-address 0.0.0.0 \
  -o none 2>/dev/null || true

# Flowise's very first migration calls uuid_generate_v4(), which lives in the
# uuid-ossp extension. Azure PostgreSQL refuses to load any extension that is
# not on the server's allow-list, so without this the container crash-loops
# with: function uuid_generate_v4() does not exist
say "Allow-listing the uuid-ossp extension"
az postgres flexible-server parameter set \
  -g "$RESOURCE_GROUP" -s "$PG_SERVER_NAME" \
  -n azure.extensions -v UUID-OSSP -o none

# --- 3. App Service plan ---------------------------------------------------
say "App Service plan: $PLAN_NAME ($APP_SERVICE_SKU, Linux)"
if ! az appservice plan show -g "$RESOURCE_GROUP" -n "$PLAN_NAME" -o none 2>/dev/null; then
  az appservice plan create \
    -g "$RESOURCE_GROUP" -n "$PLAN_NAME" -l "$LOCATION" \
    --is-linux --sku "$APP_SERVICE_SKU" -o none
fi

# --- 4. Web App (container) ------------------------------------------------
say "Web App: $APP_NAME"
if ! az webapp show -g "$RESOURCE_GROUP" -n "$APP_NAME" -o none 2>/dev/null; then
  az webapp create \
    -g "$RESOURCE_GROUP" -p "$PLAN_NAME" -n "$APP_NAME" \
    --container-image-name "$FLOWISE_IMAGE" -o none
else
  az webapp config container set \
    -g "$RESOURCE_GROUP" -n "$APP_NAME" \
    --container-image-name "$FLOWISE_IMAGE" -o none
fi

# --- 5. Mount the Azure Files share ---------------------------------------
# NOTE: App Service rejects a mount path containing a dot-prefixed directory
# with a bare "Bad Request". The Flowise docs use /opt/flowise/.flowise, which
# therefore CANNOT be used here -- hence /opt/flowise/data.
say "Mounting $FILE_SHARE_NAME at $MOUNT_PATH"
if az webapp config storage-account list -g "$RESOURCE_GROUP" -n "$APP_NAME" \
     --query "[?name=='flowisedata']" -o tsv | grep -q .; then
  MOUNT_VERB=update
else
  MOUNT_VERB=add
fi
az webapp config storage-account "$MOUNT_VERB" \
  -g "$RESOURCE_GROUP" -n "$APP_NAME" \
  --custom-id flowisedata \
  --storage-type AzureFiles \
  --share-name "$FILE_SHARE_NAME" \
  --account-name "$STORAGE_ACCOUNT" \
  --access-key "$STORAGE_KEY" \
  --mount-path "$MOUNT_PATH" \
  -o none

# --- 6. Application settings ----------------------------------------------
say "Applying application settings"
az webapp config appsettings set -g "$RESOURCE_GROUP" -n "$APP_NAME" -o none --settings \
  WEBSITES_PORT=3000 \
  PORT=3000 \
  WEBSITES_CONTAINER_START_TIME_LIMIT=1800 \
  WEBSITES_ENABLE_APP_SERVICE_STORAGE=false \
  DATABASE_TYPE=postgres \
  DATABASE_HOST="$PG_HOST" \
  DATABASE_PORT=5432 \
  DATABASE_NAME="$PG_DB_NAME" \
  DATABASE_USER="$PG_ADMIN_USER" \
  DATABASE_PASSWORD="$PG_ADMIN_PASSWORD" \
  DATABASE_SSL=true \
  SECRETKEY_STORAGE_TYPE=local \
  FLOWISE_SECRETKEY_OVERWRITE="$FLOWISE_SECRETKEY_OVERWRITE" \
  APIKEY_STORAGE_TYPE=db \
  STORAGE_TYPE=local \
  BLOB_STORAGE_PATH="$MOUNT_PATH/storage" \
  LOG_PATH="$MOUNT_PATH/logs" \
  LOG_LEVEL=info \
  JWT_AUTH_TOKEN_SECRET="$JWT_AUTH_TOKEN_SECRET" \
  JWT_REFRESH_TOKEN_SECRET="$JWT_REFRESH_TOKEN_SECRET" \
  JWT_TOKEN_EXPIRY_IN_MINUTES=360 \
  JWT_REFRESH_TOKEN_EXPIRY_IN_MINUTES=129600 \
  TOKEN_HASH_SECRET="$TOKEN_HASH_SECRET" \
  EXPRESS_SESSION_SECRET="$EXPRESS_SESSION_SECRET" \
  PASSWORD_SALT_HASH_ROUNDS=10 \
  FLOWISE_FILE_SIZE_LIMIT=50mb

# --- 7. Runtime config -----------------------------------------------------
say "Enabling Always On + HTTPS-only + container logging"
az webapp config set -g "$RESOURCE_GROUP" -n "$APP_NAME" \
  --always-on true --ftps-state Disabled -o none
az webapp update -g "$RESOURCE_GROUP" -n "$APP_NAME" --https-only true -o none
az webapp log config -g "$RESOURCE_GROUP" -n "$APP_NAME" \
  --docker-container-logging filesystem -o none

say "Restarting to pick up settings"
az webapp restart -g "$RESOURCE_GROUP" -n "$APP_NAME" -o none

URL="https://${APP_NAME}.azurewebsites.net"
cat <<EOF

---------------------------------------------------------------------------
  Flowise URL      : $URL
  Postgres host    : $PG_HOST
  Storage account  : $STORAGE_ACCOUNT  (share: $FILE_SHARE_NAME)
  Secrets file     : $ENV_FILE   <-- BACK THIS UP

  First container pull is ~1.4 GB; allow 5-10 minutes before the page loads.
  Tail logs with:  ./02-logs.sh
  Health check  :  ./03-verify.sh
---------------------------------------------------------------------------
EOF
