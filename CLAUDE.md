# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Overview

This is a Camunda 8 Self-Managed Docker Compose distribution for local development. It deploys a full Camunda 8 stack including Zeebe (workflow engine), Operate, Tasklist, Optimize, Identity, Keycloak, Elasticsearch, Web Modeler, Connectors, and Console.

## Common Commands

### Starting the Environment

```bash
# Start all services (detached mode)
docker compose up -d

# Stop all services
docker compose down

# View logs
docker compose logs -f [service-name]
```

### Running Tests

E2e tests are in `tests/` using Playwright.

```bash
cd tests

# Install dependencies
npm install

# Run all tests
npm test

# Run tests in headed mode (visual browser)
npm run test:headed

# Run tests with Playwright debugger
npm run test:debug

# View HTML report
npm run report
```

## Architecture

### HOST vs KEYCLOAK_HOST — Critical Distinction

This is the most important routing concept in this project:

```
HOST=localhost           # Browser-facing URLs (redirects, callbacks)
KEYCLOAK_HOST=keycloak  # Internal container-to-container communication
```

**Why:** Inside a container, `localhost` refers to the container itself, not other containers. Using `keycloak` (the container name) allows Docker's internal DNS to resolve the actual Keycloak IP.

**Rule of thumb:**
- `${HOST}` appears in URLs the **browser** visits (authorization endpoints, redirect URIs)
- `${KEYCLOAK_HOST}` appears in URLs for **service-to-service** token validation and JWKS lookups

### Container Networks

| Network | Members |
|---------|---------|
| `camunda-platform` | orchestration, connectors, optimize, console, elasticsearch, keycloak, identity, web-modeler-restapi*, web-modeler-webapp* |
| `identity-network` | keycloak, identity, postgres |
| `web-modeler` | web-modeler-db, mailpit, web-modeler-restapi, web-modeler-webapp, web-modeler-websockets |

*web-modeler-restapi and web-modeler-webapp are dual-homed on both `web-modeler` and `camunda-platform` to reach orchestration and identity.

Container names serve as DNS hostnames within networks. E.g., `keycloak:18080`, `identity:8084`, `orchestration:8080`.

### OIDC Authentication Flow

1. Browser requests `http://localhost:8088` (or other service UI)
2. Service redirects to Keycloak authorization endpoint using `${HOST}` → `http://localhost:18080/auth/realms/...`
3. User authenticates at Keycloak (browser ↔ Keycloak direct)
4. Keycloak redirects back to service callback URL (e.g., `http://localhost:8088/sso-callback`)
5. Service exchanges auth code for token using `${KEYCLOAK_HOST}` → `http://keycloak:18080/auth/realms/...`

**Callback URLs by service** (`{HOST}` = value of `HOST` in `.env`):

| Service | External URL | Callback |
|---------|-------------|----------|
| Orchestration | `https://orchestration.{HOST}` | `/sso-callback` |
| Optimize | `https://optimize.{HOST}` | `/api/authentication/callback` |
| Web Modeler | `https://webmodeler.{HOST}` | `/login-callback` |
| Console | `http://localhost:8087` | handled internally |

### Exposed Ports

| Service | Host Port | Container Port | Notes |
|---------|----------|----------------|-------|
| orchestration | 26500, 9600, **8088** | 26500, 9600, 8080 | Zeebe gRPC, actuator, Operate/Tasklist UI |
| connectors | **8086** | 8080 | |
| optimize | **8083** | 8090 | |
| identity | **8084** | 8084 | |
| keycloak | **18080** | 18080 | Admin UI + OIDC |
| elasticsearch | **9200**, 9300 | 9200, 9300 | |
| console | **8087**, 9100 | 8080, 9100 | UI + metrics |
| web-modeler-webapp | **8070** | 8070 | |
| web-modeler-websockets | **8060** | 8060 | |
| web-modeler-restapi | (internal) | 8091 | No host port exposed |

### Web Modeler Architecture

Three components with dual network membership:

- **web-modeler-restapi** (internal port 8091) — reaches identity, elasticsearch, orchestration, mailpit, websockets
- **web-modeler-webapp** (port 8070) — browser-facing UI, reaches restapi and websockets
- **web-modeler-websockets** (port 8060) — push notifications for webapp

The cluster configuration (`CAMUNDA_MODELER_CLUSTERS_0_URL_WEBAPP`) points to the local Orchestration UI (e.g. `https://orchestration.localhost` when using the proxy, or `http://localhost:8088` for direct access), not Web Modeler itself, because Web Modeler connects to the Zeebe broker running in orchestration.

### Configuration Files

- `.env` — Image versions, `${HOST}`, `${KEYCLOAK_HOST}`, OIDC client secrets, database credentials
- `.env.example` — Template with defaults (copy to `.env`)
- `.orchestration/application.yaml` — Orchestration (Zeebe) config
- `.connectors/application.yaml` — Connectors config
- `.identity/application.yaml` — Identity + Keycloak realm/client setup
- `.optimize/environment-config.yaml` — Optimize config
- `.console/application.yaml` — Console config
- `connector-secrets.txt` — Connectors secrets (mounted as env_file)

### Reverse Proxy

A Caddy reverse proxy provides subdomain routing on standard HTTPS port 443.

**Service:** `reverse-proxy` (caddy:latest)

**Working services** (replace `{HOST}` with the value of `HOST` in `.env`):
- `https://keycloak.{HOST}/auth/` — Keycloak admin and OIDC
- `https://identity.{HOST}/` — Identity UI
- `https://console.{HOST}/` — Console UI
- `https://orchestration.{HOST}/` — Operate and Tasklist UIs
- `https://webmodeler.{HOST}/` — Web Modeler UI (with WebSocket/Pusher support)
- `https://{HOST}/` — Dashboard landing page with links to all services

**Hosts file entries required** (added automatically by `setup-host` scripts):
```
127.0.0.1 {HOST}
127.0.0.1 keycloak.{HOST}
127.0.0.1 identity.{HOST}
127.0.0.1 console.{HOST}
127.0.0.1 optimize.{HOST}
127.0.0.1 orchestration.{HOST}
127.0.0.1 webmodeler.{HOST}
```

**Key configuration files:**
- `Caddyfile` — subdomain route definitions; managed by `setup-host` scripts (do not edit hostnames manually)
- `certs/` — optional TLS certificate files; gitignored, mounted at `/certs` in the Caddy container
- `KEYCLOAK_PROXY_HEADERS: xforwarded` — tells Keycloak v26+ to trust proxy headers

**TLS:** Caddy auto-generates a self-signed TLS certificate by default. Set `FULLCHAIN_PEM` and `PRIVATEKEY_PEM` in `.env` to use a custom certificate (e.g. from mkcert or a corporate CA). The `setup-host` scripts inject the `tls` directive idempotently — re-running never duplicates it.

### Adding Services to Reverse Proxy

For a service to work behind the reverse proxy, two things must be configured:

**1. Service configuration** — Update the service's `application.yaml` (Spring Boot) or `docker-compose.yaml` env vars (Node.js) to use external URLs:
```yaml
# Spring Boot (application.yaml)
authProvider:
  issuer-url: "https://keycloak.{HOST}/auth/realms/camunda-platform"
  backend-url: "http://keycloak:18080/auth/realms/camunda-platform"  # Internal
```
```yaml
# Node.js (docker-compose.yaml environment)
KEYCLOAK_BASE_URL: https://keycloak.${HOST}/auth       # browser-facing — MUST be HTTPS when served via proxy
KEYCLOAK_INTERNAL_BASE_URL: http://keycloak:18080/auth  # container-to-container
```

> **Mixed content rule:** If the service is served over HTTPS via the proxy, `KEYCLOAK_BASE_URL` (or equivalent browser-facing Keycloak URL) must also use `https://keycloak.{HOST}`. Browsers block HTTP resources loaded from HTTPS pages.

**Caddyfile template for Spring Boot services** — handles fonts (sec-fetch-mode: cors 403) and CORS preflight (replace `service.{HOST}` and `container-name:port` accordingly):
```caddy
service.{HOST} {
    @options { method OPTIONS }
    handle @options {
        respond "OK" 200
        header Access-Control-Allow-Origin "*"
        header Access-Control-Allow-Methods "GET, POST, PUT, DELETE, OPTIONS"
        header Access-Control-Allow-Headers "Content-Type, Authorization, X-Requested-With, Accept, Origin"
        header Access-Control-Max-Age "3600"
    }
    @static { path /static/* }
    handle @static {
        reverse_proxy container-name:port {
            header_up -Origin
        }
    }
    reverse_proxy container-name:port
}
```
Also add `SERVER_FORWARD_HEADERS_STRATEGY: framework` to the service's environment in `docker-compose.yaml`.

**2. Keycloak client redirect URIs** — These are configured automatically by Identity on first startup via `.identity/application.yaml`. No manual action needed.

| Service | Callback URL |
|---------|-------------|
| camunda-identity | `https://identity.{HOST}/auth/login-callback` |
| orchestration | `https://orchestration.{HOST}/sso-callback` |
| console | `https://console.{HOST}/` (root path — no sub-path) |
| optimize | `https://optimize.{HOST}/api/authentication/callback` |
| web-modeler | `https://webmodeler.{HOST}/login-callback` |

## Git Conventions

- **Never add `Co-Authored-By` lines to commit messages.**

### Common Gotchas

1. **KEYCLOAK_HOST must be `keycloak` (container name), not `localhost`** — otherwise services inside containers cannot reach Keycloak (they resolve to themselves)

2. **Identity health check tests port 8082** — but container exposes 8084; this works if actuator runs on a different port

3. **web-modeler-restapi has no host port** — accessed via webapp at port 8070

4. **Console uses two Keycloak URLs:** `KEYCLOAK_BASE_URL` (browser) and `KEYCLOAK_INTERNAL_BASE_URL` (service-to-service)

5. **Keycloak client redirect URIs are configured automatically** — `.identity/application.yaml` defines all redirect URIs with `${HOST}` interpolation. Identity applies them on first startup. If you change `HOST` after Keycloak data already exists, wipe the Keycloak/Identity database volumes and restart.

6. **Spring Boot font/static asset 403 via proxy** — CSS `@font-face` triggers `sec-fetch-mode: cors`, causing Spring Security to reject `/static/media/*.woff*` because `Origin: https://service.localhost` doesn't match the backend's own URL. Fix: strip the Origin header for static paths using `header_up -Origin` inside the `reverse_proxy` block (see Caddyfile template above).

7. **Spring Boot POST 403 via proxy (CSRF Origin check)** — Spring Security validates that the `Origin` header on POST/PUT/DELETE matches the server's own URL. Behind Caddy this fails unless you add `SERVER_FORWARD_HEADERS_STRATEGY: framework` to the service's environment in `docker-compose.yaml`. **Apply this to every Spring Boot service added to the proxy.**

8. **`header_up` is a `reverse_proxy` subdirective** — It cannot be used as a standalone directive inside a Caddy `handle` block. Always nest it: `reverse_proxy upstream { header_up -Origin }`.

9. **HTTPS proxy → browser-facing Keycloak URL must also be HTTPS** — Services accessed via the reverse proxy are served over HTTPS. If `KEYCLOAK_BASE_URL` (or equivalent) still points to `http://localhost:18080`, the browser will refuse the OIDC discovery request (mixed content). Set it to `https://keycloak.{HOST}/auth` instead.

10. **Console is Node.js, not Spring Boot** — OIDC config is in `docker-compose.yaml` env vars (`KEYCLOAK_BASE_URL`, `KEYCLOAK_INTERNAL_BASE_URL`), not in `.console/application.yaml`. Spring Boot gotchas (font 403, CSRF POST, `SERVER_FORWARD_HEADERS_STRATEGY`) do not apply to Console.

11. **Spring Boot `redirectRootUrl` must use proxy URL** — Camunda Spring Boot services configure post-login redirect roots in `application.yaml` (e.g. `camunda.operate.identity.redirectRootUrl`, `camunda.tasklist.identity.redirectRootUrl`). When behind the proxy these must point to the proxy URL (e.g. `https://orchestration.{HOST}/operate`), not `http://localhost:8088`. Otherwise the browser is sent to the non-proxy URL after SSO completes.

12. **Web Modeler WebSocket (Pusher) via proxy** — When `webmodeler.{HOST}` is served over HTTPS, the browser's Pusher client must connect to the proxy host with TLS. Required changes in `docker-compose.yaml`:
    - `web-modeler-webapp`: `CLIENT_PUSHER_HOST: webmodeler.${HOST}`, `CLIENT_PUSHER_PORT: "443"`, `CLIENT_PUSHER_FORCE_TLS: "true"`, `SERVER_URL: https://webmodeler.${HOST}`, `OAUTH2_TOKEN_ISSUER: https://keycloak.${HOST}/auth/realms/camunda-platform`
    - `web-modeler-restapi`: `RESTAPI_SERVER_URL: https://webmodeler.${HOST}`, `RESTAPI_OAUTH2_TOKEN_ISSUER: https://keycloak.${HOST}/auth/realms/camunda-platform` (must match the `iss` claim in tokens issued via the proxy — otherwise restapi rejects every token with 401 and webapp loops back to `/login`)
    - `reverse-proxy`: add `web-modeler` to its networks so Caddy can reach `web-modeler-websockets:8060`
    - `Caddyfile`: add `handle /app/* { reverse_proxy web-modeler-websockets:8060 }` inside the `webmodeler.{HOST}` block

13. **Web Modeler "login has expired" immediately after login** — Chrome 120+ blocks cross-origin JavaScript cookie access in iframes. The OIDC `check_session_iframe` (`login-status-iframe.html`) uses `document.cookie` to read `KEYCLOAK_SESSION` from inside a `webmodeler.{HOST}` page context; Chrome blocks this, the iframe returns "error", oidc-client-ts fires a `prompt=none` silent check, and Keycloak returns `login_required` — clearing the token. Fix: intercept `login-status-iframe.html` in the `keycloak.{HOST}` Caddyfile block and return a mock that always responds "unchanged" to postMessages. The real session check never fires; token expiry still works via JWT `exp` claim.

14. **`$HOST` is read-only in PowerShell** — PowerShell has a built-in automatic variable `$HOST` (the console host object). Never use `$HOST` as a variable name in `.ps1` scripts; use `$EnvHost` or similar instead.

15. **`setup-host` must run as Administrator on Windows** — The script writes to `C:\Windows\System32\drivers\etc\hosts`, which requires elevation. Without it the Caddyfile update still succeeds but the hosts file update fails with "Access to the path is denied". Run PowerShell as Administrator before executing the script.

16. **`setup-host` is idempotent for TLS injection** — The scripts strip all existing `tls /...` lines before inserting new ones, so re-running never stacks duplicate `tls` directives. The TLS regex only matches top-level site block headers (lines without leading whitespace) — nested blocks (`@options`, `handle`, `reverse_proxy`) are not affected.

17. **Dashboard links are driven by Caddy templates** — `dashboard/index.html` uses `{{env "HOST"}}` template expressions rendered by Caddy's `templates` directive. Links and URL labels in the dashboard adapt automatically to whatever `HOST` is set to — no manual editing needed when changing the hostname.

18. **`certs/` is gitignored** — TLS certificate files placed in `certs/` are never committed. The folder is mounted read-only into the Caddy container at `/certs`. Always use container-internal paths (e.g. `/certs/cert.pem`) in `FULLCHAIN_PEM`/`PRIVATEKEY_PEM` in `.env`.

19. **`HOST` must be lowercase** — Browsers normalize domain names to lowercase in HTTP Host headers. Services (Node.js in particular) derive their OIDC `redirect_uri` from the incoming `Host` header, so the URI they send to Keycloak is always lowercase. Keycloak validates redirect URIs with case-sensitive string matching. If `HOST=Camunda.Dev.Local` (uppercase), the registered URI is `https://console.Camunda.Dev.Local/` but the browser's request produces `https://console.camunda.dev.local/` — mismatch → "Invalid parameter: redirect_uri". Always set `HOST` to lowercase (e.g. `HOST=camunda.dev.local`). Note: `FULLCHAIN_PEM`/`PRIVATEKEY_PEM` in `.env` are literal file paths to cert files on disk — if those filenames contain uppercase, keep them as-is; only `HOST` itself needs to be lowercase.
