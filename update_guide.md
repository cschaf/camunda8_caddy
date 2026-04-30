# Minor Update Guide

This project is a Camunda 8 Self-Managed Docker Compose stack. A minor update means moving the stack from one Camunda minor line to another, for example `8.9.x` to `8.10.x`. Treat a minor update as a controlled stack upgrade, not as a simple image tag bump.

For patch-only updates inside the same minor line, for example `8.9.1` to `8.9.2`, the same files are relevant, but the risk is lower and most configuration changes are usually not required.

## Current Version Sources

The main version pins are in `.env.example`. The running stack uses `.env`, which is gitignored and must be updated separately.

| Component | Version variable | Image used in `docker-compose.yaml` |
|---|---|---|
| Orchestration / Zeebe / Operate / Tasklist / Admin | `CAMUNDA_VERSION` | `camunda/camunda:${CAMUNDA_VERSION}` |
| Connectors | `CAMUNDA_CONNECTORS_VERSION` | `camunda/connectors-bundle:${CAMUNDA_CONNECTORS_VERSION}` |
| Identity | `CAMUNDA_IDENTITY_VERSION` | `camunda/identity:${CAMUNDA_IDENTITY_VERSION}` |
| Optimize | `CAMUNDA_OPTIMIZE_VERSION` | `camunda/optimize:${CAMUNDA_OPTIMIZE_VERSION}` |
| Web Modeler REST API and UI | `CAMUNDA_WEB_MODELER_VERSION` | `camunda/web-modeler-restapi:${CAMUNDA_WEB_MODELER_VERSION}` and `camunda/web-modeler-websockets:${CAMUNDA_WEB_MODELER_VERSION}` |
| Console | `CAMUNDA_CONSOLE_VERSION` | `camunda/console:${CAMUNDA_CONSOLE_VERSION}` |
| Elasticsearch | `ELASTIC_VERSION` | `docker.elastic.co/elasticsearch/elasticsearch:${ELASTIC_VERSION}` |
| Keycloak | `KEYCLOAK_SERVER_VERSION` | `bitnamilegacy/keycloak:${KEYCLOAK_SERVER_VERSION}` |
| PostgreSQL | `POSTGRES_VERSION` | `postgres:${POSTGRES_VERSION}` |
| Mailpit | `MAILPIT_VERSION` | `axllent/mailpit:${MAILPIT_VERSION}` |
| Caddy | hardcoded in `docker-compose.yaml` | `caddy:2.11.2@sha256:...` |
| Autoheal | hardcoded in `docker-compose.yaml` | `willfarrell/autoheal@sha256:...` |

`CAMUNDA_OPERATE_VERSION` and `CAMUNDA_TASKLIST_VERSION` still exist in `.env.example` for documentation/Console display alignment, but Operate and Tasklist run inside the unified `camunda/camunda` orchestration image in this stack.

## Where To Look Up New Minor Versions

Start with Camunda's official release information, then confirm the Docker tags that actually exist.

- Camunda release notes: `https://docs.camunda.io/docs/reference/announcements-release-notes/`
- Camunda Self-Managed Docker Compose docs: `https://docs.camunda.io/docs/self-managed/setup/deploy/other/docker/`
- Camunda Docker Hub repositories:
  - `https://hub.docker.com/r/camunda/camunda/tags`
  - `https://hub.docker.com/r/camunda/connectors-bundle/tags`
  - `https://hub.docker.com/r/camunda/identity/tags`
  - `https://hub.docker.com/r/camunda/optimize/tags`
  - `https://hub.docker.com/r/camunda/web-modeler-restapi/tags`
  - `https://hub.docker.com/r/camunda/web-modeler-websockets/tags`
  - `https://hub.docker.com/r/camunda/console/tags`
- Elasticsearch compatibility and tags:
  - `https://docs.camunda.io/docs/self-managed/reference/supported-environments/`
  - `https://www.docker.elastic.co/r/elasticsearch/elasticsearch`
- Keycloak image tags: `https://hub.docker.com/r/bitnamilegacy/keycloak/tags`
- PostgreSQL tags: `https://hub.docker.com/_/postgres/tags`
- Mailpit tags: `https://hub.docker.com/r/axllent/mailpit/tags`
- Caddy tags and digest: `https://hub.docker.com/_/caddy/tags`

For a minor Camunda upgrade, also read the migration/update notes for the target minor. Look specifically for renamed environment variables, profile names, removed images, changed health endpoints, storage/backend changes, authentication changes, and backup/restore changes.

## Files To Update

### 1. Version files

Update both `.env.example` and the local `.env`.

Required checks:

- Keep all Camunda core components on the same minor line unless Camunda explicitly documents otherwise.
- Use the exact Console patch version that exists for the target minor. Console often has a different patch number from the platform images.
- Confirm the target Elasticsearch version is supported by the target Camunda minor before changing `ELASTIC_VERSION`.
- Do not overwrite production secrets in `.env`; edit only the version values unless a migration guide explicitly requires new variables.

### 2. `docker-compose.yaml`

Check every service that uses an image tag or version-specific configuration.

Areas that commonly change during minor upgrades:

- `orchestration` image, environment variables, health check, volume mounts, and `depends_on`
- `connectors` authentication variables and readiness endpoint
- `optimize` environment variables, config path, health check, and Elasticsearch compatibility
- `identity` environment variables, Keycloak provisioning values, health check, and mounted config
- `web-modeler-restapi` and `web-modeler-websockets` image layout, ports, readiness endpoints, and feature flags
- `console` image, readiness/metrics endpoints, and mounted `.console` config
- `elasticsearch` version, security settings, snapshot repository path, and index allowlist
- hard-pinned `reverse-proxy` and `autoheal` images if you intentionally update them
- named volumes under `volumes:` if the new minor introduces or removes persistent paths
- networks and host ports if services are split, merged, or renamed

Never remove or recreate persistent named volumes as part of a normal minor update unless the migration procedure explicitly says so.

### 3. Application configs

Review these files against the target minor's docs and migration notes:

- `.orchestration/application.yaml`
- `.identity/application.yaml`
- `.connectors/application.yaml`
- `.optimize/environment-config.yaml.example`
- `.console/application.yaml.template`

Important project-specific notes:

- `.orchestration/application.yaml` currently uses the `admin,operate,tasklist,broker,consolidated-auth` profiles and RDBMS secondary storage through `camunda.data.secondary-storage.type: rdbms`.
- Elasticsearch is still used for Optimize and `zeebe-record-*` exporter records.
- `.console/application.yaml` is generated from `.console/application.yaml.template` by the start scripts. Update the template, not only the generated file.
- `.optimize/environment-config.yaml` is generated from `.optimize/environment-config.yaml.example` by the start scripts. Update the example/template, not only the generated file.

### 4. Stage overlays

Review all stage overlays:

- `stages/prod.yaml`
- `stages/dev.yaml`
- `stages/test.yaml`
- `stages/drill.yaml`

Update them when a service is added, removed, renamed, or when memory/CPU requirements change. The drill stage must stay aligned with the main Compose file because it is used to test backups in an isolated stack.

### 5. Reverse proxy and dashboard

Review:

- `Caddyfile.example`
- local `Caddyfile`
- `dashboard/index.html`
- `dashboard/style.css`

Update Caddy routes if service names, ports, paths, WebSocket paths, health endpoints, or browser-facing URLs change. Also review version-specific comments/workarounds, for example comments mentioning `Console 8.9` or `Camunda 8.9`.

### 6. Scripts

Review the scripts after any service, health endpoint, port, volume, or backup format change:

- `scripts/start.ps1` and `scripts/start.sh`
- `scripts/stop.ps1` and `scripts/stop.sh`
- `scripts/backup.ps1` and `scripts/backup.sh`
- `scripts/restore.ps1` and `scripts/restore.sh`
- `scripts/restore-drill.ps1` and `scripts/restore-drill.sh`
- `scripts/lib/backup-common.ps1` and `scripts/lib/backup-common.sh`
- `scripts/lib/drill-common.ps1` and `scripts/lib/drill-common.sh`
- `scripts/setup-host.ps1` and `scripts/setup-host.sh`
- `scripts/add-camunda-user.ps1` and `scripts/add-camunda-user.sh`
- `scripts/rehost-keycloak.sql`

Backup and restore scripts are especially sensitive to service names, volume names, port mappings, Elasticsearch index patterns, and PostgreSQL database names.

### 7. Documentation

Search for the old minor and update docs where the text is still correct but version-specific.

Useful commands:

```powershell
rg -n --hidden --no-ignore "8\.9|8\.10|CAMUNDA_VERSION|ELASTIC_VERSION|KEYCLOAK_SERVER_VERSION" . -g "!backups/**" -g "!.git/**" -g "!.worktrees/**"
```

Update at least:

- `README.md`
- `docs/project_configuration.md`
- `docs/backup-restore.md`
- `docs/cluster_upgrade.md` or create a new specific upgrade guide for the new minor
- `docs/stage_comparison.md`
- this `update_guide.md` if the project structure changes

## Backup Before Updating

Before changing image versions or copying files over an existing installation, create a full backup and verify it.

PowerShell on Windows:

```powershell
.\scripts\backup.ps1
.\scripts\restore.ps1 --verify backups\<backup-folder>
.\scripts\restore-drill.ps1 backups\<backup-folder>
```

Bash on Linux/macOS/WSL:

```bash
./scripts/backup.sh
./scripts/restore.sh --verify backups/<backup-folder>
./scripts/restore-drill.sh backups/<backup-folder>
```

The backup captures:

- Zeebe state from the `orchestration` Docker volume
- Camunda core PostgreSQL data from `camunda-db`
- Keycloak/Identity data from `postgres`
- Web Modeler data from `web-modeler-db`
- Elasticsearch snapshot data for Optimize and exported records
- configuration files such as `.env`, `connector-secrets.txt`, `Caddyfile`, and application YAML files

Also copy critical local files to a separate safe location before replacing the project directory:

- `.env`
- `connector-secrets.txt`
- `Caddyfile`
- `certs/`
- `.orchestration/application.yaml`
- `.identity/application.yaml`
- `.connectors/application.yaml`
- `.optimize/environment-config.yaml`
- `.console/application.yaml`
- any custom dashboard assets under `dashboard/`
- the latest backup folder under `backups/`, or the encrypted backup artifact under `backups-encrypted/`

Remember: Docker named volumes are not inside the project directory. Copying the project folder does not copy the running databases or Zeebe state. Use the backup scripts for data.

## Copying The Whole Project To Another Location

Use this when you want to move the project files to another folder or host before/after an update.

### Windows

From the parent directory:

```powershell
robocopy CamundaComposeNVL CamundaComposeNVL-copy /MIR /XD .git .worktrees backups /XF .env connector-secrets.txt Caddyfile
```

Then copy the sensitive files intentionally, after deciding whether the target should reuse the same secrets and hostnames:

```powershell
Copy-Item CamundaComposeNVL\.env CamundaComposeNVL-copy\.env
Copy-Item CamundaComposeNVL\connector-secrets.txt CamundaComposeNVL-copy\connector-secrets.txt
Copy-Item CamundaComposeNVL\Caddyfile CamundaComposeNVL-copy\Caddyfile
Copy-Item CamundaComposeNVL\certs CamundaComposeNVL-copy\certs -Recurse
```

### Linux/macOS/WSL

From the parent directory:

```bash
rsync -a --delete \
  --exclude .git \
  --exclude .worktrees \
  --exclude backups \
  --exclude .env \
  --exclude connector-secrets.txt \
  --exclude Caddyfile \
  CamundaComposeNVL/ CamundaComposeNVL-copy/
```

Then copy sensitive files intentionally if the target should use the same secrets:

```bash
cp CamundaComposeNVL/.env CamundaComposeNVL-copy/.env
cp CamundaComposeNVL/connector-secrets.txt CamundaComposeNVL-copy/connector-secrets.txt
cp CamundaComposeNVL/Caddyfile CamundaComposeNVL-copy/Caddyfile
cp -a CamundaComposeNVL/certs CamundaComposeNVL-copy/certs
```

Be careful with `/MIR`, `--delete`, and any copy-over-existing operation. They can remove local-only files in the destination. Back up the destination's `.env`, `connector-secrets.txt`, `Caddyfile`, `certs/`, and `backups/` before overwriting.

## Update Procedure

1. Read the target minor release notes and supported-environment matrix.
2. Create and verify a full backup with the project backup scripts.
3. Create a Git branch for the update.
4. Update `.env.example` and `.env` version variables.
5. Review and update `docker-compose.yaml`, application configs, stage overlays, Caddy config, scripts, and docs.
6. Pull the new images:

```powershell
docker compose -f docker-compose.yaml -f stages/prod.yaml pull
```

7. Start the stack:

```powershell
.\scripts\start.ps1
```

8. Check container health:

```powershell
docker compose -f docker-compose.yaml -f stages/prod.yaml ps
```

9. Check logs for migration errors:

```powershell
docker logs orchestration --tail 120
docker logs identity --tail 120
docker logs optimize --tail 120
docker logs console --tail 120
docker logs web-modeler-restapi --tail 120
```

10. Test browser login and core workflows:

- `https://orchestration.${HOST}/operate`
- `https://orchestration.${HOST}/tasklist`
- `https://identity.${HOST}`
- `https://optimize.${HOST}`
- `https://console.${HOST}`
- `https://webmodeler.${HOST}`
- deploy and start a small BPMN process, then verify it appears in Operate

11. Run a fresh backup after the update.
12. Run a restore drill against the fresh post-update backup.
13. Commit the changed project files after the stack and restore drill are verified.

## Small Step By Step Plan

1. Look up the target Camunda minor and compatible Elasticsearch version.
2. Back up the current stack and run `restore --verify`.
3. Copy `.env`, `connector-secrets.txt`, `Caddyfile`, `certs/`, and the newest backup to a safe location.
4. Change the version variables in `.env.example` and `.env`.
5. Apply required config changes from the Camunda migration notes.
6. Update stage files, Caddy routes, scripts, and docs if the service layout changed.
7. Pull images and start the stack.
8. Check `docker compose ps`, service logs, and all web UIs.
9. Deploy/start a test process and verify Operate/Tasklist/Optimize/Web Modeler.
10. Create a new backup and run a restore drill.
11. Commit the update once the drill passes.
