#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# Delete ONLY the resources these scripts created, leaving the resource group
# itself in place. Requires typing the app name to confirm.
# ---------------------------------------------------------------------------
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/00-config.sh"
az account set --subscription "$SUBSCRIPTION_ID"

cat <<EOF
About to DELETE from resource group '$RESOURCE_GROUP':
  web app         $APP_NAME
  app plan        $PLAN_NAME
  postgres        $PG_SERVER_NAME   (all flows, credentials and chat history)
  storage account $STORAGE_ACCOUNT  (all uploaded documents)

This is not reversible.
EOF
read -r -p "Type the app name ($APP_NAME) to confirm: " CONFIRM
[[ "$CONFIRM" == "$APP_NAME" ]] || { echo "Aborted."; exit 1; }

az webapp delete -g "$RESOURCE_GROUP" -n "$APP_NAME" 2>/dev/null || true
az appservice plan delete -g "$RESOURCE_GROUP" -n "$PLAN_NAME" --yes 2>/dev/null || true
az postgres flexible-server delete -g "$RESOURCE_GROUP" -n "$PG_SERVER_NAME" --yes 2>/dev/null || true
az storage account delete -g "$RESOURCE_GROUP" -n "$STORAGE_ACCOUNT" --yes 2>/dev/null || true

echo "Done. deploy.env kept at $ENV_FILE — delete it manually if you are finished."
