#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# Flowise on Azure — shared configuration
#
# Sourced by every other script. Edit the values in the "EDIT ME" block, then
# run ./01-provision.sh.
#
# On first run this file generates secrets and writes them to deploy.env in
# this same folder. deploy.env is the source of truth afterwards — KEEP IT
# SAFE and do not commit it. Losing FLOWISE_SECRETKEY_OVERWRITE makes every
# saved Flowise credential permanently undecryptable.
# ---------------------------------------------------------------------------
set -euo pipefail

# ============================== EDIT ME ====================================
# Nothing here identifies a particular tenant, so this file is safe to commit.
# Supply your own values in ONE of three ways (later wins):
#   1. edit the defaults below
#   2. create deploy/settings.local.sh  (git-ignored) — recommended
#   3. export environment variables:  AZ_RESOURCE_GROUP=... ./01-provision.sh
#
# Left empty, SUBSCRIPTION_ID falls back to whichever subscription the Azure
# CLI is currently signed in to.
SUBSCRIPTION_ID="${AZ_SUBSCRIPTION_ID:-}"
RESOURCE_GROUP="${AZ_RESOURCE_GROUP:-flowise-rg}"
LOCATION="${AZ_LOCATION:-southeastasia}"

# Short lowercase prefix used to name every resource. 3-11 chars, a-z0-9.
PREFIX="${AZ_PREFIX:-flowise}"

# App Service plan size. B2 = 2 vCPU / 3.5 GB, good for 10-30 learners.
# B1 (1 vCPU / 1.75 GB) is cheaper but Flowise gets tight under load.
# P0v3/P1v3 if you need more headroom or zone redundancy.
APP_SERVICE_SKU="B2"

# Flowise image. Pin a version rather than :latest so an upstream release
# never silently changes what your learners are using mid-course.
FLOWISE_IMAGE="docker.io/flowiseai/flowise:3.1.4"

# PostgreSQL sizing
PG_SKU="Standard_B1ms"       # 1 vCore burstable
PG_TIER="Burstable"
PG_STORAGE_GB="32"
PG_VERSION="16"
PG_ADMIN_USER="flowiseadmin"

# Azure Files share for uploaded documents + logs
FILE_SHARE_NAME="flowise-data"
FILE_SHARE_QUOTA_GB="20"

# Where the share is mounted inside the container. Must NOT contain a
# dot-prefixed directory: App Service rejects paths like /opt/flowise/.flowise
# with an unexplained "Bad Request".
MOUNT_PATH="/opt/flowise/data"
# ============================ END EDIT ME ==================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="$SCRIPT_DIR/deploy.env"

# Your own subscription / resource group / prefix live here, out of git.
# See settings.local.sh.example.
if [[ -f "$SCRIPT_DIR/settings.local.sh" ]]; then
  # shellcheck disable=SC1091
  source "$SCRIPT_DIR/settings.local.sh"
fi

# Fall back to whatever `az` is signed in to.
if [[ -z "$SUBSCRIPTION_ID" ]]; then
  SUBSCRIPTION_ID="$(az account show --query id -o tsv 2>/dev/null || true)"
  if [[ -z "$SUBSCRIPTION_ID" ]]; then
    echo "No subscription. Run 'az login', or set AZ_SUBSCRIPTION_ID." >&2
    exit 1
  fi
  echo "Using signed-in subscription $SUBSCRIPTION_ID"
fi

# --- Derived / generated values -------------------------------------------
if [[ -f "$ENV_FILE" ]]; then
  # shellcheck disable=SC1090
  source "$ENV_FILE"
  echo "Loaded existing settings from $ENV_FILE"
else
  SUFFIX="$(openssl rand -hex 3)"

  APP_NAME="${PREFIX}-${SUFFIX}"                 # web app + default hostname
  PLAN_NAME="${PREFIX}-plan"
  PG_SERVER_NAME="${PREFIX}-pg-${SUFFIX}"
  PG_DB_NAME="flowise"
  STORAGE_ACCOUNT="${PREFIX}st${SUFFIX}"         # must be <=24 chars, a-z0-9

  # Secrets. Generated once, then reused forever from deploy.env.
  PG_ADMIN_PASSWORD="$(openssl rand -base64 24 | tr -d '/+=' | cut -c1-24)Aa1!"
  FLOWISE_SECRETKEY_OVERWRITE="$(openssl rand -hex 32)"
  JWT_AUTH_TOKEN_SECRET="$(openssl rand -hex 32)"
  JWT_REFRESH_TOKEN_SECRET="$(openssl rand -hex 32)"
  TOKEN_HASH_SECRET="$(openssl rand -hex 32)"
  EXPRESS_SESSION_SECRET="$(openssl rand -hex 32)"

  cat > "$ENV_FILE" <<EOF
# Generated $(date -u +%Y-%m-%dT%H:%M:%SZ) — DO NOT COMMIT. Back this up.
SUFFIX="$SUFFIX"
APP_NAME="$APP_NAME"
PLAN_NAME="$PLAN_NAME"
PG_SERVER_NAME="$PG_SERVER_NAME"
PG_DB_NAME="$PG_DB_NAME"
STORAGE_ACCOUNT="$STORAGE_ACCOUNT"
PG_ADMIN_PASSWORD='$PG_ADMIN_PASSWORD'
FLOWISE_SECRETKEY_OVERWRITE="$FLOWISE_SECRETKEY_OVERWRITE"
JWT_AUTH_TOKEN_SECRET="$JWT_AUTH_TOKEN_SECRET"
JWT_REFRESH_TOKEN_SECRET="$JWT_REFRESH_TOKEN_SECRET"
TOKEN_HASH_SECRET="$TOKEN_HASH_SECRET"
EXPRESS_SESSION_SECRET="$EXPRESS_SESSION_SECRET"
EOF
  chmod 600 "$ENV_FILE"
  echo "Generated new settings -> $ENV_FILE  (back this file up!)"
fi

export SUBSCRIPTION_ID RESOURCE_GROUP LOCATION PREFIX APP_SERVICE_SKU \
       FLOWISE_IMAGE PG_SKU PG_TIER PG_STORAGE_GB PG_VERSION PG_ADMIN_USER \
       FILE_SHARE_NAME FILE_SHARE_QUOTA_GB MOUNT_PATH SUFFIX APP_NAME PLAN_NAME \
       PG_SERVER_NAME PG_DB_NAME STORAGE_ACCOUNT PG_ADMIN_PASSWORD \
       FLOWISE_SECRETKEY_OVERWRITE JWT_AUTH_TOKEN_SECRET \
       JWT_REFRESH_TOKEN_SECRET TOKEN_HASH_SECRET EXPRESS_SESSION_SECRET
