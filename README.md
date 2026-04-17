# Camunda 8 Self-Managed - Docker Compose

## Usage

For end user usage, please check the official documentation of [Camunda 8 Self-Managed Docker Compose](https://docs.camunda.io/docs/next/self-managed/quickstart/developer-quickstart/docker-compose/).

## First Start Setup

Complete these steps in order after a fresh clone.

### 1. Create the environment file

```bash
cp .env.example .env
```

Open `.env` and set `HOST` to your desired domain. All services will be available at `{subdomain}.{HOST}` (e.g. `https://orchestration.localhost` if `HOST=localhost`).

> **Use lowercase for `HOST`:** Browsers normalize domain names to lowercase in HTTP Host headers, and Keycloak validates redirect URIs with case-sensitive string matching. If `HOST` contains uppercase letters (e.g. `BBC-100030.bbc.local`), services that derive their `redirect_uri` from the incoming Host header will produce a lowercase URI that does not match the uppercase URI registered in Keycloak, causing "Invalid parameter: redirect_uri" errors. Always set `HOST` to lowercase (e.g. `bbc-100030.bbc.local`).
>
> **Certificate file paths are independent of HOST:** `FULLCHAIN_PEM` and `PRIVATEKEY_PEM` in `.env` are literal file paths to the actual certificate files on disk. If your certificate files have uppercase characters in their names (e.g. `_wildcard.BBC-100030.bbc.local+1.pem`), keep those paths as-is — only the `HOST` value itself needs to be lowercase.

### 2. Configure hostname, Caddyfile, and hosts

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
- `Caddyfile` — replaces all `*.localhost` domain names with `*.{HOST}`, including the root `{HOST} {` dashboard block
- hosts file — adds `127.0.0.1 {HOST}` and `127.0.0.1` entries for all subdomains (keycloak, identity, console, optimize, orchestration, webmodeler)

The scripts are **idempotent** — re-running them will not produce duplicate entries.

#### Custom TLS certificates (optional)

By default, Caddy generates a self-signed certificate and your browser will show a security warning. To use a trusted certificate instead, place your certificate files in the `certs/` folder in the project root (it is mounted read-only at `/certs` inside the Caddy container) and set the paths in `.env`:

```env
HOST=your-hostname
FULLCHAIN_PEM=/certs/cert.pem
PRIVATEKEY_PEM=/certs/private.key
```

> **Note:** The `certs/` folder is listed in `.gitignore` — certificate files (especially private keys) will never be accidentally committed.

The `setup-host` script will inject a `tls <cert> <key>` directive into every top-level site block in the Caddyfile automatically. If `FULLCHAIN_PEM`/`PRIVATEKEY_PEM` are not set, Caddy generates self-signed certs.

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

The Caddyfile change takes effect when the cluster starts (step 3).

### 3. Start the cluster

```bash
docker compose up -d
```

Wait for all services to be healthy (may take 2–3 minutes on first start):

```bash
docker compose ps
```

### 4. Configure Keycloak redirect URIs

After the cluster is up, run:

**Linux / macOS:**
```bash
bash scripts/keycloak-redirects.sh
```

**Windows (PowerShell):**
```powershell
pwsh -File scripts/keycloak-redirects.ps1
```

Both scripts read `HOST` from `.env` and add the correct HTTPS proxy redirect URIs to Keycloak for all clients. Safe to re-run.

### 5. Access the services

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
5. Re-run `scripts/keycloak-redirects.sh` (Linux/macOS) or `pwsh -File scripts/keycloak-redirects.ps1` (Windows) to update Keycloak redirect URIs

### Accessing from other machines on the network

The hosts file entries added by `setup-host` use `127.0.0.1` and only work on the local machine. To allow other devices on your network to reach the services:

- Add entries pointing to your machine's actual IP (e.g. `192.168.1.10 keycloak.your-hostname`) to the hosts file on each client machine, **or**
- Create a wildcard DNS record `*.your-hostname → <your IP>` in your corporate DNS

Each client machine also needs to trust the CA that signed your certificate. For mkcert, the root certificate is at the path printed by `mkcert -CAROOT` (`rootCA.pem`) — import it into the OS trust store on each client. For a corporate CA it is likely already trusted on domain-joined machines.

---

## Keycloak Redirect URI Management

Keycloak strictly validates redirect URIs — the browser will only be redirected to URLs explicitly allowlisted for each client. If a redirect URI is missing or wrong, you will see "Invalid redirect_uri" errors after login.

The redirect URI scripts (`keycloak-redirects.sh` / `keycloak-redirects.ps1`) add both direct `localhost` URLs and proxy HTTPS URLs. They read `HOST` from `.env` automatically.

### Prerequisites

- Keycloak must be accessible at `keycloak.{HOST}` (override with `--keycloak-host` or `KEYCLOAK_HOST` env var)
- Default admin credentials: `admin` / `admin` (configure with `--admin-user` / `--admin-password` or `ADMIN_USER` / `ADMIN_PASSWORD` env vars)
