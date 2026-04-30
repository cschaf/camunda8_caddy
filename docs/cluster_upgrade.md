# Camunda 8.8 to Current 8.9 Cluster Upgrade Guide

This guide documents what changed when this Docker Compose project moved from Camunda 8.8 to the current Camunda 8.9 stack. It is written for this repository's current state, not as a generic upstream upgrade guide.

Current target in this project:

- Camunda Platform: `8.9.1`
- Console: `8.9.26`
- Elasticsearch: `8.19.11`
- Keycloak: `26.3.2`
- PostgreSQL: `15-alpine3.22`

The largest functional change is that the current stack uses Camunda 8.9 unified Orchestration with PostgreSQL/RDBMS secondary storage for Operate, Tasklist, authorizations, and query data. Elasticsearch is still present, but mainly for Optimize and exported `zeebe-record-*` data.

## Upgrade Scope

The upgrade touches these project areas:

- image versions in `.env.example` and local `.env`
- Orchestration runtime config in `.orchestration/application.yaml`
- Docker service layout in `docker-compose.yaml`
- generated Console config template in `.console/application.yaml.template`
- Optimize config template in `.optimize/environment-config.yaml.example`
- stage overlays in `stages/prod.yaml`, `stages/dev.yaml`, and `stages/test.yaml`
- Caddy routing in `Caddyfile.example` and local `Caddyfile`
- backup and restore behavior because Camunda core query data now lives in `camunda-db`

## Pre-Upgrade Checklist

1. Confirm the existing 8.8 stack is healthy:

```powershell
docker compose ps
```

2. Create a full cold backup:

```powershell
.\scripts\backup.ps1
```

Linux/macOS/WSL equivalent:

```bash
./scripts/backup.sh
```

3. Verify the backup:

```powershell
.\scripts\restore.ps1 --verify backups\<backup-folder>
```

4. Keep a separate copy of local-only files before replacing or merging project files:

- `.env`
- `connector-secrets.txt`
- `Caddyfile`
- `certs/`
- `.orchestration/application.yaml`
- `.identity/application.yaml`
- `.connectors/application.yaml`
- `.optimize/environment-config.yaml`
- `.console/application.yaml`
- the newest folder under `backups/`

Do not rely on copying the project directory alone. Docker named volumes contain the running databases and Zeebe state; they are not inside the repository folder.

## Version Changes

Update `.env.example` and the local `.env`.

| Component | 8.8 value used before | Current 8.9 value | Project variable |
|---|---:|---:|---|
| Orchestration / Zeebe / Operate / Tasklist / Admin | `8.8.21` | `8.9.1` | `CAMUNDA_VERSION` |
| Connectors | `8.8.10` | `8.9.1` | `CAMUNDA_CONNECTORS_VERSION` |
| Identity | `8.8.10` | `8.9.1` | `CAMUNDA_IDENTITY_VERSION` |
| Operate display value | `8.8.21` | `8.9.1` | `CAMUNDA_OPERATE_VERSION` |
| Tasklist display value | `8.8.21` | `8.9.1` | `CAMUNDA_TASKLIST_VERSION` |
| Optimize | `8.8.8` | `8.9.1` | `CAMUNDA_OPTIMIZE_VERSION` |
| Web Modeler | `8.8.12` | `8.9.1` | `CAMUNDA_WEB_MODELER_VERSION` |
| Console | `8.8.133` | `8.9.26` | `CAMUNDA_CONSOLE_VERSION` |
| Elasticsearch | `8.17.10` | `8.19.11` | `ELASTIC_VERSION` |
| Keycloak | `26.3.2` | `26.3.2` | `KEYCLOAK_SERVER_VERSION` |
| Mailpit | `v1.21.8` | `v1.21.8` | `MAILPIT_VERSION` |
| PostgreSQL | `15-alpine3.22` | `15-alpine3.22` | `POSTGRES_VERSION` |

`CAMUNDA_OPERATE_VERSION` and `CAMUNDA_TASKLIST_VERSION` are retained for documentation and Console display alignment. Operate and Tasklist no longer run as separate images in this project; they are part of `camunda/camunda:${CAMUNDA_VERSION}`.

## Orchestration Config Changes

File: `.orchestration/application.yaml`

### Profile Rename

Change the active profile from `identity` to `admin`:

```yaml
spring:
  profiles:
    active: "admin,operate,tasklist,broker,consolidated-auth"
```

The current 8.9 Orchestration container uses the `admin` profile for the built-in identity/admin application area.

### Primary Storage

The Zeebe primary storage directory is pinned to the existing volume path:

```yaml
camunda:
  data:
    primary-storage:
      directory: /usr/local/camunda/data
      snapshot-period: 5m
```

This preserves the existing `orchestration:/usr/local/camunda/data` volume layout.

### Secondary Storage Moves To RDBMS

The current stack uses PostgreSQL for Camunda secondary storage:

```yaml
camunda:
  data:
    secondary-storage:
      type: rdbms
      rdbms:
        url: "jdbc:postgresql://camunda-db:5432/camunda"
        username: "camunda"
        password: "${CAMUNDA_DB_PASSWORD}"
```

This is the important data-model change from the old 8.8-style Elasticsearch/OpenSearch secondary storage setup. Operate, Tasklist, authorizations, and REST query data now use the dedicated `camunda-db` PostgreSQL service.

There is no automatic in-place migration from Elasticsearch/OpenSearch secondary storage to RDBMS secondary storage. Treat this as either:

- a fresh 8.9 secondary-storage setup, or
- a planned migration with a tested restore/validation procedure in a non-production environment.

### Elasticsearch Exporter Is Still Used

The old explicit `CamundaExporter` block is removed, but the current stack still keeps an Elasticsearch exporter under:

```yaml
camunda:
  data:
    exporters:
      elasticsearch:
```

That exporter writes `zeebe-record-*` indices. Optimize imports from those records. Retention is enabled with `minimum-age: 90d`.

### Elasticsearch Database Settings Remain For 8.9 Runtime Needs

The current file still contains:

```yaml
camunda:
  database:
    elasticsearch:
      url: "http://elasticsearch:9200"
      username: "elastic"
      password: "${ELASTIC_PASSWORD}"
```

Do not confuse this with secondary storage. The secondary storage for Operate/Tasklist/query data is `rdbms`; Elasticsearch remains part of the stack for Optimize/exported records.

### Backup, Query, Sessions, MCP, And Authorizations

The current 8.9 config also adds or keeps:

```yaml
camunda:
  backup:
    webapps:
      enabled: false
  persistent:
    sessions:
      enabled: true
  rest:
    query:
      enabled: true
  mcp:
    enabled: true
  security:
    authorizations:
      enabled: true
```

Project-specific reason:

- backups are handled by the repository scripts, not by webapp backup endpoints
- persistent sessions are enabled for the web applications
- REST query and MCP are enabled for 8.9 functionality
- resource authorizations are enabled and connected to `RESOURCE_AUTHORIZATIONS_ENABLED`

## Docker Compose Changes

File: `docker-compose.yaml`

### New `camunda-data-init` Service

The current stack adds a one-shot init service:

```yaml
camunda-data-init:
  image: camunda/camunda:${CAMUNDA_VERSION:?CAMUNDA_VERSION is required}
  user: "0:0"
  entrypoint: ["/bin/sh", "-c", "chown -R 1001:1001 /usr/local/camunda/camunda-data && chmod 775 /usr/local/camunda/camunda-data"]
  volumes:
    - camunda-data:/usr/local/camunda/camunda-data
  restart: "no"
```

It prepares ownership for the new `camunda-data` volume before Orchestration starts.

### Orchestration Depends On `camunda-db`

The current `orchestration` service mounts both persistent volumes:

```yaml
volumes:
  - orchestration:/usr/local/camunda/data
  - camunda-data:/usr/local/camunda/camunda-data
  - "./.orchestration/application.yaml:/usr/local/camunda/config/application.yaml"
```

It depends on:

```yaml
depends_on:
  camunda-data-init:
    condition: service_completed_successfully
  camunda-db:
    condition: service_healthy
```

The old guide incorrectly said the Orchestration dependency was still Elasticsearch. In the current project, `camunda-db` is the critical dependency for RDBMS secondary storage.

### New `camunda-db` PostgreSQL Service

The current stack has a dedicated PostgreSQL service for Camunda core data:

```yaml
camunda-db:
  image: postgres:${POSTGRES_VERSION}
  environment:
    POSTGRES_DB: camunda
    POSTGRES_USER: camunda
    POSTGRES_PASSWORD: ${CAMUNDA_DB_PASSWORD:?CAMUNDA_DB_PASSWORD is required}
  volumes:
    - camunda-db:/var/lib/postgresql/data
```

The required local `.env` values are:

```env
CAMUNDA_DB_NAME=camunda
CAMUNDA_DB_USER=camunda
CAMUNDA_DB_PASSWORD=<strong secret>
```

### Connectors Authentication Variables

The Connectors service keeps the internal issuer URL for realm context and also sets an explicit internal token URL:

```yaml
CAMUNDA_CLIENT_AUTH_ISSUERURL: http://${KEYCLOAK_HOST}:18080/auth/realms/camunda-platform
CAMUNDA_CLIENT_AUTH_TOKENURL: http://${KEYCLOAK_HOST}:18080/auth/realms/camunda-platform/protocol/openid-connect/token
```

The explicit token URL prevents issuer discovery from returning Keycloak's browser-facing HTTPS token endpoint to a Docker-internal machine-to-machine client.

### Web Modeler WebApp Removed

The `web-modeler-webapp` service is removed. In Camunda 8.9, the REST API image serves the Web Modeler UI.

The current project uses:

- `web-modeler-restapi`
- `web-modeler-websockets`
- `web-modeler-db`
- `mailpit`

Client-facing Web Modeler variables now live on `web-modeler-restapi`, including:

- `CLIENT_PUSHER_HOST`
- `CLIENT_PUSHER_PORT`
- `CLIENT_PUSHER_FORCE_TLS`
- `CLIENT_PUSHER_KEY`
- `OAUTH2_CLIENT_ID`
- `OAUTH2_TOKEN_ISSUER`
- `IDENTITY_BASE_URL`

The current REST API service also has:

```yaml
SPRING_SECURITY_OAUTH2_RESOURCESERVER_JWT_ISSUER_URI: https://keycloak.${HOST}/auth/realms/camunda-platform
SPRING_SECURITY_OAUTH2_RESOURCESERVER_JWT_JWK_SET_URI: http://${KEYCLOAK_HOST}:18080/auth/realms/camunda-platform/protocol/openid-connect/certs
LOGGING_LEVEL_IO_CAMUNDA_MODELER: INFO
LOGGING_LEVEL_ORG_HIBERNATE_ORM_CONNECTIONS_POOLING: WARN
SERVER_HTTPS_ONLY: "false"
PLAY_ENABLED: "true"
```

The WebSocket service runs with:

```yaml
APP_DEBUG: "false"
```

### Console Service

Console is updated to:

```yaml
image: camunda/console:${CAMUNDA_CONSOLE_VERSION}
```

The mounted config remains:

```yaml
volumes:
  - "./.console:/var/run/config"
```

But `.console/application.yaml` is generated at startup from `.console/application.yaml.template`. Update the template, not only the generated file.

## Console Config Changes

Source file: `.console/application.yaml.template`

Generated file: `.console/application.yaml`

Current template changes:

- release version is `8.9.1`
- Console component version is `8.9.26`
- Orchestration, Operate, Tasklist, Orchestration Admin, Optimize, Identity, WebModeler, and Connectors show `8.9.1`
- Keycloak display version is `26.3.2`
- WebModeler is a single logical component
- Orchestration endpoints use browser-facing proxy URLs for Console display:

```yaml
urls:
  grpc: "https://zeebe.${HOST}"
  http: "https://orchestration.${HOST}"
```

The rendered `.console/application.yaml` is gitignored and should be regenerated by `scripts/start.ps1` or `scripts/start.sh`.

## Optimize Config Changes

Source file: `.optimize/environment-config.yaml.example`

Generated file: `.optimize/environment-config.yaml`

The current template keeps Optimize on Elasticsearch and uses the Zeebe record prefix:

```yaml
zeebe:
  enabled: true
  name: zeebe-record
  partitionCount: 1
```

It also configures:

- Elasticsearch username `elastic`
- generated Elasticsearch password substitution
- `number_of_shards: 1`
- `number_of_replicas: 0`
- Optimize history cleanup with `ttl: P365D`

The generated `.optimize/environment-config.yaml` contains secrets and is gitignored.

## Stage Overlay Changes

Files:

- `stages/prod.yaml`
- `stages/dev.yaml`
- `stages/test.yaml`

Current stage overlays include resource settings for:

- `camunda-data-init`
- `orchestration`
- `camunda-db`
- `web-modeler-restapi`
- `web-modeler-websockets`
- all existing supporting services

Important resource changes:

- Orchestration receives more memory because it now contains Zeebe, Operate, Tasklist, and Admin.
- `camunda-db` has its own resource limits because it stores Camunda core operational/query data.
- Elasticsearch resources are still required for Optimize and exported records, but not for Operate/Tasklist secondary storage.
- `web-modeler-webapp` should not be part of the current stage overlays because the service was removed from the base Compose file.

## Reverse Proxy Changes

Files:

- `Caddyfile.example`
- local `Caddyfile`

Current routing expects Web Modeler UI traffic to go to `web-modeler-restapi`, not `web-modeler-webapp`.

Keep the route for Web Modeler WebSocket traffic:

```caddy
handle /app/* {
    reverse_proxy web-modeler-websockets:8060
}
```

Also keep the project-specific Caddy workarounds for:

- Keycloak login-status iframe behavior
- Identity cross-origin font requests
- Console 8.9 font URL behavior
- Orchestration 8.9 `Permissions-Policy` browser warnings
- Optimize proxy headers and CSP behavior

## Backup And Restore Changes

The backup system must include the new `camunda-db` data.

Current backup artifacts include:

- `orchestration.tar.gz` for Zeebe primary state
- `camunda.sql.gz` for Camunda core PostgreSQL data
- `keycloak.sql.gz` for Keycloak/Identity data
- `webmodeler.sql.gz` for Web Modeler data
- Elasticsearch snapshot data for Optimize and `zeebe-record-*`
- `configs.tar.gz` for local config files

After the 8.9 RDBMS change, `camunda.sql.gz` is not optional. It contains the Camunda core operational/query database used by Orchestration, Operate, Tasklist, and authorizations.

Run a restore drill after the upgrade:

```powershell
.\scripts\restore-drill.ps1 backups\<backup-folder>
```

## Post-Upgrade Verification

1. Start the stack:

```powershell
.\scripts\start.ps1
```

2. Check all containers:

```powershell
docker compose ps
```

Expected:

- application services are `Up`
- health-checked services become `healthy`
- `camunda-data-init` exits with code `0`

3. Check core logs:

```powershell
docker logs orchestration --tail 120
docker logs camunda-db --tail 80
docker logs identity --tail 120
docker logs optimize --tail 120
docker logs web-modeler-restapi --tail 120
docker logs console --tail 120
```

4. Check health endpoints:

```powershell
curl.exe http://localhost:9600/actuator/health
curl.exe http://localhost:8088/actuator/health/readiness
curl.exe -u "elastic:$env:ELASTIC_PASSWORD" http://localhost:9200/_cluster/health
```

5. Verify browser flows:

- `https://orchestration.${HOST}/operate`
- `https://orchestration.${HOST}/tasklist`
- `https://orchestration.${HOST}/admin`
- `https://identity.${HOST}`
- `https://optimize.${HOST}`
- `https://console.${HOST}`
- `https://webmodeler.${HOST}`

6. Verify data and workflow behavior:

- log in through Keycloak
- deploy a small BPMN process
- start an instance
- verify it appears in Operate
- verify Tasklist opens
- verify Web Modeler opens an existing or new project
- verify Optimize starts and imports data after records exist

7. Create a fresh post-upgrade backup and run a restore drill.

## Rollback Guidance

Rollback from the current 8.9 stack to the old 8.8 stack is not just a branch switch after data has been written.

Because the current 8.9 setup uses RDBMS secondary storage and a dedicated `camunda-db`, use this approach:

1. Stop the current stack.
2. Restore the full pre-upgrade 8.8 backup if you need to go back to 8.8 runtime behavior.
3. Restore the matching 8.8 project files and `.env` version values.
4. Start the old stack.
5. Validate login, Operate, Tasklist, Optimize, Web Modeler, and a process instance.

Do not expect upgraded 8.9 volumes to be safely reusable by an older 8.8 stack.

## Troubleshooting

### Orchestration Fails Because Profile `identity` Is Unknown

Verify `.orchestration/application.yaml` uses:

```yaml
spring:
  profiles:
    active: "admin,operate,tasklist,broker,consolidated-auth"
```

### Secondary Storage Is Missing Or Misconfigured

Verify `.orchestration/application.yaml` uses RDBMS secondary storage:

```yaml
camunda:
  data:
    secondary-storage:
      type: rdbms
      rdbms:
        url: "jdbc:postgresql://camunda-db:5432/camunda"
        username: "camunda"
        password: "${CAMUNDA_DB_PASSWORD}"
```

Also verify `camunda-db` is running and healthy.

### Connectors Cannot Authenticate

Verify `docker-compose.yaml` uses:

```yaml
CAMUNDA_CLIENT_AUTH_ISSUERURL: http://${KEYCLOAK_HOST}:18080/auth/realms/camunda-platform
```

and does not use the old `CAMUNDA_CLIENT_AUTH_TOKENURL`.

### Web Modeler Route Fails

Verify Caddy proxies normal Web Modeler traffic to `web-modeler-restapi`, and WebSocket `/app/*` traffic to `web-modeler-websockets`.

Also verify `docker-compose.yaml` does not reference the removed `web-modeler-webapp` service.

### Console Shows Old Component Versions

Update `.console/application.yaml.template`, then restart with the project start script so `.console/application.yaml` is regenerated.

### Optimize Cannot Connect To Elasticsearch

Verify:

- `ELASTIC_PASSWORD` is present in `.env`
- `.optimize/environment-config.yaml` was regenerated from `.optimize/environment-config.yaml.example`
- Elasticsearch is healthy
- Optimize logs do not show authentication failures

### Zeebe Data Directory Problems

Verify:

```yaml
camunda:
  data:
    primary-storage:
      directory: /usr/local/camunda/data
```

and:

```yaml
volumes:
  - orchestration:/usr/local/camunda/data
```

Also verify `camunda-data-init` completed successfully.

## Summary Of Changed Files

| File | Required 8.9 change |
|---|---|
| `.env` | Update local image versions and add/keep `CAMUNDA_DB_*`, `RESOURCE_AUTHORIZATIONS_ENABLED`, and generated secrets |
| `.env.example` | Document current 8.9 image versions and required variables |
| `.orchestration/application.yaml` | Use `admin` profile, RDBMS secondary storage, primary storage path, Elasticsearch exporter, persistent sessions, REST query, MCP, and authorizations |
| `docker-compose.yaml` | Add `camunda-data-init`, `camunda-data`, `camunda-db`; wire Orchestration to `camunda-db`; remove `web-modeler-webapp`; move Web Modeler client variables to `web-modeler-restapi`; update Connectors issuer URL |
| `.console/application.yaml.template` | Set current 8.9 component display versions and merged WebModeler component; generated `.console/application.yaml` is not the source of truth |
| `.optimize/environment-config.yaml.example` | Keep Optimize on Elasticsearch with generated password placeholder, shard settings, Zeebe record import, and history cleanup |
| `stages/prod.yaml` | Add/update resources for `camunda-data-init`, `camunda-db`, unified Orchestration, and current Web Modeler services |
| `stages/dev.yaml` | Same service/resource alignment for development sizing |
| `stages/test.yaml` | Same service/resource alignment for test sizing |
| `Caddyfile.example` and `Caddyfile` | Route Web Modeler through `web-modeler-restapi`, keep WebSocket route, and preserve 8.9 proxy workarounds |
| `scripts/backup.*` and `scripts/restore.*` | Include `camunda.sql.gz`, validate manifests, restore `camunda-db`, and keep Elasticsearch snapshot handling for Optimize/exported records |
