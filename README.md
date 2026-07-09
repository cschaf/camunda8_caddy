# Camunda 8 Self-Managed - Docker Compose

## Prerequisites

- [Docker Engine](https://docs.docker.com/engine/install/) 24.0+ and [Docker Compose](https://docs.docker.com/compose/install/) ( Compose V2 plugin `docker compose`)
- [Git](https://git-scm.com/downloads) — to clone this repository
- **Linux/macOS:** Bash + `openssl` (for `generate-secrets.sh`)
- **Windows:** PowerShell 7+ (for `.ps1` scripts)
- `bash` available in your PATH (Linux/macOS, or Git Bash on Windows) — needed to run the `*.sh` scripts in `scripts/` (e.g. `generate-secrets.sh`, `start.sh`). The `bash` used inside the Camunda container images (e.g. for the orchestration healthcheck) is shipped with the image and is not a host requirement.

> **RAM:** This stack reserves ~16 GB and limits at ~27 GB. The host machine needs at least **32 GB RAM** for stable operation.

## Usage

For end user usage, please check the official documentation of [Camunda 8 Self-Managed Docker Compose](https://docs.camunda.io/docs/next/self-managed/quickstart/developer-quickstart/docker-compose/).

## Documentation

- [`docs/operations-handover-template.md`](docs/operations-handover-template.md) - **Operations & handover manual template (German content).** Self-contained, fill-in template for running the stack at a customer site: per-installation facts, server environments (PROD/DEV/SANDBOX) with connection paths, roles/contacts, a customer & infra-admin part (what's installed, access, what to monitor, security, backup essentials) and an operator part with runbooks and a symptom→action incident playbook. Designed to be delivered on its own, without the other reference docs.
- [`docs/project_configuration.md`](docs/project_configuration.md) - Full configuration reference for this stack, including service settings, resource sizing, reverse proxy behavior, `autoheal`, the host recovery guard, and a decision guide for PostgreSQL vs Elasticsearch as Camunda core data backend.
- [`docs/stage_comparison.md`](docs/stage_comparison.md) - Side-by-side comparison of the `prod`, `dev`, and `test` stage resource profiles.
- [`docs/agentic-ai.md`](docs/agentic-ai.md) - Camunda 8.9 Agentic AI setup for AI Agent connectors, MCP clients, LLM provider secrets, proxy/truststore notes, and safety guardrails.
- [`docs/backup-restore.md`](docs/backup-restore.md) - Backup, restore, and disaster-recovery drills. Covers the three scripts (`backup.sh`, `restore.sh`, `restore-drill.sh`), the cold-backup model, granular and cross-cluster restore, and the isolated drill stack used to verify backups end-to-end without touching live data.
- [`docs/cluster_upgrade.md`](docs/cluster_upgrade.md) - The 8.8 → 8.9 cluster upgrade: what changed, file-by-file migration steps, config diffs, and troubleshooting for common post-upgrade issues including the Optimize schema migration.
- [`docs/update_guide.md`](docs/update_guide.md) - The minor/patch update procedure: how to look up new versions, the file list to review per update, the backup-before-update protocol, and a step-by-step plan with a restore drill at the end.

## First Start Setup

Complete these steps in order after a fresh clone.

### 1. Configuration and credentials

The project ships two environment files:

- **`.env`** — committed, contains non-credential configuration (image versions, `HOST`, `STAGE`, banner paths, backup/TLS paths, registry URL, mail address, feature flags). All operators start from the same defaults.
- **`.env-credentials`** — **gitignored**, contains every secret (OIDC client secrets, database passwords, Elasticsearch password, Keycloak admin, Pusher keys, registry credentials, Camunda license key). Generate this on the target host.

#### Generate `.env-credentials` with strong random secrets (recommended)

```bash
# Linux / macOS
bash scripts/generate-secrets.sh

# Windows (PowerShell)
pwsh -File scripts/generate-secrets.ps1
```

This creates `.env-credentials` with cryptographically random secrets (48-character hex strings via `openssl rand -hex 24` / `System.Security.Cryptography.RandomNumberGenerator`). The file is given restricted permissions (`chmod 600` on Linux/macOS).

> **Always use `--force` / `-Force` with caution** — it overwrites an existing `.env-credentials`, invalidating all current secrets. Not recommended on an already-running deployment.

#### Local demo fallback (never use in production)

If you need weak demo secrets for a quick local demo, copy both example files:

```bash
cp .env.example .env
cp .env-credentials.example .env-credentials
```

The example files contain known weak values (`admin`, `demo`, `demo-connectors-secret`, etc.) and are clearly marked unsafe for production.

> **Use lowercase for `HOST`:** Browsers normalize domain names to lowercase in HTTP Host headers, and Keycloak validates redirect URIs with case-sensitive string matching. If `HOST` contains uppercase letters (e.g. `Camunda.Dev.Local`), services that derive their `redirect_uri` from the incoming Host header will produce a lowercase URI that does not match the uppercase URI registered in Keycloak, causing "Invalid parameter: redirect_uri" errors. Always set `HOST` to lowercase (e.g. `camunda.dev.local`).
>
> **Certificate file paths are independent of HOST:** `FULLCHAIN_PEM` and `PRIVATEKEY_PEM` in `.env` are literal file paths to the actual certificate files on disk. If your certificate files have uppercase characters in their names, keep those paths as-is — only the `HOST` value itself needs to be lowercase.

### Optional: Add a Camunda Self-Managed license

For production use, add the Camunda license key to `.env-credentials`. The key is injected into the Camunda containers as `CAMUNDA_LICENSE_KEY`; the file is gitignored and must not be committed.

```env
CAMUNDA_LICENSE_KEY='--------------- BEGIN CAMUNDA LICENSE KEY ---------------
... complete key from Camunda ...
--------------- END CAMUNDA LICENSE KEY ---------------'
```

Restart the stack with the normal stage-aware start script after adding or changing the key. Check `orchestration`, `optimize`, `web-modeler-restapi`, and `console` logs for remaining license warnings.

### 2. Create the connector secrets file

```bash
cp connector-secrets.txt.example connector-secrets.txt
```

`connector-secrets.txt` is mounted into the Connectors container as an env file. Add any connector secrets you need in `NAME=VALUE` format. The file is gitignored — never commit it.

For Camunda 8.9 Agentic AI connectors, this stack uses the `CONNECTORS_SECRET` prefix. A connector field such as `{{secrets.OPENAI_API_KEY}}` resolves `CONNECTORS_SECRET_OPENAI_API_KEY` from `connector-secrets.txt`.

Example:

```env
CONNECTORS_SECRET_OPENAI_API_KEY=sk-...
CONNECTORS_SECRET_MCP_CLIENT_SECRET=...
```

See [`docs/agentic-ai.md`](docs/agentic-ai.md) for provider-specific examples and MCP client configuration.

### Management endpoints and secret exposure

Runtime services receive OAuth client secrets, database passwords, Keycloak admin credentials, and connector credentials through environment variables. Do not expose `/actuator/configprops` in committed configuration, and do not enable `MANAGEMENT_ENDPOINT_CONFIGPROPS_SHOW_VALUES=ALWAYS` or `management.endpoint.configprops.show-values: ALWAYS`.

Only expose the actuator endpoints required for health checks and monitoring, such as `health`, `info`, `metrics`, and `prometheus`. If `configprops` is temporarily needed for local debugging, keep it bound to localhost and use `show-values: NEVER`.

### 3. Create the Caddyfile

```bash
cp Caddyfile.example Caddyfile
```

The `Caddyfile` is gitignored because the `setup-host` scripts rewrite it with your actual `HOST` value and optional TLS paths. `Caddyfile.example` is the committed template — never edit `Caddyfile` directly; re-run `setup-host` instead.

### 4. Custom TLS certificates (optional)

By default, Caddy generates a self-signed certificate and your browser will show a security warning. To use a trusted certificate instead, place your certificate files in the `certs/` folder in the project root (it is mounted read-only at `/certs` inside the Caddy container) and set the paths in `.env`:

```env
HOST=your-hostname
FULLCHAIN_PEM=/certs/cert.pem
PRIVATEKEY_PEM=/certs/private.key
```

> **Note:** The `certs/` folder is listed in `.gitignore` — certificate files (especially private keys) will never be accidentally committed.

Before starting the cluster, verify that the certificate covers your `HOST`:

```bash
openssl x509 -in certs/cert.pem -noout -text | grep -A1 "Subject Alternative Name"
```

It must include `*.your-hostname` (or at least each individual subdomain). Caddy will reject the certificate at startup if the SNI does not match.

> **CA trust:** If the certificate was issued by your corporate CA (e.g. Active Directory), it may already be trusted on your Windows machine and no further action is needed. If browsers still show a warning, import the issuing root CA into the Windows trust store.

**No existing certificate? Use mkcert.**

[mkcert](https://github.com/FiloSottile/mkcert) creates a local CA, installs it into the OS trust store once, and issues wildcard certificates for any domain — including private domains like `*.myhost.corp.local`.

```powershell
# Install mkcert (run once)
winget install FiloSottile.mkcert   # Windows
# brew install mkcert               # macOS

# Register the local CA in the system trust store (run once, as admin on Windows)
mkcert -install

# Create a wildcard certificate for your HOST (run from the project root)
mkdir certs
cd certs
mkcert "*.your-hostname" "your-hostname"
```

```env
HOST=your-hostname
FULLCHAIN_PEM=/certs/_wildcard.your-hostname+1.pem
PRIVATEKEY_PEM=/certs/_wildcard.your-hostname+1-key.pem
```

> **Note on filenames:** `mkcert` appends a counter suffix when multiple SANs are given (`+1`, `+2`, …). Check the actual filenames in `certs/` after running `mkcert`.

The `setup-host` script in the next step reads `FULLCHAIN_PEM` and `PRIVATEKEY_PEM` from `.env` and injects a `tls <cert> <key>` directive into every top-level site block in the Caddyfile. If those variables are not set, Caddy generates self-signed certs instead.

### 5. Configure hostname, Caddyfile, and hosts

**Linux / macOS:**
```bash
bash scripts/setup-host.sh
```

**Windows (PowerShell — run as Administrator):**
```powershell
pwsh -File scripts/setup-host.ps1
```

> **Admin required on Windows:** the script writes to `C:\Windows\System32\drivers\etc\hosts`. Without elevation the Caddyfile update still succeeds but the hosts file update will fail.

Both scripts read `HOST` from `.env` and update:
- `Caddyfile` — replaces all `*.localhost` domain names with `*.{HOST}`, including the root `{HOST} {` dashboard block; also injects `tls` directives if custom certificates are configured
- hosts file — adds `127.0.0.1 {HOST}` and `127.0.0.1` entries for all subdomains (keycloak, identity, console, optimize, orchestration, webmodeler)

The scripts are **idempotent** — re-running them will not produce duplicate entries.

### 6. Start the cluster

```bash
# Linux / macOS
bash scripts/start.sh

# Windows (PowerShell)
pwsh -File scripts/start.ps1
```

> **Note:** PowerShell 7+ required on Windows. For Windows PowerShell 5.1, use Git Bash and run `bash scripts/start.sh`.

Wait for all services to be healthy:

```bash
docker compose --env-file .env --env-file .env-credentials -f docker-compose.yaml -f stages/prod.yaml ps
```

> **Expect a slow first start (5–10 minutes).** The very first `up` runs a one-time bootstrap regardless of stage: Keycloak imports the realm, Identity provisions all OIDC clients in Keycloak, Postgres and web-modeler-db run schema migrations, and Elasticsearch creates index templates and ILM policies. During this phase `keycloak`, `identity`, and `web-modeler-restapi` are CPU-heavy and the UIs feel unresponsive. Subsequent starts reuse the persisted named volumes (`postgres`, `keycloak-theme`, `elastic`, `postgres-web`, …) and come up in 1–2 minutes. If a *later* start ever feels slow again, a volume was likely wiped (e.g. `docker compose down -v`) and you are paying the bootstrap cost a second time — check `docker volume ls` before assuming a config issue.
>
> **Always use the start scripts — not bare `docker compose up -d`.** The scripts pass both `.env` and `.env-credentials` to Compose for interpolation, read `STAGE` from `.env`, and overlay `stages/<stage>.yaml` on top of `docker-compose.yaml`. Plain `docker compose up -d` does not load `.env-credentials` for `${VAR}` interpolation and loads only the base file, which is sized for `prod`. With `STAGE=dev` or `STAGE=test` you must use the wrapper, otherwise the JVM heap settings from the stage overlay are not applied and Java services get the production heap (e.g. `-Xms4500m` for orchestration, `-Xms4g` for Elasticsearch) inside smaller container memory limits — the kernel OOM-killer terminates them on startup (exit 137).

The stack also includes an `autoheal` sidecar that watches labeled containers and restarts them when Docker marks them as `unhealthy`. It complements `restart: unless-stopped`, which covers unexpected process exits. `autoheal` does not restart containers that were stopped intentionally with `docker stop` or removed with `docker compose down`.

For host-level recovery, the repository also provides `scripts/ensure-stack.sh`. It is intended for cron and checks whether all expected Compose services for the configured `STAGE` are currently running. If one or more containers are missing or stopped, it starts only those missing services with the same stage-aware Compose file selection used by the repository startup scripts. This is useful after a host reboot, after Docker starts later than the OS, or when selected containers were not recreated automatically. On Windows, the equivalent manual helper is `pwsh -File scripts/ensure-stack.ps1`.

### 7. Access the services

The dashboard at `https://{HOST}` provides a landing page with links to all services. Links adapt automatically to the configured `HOST`.

| Service | URL |
|---------|-----|
| Dashboard | https://{HOST} |
| Operate / Tasklist | https://orchestration.{HOST} |
| Identity | https://identity.{HOST} |
| Console | https://console.{HOST} |
| Optimize | https://optimize.{HOST} |
| Web Modeler | https://webmodeler.{HOST} |
| Keycloak Admin | https://keycloak.{HOST}/auth/ (admin / admin) |
| Zeebe Gateway | https://zeebe.{HOST} |
| Admin | https://orchestration.{HOST}/admin |
| Orchestration MCP Server | https://orchestration.{HOST}/mcp/cluster |

> **TLS warning:** If no custom certificates are configured, Caddy uses a self-signed cert. Your browser will show a security warning — click "Advanced" and proceed. With a trusted certificate (your own or one from mkcert) this warning disappears.

> **Optimize browser console warning:** Optimize 8.9.6 ships a frontend loader for Mixpanel at `//cdn.mxpnl.com/libs/mixpanel-2-latest.min.js`. Browser privacy tools such as uBlock, AdBlock, or Brave Shields commonly block that URL and log `net::ERR_BLOCKED_BY_CLIENT`. This is a client-side blocker message, not a reverse-proxy or Optimize container failure. If Optimize loads normally, the warning can be ignored or removed by allowing `cdn.mxpnl.com` for `optimize.{HOST}`.

## Environment Stages

The stack reads `STAGE` from `.env` and applies a matching resource profile from `stages/`. The value is case-insensitive, so `DEV`, `dev`, and `DeV` all select the same profile.

Supported values:

| STAGE | Target |
|-------|--------|
| `prod` | Full production-grade resources, matching the base `docker-compose.yaml` limits and reservations |
| `dev` | Reduced resources for developer workstations with fewer CPUs and less RAM |
| `test` | Compact resources for constrained test hosts |

### Decoupling the displayed label (`DISPLAY_STAGE`)

`STAGE` selects the resource profile *and*, by default, the label shown on the dashboard badge / page title and the Camunda Console release tag. To run one profile while displaying a different label — for example `dev` resources but a `TEST` badge — set the optional `DISPLAY_STAGE` variable in `.env`:

```
STAGE=DEV
DISPLAY_STAGE=TEST
```

If `DISPLAY_STAGE` is unset, both surfaces fall back to `STAGE` (existing setups are unaffected). Casing of `DISPLAY_STAGE` is preserved verbatim, so `DISPLAY_STAGE=Staging-A` shows up exactly as `Staging-A`. After changing `DISPLAY_STAGE`, rerun the stage-aware start script:

```bash
# Linux / macOS
bash scripts/start.sh

# Windows PowerShell
pwsh -File scripts/start.ps1
```

Start the stack with the stage-aware wrapper:

```bash
# Linux / macOS
bash scripts/start.sh

# Windows (PowerShell)
pwsh -File scripts/start.ps1
```

Stop the stack with:

```bash
# Linux / macOS
bash scripts/stop.sh

# Windows (PowerShell)
pwsh -File scripts/stop.ps1
```

Internally, the start scripts run Docker Compose with the base file and the selected stage override, for example:

```bash
docker compose --env-file .env --env-file .env-credentials -f docker-compose.yaml -f stages/dev.yaml up -d
```

Use the same `--env-file` and `-f` arguments for manual Compose commands that read the Compose model. A bare command such as `docker compose logs -f optimize` can fail because `docker-compose.yaml` contains variables from `.env-credentials`.

Examples:

```bash
# Follow Optimize logs (replace stages/prod.yaml with the stage from .env)
docker compose --env-file .env --env-file .env-credentials -f docker-compose.yaml -f stages/prod.yaml logs -f optimize

# Check rendered services / config
docker compose --env-file .env --env-file .env-credentials -f docker-compose.yaml -f stages/prod.yaml ps
docker compose --env-file .env --env-file .env-credentials -f docker-compose.yaml -f stages/prod.yaml config
```

To run the stack guard from cron on Linux every 30 minutes, add an entry similar to:

```cron
*/30 * * * * cd /path/to/CamundaComposeNVL && bash scripts/ensure-stack.sh >> /var/log/camunda-ensure-stack.log 2>&1
```

This guard is intentionally separate from `autoheal`: `autoheal` handles containers that are still running but become `unhealthy`, while `ensure-stack.sh` handles missing or stopped containers and host reboot recovery without restarting healthy services.

For manual recovery on Windows, run:

```powershell
pwsh -File scripts/ensure-stack.ps1
```

---

## Optimize schema upgrade (after a patch bump)

Optimize persists its schema version in Elasticsearch and **refuses to start** when the stored version is older than the new binary. After bumping `CAMUNDA_OPTIMIZE_VERSION` in `.env` (e.g. `8.9.1` → `8.9.6`) and starting the stack, the `optimize` container restart-loops with:

```
The database Optimize schema version [8.9.1] doesn't match the
current Optimize version [8.9.6]. Please make sure to run the
Upgrade first.
```

This is by design — Camunda's defense against jumping Optimize versions without applying the intermediate schema migrations. Run the bundled schema upgrade one-shot before the regular service can come up:

```bash
# Linux / macOS / Git Bash
bash scripts/optimize-upgrade.sh

# Windows (PowerShell)
pwsh -File scripts/optimize-upgrade.ps1
```

The script stops the broken `optimize` service, runs the upgrade container that inherits the service's env config and reaches Elasticsearch on the same Docker network, then restarts the service and polls for healthy. It is non-destructive (ES metadata is updated in place, no indices dropped, no data lost) and safe to re-run idempotently.

Every patch bump of Optimize will require this step, so the script belongs in the standard post-update workflow alongside `docker compose pull` and a fresh backup.

> **Pre-flight:** `scripts/start.sh` and `scripts/start.ps1` run the same upgrade one-shot automatically after pulling the new image and waiting for Elasticsearch to become healthy, so a normal `start` of the stack will not hit this error. The script above is only needed as a manual fallback — for example, if the pre-flight is bypassed or if the pre-flight itself fails.

> **Future-proof across 8.x:** The pre-flight and the manual `optimize-upgrade` script are not pinned to any specific Optimize version. Both invoke `/optimize/upgrade/upgrade.sh --skip-warning` *inside* the freshly-pulled Optimize image, so the next start after a `CAMUNDA_OPTIMIZE_VERSION` bump automatically runs the new image's bundled upgrade logic. No edits to `start.sh` / `start.ps1` or to the recovery script are required for future 8.x → 8.x patch or minor releases. The pre-flight only needs re-checking if Camunda renames the upgrade path inside the image or renames the `optimize` service in `docker-compose.yaml` (both would surface as a recurring `Optimize schema pre-flight failed` warning). For an 8 → 9 major jump, follow the official Camunda migration guide on top of the pre-flight.

---

## Changing the hostname

All configuration is driven by the `HOST` variable in `.env`. To switch domain:

1. Edit `.env` and set `HOST=your-new-domain`
2. If you want trusted TLS, place certificate files in `certs/` and set `FULLCHAIN_PEM`/`PRIVATEKEY_PEM` in `.env` (see [Custom TLS certificates](#custom-tls-certificates-optional) above)
3. Run `scripts/setup-host.sh` (Linux/macOS) or `pwsh -File scripts/setup-host.ps1` **as Administrator** (Windows) to update Caddyfile and hosts file
4. Start/restart the cluster with `bash scripts/start.sh` (Linux/macOS) or `pwsh -File scripts/start.ps1` (Windows)
5. If Keycloak data persists, the redirect URIs from `.identity/application.yaml` are already correct. Only if you see "Invalid redirect_uri" errors after hostname changes, stop the stack, remove the Keycloak/Identity database volumes for this Compose project, and rerun the start script.

### Accessing from other machines on the network

The hosts file entries added by `setup-host` use `127.0.0.1` and only work on the local machine. Direct service ports such as `8088`, `9200`, and `9600` are intentionally bound to `127.0.0.1` for local diagnostics and scripts; remote clients should use only the HTTPS Caddy subdomains on port 443.

To allow other devices on your network to reach the services through Caddy:

- Add entries pointing to your machine's actual IP (e.g. `192.168.1.10 keycloak.your-hostname`) to the hosts file on each client machine, **or**
- Create a wildcard DNS record `*.your-hostname → <your IP>` in your corporate DNS

Each client machine also needs to trust the CA that signed your certificate. For mkcert, the root certificate is at the path printed by `mkcert -CAROOT` (`rootCA.pem`) — import it into the OS trust store on each client. For a corporate CA it is likely already trusted on domain-joined machines.

Elasticsearch requires Basic Auth on port `9200`. Direct access is still bound to `127.0.0.1` for local backup/restore scripts and diagnostics. Do not expose `9200`, `9300`, or `9600` on LAN interfaces.

---

---

## User Management

### Background: Why two systems?

Camunda 8 has **two independent security systems**. Both must be satisfied for a user to access Operate or Tasklist:

1. **Keycloak** — the central login system. Users are created here and assigned roles (e.g., "may use Camunda").

2. **Camunda's own authorization system** — an internal list that defines which users may actually access which functions.

Both systems must match — Keycloak alone is not enough.

The built-in demo user (`demo`) works immediately after startup because it is automatically registered in **both** systems on first boot. Previously, manually created users were only added to Keycloak and ended up on a "Forbidden" page even though their login succeeded.

The `add-camunda-user` script therefore adds new users to both systems.

---

### Creating users

Create Camunda users in Keycloak with role-based permissions.

**Linux / macOS:**
```bash
bash scripts/add-camunda-user.sh --username jdoe --password "changeme" --email "jdoe@example.com" --first-name John --last-name Doe --role NormalUser
```

**Windows (PowerShell):**
```powershell
pwsh -File scripts/add-camunda-user.ps1 -Username jdoe -Password "changeme" -Email "jdoe@example.com" -FirstName John -LastName Doe -Role NormalUser
```

By default the initial password is marked **temporary** — the user must set a new password at first login (same as the "Temporary" toggle in the Keycloak UI). To skip this, e.g. for service accounts, pass `--permanent-password` (Bash) or `-PermanentPassword` (PowerShell):

```bash
bash scripts/add-camunda-user.sh --username svc-bot --password "s3cret" --email "svc-bot@example.com" --first-name Service --last-name Bot --role NormalUser --permanent-password
```

### Roles

| Role | Keycloak realm roles | Camunda internal role | Access |
|------|----------------------|-----------------------|--------|
| `NormalUser` | Default user role, Orchestration, Optimize, Web Modeler | `readonly-admin` | Read-only in Operate + Tasklist; can complete tasks |
| `Admin` | All roles incl. ManagementIdentity, Console, Web Modeler Admin | `admin` | Full access to all components |

The scripts read `HOST` and `ORCHESTRATION_CLIENT_SECRET` from `.env`. On failure the created user is automatically rolled back.

> **How authorization works:** Camunda 8 has its own internal authorization system (`camunda.security.authorizations.enabled=true`) independent of Keycloak roles. The scripts assign users to both their Keycloak realm roles *and* the corresponding Camunda internal role via the REST API.

---

## Inspecting Camunda's private Docker registry

Camunda 8 enterprise customers receive credentials for `registry.camunda.cloud` — a Harbor registry that hosts the public Docker Hub mirror (`dockerhub-camunda`), enterprise-only projects (`console`, `web-modeler-ee`, `iam-ee`, `keycloak-ee`, …), and customer hotfix repositories. The `registry-info` script queries the Harbor v2 REST API to list projects, repositories, and tags so you can discover which images and versions are available before pinning one in `docker-compose.yaml`.

### Why use it

`docker search` only works against Docker Hub, so for any private registry you have to talk to its REST API directly. The script wraps that with three things you would otherwise build by hand:

1. **Reads credentials from `.env`** — no need to hand-craft Basic-Auth headers each time.
2. **Handles Harbor's repository-name quirk** — Harbor's listing endpoint returns repos as `<project>/<repo>`, but the artifacts endpoint expects only the bare `<repo>` portion. The script strips the project prefix automatically, so you can copy-paste names from the listing without thinking about it.
3. **Default mode lists tags for the images this stack actually uses** — a quick way to spot when newer versions of `camunda/camunda`, `camunda/console`, `camunda/optimize`, etc. show up on the mirror.

### Prerequisites

Add the registry URL and your customer credentials to `.env`:

```env
CAMUNDA_REGISTRY_URL=https://registry.camunda.cloud
CAMUNDA_REGISTRY_USERNAME=your-customer-account
CAMUNDA_REGISTRY_PASSWORD=your-customer-password
```

> The script only needs these three variables. They are independent of `docker login` — that login is what allows `docker compose pull` to fetch images, while the script reads the values from `.env` to call the Harbor REST API.

The Bash version additionally requires `curl` and `jq`.

### Usage

**Linux / macOS:**
```bash
bash scripts/registry-info.sh                                                              # default: tags for the standard images
bash scripts/registry-info.sh --projects                                                   # list all projects
bash scripts/registry-info.sh --project console                                            # list repos in a project
bash scripts/registry-info.sh --project console --repository console-sm --limit 20         # tags for one repo
```

**Windows (PowerShell):**
```powershell
pwsh -File scripts/registry-info.ps1                                                       # default: tags for the standard images
pwsh -File scripts/registry-info.ps1 -ListProjects                                          # list all projects
pwsh -File scripts/registry-info.ps1 -Project console                                      # list repos in a project
pwsh -File scripts/registry-info.ps1 -Project console -Repository console-sm -Limit 20     # tags for one repo
```

Both forms accept the repository either as the bare name (`console-sm`) or the full name as printed by the listing (`console/console-sm`) — the project prefix is stripped automatically.

### What you'll see

| Mode | Output |
|------|--------|
| Default | Newest tags for each of the nine standard images used by `docker-compose.yaml` (camunda, console, optimize, identity, connectors-bundle, web-modeler-restapi/webapp/websockets, keycloak), pulled from the `dockerhub-camunda` mirror project |
| Projects | Project name, repo count, and whether the project is public |
| Project repositories | Repo name, artifact count, and last update timestamp |
| Repository tags | Tag name and push timestamp, sorted newest-first, capped to `--limit` (default 10) |

### Troubleshooting

- **`-DebugRaw` (PowerShell)** dumps the first 800 characters of the raw API response, which is helpful when the API shape ever changes.
- **HTTP 401 on `/projects/<x>/repositories`** means your account does not have permission for that project. Camunda customer accounts are Harbor *robot accounts* with project-scoped pull permissions; the public catalog endpoint and many user-info endpoints are deliberately closed.
- **A repository shows `0` tags but a high artifact count** usually means you queried with the full `<project>/<repo>` name without prefix-stripping (the script handles this; manual `curl` calls do not).
