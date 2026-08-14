#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# Read the Flowise container log (the app's own stdout/stderr, not the Azure
# platform chatter).
#
#   ./02-logs.sh          last 80 lines, stack-trace noise stripped
#   ./02-logs.sh -f       follow (streams; Ctrl-C to stop)
#   ./02-logs.sh -a       everything, unfiltered
#   ./02-logs.sh -p       the Azure platform log (container start/stop/pull)
#
# NOTE: `az webapp log tail` needs SCM basic authentication, which many
# organisations disable by policy. It then silently produces NOTHING rather
# than an error. This script enables the SCM credential if required, reads the
# log over the Kudu VFS API, and tells you if it changed the setting.
# ---------------------------------------------------------------------------
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/00-config.sh"
az account set --subscription "$SUBSCRIPTION_ID"

MODE="${1:-}"

ALLOWED="$(az resource show -g "$RESOURCE_GROUP" --name scm --namespace Microsoft.Web \
  --resource-type basicPublishingCredentialsPolicies --parent "sites/$APP_NAME" \
  --query properties.allow -o tsv 2>/dev/null || echo false)"
if [[ "$ALLOWED" != "true" ]]; then
  echo "NOTE: enabling SCM basic auth so logs can be read." >&2
  echo "      Disable again with:  ./02-logs.sh --lock" >&2
  az resource update -g "$RESOURCE_GROUP" --name scm --namespace Microsoft.Web \
    --resource-type basicPublishingCredentialsPolicies --parent "sites/$APP_NAME" \
    --set properties.allow=true -o none
fi

if [[ "$MODE" == "--lock" ]]; then
  az resource update -g "$RESOURCE_GROUP" --name scm --namespace Microsoft.Web \
    --resource-type basicPublishingCredentialsPolicies --parent "sites/$APP_NAME" \
    --set properties.allow=false -o none
  echo "SCM basic auth disabled."
  exit 0
fi

read -r U P < <(az webapp deployment list-publishing-profiles \
  -g "$RESOURCE_GROUP" -n "$APP_NAME" \
  --query "[?publishMethod=='MSDeploy'].[userName,userPWD]" -o tsv | head -1)

SCM="https://${APP_NAME}.scm.azurewebsites.net"

# The platform log is <date>_<machine>_docker.log; the app's own stdout is
# <date>_<machine>_default_docker.log. They are easy to confuse.
pick_log() {
  curl -s -m 60 -u "$U:$P" "$SCM/api/logs/docker" | python3 -c "
import sys, json
want_default = $1
d = json.load(sys.stdin)
d = [f for f in d if ('_default_docker.log' in f['href']) == bool(want_default)
     and '_scm_' not in f['href']]
d.sort(key=lambda x: x['lastUpdated'])
print(d[-1]['href'] if d else '')"
}

case "$MODE" in
  -p) HREF="$(pick_log 0)"; FILTER=cat ;;
  -a) HREF="$(pick_log 1)"; FILTER=cat ;;
  *)  HREF="$(pick_log 1)"; FILTER="grep -vE '^[0-9T:.Z-]+ +at |node_modules'" ;;
esac

[[ -n "$HREF" ]] || { echo "No container log yet — the app may not have started."; exit 1; }

if [[ "$MODE" == "-f" ]]; then
  echo "Following $HREF  (Ctrl-C to stop)"
  SEEN=0
  while :; do
    BODY="$(curl -s -m 60 -u "$U:$P" "$HREF" || true)"
    TOTAL="$(printf '%s' "$BODY" | wc -l | tr -d ' ')"
    if (( TOTAL > SEEN )); then
      printf '%s\n' "$BODY" | tail -n +$((SEEN + 1)) | eval "$FILTER"
      SEEN=$TOTAL
    fi
    sleep 5
  done
else
  curl -s -m 60 -u "$U:$P" "$HREF" | eval "$FILTER" | tail -80
fi
