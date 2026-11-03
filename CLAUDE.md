# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Overview

This is a Camunda 8 Self-Managed Docker Compose distribution for local development. It deploys a full Camunda 8 stack including Zeebe (workflow engine), Operate, Tasklist, Optimize, Identity, Keycloak, Elasticsearch, Connectors, and Camunda Hub (8.10+, replaces Web Modeler and Console).

## Common Commands

### Starting the Environment

```bash
# Start all services with the resource profile from STAGE in .env
bash scripts/start.sh
pwsh -File scripts/start.ps1

# Stop all services
bash scripts/stop.sh
pwsh -File scripts/stop.ps1

# View logs
docker compose logs -f [service-name]
```

On Windows, if `bash` is unavailable or WSL cannot start, use Git Bash from `C:\Program Files\Git\git-bash.exe` to run repository Bash scripts.

### Cluster Changes

Do not write automated tests for cluster changes in this repository. Cluster-related changes should be validated through Docker Compose configuration checks and manual runtime verification instead.

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
| `camunda-platform` | orchestration, connectors, optimize, elasticsearch, keycloak, identity, hub* |
| `identity-network` | keycloak, identity, postgres |
| `web-modeler` | web-modeler-db, mailpit, hub, hub-websockets |

*hub is dual-homed on both `web-modeler` and `camunda-platform` to reach orchestration and identity. The network keeps its `web-modeler` name for compatibility.

Container names serve as DNS hostnames within networks. E.g., `keycloak:18080`, `identity:8084`, `orchestration:8080`.

### OIDC Authentication Flow

1. Browser requests `http://localhost:8088` (or other service UI)
2. Service redirects to Keycloak authorization endpoint using `${HOST}` → `https://keycloak.${HOST}/auth/realms/...`
3. User authenticates at Keycloak (browser ↔ Keycloak direct)
4. Keycloak redirects back to service callback URL (e.g., `http://localhost:8088/sso-callback`)
5. Service exchanges auth code for token using `${KEYCLOAK_HOST}` → `http://keycloak:18080/auth/realms/...`

**Callback URLs by service** (`{HOST}` = value of `HOST` in `.env`):

| Service | External URL | Callback |
|---------|-------------|----------|
| Orchestration | `https://orchestration.{HOST}` | `/sso-callback` |
| Optimize | `https://optimize.{HOST}` | `/api/authentication/callback` |
| Camunda Hub | `https://webmodeler.{HOST}` | `/login-callback` |

### Exposed Ports

Direct service ports are bound to `127.0.0.1` for local diagnostics and scripts only. Browser/user access should use the HTTPS Caddy subdomains on port 443.

| Service | Host Port | Container Port | Notes |
|---------|----------|----------------|-------|
| orchestration | 127.0.0.1:26500, 127.0.0.1:9600, **127.0.0.1:8088** | 26500, 9600, 8080 | Zeebe gRPC, actuator, Operate/Tasklist UI |
| connectors | **127.0.0.1:8086** | 8080 | |
| optimize | **127.0.0.1:8083** | 8090 | |
| identity | **127.0.0.1:8084** | 8084 | |
| keycloak | (internal) | 18080 | Admin UI + OIDC via `https://keycloak.{HOST}/auth/` |
| elasticsearch | **127.0.0.1:9200**, 127.0.0.1:9300 | 9200, 9300 | Local backup/restore and diagnostics only |
| hub | **127.0.0.1:8070** | 8081 | Serves Hub UI + API; management/health on container port 8091 (not published) |
| hub-websockets | **127.0.0.1:8060** | 8060 | Pusher-compatible WebSocket server |
| mailpit | 127.0.0.1:1025, 127.0.0.1:8075 | 1025, 8025 | Local SMTP/UI diagnostics |

When adding a new service, publish host ports only if a host-side script or local diagnostic workflow needs them. Bind such ports to `127.0.0.1`. Public user-facing access should be routed through Caddy on port 443.

Elasticsearch requires Basic Auth on port `9200`. Direct access is bound to `127.0.0.1` for backup/restore scripts and diagnostics only. Do not expose `9200` on LAN interfaces.

### Camunda Hub Architecture

Camunda Hub (8.10+) replaces both Web Modeler and Console. Two containers:

- **hub** (Java/Spring Boot; host port 8070, container port 8081) — browser-facing UI/API, reaches identity, orchestration, mailpit, and hub-websockets. Reuses the Web Modeler database (`web-modeler-db`) and migrates it in place with Flyway on first 8.10 start (not backwards compatible — back up first).
- **hub-websockets** (PHP/Laravel Reverb; port 8060) — Pusher-compatible push notifications for the webapp

Hub keeps the `webmodeler.{HOST}` proxy hostname and the `web-modeler` Keycloak client ID so existing redirect URIs stay valid. `console.{HOST}` only redirects to `webmodeler.{HOST}` (its `/health` proxies Hub for the dashboard LED).

Cluster registration (formerly the Console config) lives in `.hub/application.yaml`: it lists the clusters and components Hub deploys to and shows in its cluster overview.

### Configuration Files

- `.env` — **Committed.** Image versions, Camunda image source (`CAMUNDA_IMAGE_NAMESPACE`), `${HOST}`, `${KEYCLOAK_HOST}`, `${STAGE}`, banner / backup / TLS paths, feature flags, mail address, registry URL. **No secrets.**
- `.env-credentials` — **Gitignored, never commit.** Every credential: OIDC client IDs and secrets, database names / users / passwords, Keycloak admin, Pusher keys, `ELASTIC_PASSWORD`, registry credentials, Camunda license key. Generated by `scripts/generate-secrets.sh` / `.ps1` (chmod 600 / restricted ACL on Windows).
- `.env.example` — Template for `.env` (non-credential defaults).
- `.env-credentials.example` — Template for `.env-credentials` (demo credential values).
- Docker Compose loads both files: `start.sh` / `start.ps1` pass `--env-file .env --env-file .env-credentials` (so `${VAR}` interpolation in `docker-compose.yaml` works), and the credential-relevant services additionally have `env_file: - path: .env-credentials / required: true` in `docker-compose.yaml` so container environments also receive the values. `env_file` does not satisfy Compose-time interpolation; direct Compose commands must pass both `--env-file` flags.
- `.orchestration/application.yaml` — Orchestration (Zeebe) config
- `.connectors/application.yaml` — Connectors config
- `.identity/application.yaml` — Identity + Keycloak realm/client setup
- `.optimize/environment-config.yaml.example` — Optimize config **template** (rendered at startup)
- `.hub/application.yaml` — Hub cluster registration (mounted directly; Spring resolves `${...}` from the container environment, no render step)
- `.hub/application-ai.yaml` — optional Hub AI/Copilot config, toggled via `HUB_AI_ENABLED` in `.env`
- `connector-secrets.txt` — Connectors secrets (mounted as env_file)
- `stages/` — Stage-specific Docker Compose resource profiles (`prod`, `dev`, `test`) merged on top of `docker-compose.yaml` by the start scripts

**Rendered configs:** `start.sh` and `start.ps1` generate `.optimize/environment-config.yaml` (from `.example`) before `docker compose up`. The file is gitignored and overwritten on every start so that changes to `.env` (`HOST`, `ELASTIC_PASSWORD`) are picked up automatically. **When editing Optimize configuration, update the template file, not the rendered output.**

### Environment Stages

Use `scripts/start.sh` or `scripts/start.ps1` instead of direct `docker compose up` when starting the stack. The scripts read `STAGE` from `.env`, normalize it case-insensitively, validate `prod|dev|test`, and run Docker Compose with the matching `stages/<stage>.yaml` file.

Use `scripts/stop.sh` or `scripts/stop.ps1` for the matching shutdown command.

### Display Stage Override

`STAGE` selects the resource profile (`prod|dev|test`); `DISPLAY_STAGE` (optional, in `.env`) overrides only the label shown on the dashboard badge / page title and the Camunda Hub cluster tag. If `DISPLAY_STAGE` is unset, both surfaces fall back to `STAGE` (so default behavior is unchanged). Use it to run, for example, the `dev` profile while displaying `TEST` to users:

```
STAGE=DEV
DISPLAY_STAGE=TEST
```

The dashboard fallback is evaluated by Caddy at request time (`{{ or (env "DISPLAY_STAGE") (env "STAGE") }}`); the Hub fallback is computed by the start scripts, exported as `DISPLAY_STAGE`, and passed to the `hub` container as `HUB_CLUSTER_TAG` (used by `.hub/application.yaml`). Casing is preserved as-entered for `DISPLAY_STAGE`; the `STAGE` fallback path keeps its today-lowercased value.

### Reverse Proxy

A Caddy reverse proxy provides subdomain routing on standard HTTPS port 443.

**Service:** `reverse-proxy` (`caddy:2.11.2`, digest-pinned)

**Working services** (replace `{HOST}` with the value of `HOST` in `.env`):
- `https://keycloak.{HOST}/auth/` — Keycloak admin and OIDC
- `https://identity.{HOST}/` — Identity UI
- `https://console.{HOST}/` — legacy hostname, redirects to Camunda Hub
- `https://orchestration.{HOST}/` — Operate and Tasklist UIs
- `https://optimize.{HOST}/` — Optimize UI
- `https://webmodeler.{HOST}/` — Camunda Hub UI (with WebSocket/Pusher support)
- `https://zeebe.{HOST}/` — Zeebe gRPC gateway (h2c via Caddy)
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
127.0.0.1 zeebe.{HOST}
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
| optimize | `https://optimize.{HOST}/api/authentication/callback` |
| web-modeler (Hub) | `https://webmodeler.{HOST}/login-callback` |

## Git Conventions

- **Never add `Co-Authored-By` lines to commit messages.**

### Common Gotchas

1. **KEYCLOAK_HOST must be `keycloak` (container name), not `localhost`** — otherwise services inside containers cannot reach Keycloak (they resolve to themselves)

2. **Identity health check tests port 8082** — but container exposes 8084; this works if actuator runs on a different port

3. **Hub health is on port 8091, not 8081** — the compose healthcheck and the Caddy `/health` handlers use `hub:8091/health/readiness`; port 8081 serves only UI/API.

4. **Hub uses two Keycloak URLs:** `RESTAPI_OAUTH2_TOKEN_ISSUER` (public `https://keycloak.${HOST}/...`, must match the token `iss` claim) and `RESTAPI_OAUTH2_TOKEN_ISSUER_BACKEND_URL` (internal `http://keycloak:18080/...` for discovery/JWKS). These legacy `RESTAPI_OAUTH2_*` keys are translated to `camunda.security.authentication.oidc.*` at startup and must be migrated before 8.11.

5. **Keycloak client redirect URIs are configured automatically** — `.identity/application.yaml` defines all redirect URIs with `${HOST}` interpolation. Identity applies them on first startup. If you change `HOST` after Keycloak data already exists, wipe the Keycloak/Identity database volumes and restart.

6. **Spring Boot font/static asset 403 via proxy** — CSS `@font-face` triggers `sec-fetch-mode: cors`, causing Spring Security to reject `/static/media/*.woff*` because `Origin: https://service.localhost` doesn't match the backend's own URL. Fix: strip the Origin header for static paths using `header_up -Origin` inside the `reverse_proxy` block (see Caddyfile template above).

7. **Spring Boot POST 403 via proxy (CSRF Origin check)** — Spring Security validates that the `Origin` header on POST/PUT/DELETE matches the server's own URL. Behind Caddy this fails unless you add `SERVER_FORWARD_HEADERS_STRATEGY: framework` to the service's environment in `docker-compose.yaml`. **Apply this to every Spring Boot service added to the proxy.**

8. **`elastic-backup` is intentionally persistent across restore runs** — it uses a fixed Docker `name:` rather than a compose-prefixed managed volume. Restore overwrites its contents from the selected backup, but does not remove the volume itself.

9. **`header_up` is a `reverse_proxy` subdirective** — It cannot be used as a standalone directive inside a Caddy `handle` block. Always nest it: `reverse_proxy upstream { header_up -Origin }`.

10. **HTTPS proxy → browser-facing Keycloak URL must also be HTTPS** — Services accessed via the reverse proxy are served over HTTPS. If `KEYCLOAK_BASE_URL` (or equivalent) still points to an `http://...` browser-facing Keycloak URL, the browser will refuse the OIDC discovery request (mixed content). Set it to `https://keycloak.{HOST}/auth` instead.

11. **No Node.js runtime in the stack** — Since 8.10 the former Node.js Console is gone; Hub is Java/Spring Boot (so the Spring Boot proxy gotchas apply, and `SERVER_FORWARD_HEADERS_STRATEGY: framework` is set on `hub`), and hub-websockets is PHP/Laravel. The dashboard is static HTML served by Caddy (Go). A filesystem scan of all compose images on 2026-10-30 found no `node` binary or `node_modules`, so Node.js security releases do not affect this stack as long as that holds — re-check after adding or upgrading images.

12. **Spring Boot `redirectRootUrl` must use proxy URL** — Camunda Spring Boot services configure post-login redirect roots in `application.yaml` (e.g. `camunda.operate.identity.redirectRootUrl`, `camunda.tasklist.identity.redirectRootUrl`). When behind the proxy these must point to the proxy URL (e.g. `https://orchestration.{HOST}/operate`), not `http://localhost:8088`. Otherwise the browser is sent to the non-proxy URL after SSO completes.

12. **Hub WebSocket (Pusher) via proxy** — When `webmodeler.{HOST}` is served over HTTPS, the browser's Pusher client must connect to the proxy host with TLS. Required settings:
    - `hub`: `CLIENT_PUSHER_HOST: webmodeler.${HOST}`, `CLIENT_PUSHER_PORT: "443"`, `CLIENT_PUSHER_FORCE_TLS: "true"`, `RESTAPI_SERVER_URL: https://webmodeler.${HOST}`, `OAUTH2_TOKEN_ISSUER: https://keycloak.${HOST}/auth/realms/camunda-platform`
    - `hub`: `RESTAPI_OAUTH2_TOKEN_ISSUER: https://keycloak.${HOST}/auth/realms/camunda-platform` (must match the `iss` claim in tokens issued via the proxy — otherwise Hub rejects every token with 401 and the webapp loops back to `/login`)
    - `reverse-proxy`: member of the `web-modeler` network so Caddy can reach `hub-websockets:8060`
    - `Caddyfile`: `handle /app/* { reverse_proxy hub-websockets:8060 }` inside the `webmodeler.{HOST}` block

13. **Hub "login has expired" immediately after login** — Chrome 120+ blocks cross-origin JavaScript cookie access in iframes. The OIDC `check_session_iframe` (`login-status-iframe.html`) uses `document.cookie` to read `KEYCLOAK_SESSION` from inside a `webmodeler.{HOST}` page context; Chrome blocks this, the iframe returns "error", oidc-client-ts fires a `prompt=none` silent check, and Keycloak returns `login_required` — clearing the token. Fix: intercept `login-status-iframe.html` in the `keycloak.{HOST}` Caddyfile block and return a mock that always responds "unchanged" to postMessages. The real session check never fires; token expiry still works via JWT `exp` claim.

14. **`$HOST` is read-only in PowerShell** — PowerShell has a built-in automatic variable `$HOST` (the console host object). Never use `$HOST` as a variable name in `.ps1` scripts; use `$EnvHost` or similar instead.

15. **`setup-host` must run as Administrator on Windows** — The script writes to `C:\Windows\System32\drivers\etc\hosts`, which requires elevation. Without it the Caddyfile update still succeeds but the hosts file update fails with "Access to the path is denied". Run PowerShell as Administrator before executing the script.

16. **`setup-host` is idempotent for TLS injection** — The scripts strip all existing `tls /...` lines before inserting new ones, so re-running never stacks duplicate `tls` directives. The TLS regex only matches top-level site block headers (lines without leading whitespace) — nested blocks (`@options`, `handle`, `reverse_proxy`) are not affected.

17. **Dashboard links are driven by Caddy templates** — `dashboard/index.html` uses `{{env "HOST"}}` template expressions rendered by Caddy's `templates` directive. Links and URL labels in the dashboard adapt automatically to whatever `HOST` is set to — no manual editing needed when changing the hostname.

18. **`certs/` is gitignored** — TLS certificate files placed in `certs/` are never committed. The folder is mounted read-only into the Caddy container at `/certs`. Always use container-internal paths (e.g. `/certs/cert.pem`) in `FULLCHAIN_PEM`/`PRIVATEKEY_PEM` in `.env`.

19. **`HOST` must be lowercase** — Browsers normalize domain names to lowercase in HTTP Host headers. Services (Node.js in particular) derive their OIDC `redirect_uri` from the incoming `Host` header, so the URI they send to Keycloak is always lowercase. Keycloak validates redirect URIs with case-sensitive string matching. If `HOST=Camunda.Dev.Local` (uppercase), the registered URI is `https://webmodeler.Camunda.Dev.Local/login-callback` but the browser's request produces `https://webmodeler.camunda.dev.local/login-callback` — mismatch → "Invalid parameter: redirect_uri". Always set `HOST` to lowercase (e.g. `HOST=camunda.dev.local`). Note: `FULLCHAIN_PEM`/`PRIVATEKEY_PEM` in `.env` are literal file paths to cert files on disk — if those filenames contain uppercase, keep them as-is; only `HOST` itself needs to be lowercase.

20. **Retention is two-tier and intentional** — Orchestration components (Zeebe exporter, Camunda exporter history, Operate archiver, Tasklist archiver in `.orchestration/application.yaml`) keep data for **90 days**; Optimize (`historyCleanup.ttl` in `.optimize/environment-config.yaml`) keeps it for **365 days (P365D)**. Do not "harmonize" them — orchestration data serves operational troubleshooting (instance history, incidents) where 90 days is sufficient, while Optimize stores aggregated analytical data needed for quarterly comparisons and year-over-year trend reports. Aggregated Optimize data is small, so the longer window has negligible disk impact at low process volumes (≤10,000 instances/year stays well under 1 GB).

21. **ILM/retention changes only affect new indices** — Updating `minimumAge` or `ttl` does not retroactively delete existing indices on the next restart. ILM policies are applied to index *templates*; existing indices keep their original policy until rolled over or recreated. To force cleanup in a dev environment, use the Elasticsearch Delete Index API directly. Don't expect `docker compose restart` to immediately reduce disk usage after a retention change.

22. **Do not expose `/actuator/configprops`** — Runtime services receive OAuth client secrets, database passwords, Keycloak admin credentials, and connector credentials through environment variables. Keep `configprops` out of `management.endpoints.web.exposure.include`, and never commit `MANAGEMENT_ENDPOINT_CONFIGPROPS_SHOW_VALUES=ALWAYS` or `management.endpoint.configprops.show-values: ALWAYS`. If temporary local debugging needs it, use `show-values: NEVER` and keep access loopback-only.

23. **Edit the template file, not the rendered config** — `.optimize/environment-config.yaml` is generated from `.optimize/environment-config.yaml.example` by the start scripts on every run. Changes made directly to the rendered file are lost on the next start. (`.hub/application.yaml` is not rendered — edit it directly.)

24. **Hub component URLs: `webapp` external, `grpc`/`rest` internal** — In `.hub/application.yaml`, browser-facing `webapp` URLs (Operate, Tasklist, Admin, Optimize, Identity) must use the HTTPS proxy hostnames (`https://orchestration.${HOST}/...`). The `orchestration` component's `grpc`/`rest` URLs are used by Hub itself for deployments and stay on internal Docker DNS (`grpc://orchestration:26500`, `http://orchestration:8080`). `readiness` URLs are internal too.

25. **Hub component types changed in 8.10** — Component types `console` and `keycloak` are invalid and make Hub fail on startup. The former Console `orchestrationIdentity` component is now `type: admin` (Admin card, pointing to `https://orchestration.${HOST}/admin`). The cluster `version` must be full SemVer (`${CAMUNDA_VERSION}`), not an image tag like `8.10-rc1`.

26. **Optimize logs `No Zeebe index with alias zeebe-record-* found` every 30s on a quiet cluster** — Optimize's import scheduler polls `zeebe-record-{process,process-instance,incident,user-task,variable}` aliases every 30s. The Zeebe ES exporter (`.orchestration/application.yaml`, `camunda.data.exporters.elasticsearch`) only creates these indices on the first record write — i.e. the first time a workflow is deployed/executed. Until then, every poll cycle emits five WARNs. Same root cause: opening an Optimize report against an empty cluster logs `Could not calculate minMaxStats … process-instance does not exist` and `Could not evaluate report. Returning empty result instead`. Both go away as soon as any workflow runs. Not a misconfiguration — confirmed via orchestration logs (`Exporter opened` for `io.camunda.zeebe.broker.exporter.elasticsearch`) and ES index listing (only `optimize-*` indices present, no `zeebe-record-*`). Don't try to silence it via logback — once data exists, future warnings would be legitimate.

27. **Camunda image source is a `.env` namespace, not a script flag** — The seven Camunda images (`camunda`, `connectors-bundle`, `identity`, `optimize`, `hub`, `hub-websockets`, `keycloak`) use `${CAMUNDA_IMAGE_NAMESPACE:-camunda}/<image>` in `docker-compose.yaml`. `CAMUNDA_IMAGE_NAMESPACE=registry.camunda.cloud/dockerhub-camunda/camunda` pulls them from Camunda's public Harbor proxy cache of Docker Hub (anonymous pull, digests identical to Docker Hub — verified 2026-11-03 for all 8.10 tags); commenting it out switches back to Docker Hub. Keep it a plain Compose-interpolated value: a boolean derived in `start.sh` / `start.ps1` (like `DISPLAY_STAGE`) would not be seen by `restore`, direct `docker compose` calls and other scripts, which would then recreate containers from the other registry. Hotfix overrides (`CAMUNDA_IMAGE`, `HUB_IMAGE`, …) are full image names and win over the namespace. Postgres, Elasticsearch, Mailpit, Caddy and Autoheal are unaffected. When adding a new Camunda image, use the same namespace pattern.

28. **Connectors only read `.connectors/application.yaml` via `SPRING_CONFIG_ADDITIONAL_LOCATION`** — The `connectors-bundle` image runs from working dir `/` with the app in `/opt/app`, so Spring never picks up the mount at `/app/application.yaml` by itself; `docker-compose.yaml` sets `SPRING_CONFIG_ADDITIONAL_LOCATION: file:/app/application.yaml`. Without it the runtime falls back to secret prefix `SECRET_` and every `{{secrets.X}}` fails with `Secret with name 'X' is not available`. The prefix needs its trailing underscore (`CONNECTORS_SECRET_`): the runtime builds `prefix + name` without a separator. Verify the effective prefix with `LOGGING_LEVEL_IO_CAMUNDA_CONNECTOR_RUNTIME_SECRET=DEBUG` (log line `Prefix '…' has been configured`). After changing the mounted file, recreate the container (`up -d --force-recreate connectors`); Compose does not detect content changes of bind-mounted files.

29. **New Keycloak clients and default roles also reach existing installs** — Identity applies new `component-presets` applications from `.identity/application.yaml` to an existing realm when it restarts, and Orchestration assigns new `camunda.security.initialization.defaultRoles` members on restart (both verified 2026-11-03 with the `c8ctl` client: baseline install without it, then restart with it → client created, `admin` role effective for deploy/start/jobs). A new client secret is a new **required** variable in `.env-credentials`, which `generate-secrets.*` only writes for fresh installs: existing installs must append it once (`echo "C8CTL_CLIENT_SECRET=$(openssl rand -hex 24)" >> .env-credentials`) or Compose stops with `… is required`. Document that step whenever a credential is added.
