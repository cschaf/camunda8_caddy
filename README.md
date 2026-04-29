# Camunda 8 Self-Managed - Docker Compose

## Prerequisites

- [Docker Engine](https://docs.docker.com/engine/install/) 24.0+ and [Docker Compose](https://docs.docker.com/compose/install/) ( Compose V2 plugin `docker compose`)
- [Git](https://git-scm.com/downloads) — to clone this repository
- **Linux/macOS:** Bash + `openssl` (for `generate-secrets.sh`)
- **Windows:** PowerShell 7+ (for `.ps1` scripts)
- `bash` available in your PATH — some health checks inside containers run `bash -c` commands

> **RAM:** This stack reserves ~16 GB and limits at ~27 GB. The host machine needs at least **32 GB RAM** for stable operation.

## Usage

For end user usage, please check the official documentation of [Camunda 8 Self-Managed Docker Compose](https://docs.camunda.io/docs/next/self-managed/quickstart/developer-quickstart/docker-compose/).

## Documentation

- [`docs/project_configuration.md`](docs/project_configuration.md) - Full configuration reference for this stack, including service settings, resource sizing, reverse proxy behavior, `autoheal`, the host recovery guard, and a decision guide for PostgreSQL vs Elasticsearch as Camunda core data backend.
- [`docs/stage_comparison.md`](docs/stage_comparison.md) - Side-by-side comparison of the `prod`, `dev`, and `test` stage resource profiles.

## First Start Setup

Complete these steps in order after a fresh clone.

### 1. Generate environment file with strong random secrets

```bash
# Linux / macOS
bash scripts/generate-secrets.sh

# Windows (PowerShell)
pwsh -File scripts/generate-secrets.ps1
```

This creates `.env` with cryptographically random secrets (48-character hex strings via `openssl rand -hex 24` / `System.Security.Cryptography.RandomNumberGenerator`). The file is given restricted permissions (`chmod 600` on Linux/macOS).

> **Always use `--force` / `-Force` with caution** — it overwrites an existing `.env`, invalidating all current secrets. Not recommended on an already-running deployment.

**Local demo fallback:** If you need weak demo secrets for a quick local demo (never use this in any environment where security matters), copy `.env.example` instead:
```bash
cp .env.example .env
```
The `.env.example` file contains known weak values (`admin`, `demo`, `demo-connectors-secret`, etc.) and is clearly marked unsafe for production.

> **Use lowercase for `HOST`:** Browsers normalize domain names to lowercase in HTTP Host headers, and Keycloak validates redirect URIs with case-sensitive string matching. If `HOST` contains uppercase letters (e.g. `Camunda.Dev.Local`), services that derive their `redirect_uri` from the incoming Host header will produce a lowercase URI that does not match the uppercase URI registered in Keycloak, causing "Invalid parameter: redirect_uri" errors. Always set `HOST` to lowercase (e.g. `camunda.dev.local`).
>
> **Certificate file paths are independent of HOST:** `FULLCHAIN_PEM` and `PRIVATEKEY_PEM` in `.env` are literal file paths to the actual certificate files on disk. If your certificate files have uppercase characters in their names, keep those paths as-is — only the `HOST` value itself needs to be lowercase.

### Optional: Add a Camunda Self-Managed license

For production use, add the Camunda license key to `.env`. The key is injected into the Camunda containers as `CAMUNDA_LICENSE_KEY`; `.env` is gitignored and must not be committed.

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

> **Note:** PowerShell 7+ required on Windows. For PS 5.1, use `docker compose -f docker-compose.yaml -f stages/$STAGE.yaml up -d` directly.

Wait for all services to be healthy:

```bash
docker compose ps
```

> **Expect a slow first start (5–10 minutes).** The very first `up` runs a one-time bootstrap regardless of stage: Keycloak imports the realm, Identity provisions all OIDC clients in Keycloak, Postgres and web-modeler-db run schema migrations, and Elasticsearch creates index templates and ILM policies. During this phase `keycloak`, `identity`, and `web-modeler-restapi` are CPU-heavy and the UIs feel unresponsive. Subsequent starts reuse the persisted named volumes (`postgres`, `keycloak-theme`, `elastic`, `postgres-web`, …) and come up in 1–2 minutes. If a *later* start ever feels slow again, a volume was likely wiped (e.g. `docker compose down -v`) and you are paying the bootstrap cost a second time — check `docker volume ls` before assuming a config issue.
>
> **Always use the start scripts — not bare `docker compose up -d`.** The scripts read `STAGE` from `.env` and overlay `stages/<stage>.yaml` on top of `docker-compose.yaml`. Plain `docker compose up -d` loads only the base file, which is sized for `prod`. With `STAGE=dev` or `STAGE=test` you must use the wrapper, otherwise the JVM heap settings from the stage overlay are not applied and Java services get the production heap (e.g. `-Xms4500m` for orchestration, `-Xms4g` for Elasticsearch) inside smaller container memory limits — the kernel OOM-killer terminates them on startup (exit 137). At `STAGE=prod` the base and the overlay match, so bare `docker compose up -d` works but bypasses `STAGE` validation; using the wrapper consistently avoids the trap.

The stack also includes an `autoheal` sidecar that watches labeled containers and restarts them when Docker marks them as `unhealthy`. It complements `restart: unless-stopped`, which covers unexpected process exits. `autoheal` does not restart containers that were stopped intentionally with `docker stop` or removed with `docker compose down`.

For host-level recovery, the repository also provides `scripts/ensure-stack.sh`. It is intended for cron and checks whether all expected Compose services for the configured `STAGE` are currently running. If one or more containers are missing or stopped, it starts only those missing services with the same stage-aware Compose file selection used by the repository startup scripts. This is useful after a host reboot, after Docker starts later than the OS, or when selected containers were not recreated automatically. On Windows, the equivalent manual helper is `pwsh -File scripts/ensure-stack.ps1`.

## Environment Stages

The stack reads `STAGE` from `.env` and applies a matching resource profile from `stages/`. The value is case-insensitive, so `DEV`, `dev`, and `DeV` all select the same profile.

Supported values:

| STAGE | Target |
|-------|--------|
| `prod` | Full production-grade resources, matching the base `docker-compose.yaml` limits and reservations |
| `dev` | Reduced resources for developer workstations with fewer CPUs and less RAM |
| `test` | Compact resources for constrained test hosts |

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
docker compose -f docker-compose.yaml -f stages/dev.yaml up -d
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

> **TLS warning:** If no custom certificates are configured, Caddy uses a self-signed cert. Your browser will show a security warning — click "Advanced" and proceed. With a trusted certificate (your own or one from mkcert) this warning disappears.

---

## Changing the hostname

All configuration is driven by the `HOST` variable in `.env`. To switch domain:

1. Edit `.env` and set `HOST=your-new-domain`
2. If you want trusted TLS, place certificate files in `certs/` and set `FULLCHAIN_PEM`/`PRIVATEKEY_PEM` in `.env` (see [Custom TLS certificates](#custom-tls-certificates-optional) above)
3. Run `scripts/setup-host.sh` (Linux/macOS) or `pwsh -File scripts/setup-host.ps1` **as Administrator** (Windows) to update Caddyfile and hosts file
4. Start/restart the cluster with `bash scripts/start.sh` (Linux/macOS) or `pwsh -File scripts/start.ps1` (Windows) — or `docker compose restart reverse-proxy` if already running
5. If Keycloak data persists, the redirect URIs from `.identity/application.yaml` are already correct. Only if you see "Invalid redirect_uri" errors after hostname changes, wipe Keycloak's database volume and restart (`docker compose down -v keycloak-theme postgres && bash scripts/start.sh`).

### Accessing from other machines on the network

The hosts file entries added by `setup-host` use `127.0.0.1` and only work on the local machine. Direct service ports such as `8088`, `9200`, and `9600` are intentionally bound to `127.0.0.1` for local diagnostics and scripts; remote clients should use only the HTTPS Caddy subdomains on port 443.

To allow other devices on your network to reach the services through Caddy:

- Add entries pointing to your machine's actual IP (e.g. `192.168.1.10 keycloak.your-hostname`) to the hosts file on each client machine, **or**
- Create a wildcard DNS record `*.your-hostname → <your IP>` in your corporate DNS

Each client machine also needs to trust the CA that signed your certificate. For mkcert, the root certificate is at the path printed by `mkcert -CAROOT` (`rootCA.pem`) — import it into the OS trust store on each client. For a corporate CA it is likely already trusted on domain-joined machines.

Do not expose Elasticsearch or management ports such as `9200`, `9300`, or `9600` on LAN interfaces while Elasticsearch security and actuator hardening are not enabled.

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

### Roles

| Role | Keycloak realm roles | Camunda internal role | Access |
|------|----------------------|-----------------------|--------|
| `NormalUser` | Default user role, Orchestration, Optimize, Web Modeler | `readonly-admin` | Read-only in Operate + Tasklist; can complete tasks |
| `Admin` | All roles incl. ManagementIdentity, Console, Web Modeler Admin | `admin` | Full access to all components |

The scripts read `HOST` and `ORCHESTRATION_CLIENT_SECRET` from `.env`. On failure the created user is automatically rolled back.

> **How authorization works:** Camunda 8 has its own internal authorization system (`camunda.security.authorizations.enabled=true`) independent of Keycloak roles. The scripts assign users to both their Keycloak realm roles *and* the corresponding Camunda internal role via the REST API.
