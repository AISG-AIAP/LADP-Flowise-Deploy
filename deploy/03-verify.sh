#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# Poll the deployed Flowise app until it answers, then report what persistence
# is actually wired up. Run after 01-provision.sh.
# ---------------------------------------------------------------------------
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/00-config.sh"
az account set --subscription "$SUBSCRIPTION_ID"

URL="https://${APP_NAME}.azurewebsites.net"
DEADLINE=$(( $(date +%s) + 900 ))   # 15 minutes

echo "Waiting for $URL ..."
while :; do
  CODE="$(curl -s -o /dev/null -w '%{http_code}' -m 20 "$URL" 2>/dev/null)"; CODE="${CODE:-000}"
  echo "  $(date +%H:%M:%S)  HTTP $CODE"
  [[ "$CODE" =~ ^(200|302|401)$ ]] && { echo "  -> app is up"; break; }
  (( $(date +%s) > DEADLINE )) && { echo "  -> TIMED OUT. Run ./02-logs.sh"; exit 1; }
  sleep 20
done

echo
echo "=== Persistence wiring ==="
echo "-- Mounted storage --"
az webapp config storage-account list -g "$RESOURCE_GROUP" -n "$APP_NAME" \
  --query "[].{id:name,share:value.shareName,mount:value.mountPath,acct:value.accountName}" -o table

echo
echo "-- Database settings seen by the container --"
az webapp config appsettings list -g "$RESOURCE_GROUP" -n "$APP_NAME" \
  --query "[?starts_with(name,'DATABASE_') || name=='APIKEY_STORAGE_TYPE' || name=='BLOB_STORAGE_PATH'].{setting:name,value:value}" \
  -o table | sed 's/\(DATABASE_PASSWORD.*\)/DATABASE_PASSWORD    ***hidden***/'

echo
echo "-- Encryption key pinned? (must be 'true' or credentials will not survive) --"
az webapp config appsettings list -g "$RESOURCE_GROUP" -n "$APP_NAME" \
  --query "length([?name=='FLOWISE_SECRETKEY_OVERWRITE' && value!=''])>\`0\`" -o tsv

echo
echo "-- Tables created in Postgres (proof flows/credentials land in the DB) --"
az postgres flexible-server execute \
  -n "$PG_SERVER_NAME" -u "$PG_ADMIN_USER" -p "$PG_ADMIN_PASSWORD" \
  -d "$PG_DB_NAME" \
  -q "select table_name from information_schema.tables where table_schema='public' order by 1;" \
  -o table 2>/dev/null || echo "  (skipped: needs the rdbms-connect az extension and your IP allowed on the PG firewall)"

echo
echo "Open $URL and create your admin account."
