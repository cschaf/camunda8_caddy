# Camunda 8 Self-Managed - Docker Compose

## Usage

For end user usage, please check the official documentation of [Camunda 8 Self-Managed Docker Compose](https://docs.camunda.io/docs/next/self-managed/quickstart/developer-quickstart/docker-compose/).

## First Start Setup

Complete these steps in order after a fresh clone.

### 1. Create the environment file

```bash
cp .env.example .env
```

Open `.env` and set `HOST` to your desired domain. All services will be available at `{subdomain}.{HOST}` (e.g. `https://orchestration.localhost` if HOST is `localhost`).

### 2. Configure hostname, Caddyfile, and hosts

**Linux / macOS:**
```bash
bash scripts/setup-host.sh
```

**Windows (PowerShell):**
```powershell
pwsh -File scripts/setup-host.ps1
```

Both scripts read `HOST` from `.env` and update:
- `Caddyfile` — replaces all `*.localhost` domain names with `*.{HOST}`
- hosts file — adds `127.0.0.1` entries for all services (keycloak, identity, console, optimize, orchestration, webmodeler)

**Custom TLS certificates (optional):** If you have your own certificates, add to `.env`:
```env
FULLCHAIN_PEM=/path/to/fullchain.pem
PRIVATEKEY_PEM=/path/to/privkey.pem
```
The script will inject the `tls` directive into every site block in the Caddyfile. If not set, Caddy generates self-signed certs automatically.

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

| Service | URL |
|---------|-----|
| Operate / Tasklist | https://orchestration.{HOST} |
| Identity | https://identity.{HOST} |
| Console | https://console.{HOST} |
| Optimize | https://optimize.{HOST} |
| Web Modeler | https://webmodeler.{HOST} |
| Keycloak Admin | https://keycloak.{HOST}/auth/ (admin / admin) |

> **Note:** Caddy uses a self-signed TLS certificate. Your browser will show a security warning — click "Advanced" and proceed. This is expected for local development.

---

## Changing the hostname

All configuration is driven by the `HOST` variable in `.env`. To switch domain:

1. Edit `.env` and set `HOST=your-new-domain` (e.g. `camunda.local`)
2. Run `scripts/setup-host.sh` (Linux/macOS) or `pwsh -File scripts/setup-host.ps1` (Windows) to update Caddyfile and hosts file
3. Start/restart the cluster: `docker compose up -d` (or `docker compose restart` if already running)
4. Re-run `scripts/keycloak-redirects.sh` (Linux/macOS) or `pwsh -File scripts/keycloak-redirects.ps1` (Windows) to update Keycloak redirect URIs

---

## Keycloak Redirect URI Management

Keycloak strictly validates redirect URIs — the browser will only be redirected to URLs explicitly allowlisted for each client. If a redirect URI is missing or wrong, you will see "Invalid redirect_uri" errors after login.

The redirect URI scripts (`keycloak-redirects.sh` / `keycloak-redirects.ps1`) add both direct `localhost` URLs and proxy HTTPS URLs. They read `HOST` from `.env` automatically.

### Prerequisites

- Keycloak must be accessible at `keycloak.{HOST}` (override with `--keycloak-host` or `KEYCLOAK_HOST` env var)
- Default admin credentials: `admin` / `admin` (configure with `--admin-user` / `--admin-password` or `ADMIN_USER` / `ADMIN_PASSWORD` env vars)