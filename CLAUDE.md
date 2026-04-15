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

**Callback URLs by service:**

| Service | External URL | Callback |
|---------|-------------|----------|
| Orchestration | `http://localhost:8088` | `/sso-callback` |
| Optimize | `http://localhost:8083` | `/api/authentication/callback` |
| Web Modeler | `http://localhost:8070` | `/login-callback` |
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

The cluster configuration (`CAMUNDA_MODELER_CLUSTERS_0_URL_WEBAPP: http://localhost:8088`) points to the local Orchestration UI, not Web Modeler itself, because Web Modeler connects to the Zeebe broker running in orchestration.

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

A Caddy reverse proxy is available to simplify service access via subdomain routing.

**Service:** `reverse-proxy` (caddy:3)

**Purpose:** Proxies `keycloak.localhost:18080` → `keycloak:18080` with proper X-Forwarded headers.

**Key configuration:**
- `Caddyfile` — route definitions
- `KEYCLOAK_PROXY_HEADERS: xforwarded` — tells Keycloak v26+ to trust proxy headers

**Hosts file entry required:**
```
127.0.0.1 keycloak.localhost
```

**Note:** When accessing Keycloak through the proxy, use `keycloak.localhost:18080`. The `KEYCLOAK_HOST` variable remains `keycloak` for internal container-to-container communication.

### Common Gotchas

1. **KEYCLOAK_HOST must be `keycloak` (container name), not `localhost`** — otherwise services inside containers cannot reach Keycloak (they resolve to themselves)

2. **Identity health check tests port 8082** — but container exposes 8084; this works if actuator runs on a different port

3. **web-modeler-restapi has no host port** — accessed via webapp at port 8070

4. **Console uses two Keycloak URLs:** `KEYCLOAK_BASE_URL` (browser) and `KEYCLOAK_INTERNAL_BASE_URL` (service-to-service)
