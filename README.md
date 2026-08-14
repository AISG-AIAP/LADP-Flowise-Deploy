# Flowise on Azure

Scripts and a step-by-step guide for running a **shared Flowise instance on
Azure** for a class of 10–30 learners, with persistent storage so credentials,
chatflows and chat history survive restarts, redeployments and version upgrades.

Built and verified end-to-end against `flowiseai/flowise:3.1.4` on Azure App
Service, August 2026.

**→ [Full guide](FLOWISE_AZURE_GUIDE.md)** — architecture, an Azure Portal
walkthrough, operations and troubleshooting. This README is the fast path.

---

## What it builds

| Component | Purpose | SKU | ~US$/mo |
|---|---|---|---|
| App Service (Linux container) | runs Flowise | B2 — 2 vCPU, 3.5 GB | ~34 |
| PostgreSQL Flexible Server | flows, credentials, chat history | B1ms, 32 GB | ~19 |
| Storage account + file share | uploaded documents, logs | Standard LRS, 20 GB | ~1 |
| | | **Total** | **~54** |

Southeast Asia list prices. Excludes LLM token costs.

---

## Prerequisites

- An **Azure subscription** and the **Contributor** role on a resource group.
- **Azure CLI 2.60 or later**:
  - macOS — `brew install azure-cli`
  - Windows — `winget install Microsoft.AzureCLI`
  - Linux — [install docs](https://learn.microsoft.com/cli/azure/install-azure-cli-linux)
- **Bash.** On Windows use WSL or Git Bash; the scripts are bash, not PowerShell.
  If you would rather not use a shell at all, follow
  [§5 of the guide](FLOWISE_AZURE_GUIDE.md#5-deploy-it-azure-portal) instead — it
  is a full Portal walkthrough producing the same result.

Check your version:

```bash
az version
```

---

## Step 1 — sign in and find your values

```bash
az login
```

You need four values. Only the resource group and prefix really require a
decision.

| Value | How to get it | Required? |
|---|---|---|
| `SUBSCRIPTION_ID` | `az account list -o table` | **No** — leave it commented out and the scripts use whichever subscription you are signed in to |
| `RESOURCE_GROUP` | `az group list -o table` for an existing one, or create one (below) | Yes |
| `LOCATION` | `az account list-locations --query "[].name" -o tsv` — pick the region nearest your learners | Yes |
| `PREFIX` | **You invent it.** 3–11 lowercase letters/digits | Yes |

Show your current subscription and resource groups:

```bash
az account show --query "{subscription:name, subscriptionId:id}" -o table
az group list --query "[].{name:name, location:location}" -o table
```

Create a resource group if you need one:

```bash
az group create -n flowise-rg -l southeastasia
```

**About `PREFIX`:** it names every resource, so make it recognisable. `acme`
produces `acme-plan`, `acme-pg-1a2b3c`, `acmest1a2b3c` and the hostname
`acme-1a2b3c.azurewebsites.net`. App hostnames, storage account names and
Postgres server names must be globally unique across all of Azure, so the
scripts append a random 6-character suffix for you.

If your subscription has never used these services, register the providers once:

```bash
az provider register --namespace Microsoft.Web --wait
az provider register --namespace Microsoft.DBforPostgreSQL --wait
az provider register --namespace Microsoft.Storage --wait
```

---

## Step 2 — configure

```bash
git clone https://github.com/AISG-AIAP/LADP-Flowise-Deploy.git
cd LADP-Flowise-Deploy/deploy

cp settings.local.sh.example settings.local.sh
```

Edit `settings.local.sh` with your values from Step 1:

```bash
# SUBSCRIPTION_ID="00000000-0000-0000-0000-000000000000"   # optional
RESOURCE_GROUP="flowise-rg"
LOCATION="southeastasia"
PREFIX="acme"
```

`settings.local.sh` is git-ignored, so your values never reach the repo.

To change the App Service size or pin a different Flowise version, edit the
`EDIT ME` block in `00-config.sh`. Keep the image tag pinned — `:latest` means
an upstream release can change what learners are using mid-course.

---

## Step 3 — provision

```bash
./01-provision.sh
```

Takes 8–12 minutes; PostgreSQL creation is most of it. Safe to re-run — every
step is create-if-missing. It prints your app URL, the Postgres host, and the
path to the generated `deploy.env` when it finishes.

---

## Step 4 — wait for the container, then verify

```bash
./03-verify.sh
```

The first container start pulls a ~1.4 GB image, so allow 5–10 minutes. The
script polls until the app answers, then confirms the file share is mounted, the
database settings are live, the encryption key is pinned, and the Flowise tables
exist in PostgreSQL.

If it times out, read the logs:

```bash
./02-logs.sh
```

---

## Step 5 — create the admin account

Open the URL printed in Step 3. The first visit redirects to
`/organization-setup`:

- **Administrator Name** — display only
- **Administrator Email** — becomes the login ID
- **Password** — minimum 8 characters with an uppercase, a lowercase, a digit
  and a special character

The account is stored in PostgreSQL, so it survives restarts. There is no
default password and **no recovery without SMTP configured** — record it in a
password manager.

---

## Step 6 — back up the secrets

Do this before anyone saves a real credential.

```bash
cat deploy.env      # copy into your password manager or Azure Key Vault
```

`deploy.env` is generated on first run and git-ignored. It holds the Postgres
admin password and `FLOWISE_SECRETKEY_OVERWRITE`, the key that decrypts every
credential learners save.

Lose that key and the credential rows remain in the database but become
permanently undecryptable — learners see their credentials listed while every
flow fails. There is one escape hatch: the key is also stored as an App Setting,
so it can be read back for as long as the web app exists:

```bash
az webapp config appsettings list -g <rg> -n <app> \
  --query "[?name=='FLOWISE_SECRETKEY_OVERWRITE'].value | [0]" -o tsv
```

It is gone for good only if you lose `deploy.env` **and** delete the app.

---

## Everyday commands

Run these from the `deploy/` directory.

| Command | |
|---|---|
| `./02-logs.sh` | Last 80 lines of the Flowise log, stack noise stripped |
| `./02-logs.sh -f` | Follow the log |
| `./02-logs.sh -p` | Azure platform log — container pull, start, stop, probes |
| `./03-verify.sh` | Re-check that persistence is wired up |
| `./05-backup.sh` | Portable `pg_dump` + file share + encryption key, timestamped |
| `./04-teardown.sh` | Delete everything these scripts created. Asks you to type the app name |

Upgrade Flowise:

```bash
./05-backup.sh                                    # always back up first
az webapp config container set -g <rg> -n <app> \
  --container-image-name docker.io/flowiseai/flowise:<new-tag>
az webapp restart -g <rg> -n <app>
./02-logs.sh -f                                   # watch migrations run
```

Watch for `Database migrations completed successfully`. **Never upgrade
mid-class.**

---

## Read this before you go live

**Open-source Flowise has exactly one account.** No user management, no
invitations, no per-learner workspaces. Every learner shares one login and sees
everyone else's flows and saved credentials — including API keys. Create the
credentials centrally with a key you own and can rotate, rather than having
learners paste personal keys into a shared instance. Learners keep their own work
using **Export/Import** in the account menu.
[§8 of the guide](FLOWISE_AZURE_GUIDE.md#8-giving-learners-access) covers this.

**The default URL is public.** Anyone with the link reaches the login page.
[§11](FLOWISE_AZURE_GUIDE.md#11-optional-hardening) covers gating it behind
Entra ID or IP restrictions, plus locking down PostgreSQL and moving secrets to
Key Vault.

**Do not scale out to multiple instances.** Flowise is not designed for it. Run
one instance and scale the plan up if it struggles.

---

## What's in here

| Path | |
|---|---|
| [`FLOWISE_AZURE_GUIDE.md`](FLOWISE_AZURE_GUIDE.md) | The full guide |
| `deploy/00-config.sh` | All tunables; generates secrets into `deploy.env` on first run |
| `deploy/01-provision.sh` | Creates the whole stack. Safe to re-run |
| `deploy/02-logs.sh` | Reads the Flowise container log |
| `deploy/03-verify.sh` | Confirms the persistence wiring is live |
| `deploy/04-teardown.sh` | Deletes only what these scripts created |
| `deploy/05-backup.sh` | Portable `pg_dump` + file share + encryption key |
| `deploy/settings.local.sh.example` | Template to copy to `settings.local.sh` |

Never commit these — the included `.gitignore` covers all three:

| Path | Why |
|---|---|
| `deploy/deploy.env` | Postgres password, encryption key, JWT and session secrets |
| `deploy/settings.local.sh` | Your subscription id and resource group |
| `deploy/backups/` | Full copies of learner data; each backup also contains `deploy.env` |

Check before your first commit — everything listed is excluded:

```bash
git status --porcelain --ignored | grep '^!!'
```

---

## Why not just follow the official Flowise docs?

The [Flowise Azure page](https://docs.flowiseai.com/configuration/deployment/azure)
offers two options, and neither suits a shared class as written. Its Terraform
option specifies a P3v3 plan (~US$280/mo) on PostgreSQL 11, end-of-life since
November 2023. Its Container Instances option puts SQLite on an SMB file share,
which breaks down once 10–30 learners write concurrently.

This repo targets the same architecture as the first option — App Service +
Postgres + Azure Files — with current SKUs, plain `az` commands, and fixes for
four failures that block a first-time deployment:

- `--database-name` was removed from `az postgres flexible-server create` in CLI 2.89
- `db create` takes `-n` for the database, not `-d`
- App Service rejects mount paths containing a dot-prefixed directory, so the
  documented `/opt/flowise/.flowise` fails with a bare `Bad Request`
- `uuid-ossp` must be allow-listed via the `azure.extensions` server parameter,
  or migrations crash-loop on `function uuid_generate_v4() does not exist`

All four, with fixes, are in
[§10 Troubleshooting](FLOWISE_AZURE_GUIDE.md#10-troubleshooting).
