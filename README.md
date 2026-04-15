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
pwsh -File scripts/keycloak-redirects.ps1 -Mode Merge
```

This adds the proxy HTTPS URLs to Keycloak so that login works through the reverse proxy.

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
pwsh -File scripts/keycloak-redirects.ps1 [-Mode {Merge|Fix}]
```

### Modes

| Mode | When to use | What it does |
|------|-------------|--------------|
| `Merge` (default) | Adding the reverse proxy for the first time, or adding a new service to an existing proxy setup | Adds proxy URLs to whatever URIs already exist. Safe to re-run — never removes existing URIs. |
| `Fix` | Redirect URIs are corrupted (duplicates, stale staging URLs, broken experiments) or you are getting "Invalid redirect_uri" errors that Merge doesn't resolve | Replaces all redirect URIs with a clean known-good set: both direct `localhost` URLs and proxy HTTPS URLs. |

### Examples

```powershell
# Add proxy URLs to existing redirect URIs (additive, safe)
pwsh -File scripts/keycloak-redirects.ps1

# Same as above, explicit
pwsh -File scripts/keycloak-redirects.ps1 -Mode Merge

# Reset all redirect URIs to known-good baseline
pwsh -File scripts/keycloak-redirects.ps1 -Mode Fix
```

### Prerequisites

- Keycloak must be accessible at `keycloak.localhost` (or use `-KeycloakHost` to point elsewhere)
- Default admin credentials: `admin` / `admin` (configure with `-AdminUser` / `-AdminPassword`)
- Requires PowerShell Core (`pwsh`)
