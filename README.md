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
docker compose up -d
```

Wait for all services to be healthy (may take 2–3 minutes on first start):

```bash
docker compose ps
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
4. Start/restart the cluster: `docker compose up -d` (or `docker compose restart reverse-proxy` if already running)
5. If Keycloak data persists, the redirect URIs from `.identity/application.yaml` are already correct. Only if you see "Invalid redirect_uri" errors after hostname changes, wipe Keycloak's database volume and restart (`docker compose down -v keycloak-theme postgres && docker compose up -d`).

### Accessing from other machines on the network

The hosts file entries added by `setup-host` use `127.0.0.1` and only work on the local machine. To allow other devices on your network to reach the services:

- Add entries pointing to your machine's actual IP (e.g. `192.168.1.10 keycloak.your-hostname`) to the hosts file on each client machine, **or**
- Create a wildcard DNS record `*.your-hostname → <your IP>` in your corporate DNS

Each client machine also needs to trust the CA that signed your certificate. For mkcert, the root certificate is at the path printed by `mkcert -CAROOT` (`rootCA.pem`) — import it into the OS trust store on each client. For a corporate CA it is likely already trusted on domain-joined machines.

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
bash scripts/add-camunda-user.sh \
  --username jdoe \
  --password "changeme" \
  --email "jdoe@example.com" \
  --first-name John \
  --last-name Doe \
  --role NormalUser
```

**Windows (PowerShell):**
```powershell
pwsh -File scripts/add-camunda-user.ps1 \
  -Username jdoe \
  -Password "changeme" \
  -Email "jdoe@example.com" \
  -FirstName John \
  -LastName Doe \
  -Role NormalUser
```

### Roles

| Role | Keycloak realm roles | Camunda internal role | Access |
|------|----------------------|-----------------------|--------|
| `NormalUser` | Default user role, Orchestration, Optimize, Web Modeler | `readonly-admin` | Read-only in Operate + Tasklist; can complete tasks |
| `Admin` | All roles incl. ManagementIdentity, Console, Web Modeler Admin | `admin` | Full access to all components |

The scripts read `HOST` and `ORCHESTRATION_CLIENT_SECRET` from `.env`. On failure the created user is automatically rolled back.

> **How authorization works:** Camunda 8 has its own internal authorization system (`camunda.security.authorizations.enabled=true`) independent of Keycloak roles. The scripts assign users to both their Keycloak realm roles *and* the corresponding Camunda internal role via the REST API.
