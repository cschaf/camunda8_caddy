# Camunda 8.8 to 8.9 Cluster Upgrade Guide

This guide documents the upgrade procedure for the Camunda Compose NVL Docker Compose stack from Camunda 8.8 to 8.9. It covers all configuration changes, the rationale behind each change, and step-by-step verification procedures.

---

## Table of Contents

1. [Prerequisites](#prerequisites)
2. [Pre-Upgrade Checklist](#pre-upgrade-checklist)
3. [Version Changes](#version-changes)
4. [Orchestration Configuration Changes](#orchestration-configuration-changes)
5. [Docker Compose Changes](#docker-compose-changes)
6. [Console Configuration Changes](#console-configuration-changes)
7. [Stage Profile Changes](#stage-profile-changes)
8. [Post-Upgrade Verification](#post-upgrade-verification)
9. [Rollback Procedure](#rollback-procedure)
10. [Troubleshooting](#troubleshooting)

---

## Prerequisites

- Current stack running Camunda 8.8.x
- `docker` and `docker compose` CLI available
- Git access to switch branches
- Sufficient disk space for new images (approximately 2-3 GB)
- Backup completed and verified

---

## Pre-Upgrade Checklist

### 1. Verify Current Stack Health

Before starting the upgrade, confirm all services are healthy:

```bash
docker compose ps
```

Expected output: All services should show `Up` and `healthy`.

### 2. Create a Full Backup

Run the backup script to preserve all data:

```bash
bash scripts/backup.sh
```

This creates snapshots of:
- Elasticsearch data and indices
- PostgreSQL databases (Keycloak, Web Modeler)
- Zeebe broker data

### 3. Verify Backup Integrity

Check that backup files exist in the `backups/` directory and have non-zero size:

```bash
ls -lah backups/
```

### 4. Review This Guide

Read through the entire guide before proceeding. Do not skip steps.

---

## Version Changes

### File: `.env` and `.env.example`

All Camunda component images are upgraded from 8.8.x to 8.9.x. Elasticsearch is also bumped to maintain compatibility.

| Component | Old Version | New Version | Notes |
|-----------|-------------|-------------|-------|
| Camunda (Orchestration) | 8.8.21 | 8.9.1 | Unified Zeebe + Operate + Tasklist image |
| Connectors | 8.8.10 | 8.9.1 | Connectors runtime bundle |
| Identity | 8.8.10 | 8.9.1 | Identity management service |
| Operate | 8.8.21 | 8.9.1 | Now part of unified orchestration image |
| Tasklist | 8.8.21 | 8.9.1 | Now part of unified orchestration image |
| Optimize | 8.8.8 | 8.9.1 | Process analytics |
| Web Modeler | 8.8.12 | 8.9.1 | Both restapi and webapp components |
| Console | 8.8.133 | 8.9.26 | Management console |
| Elasticsearch | 8.17.10 | 8.19.11 | Search and analytics engine |
| Keycloak | 26.3.2 | 26.3.2 | No change |
| Mailpit | v1.21.8 | v1.21.8 | No change |
| PostgreSQL | 15-alpine3.22 | 15-alpine3.22 | No change |

**Why these versions?** The upstream Camunda 8.9 docker-compose distribution uses these versions. All Camunda patch versions are aligned to 8.9.1 for consistency. Elasticsearch 8.19.11 is the version tested and validated against Camunda 8.9.

---

## Orchestration Configuration Changes

### File: `.orchestration/application.yaml`

#### 1. Spring Profile Rename: `identity` → `admin`

**Change:**
```yaml
# Before
spring:
  profiles:
    active: "identity,operate,tasklist,broker,consolidated-auth"

# After
spring:
  profiles:
    active: "admin,operate,tasklist,broker,consolidated-auth"
```

**Explanation:** In Camunda 8.9, the `identity` profile is renamed to `admin`. This profile controls the management/identity features within the orchestration container. Using the old profile name will cause the application to fail to load identity-related beans.

#### 2. Unified Secondary Storage Configuration

**Change:**
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

**Explanation:** This stack uses Camunda 8.9 unified configuration with PostgreSQL as RDBMS secondary storage for Operate, Tasklist, authorizations, and API query data. Elasticsearch is still retained for Optimize and for `zeebe-record-*` indices that Optimize imports, but it is no longer the secondary-storage backend for Operate/Tasklist.

> **Can I migrate existing data from Elasticsearch/OpenSearch secondary storage to RDBMS?** Camunda 8.9 does **not** provide an automatic in-place migration path between secondary-storage backend families. Switching `camunda.data.secondary-storage.type` to `rdbms` makes Operate/Tasklist/API query data come from PostgreSQL; historical data that exists only in Elasticsearch/OpenSearch is not automatically moved. Validate this as a fresh secondary-store setup or a planned migration procedure in a non-production environment.

#### 3. Backup Webapps Setting

**Change:**
```yaml
camunda:
  backup:
    webapps:
      enabled: false
```

**Explanation:** This disables the web application backup feature. In a Docker Compose local development setup, external backup orchestration is not needed. The backup scripts in `scripts/backup.sh` handle backups at the infrastructure level.

#### 4. MCP Support

**Change:**
```yaml
camunda:
  mcp:
    enabled: true
```

**Explanation:** MCP (Model Context Protocol) is a new feature in Camunda 8.9 that enables AI-driven assistance and context-aware tooling. Enabling it makes the feature available without impacting existing functionality.

#### 5. Removal of CamundaExporter

**Change:** The `CamundaExporter` block under `zeebe.broker.exporters` is removed.

**Explanation:** In Camunda 8.8, the `CamundaExporter` was responsible for exporting process data to Elasticsearch for the unified Camunda API. In 8.9, this functionality is integrated into the core platform and controlled via `camunda.data.secondary-storage`. The explicit `CamundaExporter` configuration is no longer needed. The Elasticsearch exporter for `zeebe-record-*` is retained because Optimize imports from those records.

#### 6. Primary Storage Data Directory

**Change:**
```yaml
camunda:
  data:
    primary-storage:
      directory: /usr/local/camunda/data
```

**Explanation:** The broker's primary storage is configured through the Camunda 8.9 unified `camunda.data.primary-storage` namespace. The directory remains `/usr/local/camunda/data` to preserve the existing Docker volume layout.

#### 7. Kept Unchanged (Important)

The following settings are intentionally retained from 8.8:

- `server.forward-headers-strategy: framework` — Required for correct operation behind the Caddy reverse proxy
- Zeebe Elasticsearch exporter retention (`minimum-age: 90d`) — Keeps `zeebe-record-*` indices bounded while preserving Optimize import source data
- `camunda.operate.identity.redirectRootUrl` and `camunda.tasklist.identity.redirectRootUrl` — Keep proxy-aware HTTPS URLs

---

## Docker Compose Changes

### File: `docker-compose.yaml`

#### 1. New Service: `camunda-data-init`

**Change:** A new initialization service is added before `orchestration`:

```yaml
camunda-data-init:
  image: camunda/camunda:${CAMUNDA_VERSION}
  container_name: camunda-data-init
  user: "0:0"
  entrypoint: ["/bin/sh", "-c", "chown -R 1001:1001 /usr/local/camunda/camunda-data && chmod 775 /usr/local/camunda/camunda-data"]
  volumes:
    - camunda-data:/usr/local/camunda/camunda-data
  networks:
    - camunda-platform
  restart: "no"
```

**Explanation:** The orchestration container runs as user `1001:1001`. In Camunda 8.9, a new `camunda-data` volume is introduced for runtime data (e.g., H2 database files if RDBMS is used, or other runtime files). This init container ensures the directory has correct ownership before the main orchestration container starts. It runs once and exits.

#### 2. New Volume: `camunda-data`

**Change:** Added to the volumes section:

```yaml
volumes:
  orchestration:
  camunda-data:
  elastic:
  ...
```

**Explanation:** This volume stores Camunda runtime data separate from Zeebe broker data. Even though we keep Elasticsearch as the database, 8.9 may write other runtime files to this location.

#### 3. Orchestration Service Updates

**Volume mounts:**
```yaml
volumes:
  - orchestration:/usr/local/camunda/data      # Kept for production data safety
  - camunda-data:/usr/local/camunda/camunda-data  # New in 8.9
  - "./.orchestration/application.yaml:/usr/local/camunda/config/application.yaml"
```

**Dependency:**
```yaml
depends_on:
  camunda-data-init:
    condition: service_completed_successfully
  elasticsearch:
    condition: service_healthy
```

**Explanation:** The orchestration container now depends on `camunda-data-init` completing successfully before it starts. This guarantees filesystem permissions are correct.

#### 4. Connectors Authentication URL

**Change:**
```yaml
# Before
CAMUNDA_CLIENT_AUTH_TOKENURL: http://${KEYCLOAK_HOST}:18080/auth/realms/camunda-platform/protocol/openid-connect/token

# After
CAMUNDA_CLIENT_AUTH_ISSUERURL: http://${KEYCLOAK_HOST}:18080/auth/realms/camunda-platform
```

**Explanation:** Camunda 8.9 connectors use the issuer URL pattern instead of the direct token URL. The connectors runtime discovers the token endpoint automatically from the issuer's OpenID Connect configuration. This is the recommended pattern in 8.9.

#### 5. Web Modeler RestAPI New Flags

**Change:**
```yaml
SERVER_HTTPS_ONLY: "false"
PLAY_ENABLED: "true"
```

**Explanation:**
- `SERVER_HTTPS_ONLY: "false"` — Allows the Web Modeler REST API to operate over HTTP internally while the reverse proxy handles HTTPS termination externally.
- `PLAY_ENABLED: "true"` — Enables the new "Play" feature in Web Modeler 8.9, which allows simulating and testing BPMN processes directly in the modeler without deploying them.

#### 6. Web Modeler WebApp Discontinued

**Change:** The entire `web-modeler-webapp` service is removed from `docker-compose.yaml`.

**Explanation:** Starting with Camunda 8.9, the `camunda/web-modeler-webapp` Docker image is discontinued. Its functionality is now integrated into `camunda/web-modeler-restapi`. The REST API container now also serves the web application frontend.

**What changed:**
- `web-modeler-restapi` now exposes port `8070:8081` (previously no host port)
- Client-facing environment variables moved from `web-modeler-webapp` to `web-modeler-restapi`:
  - `CLIENT_PUSHER_HOST`
  - `CLIENT_PUSHER_PORT`
  - `CLIENT_PUSHER_FORCE_TLS`
  - `CLIENT_PUSHER_KEY`
  - `OAUTH2_CLIENT_ID`
  - `OAUTH2_TOKEN_ISSUER`
  - `IDENTITY_BASE_URL`
- The `web-modeler-webapp` service and its resource limits are removed from all stage profiles

---

## Console Configuration Changes

### File: `.console/application.yaml`

#### 1. Component Version Bumps

All component `version` fields are updated from `"8.8.0"` to `"8.9.0"`.

**Explanation:** The Console UI displays these versions in its dashboard. They are for informational purposes and do not affect image pulling.

#### 2. Orchestration Gateway Renamed

**Change:**
```yaml
# Before
- name: "Orchestration Gateway"
  id: "orchestrationGateway"
  urls:
    grpc: "grpc://localhost:26500"
    http: "http://localhost:8088"

# After
- name: "Orchestration"
  id: "orchestration"
  urls:
    grpc: "grpc://orchestration:26500"
    http: "http://orchestration:8080"
```

**Explanation:** In 8.9, the naming is simplified. The internal URLs now use Docker service names (`orchestration`) instead of `localhost` for container-to-container communication.

#### 3. WebModeler Components Merged

**Change:** `WebModeler WebApp` and `WebModeler RestAPI` are merged into a single `WebModeler` component.

**Explanation:** The Console dashboard now treats Web Modeler as a single logical component instead of two separate ones.

#### 4. Keycloak Version Display

**Change:** Keycloak version updated from `"24.0.5"` to `"26.3.2"`.

**Explanation:** This reflects the actual Keycloak version running in the stack. The display version was outdated.

---

## Stage Profile Changes

### Files: `stages/dev.yaml`, `stages/test.yaml`, `stages/prod.yaml`

**Change:** Added resource limits for the new `camunda-data-init` service:

```yaml
camunda-data-init:
  deploy:
    resources:
      limits:
        cpus: "0.25"
        memory: 128M
      reservations:
        cpus: "0.05"
        memory: 32M
```

**Explanation:** The init service runs briefly (a few seconds) to set filesystem permissions. Minimal resources are sufficient.

---

## Post-Upgrade Verification

### Step 1: Start the Stack

```bash
bash scripts/start.sh
```

### Step 2: Check All Containers Are Running

```bash
docker compose ps
```

Expected: All services show `Up` and `healthy`. `camunda-data-init` should show `Exited (0)` which is correct.

### Step 3: Verify Elasticsearch

```bash
curl -s http://localhost:9200/_cluster/health | jq .
```

Expected: `status` is `green` or `yellow`.

### Step 4: Verify Orchestration Health

```bash
curl -s http://localhost:9600/actuator/health
```

Expected: `{"status":"UP"}`

### Step 5: Test OIDC Login via Reverse Proxy

Open `https://orchestration.camunda.dev.local/operate` in a browser.

Expected: Redirects to Keycloak login, then back to Operate after authentication.

### Step 6: Test Console Dashboard

Open `https://console.camunda.dev.local/`.

Expected: All components show green/healthy status.

### Step 7: Test Web Modeler

Open `https://webmodeler.camunda.dev.local/`.

Expected: Login works. The new Play button is visible in the modeler.

### Step 8: Verify Optimize

Open `https://optimize.camunda.dev.local/`.

Expected: Login works and dashboards load.

### Step 9: Deploy and Run a Process

1. Open Web Modeler
2. Create or open a BPMN process
3. Deploy it
4. Start an instance
5. Verify it appears in Operate

---

## Rollback Procedure

If the upgrade fails or issues are encountered:

### 1. Stop the Stack

```bash
bash scripts/stop.sh
```

### 2. Revert to the Previous Branch

```bash
git checkout master
```

### 3. Start the Old Stack

```bash
bash scripts/start.sh
```

### Important Notes

- **Named volumes are preserved** across branch switches because Docker volumes are not tied to Git state.
- **The `.env` file** is gitignored. If you switch branches, ensure the `.env` on `master` still has the 8.8 versions, or checkout the `.env` from master explicitly.
- **Images are not deleted** when switching branches. The 8.8 images will still be available locally.
- **No data migration is required** for rollback because we kept Elasticsearch and did not switch to RDBMS.

---

## Troubleshooting

### Issue: Orchestration fails to start with "Profile 'identity' not found"

**Cause:** The old `identity` profile is no longer valid in 8.9.

**Fix:** Verify `.orchestration/application.yaml` has `active: "admin,operate,tasklist,broker,consolidated-auth"`.

### Issue: "Secondary storage type not configured" error

**Cause:** Camunda 8.9 requires explicit secondary storage configuration.

**Fix:** Verify `.orchestration/application.yaml` contains:
```yaml
camunda:
  database:
    type: elasticsearch
  data:
    secondary-storage:
      type: elasticsearch
      elasticsearch:
        url: "http://elasticsearch:9200"
```

### Issue: Connectors cannot authenticate

**Cause:** Using the old `TOKENURL` environment variable.

**Fix:** Verify `docker-compose.yaml` uses `CAMUNDA_CLIENT_AUTH_ISSUERURL` instead of `CAMUNDA_CLIENT_AUTH_TOKENURL`.

### Issue: Web Modeler shows "login has expired" immediately

**Cause:** This is typically a Chrome cross-origin cookie issue, not related to the 8.9 upgrade.

**Fix:** Verify the Caddyfile still intercepts `login-status-iframe.html`. This should be unchanged from 8.8.

### Issue: Elasticsearch health check fails after upgrade

**Cause:** Elasticsearch 8.19 may have stricter health requirements.

**Fix:** Check Elasticsearch logs with `docker compose logs elasticsearch`. Ensure disk space is available and cluster settings are compatible.

### Issue: Zeebe data not found after upgrade

**Cause:** The data directory path mismatch between old and new image defaults.

**Fix:** Verify `.orchestration/application.yaml` has:
```yaml
camunda:
  data:
    primary-storage:
      directory: /usr/local/camunda/data
```

And verify `docker-compose.yaml` mounts the volume at `/usr/local/camunda/data`.

---

## Summary of Changed Files

| File | What Changed |
|------|-------------|
| `.env` | All Camunda versions bumped to 8.9.x, Elasticsearch to 8.19.11 |
| `.env.example` | Same version bumps for template |
| `.orchestration/application.yaml` | Profile `identity` → `admin`, configured `camunda.data.secondary-storage.type: rdbms`, `backup.webapps.enabled: false`, `mcp.enabled: true`, removed `CamundaExporter`, retained primary storage at `/usr/local/camunda/data` |
| `docker-compose.yaml` | Added `camunda-data-init` service, added `camunda-data` volume, updated orchestration depends_on/volumes, updated connectors auth URL, removed `web-modeler-webapp` (merged into restapi), added Web Modeler client flags to restapi |
| `.console/application.yaml` | Version bumps to 8.9.0, merged WebModeler, renamed Orchestration Gateway, updated Keycloak version |
| `stages/dev.yaml` | Added `camunda-data-init` resource limits |
| `stages/test.yaml` | Added `camunda-data-init` resource limits |
| `stages/prod.yaml` | Added `camunda-data-init` resource limits |
