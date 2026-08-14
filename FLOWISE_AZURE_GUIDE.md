# Deploying Flowise on Azure — Setup Guide

How to run a shared Flowise instance on Azure for a class of 10–30 learners, with
**persistent storage** so credentials, chatflows and chat history survive
restarts, redeployments and version upgrades.

Every step here was executed end-to-end on a real Azure subscription
(Southeast Asia, August 2026) against `flowiseai/flowise:3.1.4`. The
troubleshooting section documents four failures that actually occurred and how
each was fixed — all four will hit anyone following the official Flowise Azure
page verbatim.

---

## Contents

1. [What you are building](#1-what-you-are-building)
2. [Why this shape — the three layers of persistence](#2-why-this-shape--the-three-layers-of-persistence)
3. [Before you start](#3-before-you-start)
— [Choose one path](#choose-one-path) · [Where each value comes from](#where-each-value-comes-from)
4. [Deploy it (scripted)](#4-deploy-it-scripted) — **or** [(portal)](#5-deploy-it-azure-portal)
5. [Deploy it (Azure Portal)](#5-deploy-it-azure-portal)
6. [First login](#6-first-login)
7. [Prove the persistence works](#7-prove-the-persistence-works)
8. [Giving learners access](#8-giving-learners-access)
9. [Day-2 operations](#9-day-2-operations)
10. [Troubleshooting](#10-troubleshooting)
11. [Optional hardening](#11-optional-hardening)
12. [Appendix: environment variables](#12-appendix-environment-variables)

---

## 1. What you are building

```
                 https://<your-app>.azurewebsites.net
                               │
                    ┌──────────┴───────────┐
                    │  Azure App Service   │
                    │  Linux container, B2 │
                    │  flowiseai/flowise   │
                    └──────────┬───────────┘
                               │
            ┌──────────────────┴──────────────────┐
            │                                     │
 ┌──────────┴────────────┐         ┌──────────────┴──────────┐
 │ PostgreSQL Flexible   │         │  Azure Files share      │
 │ Server  (B1ms, 32 GB) │         │  mounted /opt/flowise/  │
 ├───────────────────────┤         ├─────────────────────────┤
 │ chatflows/agentflows  │         │ uploaded documents      │
 │ credentials (encrypted)│        │ document-store files    │
 │ chat history+feedback │         │ application logs        │
 │ API keys, variables   │         └─────────────────────────┘
 │ user account          │
 └───────────────────────┘
            +
   FLOWISE_SECRETKEY_OVERWRITE  ← app setting; decrypts the credentials
```

### Estimated monthly cost (Southeast Asia, list price)

| Resource | SKU | ~US$/month |
|---|---|---|
| App Service Plan (Linux) | B2 — 2 vCPU, 3.5 GB | ~34 |
| PostgreSQL Flexible Server | B1ms — 1 vCore, 32 GB | ~19 |
| Storage account + 20 GB file share | Standard LRS | ~1 |
| **Total** | | **~US$54** |

Cheaper and larger variants are in [§9](#9-scaling-and-cost-control).

---

## 2. Why this shape — the three layers of persistence

Most broken Flowise deployments get this wrong, so be explicit about it.
"Persistence" is **three separate problems**. Solve all three or learners lose
work.

### Layer 1 — the database

By default Flowise writes to a **SQLite file inside the container**. App Service
containers are recreated on every restart, redeploy, scale event and platform
patch, and anything on the container filesystem dies with them. Every chatflow a
learner built would be gone the next morning.

`DATABASE_TYPE=postgres` moves it all to PostgreSQL Flexible Server — a separate
resource with its own lifecycle and its own backups. The container becomes
disposable, which is the goal.

> **Why not SQLite on the mounted file share?** The official Flowise Azure doc
> shows exactly that for Azure Container Instances, and it does work for one
> user. But SQLite depends on file locking, and file locking over an SMB network
> share is unreliable. With 10–30 learners writing concurrently you get
> `database is locked` errors and eventually a corrupted file. Use Postgres for
> any shared instance.

### Layer 2 — the file share

Files learners upload into Document Stores go to disk, not the database.
`BLOB_STORAGE_PATH` points that at an **Azure Files share mounted into the
container**, so uploads outlive the container too. Logs go to the same share so
you can read them after a crash.

### Layer 3 — the encryption key (the one everyone forgets)

Flowise encrypts saved credentials — OpenAI keys, Azure OpenAI keys, database
passwords — before writing them to the database. By default the encryption key
is generated into a file **inside the container** on first boot.

Replace that container and a **new key is generated**. The credential rows are
still in Postgres, perfectly intact, and are now permanently undecryptable.
Learners see their credentials listed but every flow fails, and there is no
recovery path.

`FLOWISE_SECRETKEY_OVERWRITE` pins the key to a fixed value held as an App
Setting. Generated once at provisioning time and written to `deploy.env`.

> ⚠️ **Back up `deploy.env`.**
> Lose `FLOWISE_SECRETKEY_OVERWRITE` → every saved credential must be re-entered by hand.
> Lose the Postgres password → you lose everything.
> Put it in a password manager or Azure Key Vault before handing the deployment over.
>
> **One escape hatch:** the encryption key is also stored as an App Setting, so
> it can be read back with `az webapp config appsettings list` for as long as
> the web app exists — see
> [Recovering values later](#recovering-values-later). It is gone for good only
> if you lose the file *and* delete the app.

---

## 3. Before you start

You need:

- An Azure subscription and the **Contributor** role on a resource group.
- **Azure CLI 2.60+**. macOS: `brew install azure-cli`. Windows: `winget install Microsoft.AzureCLI`.
- About 25 minutes, most of it waiting on Azure.

```bash
az login
az account show -o table          # confirm the right subscription
```

If provisioning later fails with `MissingSubscriptionRegistration`:

```bash
az provider register --namespace Microsoft.DBforPostgreSQL --wait
az provider register --namespace Microsoft.Web --wait
az provider register --namespace Microsoft.Storage --wait
```

---

## Choose one path

**Sections 4 and 5 are two routes to the identical result. Do one, not both.**

| | §4 Scripted | §5 Portal |
|---|---|---|
| How | Run six shell scripts | Click through the Azure Portal |
| Needs | Azure CLI + the `deploy/` folder | Just a browser |
| Time | ~12 min, mostly waiting | ~30 min of clicking |
| Best for | Anyone comfortable in a terminal; repeatable for a second cohort | Teams who prefer the GUI, or where CLI access is restricted |

Same resources, same settings, same outcome either way.

> ⚠️ **Do not copy someone else's `deploy.env`.** Hand over `00-` through
> `05-*.sh` only. `deploy.env` holds the Postgres password and credential
> encryption key of whichever instance created it. With no `deploy.env`
> present, `01-provision.sh` generates fresh secrets on first run — copying an
> existing one makes the new deployment inherit another instance's credentials.

### How this relates to the official Flowise docs

The [Flowise Azure page](https://docs.flowiseai.com/configuration/deployment/azure)
offers two options. Neither fits a 10–30 learner class as written.

| Their option | Why not |
|---|---|
| App Service + Postgres, via Terraform | Same architecture as this guide, but specifies a **P3v3** plan (~US$280/mo) and **PostgreSQL 11**, end-of-life since Nov 2023. Also requires installing Terraform |
| Container Instances + SQLite on a file share | The simpler option most people follow. SQLite over SMB breaks down with concurrent learners, and it is the source of the `/opt/flowise/.flowise` mount path App Service rejects |

This guide targets the *same architecture* as their first option — App Service +
Postgres + Azure Files — with current SKUs sized to a class budget, plain `az`
commands or portal clicks instead of Terraform, and the four fixes in
[§10](#10-troubleshooting) that made it actually boot. Their page remains useful
as background on the environment variables.

---

## Where each value comes from

Two files hold configuration. Only one of them you fill in by hand.

| File | Who fills it | Committed? |
|---|---|---|
| `deploy/settings.local.sh` | **you, by hand** — 4 values | no |
| `deploy/deploy.env` | generated by `01-provision.sh` | no |

The Flowise admin login is neither of these — you choose it on the setup screen
at first launch and it lives in PostgreSQL. Keep it in a password manager.

### settings.local.sh — the four values you choose

```bash
cp deploy/settings.local.sh.example deploy/settings.local.sh
```

| Value | Where to get it |
|---|---|
| `SUBSCRIPTION_ID` | `az account list -o table`, or Portal → **Subscriptions**. **Optional** — leave it commented out and the scripts use whichever subscription you are signed in to |
| `RESOURCE_GROUP` | Existing: `az group list -o table`. New: `az group create -n flowise-rg -l southeastasia` |
| `LOCATION` | `az account list-locations --query "[].name" -o tsv`. Pick the region nearest your learners, and use the same one as the resource group |
| `PREFIX` | **You invent this.** 3–11 lowercase letters/digits. It names every resource, so make it recognisable — `acme` gives `acme-plan`, `acmest1a2b3c`, `acme-pg-1a2b3c` |

To find your values in one go:

```bash
az account show --query "{subscription:name, subscriptionId:id}" -o table
az group list --query "[].{name:name, location:location}" -o table
```

> **On `PREFIX`:** App hostnames, storage account names and Postgres server
> names must be globally unique across all of Azure. The scripts append a random
> 6-character suffix, so `acme` becomes `acme-1a2b3c.azurewebsites.net`.
> Collisions are very unlikely, but if provisioning fails on a name conflict,
> delete `deploy.env` and re-run to draw a new suffix.

### deploy.env — generated, not hand-written

`01-provision.sh` creates this on first run and reuses it forever after. You
never author it. It holds:

| Value | How it is produced |
|---|---|
| `SUFFIX` | random 6 hex chars, for global uniqueness |
| `APP_NAME`, `PLAN_NAME`, `PG_SERVER_NAME`, `STORAGE_ACCOUNT` | derived from `PREFIX` + `SUFFIX` |
| `PG_ADMIN_PASSWORD` | random, meeting Azure's rules (8–128 chars, 3 of 4 character classes) |
| `FLOWISE_SECRETKEY_OVERWRITE` | `openssl rand -hex 32` |
| `JWT_AUTH_TOKEN_SECRET`, `JWT_REFRESH_TOKEN_SECRET`, `TOKEN_HASH_SECRET`, `EXPRESS_SESSION_SECRET` | `openssl rand -hex 32` each |

**Only if you are following the Portal path (§5)** do you generate these
yourself, one per secret:

```bash
openssl rand -hex 32                      # macOS / Linux / WSL
```

```powershell
-join ((1..32) | ForEach-Object { '{0:x2}' -f (Get-Random -Max 256) })   # PowerShell
```

### Recovering values later

If you inherit a deployment and have no `deploy.env`:

| Value | How to recover |
|---|---|
| App name / URL | `az webapp list -g <rg> --query "[].{name:name,host:defaultHostName}" -o table` |
| Postgres host | `az postgres flexible-server list -g <rg> --query "[].{name:name,host:fullyQualifiedDomainName}" -o table` |
| Storage account | `az storage account list -g <rg> --query "[].name" -o table` |
| `FLOWISE_SECRETKEY_OVERWRITE` and all JWT secrets | `az webapp config appsettings list -g <rg> -n <app> --query "[?name=='FLOWISE_SECRETKEY_OVERWRITE'].value \| [0]" -o tsv` |
| `PG_ADMIN_PASSWORD` | **Not recoverable.** Reset it: `az postgres flexible-server update -g <rg> -n <server> -p '<new>'`, then update the `DATABASE_PASSWORD` app setting to match |

> **This softens the warning in §2.** App settings are readable by anyone with
> Contributor on the resource group, so the encryption key survives the loss of
> `deploy.env` as long as **the web app still exists**. It is unrecoverable only
> if you lose `deploy.env` *and* delete the app. Back up anyway — but if you
> have just deleted `deploy.env` in a panic, check the app settings first.

---

## 4. Deploy it (scripted)

The `deploy/` folder holds six scripts. Repeatable, and re-running it is safe.
Skip to [§5](#5-deploy-it-azure-portal) if you prefer the portal.

| Script | What it does |
|---|---|
| `00-config.sh` | All tunables; generates secrets into `deploy.env` on first run |
| `01-provision.sh` | Creates the whole stack. Re-runnable |
| `02-logs.sh` | Reads the Flowise container log |
| `03-verify.sh` | Waits for the app, then reports the persistence wiring |
| `04-teardown.sh` | Deletes only what these scripts created |
| `05-backup.sh` | Portable `pg_dump` + file share + encryption key |

### Step 1 — set your targets

Edit the `EDIT ME` block at the top of `deploy/00-config.sh`:

```bash
SUBSCRIPTION_ID="<your subscription id>"
RESOURCE_GROUP="<your resource group>"
LOCATION="southeastasia"
PREFIX="ladpflowise"           # 3-11 chars, a-z0-9; names every resource
APP_SERVICE_SKU="B2"
FLOWISE_IMAGE="docker.io/flowiseai/flowise:3.1.4"
```

**Pin the image tag.** `:latest` means an upstream release can change what your
learners are using in the middle of a course.

### Step 2 — run it

```bash
cd deploy
./01-provision.sh
```

Takes 8–12 minutes; PostgreSQL creation is most of it. It prints the app URL,
the Postgres host, and the path to `deploy.env` when done.

### Step 3 — wait for the container and check the wiring

```bash
./03-verify.sh
```

The first container start pulls a ~1.4 GB image; allow 5–10 minutes. The script
polls until the app answers, then prints the mounted share, the database
settings and whether the encryption key is pinned.

### Putting this in git

The scripts are safe to commit as they stand — `00-config.sh` carries no
subscription, and falls back to whichever subscription `az` is signed in to.
Put your own values in `deploy/settings.local.sh`, which is git-ignored:

```bash
cp deploy/settings.local.sh.example deploy/settings.local.sh
# edit it: RESOURCE_GROUP, LOCATION, PREFIX
```

Three things must never be committed. The included `.gitignore` covers all three:

| Path | Why |
|---|---|
| `deploy/deploy.env` | Postgres password, `FLOWISE_SECRETKEY_OVERWRITE`, JWT and session secrets |
| `deploy/settings.local.sh` | Your subscription id and resource group |
| `deploy/backups/` | Full copies of learner data — and each backup contains a copy of `deploy.env` |

Verify before your first commit:

```bash
git add -A && git status --porcelain --ignored | grep '^!!'
```

Everything in that list is excluded. If `deploy.env` is *not* listed, stop and
fix `.gitignore` before committing.

> **Subscription IDs are not secrets.** A subscription ID is an identifier, not
> a credential — it grants no access without authentication. Keeping it out of
> the repo is tidiness, not a security control. The passwords and keys in
> `deploy.env` are the real risk.

### Step 4 — secure `deploy.env` immediately

```bash
cat deploy/deploy.env      # copy into your password manager, then:
chmod 600 deploy/deploy.env
```

Never commit it. It contains the Postgres admin password and the credential
encryption key.

---

## 5. Deploy it (Azure Portal)

**The alternative to §4 — do this *or* that, not both.** Create all resources in
**one region** and **one resource group**.

### 5.1 Storage account and file share

1. **Create a resource → Storage account.**
2. Performance **Standard**, Redundancy **LRS**, minimum TLS **1.2**, disable blob public access.
3. After creation → **Data storage → File shares → + File share**.
4. Name `flowise-data`, quota 20 GB, tier **Transaction optimized**.

### 5.2 PostgreSQL Flexible Server

1. **Create a resource → Azure Database for PostgreSQL → Flexible server.**
2. Version **16**, Workload **Development**, Compute **Burstable B1ms**, Storage **32 GB**.
3. Authentication **PostgreSQL authentication only**. Record the admin username and password.
4. Networking → **Public access**, tick **Allow public access from any Azure service within Azure**.
5. After creation → **Settings → Databases → + Add** → name `flowise`.
6. **Settings → Server parameters** → search `azure.extensions` → tick **UUID-OSSP** → **Save**.

   > Step 6 is not optional and is not in the Flowise docs. Skip it and the
   > container crash-loops on `function uuid_generate_v4() does not exist`.

### 5.3 App Service

1. **Create a resource → Web App.**
2. Publish **Container**, OS **Linux**, Region same as above.
3. Plan → **Create new** → Pricing plan **B2**.
4. **Container** tab → Image Source **Other container registries**, Access **Public**,
   Registry server URL `https://index.docker.io`, Image and tag `flowiseai/flowise:3.1.4`.
5. Create.

### 5.4 Mount the file share

App Service → **Settings → Configuration → Path mappings → + New Azure Storage Mount**:

| Field | Value |
|---|---|
| Name | `flowisedata` |
| Configuration options | Basic |
| Storage account | your storage account |
| Storage type | Azure Files |
| Storage container | `flowise-data` |
| Mount path | `/opt/flowise/data` |

> **Mount path must not contain a dot-prefixed folder.** The Flowise docs use
> `/opt/flowise/.flowise`; App Service rejects it with a bare `Bad Request` and
> no explanation. Use `/opt/flowise/data`.

### 5.5 Application settings

App Service → **Settings → Environment variables → App settings**. Add each of
these ([full reference in §12](#12-appendix-environment-variables)):

| Name | Value |
|---|---|
| `WEBSITES_PORT` | `3000` |
| `PORT` | `3000` |
| `WEBSITES_CONTAINER_START_TIME_LIMIT` | `1800` |
| `DATABASE_TYPE` | `postgres` |
| `DATABASE_HOST` | `<server>.postgres.database.azure.com` |
| `DATABASE_PORT` | `5432` |
| `DATABASE_NAME` | `flowise` |
| `DATABASE_USER` | your PG admin user |
| `DATABASE_PASSWORD` | your PG admin password |
| `DATABASE_SSL` | `true` |
| `FLOWISE_SECRETKEY_OVERWRITE` | a fresh 64-char hex string — **generate once, never change** |
| `APIKEY_STORAGE_TYPE` | `db` |
| `BLOB_STORAGE_PATH` | `/opt/flowise/data/storage` |
| `LOG_PATH` | `/opt/flowise/data/logs` |
| `JWT_AUTH_TOKEN_SECRET` | fresh 64-char hex |
| `JWT_REFRESH_TOKEN_SECRET` | fresh 64-char hex |
| `TOKEN_HASH_SECRET` | fresh 64-char hex |
| `EXPRESS_SESSION_SECRET` | fresh 64-char hex |

Generate the secrets with `openssl rand -hex 32` (or `[guid]::NewGuid()` twice on
Windows). **Record all five in your password manager.**

### 5.6 Turn on Always On

**Settings → Configuration → General settings → Always On = On**, then **Save**
and **Restart**.

---

## 6. First login

Browse to `https://<your-app>.azurewebsites.net`. First visit redirects to
`/organization-setup`:

- **Administrator Name** — display only
- **Administrator Email** — this becomes the login ID
- **Password** — min 8 chars, with an uppercase, a lowercase, a digit and a special character

This account is created **in PostgreSQL**, so it survives restarts. There is no
default password and no way to recover this one without SMTP configured — record
it.

> **The open-source edition has exactly one account.** There is no user
> management, no invitations, and no per-learner workspaces — the account menu
> offers only Export, Import, Version, Account Settings and Logout. The
> `organization` and `workspace` tables exist in the schema but the UI does not
> expose them; that is Flowise Enterprise. Plan your class around one shared
> login — see [§8](#8-giving-learners-access).

---

## 7. Prove the persistence works

Do not assume it works. These are the checks that were actually run.

### 7.1 Is the schema in Postgres?

```bash
psql "host=<server>.postgres.database.azure.com port=5432 dbname=flowise \
      user=<admin> sslmode=require" \
  -c "select table_name from information_schema.tables where table_schema='public' order by 1;"
```

You should see ~30 tables including `chat_flow`, `credential`, `chat_message`,
`user`, `apikey`, `document_store`. If you see none, Flowise never completed
migrations — check the logs.

### 7.2 Is the container really writing to the file share?

Flowise writes its logs to the mounted path, so the share proves the mount works
from *inside* the container:

```bash
az storage file list --account-name <storage> --account-key <key> -s flowise-data -o table
```

Expect `logs` and `storage` directories. If the share is empty, the mount is not
active.

### 7.3 The one that matters — do credentials survive a new container?

1. In Flowise, **Credentials → Add Credential**. Save any credential.
2. Restart the app: `az webapp restart -g <rg> -n <app>`. This destroys the
   container and starts a fresh one from the image.
3. Wait for the app, then open **Credentials** and click the pencil icon.

**Pass:** the fields are populated. The new container decrypted data written by
the old one, so `FLOWISE_SECRETKEY_OVERWRITE` is doing its job.

**Fail:** fields are blank or you get a decryption error. The key is not pinned.
Fix the app setting before letting anyone save real credentials.

You should also still be logged in after the restart — that confirms the JWT
secrets are pinned too. If every restart logs everyone out, `JWT_AUTH_TOKEN_SECRET`
is missing and Flowise is generating a throwaway one each boot.

---

## 8. Giving learners access

One instance, one login, 10–30 people. The practical consequences:

**Everyone shares one workspace.** All learners see every chatflow and every
saved credential. A learner's personal OpenAI key is visible to the whole
cohort. Tell them this up front.

**Recommended setup for a class:**

- **You** create the credentials centrally — one shared Azure OpenAI or OpenAI
  key that you own and can rotate — rather than having 30 learners paste personal
  keys into a shared instance.
- **Naming convention** so work doesn't collide: ask learners to prefix
  everything with their initials, e.g. `JT — RAG chatbot`.
- **Export/Import is how learners keep their own work.** The account menu
  (top-right gear) has **Export** and **Import**. Each learner exports their
  chatflows to a JSON file at the end of a session and can re-import into any
  Flowise — including their own local install after the course. This is the
  answer to "how do I take my work home", and it is worth demonstrating in
  session one.
- **Restrict who can reach the URL.** The default `*.azurewebsites.net` address
  is public — anyone with the link hits the login page. See
  [§11](#11-optional-hardening).

**If learners genuinely need isolation**, the options are:

| Option | Cost | Notes |
|---|---|---|
| One App Service per learner, shared plan | plan cost only, until CPU/RAM runs out | Each needs its own database and its own `FLOWISE_SECRETKEY_OVERWRITE` |
| One full stack per learner | ~US$54 × N | Clean but expensive |
| Flowise Enterprise | licence fee | Real workspaces, SSO, RBAC. Contact FlowiseAI |

---

## 9. Day-2 operations

### Reading logs

`az webapp log tail` needs **SCM basic authentication**, which many
organisations disable by policy — and in that state it prints **nothing at all**
rather than an error. `02-logs.sh` handles this: it enables the SCM credential
if needed, reads the log over the Kudu API, and `./02-logs.sh --lock` disables it
again.

```bash
./02-logs.sh          # last 80 lines of the app log, stack noise stripped
./02-logs.sh -f       # follow
./02-logs.sh -p       # Azure platform log: container pull/start/stop
./02-logs.sh --lock   # re-disable SCM basic auth
```

Two different logs are easy to confuse:
`..._default_docker.log` is **Flowise's own stdout** — errors live here.
`..._docker.log` is the **platform** log — image pulls, container exits, probes.

### Backups

PostgreSQL Flexible Server already takes automatic daily backups with 7-day
point-in-time restore — that covers "a learner deleted a flow". For a portable
copy you can restore into a different subscription:

```bash
./05-backup.sh          # pg_dump + file share + deploy.env, timestamped
```

Run it before every upgrade and at the end of each course. It writes a
`RESTORE.md` next to the dump with the exact restore commands.

### Upgrading Flowise

```bash
# 1. Back up first
./05-backup.sh

# 2. Bump FLOWISE_IMAGE in 00-config.sh, then:
az webapp config container set -g <rg> -n <app> \
  --container-image-name docker.io/flowiseai/flowise:<new-tag>
az webapp restart -g <rg> -n <app>

# 3. Watch the migrations run
./02-logs.sh -f
```

Flowise runs schema migrations automatically on boot. Watch for
`Database migrations completed successfully`. **Never upgrade mid-class.**

### Scaling and cost control

| Situation | Change |
|---|---|
| Sluggish with 20+ concurrent learners | Plan → **B3** or **P0v3** |
| Container OOM-kills during big document ingests | Plan → more RAM (B3/P1v3) |
| Course is over, keep the data | Stop the web app; keep Postgres + storage (~US$20/mo) |
| Course is over, keep nothing | `./04-teardown.sh` |
| Evenings/weekends idle | Stop the web app on a schedule; Postgres can be stopped up to 7 days |

**Do not scale out to multiple instances.** Flowise is not designed for it —
run one instance and scale up instead.

### Monitoring

Worth setting once:

- App Service → **Diagnose and solve problems → Application Logs** for crash loops.
- An **alert rule** on HTTP 5xx > 10 in 5 minutes.
- A **budget alert** on the resource group at your expected monthly spend.

---

## 10. Troubleshooting

These four all occurred during the reference deployment. Every one hits anyone
following the official Flowise Azure page.

### `The --database-name argument can only be used when --node-count is present`

Azure CLI 2.89 removed `--database-name` from `postgres flexible-server create`
(it is now elastic-cluster only). Create the server first, then the database:

```bash
az postgres flexible-server db create -g <rg> -s <server> -n flowise
```

### `database "flowise" does not exist` and the container exits with code 1

The database was never created. Note the flags: for `db create`, **`-s` is the
server and `-n` is the database**. Using `-d` fails, and older guides show `-d`.

```bash
az postgres flexible-server db list -g <rg> -s <server> -o table   # confirm
```

The same trap applies to `firewall-rule create`: `-s` is the server, `-n` is the
rule name.

### `Operation returned an invalid status 'Bad Request'` when adding the storage mount

The mount path contains a **dot-prefixed directory**. App Service rejects
`/opt/flowise/.flowise` — the exact path the Flowise docs use — with no
explanation. `/opt/flowise/data` works. Verified: `/opt/flowise/dotflowise`
succeeds, `/opt/flowise/.flowise` fails.

### `function uuid_generate_v4() does not exist`

Flowise's first migration needs the `uuid-ossp` extension, and **Azure Postgres
refuses to load any extension not on the server allow-list**:

```bash
az postgres flexible-server parameter set -g <rg> -s <server> \
  -n azure.extensions -v UUID-OSSP
az webapp restart -g <rg> -n <app>
```

Flowise's migration then creates the extension itself. Symptom is a crash-loop;
App Service eventually throttles restarts with *"Site is blocked due to
multiple, consecutive cold start failures"*.

### Other symptoms

| Symptom | Cause and fix |
|---|---|
| Page hangs, no HTTP response, TCP connects | Container not listening yet. First pull is ~1.4 GB — allow 10 min. Then check the app log |
| `az webapp log tail` prints nothing at all | SCM basic auth disabled by policy. Use `./02-logs.sh` |
| Everyone logged out after every restart | `JWT_AUTH_TOKEN_SECRET` / `JWT_REFRESH_TOKEN_SECRET` not set |
| Credentials listed but fail to decrypt | `FLOWISE_SECRETKEY_OVERWRITE` missing or changed. If the original value is lost, delete and re-enter the credentials |
| Uploaded documents vanish on restart | `BLOB_STORAGE_PATH` not pointing inside the mounted share, or the mount is inactive |
| `Cannot find module '@smithy/eventstream-codec'` in the log | Harmless. An optional AWS Bedrock dependency; Flowise starts normally |
| Container start times out | Raise `WEBSITES_CONTAINER_START_TIME_LIMIT` (seconds; 1800 is generous) |

---

## 11. Optional hardening

Worth doing before a real cohort uses this.

### Restrict who can reach the app

The instance is on the public internet behind a single shared password. Either:

**Entra ID (recommended for a company.)** App Service → **Settings →
Authentication → Add identity provider → Microsoft**. Restrict to your tenant.
Staff then sign in with their work account before Flowise's own login appears.
Note this does **not** create per-learner workspaces — it only controls who can
reach the URL.

**IP restrictions.** App Service → **Networking → Access restrictions**. Allow
only the office/training-room ranges. Simple, and appropriate if the class is
on-site.

### Lock down PostgreSQL

Provisioning allows "all Azure services" (`0.0.0.0`), which is broad. Tighter
options, in increasing order of effort: restrict to the App Service outbound IPs
(`az webapp show --query outboundIpAddresses`), or move both onto a VNet with a
private endpoint and turn public access off entirely.

Also remove any temporary admin firewall rules when you are done:

```bash
az postgres flexible-server firewall-rule list -g <rg> -s <server> -o table
az postgres flexible-server firewall-rule delete -g <rg> -s <server> -n <rule>
```

### Move secrets to Key Vault

Replace the plaintext app settings with Key Vault references so the values never
appear in the portal or in `az` output:

```
@Microsoft.KeyVault(SecretUri=https://<vault>.vault.azure.net/secrets/<name>/)
```

Requires a managed identity on the web app with **Key Vault Secrets User**.

### Custom domain

App Service → **Custom domains → Add**. A managed certificate is free. Gives
learners `flowise.yourcompany.com` instead of the `azurewebsites.net` address.

---

## 12. Appendix: environment variables

Settings used by this deployment. Full list at
<https://docs.flowiseai.com/configuration/environment-variables>.

### Required for persistence

| Variable | Value | Why |
|---|---|---|
| `DATABASE_TYPE` | `postgres` | Without it, SQLite inside the container — data lost on restart |
| `DATABASE_HOST` | `<server>.postgres.database.azure.com` | |
| `DATABASE_PORT` | `5432` | |
| `DATABASE_NAME` | `flowise` | Must exist before first boot |
| `DATABASE_USER` / `DATABASE_PASSWORD` | admin credentials | |
| `DATABASE_SSL` | `true` | Azure enforces TLS. Verifies against Node's bundled roots — no custom CA needed |
| `FLOWISE_SECRETKEY_OVERWRITE` | 64-char hex | **Pins credential encryption. Never change it** |
| `BLOB_STORAGE_PATH` | `/opt/flowise/data/storage` | Uploaded documents, on the mounted share |
| `LOG_PATH` | `/opt/flowise/data/logs` | Logs survive a crashed container |
| `APIKEY_STORAGE_TYPE` | `db` | Keeps Flowise API keys in Postgres, not a container file |

### Required for App Service

| Variable | Value | Why |
|---|---|---|
| `WEBSITES_PORT` | `3000` | Tells App Service which port the container listens on |
| `PORT` | `3000` | What Flowise binds to |
| `WEBSITES_CONTAINER_START_TIME_LIMIT` | `1800` | Default is too short for a 1.4 GB image |

### Session and auth

| Variable | Value | Why |
|---|---|---|
| `JWT_AUTH_TOKEN_SECRET` | 64-char hex | Otherwise regenerated each boot → everyone logged out |
| `JWT_REFRESH_TOKEN_SECRET` | 64-char hex | As above |
| `JWT_TOKEN_EXPIRY_IN_MINUTES` | `360` | 6 hours suits a training day |
| `JWT_REFRESH_TOKEN_EXPIRY_IN_MINUTES` | `129600` | 90 days |
| `TOKEN_HASH_SECRET` | 64-char hex | Hashes sensitive tokens |
| `EXPRESS_SESSION_SECRET` | 64-char hex | Session signing |
| `PASSWORD_SALT_HASH_ROUNDS` | `10` | bcrypt cost |

### Useful extras

| Variable | Value | Why |
|---|---|---|
| `FLOWISE_FILE_SIZE_LIMIT` | `50mb` | Raise if learners upload large PDFs |
| `LOG_LEVEL` | `info` | `debug` when troubleshooting |
| `CORS_ORIGINS` | domain list | Only if embedding chatbots in another site |
| `DISABLE_FLOWISE_TELEMETRY` | `true` | Stops usage telemetry to FlowiseAI |

### Deliberately not used

| Variable | Why not |
|---|---|
| `DATABASE_PATH` | SQLite only; irrelevant with Postgres |
| `SECRETKEY_PATH` | Superseded by `FLOWISE_SECRETKEY_OVERWRITE` |
| `FLOWISE_USERNAME` / `FLOWISE_PASSWORD` | Deprecated. Replaced by the account system in 3.x |
| `STORAGE_TYPE=s3` / `gcs` | Azure Files mount is simpler here. Flowise has no native Azure Blob driver |

---

## Reference deployment

Built and verified 14 August 2026, Southeast Asia:

| | |
|---|---|
| Image | `flowiseai/flowise:3.1.4` (reports version 3.1.2) |
| App Service | B2 Linux container, Always On, HTTPS-only |
| PostgreSQL | Flexible Server 16, B1ms, 32 GB, `uuid-ossp` allow-listed |
| Storage | Standard LRS, 20 GB share at `/opt/flowise/data` |

Verified: 30 tables created in Postgres; container writing `logs/` and
`storage/` to the file share; a saved Azure OpenAI credential decrypted
correctly by a **replacement container**; session survived the restart.
