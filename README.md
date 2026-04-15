# Camunda 8 Self-Managed - Docker Compose

## Usage

For end user usage, please check the offical documentation of [Camunda 8 Self-Managed Docker Compose](https://docs.camunda.io/docs/next/self-managed/quickstart/developer-quickstart/docker-compose/).

## First Start Setup

Complete these steps once after a fresh clone:

### 1. Add hosts file entries

Add the following to your hosts file (`C:\Windows\System32\drivers\etc\hosts` on Windows, `/etc/hosts` on macOS/Linux):

```
127.0.0.1 keycloak.localhost
127.0.0.1 identity.localhost
127.0.0.1 console.localhost
127.0.0.1 optimize.localhost
127.0.0.1 orchestration.localhost
127.0.0.1 webmodeler.localhost
```

### 2. Create the environment file

```bash
cp .env.example .env
```

Edit `.env` if you need to customize any values (image versions, credentials, etc.).

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

```powershell
pwsh -File scripts/keycloak-redirects.ps1
```

This adds the proxy HTTPS URLs to Keycloak so that login works through the reverse proxy. Safe to re-run.

### 5. Access the services

| Service | URL |
|---------|-----|
| Operate / Tasklist | https://orchestration.localhost |
| Identity | https://identity.localhost |
| Console | https://console.localhost |
| Optimize | https://optimize.localhost |
| Web Modeler | https://webmodeler.localhost |
| Keycloak Admin | https://keycloak.localhost/auth/ (admin / admin) |

> **Note:** Caddy uses a self-signed TLS certificate. Your browser will show a security warning — click "Advanced" and proceed. This is expected for local development.

---

## Keycloak Redirect URI Management

Keycloak strictly validates redirect URIs — the browser will only be redirected to URLs explicitly allowlisted for each client. If a redirect URI is missing or wrong, you will see "Invalid redirect_uri" errors after login.

A single script manages all redirect URIs:

```powershell
pwsh -File scripts/keycloak-redirects.ps1
```

The script adds both direct `localhost` URLs and proxy HTTPS URLs. Safe to re-run.

### Changing the hostname

To use a different hostname instead of `localhost`, edit these variables at the top of the script:

```powershell
$LocalHost = "localhost"    # direct access URLs
$ProxyDomain = "localhost"  # proxy URLs
```

For example, to use `camunda.local`:
```powershell
$LocalHost = "camunda.local"
$ProxyDomain = "camunda.local"
```

### Prerequisites

- Keycloak must be accessible at `keycloak.localhost` (or use `-KeycloakHost` to point elsewhere)
- Default admin credentials: `admin` / `admin` (configure with `-AdminUser` / `-AdminPassword`)
- Requires PowerShell Core (`pwsh`)
