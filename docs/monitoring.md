# Monitoring

This document is for sysadmins integrating a host that runs the Camunda 8.9
Self-Managed Docker Compose stack (this repository) into an existing
monitoring system.

It is **tool-neutral**. Endpoints, parseable output, recommended thresholds,
and copyable shell probes are listed so they can be wired into Nagios,
Zabbix, Checkmk, Icinga, Prometheus + node_exporter, Datadog, SCOM, or any
other check engine. No specific monitoring product is recommended or
required.

The stack ships no in-cluster Prometheus, Grafana, or AlertManager. Several
services do emit Prometheus-format metrics on plain HTTP endpoints — those
endpoints are listed below as raw probes. Whether to scrape them with a
Prometheus server, ingest them via a generic HTTP check, or ignore them is
left to the sysadmin.

Two layers are in scope:

1. **Host machine** — the Linux/Windows server running Docker Engine
2. **Camunda services** — the containers defined in `docker-compose.yaml`

Backup-related signals (last successful run, archive age, restore drill) are
covered separately in [backup-restore.md](backup-restore.md) and not
duplicated here.

Stage awareness: thresholds for memory, CPU, and disk depend on the value of
`STAGE` in `.env` (`prod` / `dev` / `test`). The exact resource limits live
in `stages/<stage>.yaml`; see [stage_comparison.md](stage_comparison.md).

---

## 1. Quick reference

All host-bound ports are bound to `127.0.0.1` (loopback) by design — only
ports `80` and `443` (Caddy reverse proxy) are exposed on LAN interfaces.
The "loopback port" column is what an external monitor running **on the same
host** should probe.

| Service | Internal `host:port` | Loopback port | Health endpoint | Metrics endpoint | Auth |
|---------|----------------------|---------------|-----------------|------------------|------|
| orchestration (Zeebe + Operate + Tasklist) | `orchestration:8080`, `:9600`, `:26500` | `8088`, `9600`, `26500` | `GET :9600/actuator/health/{liveness,readiness,startup}` | `GET :9600/actuator/prometheus` | none on management port |
| connectors | `connectors:8080` | `8086` | `GET :8086/actuator/health/readiness` | `GET :8086/actuator/prometheus` | none on management port |
| optimize | `optimize:8090` | `8083` | `GET :8083/api/readyz` | `GET :8083/actuator/prometheus` | none on management port |
| identity | `identity:8084` (API), `:8082` (management — not host-published) | `8084` (API only) | `docker inspect identity` (health field) — see §3.4 | not exposed by default | n/a |
| keycloak | `keycloak:18080` | (proxy only) | `GET https://keycloak.{HOST}/auth/` | not exposed by default | none |
| elasticsearch | `elasticsearch:9200`, `:9300` | `9200`, `9300` | `GET :9200/_cluster/health` | `GET :9200/_nodes/stats`, `_cat/indices`, etc. | **HTTP Basic** (`elastic` / `$ELASTIC_PASSWORD`) |
| console | `console:8080`, `:9100` | `8087`, `9100` | `GET :9100/health/readiness` | `GET :9100/prometheus` *(not `/actuator/prometheus`)* | none on metrics port |
| web-modeler-restapi | `web-modeler-restapi:8081` (API), `:8091` (management — not host-published) | `8070` (API only) | `docker inspect web-modeler-restapi` (health field) | not exposed by default | n/a |
| web-modeler-websockets | `web-modeler-websockets:8060` | `8060` | `GET :8060/up` | not exposed | none |
| postgres (Identity/Keycloak DB) | `postgres:5432` | not published | `pg_isready` via `docker exec` | n/a | psql credentials |
| camunda-db (Camunda core DB) | `camunda-db:5432` | not published | `pg_isready` via `docker exec` | n/a | psql credentials |
| web-modeler-db | `web-modeler-db:5432` | not published | `pg_isready` via `docker exec` | n/a | psql credentials |
| mailpit | `mailpit:1025`, `:8025` | `1025`, `8075` | TCP probe `1025` | not exposed | none |
| reverse-proxy (Caddy) | `reverse-proxy:80`, `:443`, `:2019` | `443` (LAN), `2019` (loopback) | `GET :2019/config/` | not enabled in default build | none on admin port (loopback) |

> The container's *internal* health-check command is what Docker uses to mark
> a container `healthy`/`unhealthy`. External monitors should probe the
> *loopback host port* with the equivalent endpoint. The two sometimes
> differ — see §4.4 for the Identity quirk.

---

## 2. Host machine monitoring

### 2.1 Disk

The host needs free space in two places:

1. **Docker data directory** — where Docker stores images, container
   filesystems, and named volumes.
   - Linux: `/var/lib/docker` (varies by distro/configuration; check
     `docker info | grep "Docker Root Dir"`)
   - Windows Docker Desktop: a backing VHD, typically under
     `%LOCALAPPDATA%\Docker\wsl\` (WSL2) or
     `C:\ProgramData\Docker\` (Hyper-V mode)
2. **Named volumes** — the Compose project creates these. List with
   `docker system df -v`.

The volumes that grow under load, in expected order of magnitude (highest
first):

| Volume | Owning service | Growth driver | Retention |
|--------|---------------|---------------|-----------|
| `elastic` | elasticsearch | Zeebe records, Operate/Tasklist indices, Optimize analytics | `zeebe-record-*` 90 days; `optimize-*` 365 days; **applies only to new indices** (see §6, [CLAUDE.md gotcha 21](../CLAUDE.md)) |
| `camunda-db` | camunda-db | Process instance history, variables, tasks | **No automatic cleanup.** Grows monotonically until manual archival |
| `orchestration` | orchestration | Zeebe RocksDB state, segments, snapshots | Compacted by Zeebe; usually < 1 GB at steady state |
| `postgres-web` | web-modeler-db | BPMN/DMN files, comments | Grows with modeling activity |
| `postgres` | postgres | Keycloak users, sessions, Identity metadata | Stable; tens of MB unless user/session volume is high |
| `elastic-backup` | elasticsearch | Snapshot repository (used by `scripts/backup.sh`) | Persistent across restore runs by design ([CLAUDE.md gotcha 8](../CLAUDE.md)) |
| `keycloak-theme` | identity, keycloak | Theme assets generated by Identity | Stable; < 10 MB |

**Probes**

```bash
# Total Docker engine disk usage (images + containers + volumes + build cache)
docker system df -v

# Per-volume size on Linux (root required)
sudo du -sh /var/lib/docker/volumes/*

# Free space on the Docker data directory
df -h "$(docker info --format '{{.DockerRootDir}}')"
```

**Recommended thresholds**

For the partition holding the Docker data directory:

| Level | Threshold | Rationale |
|-------|-----------|-----------|
| Warn | < 25% free | Leaves headroom before Elasticsearch enters its low watermark |
| Critical | < 15% free | Elasticsearch's `cluster.routing.allocation.disk.watermark.low` is 85% (15% free) — past this, ES stops allocating new shards on this node |
| Emergency | < 5% free | Elasticsearch flood-stage watermark (95%) makes all indices read-only — Camunda starts failing |

Watermark values come from `docker-compose.yaml` (`cluster.routing.allocation.disk.watermark.low/high/flood_stage`). Aligning host-disk alerts a few percentage points *before* those values gives the sysadmin time to react before the cluster degrades itself.

### 2.2 Memory and CPU

Resource limits per service per stage are defined in `stages/{prod,dev,test}.yaml`.
Approximate totals of `deploy.resources.limits` (worst-case sustained):

| Stage | CPU limit total | Memory limit total |
|-------|-----------------|--------------------|
| `prod` | ~16 vCPU | ~25 GB |
| `dev` | ~10 vCPU | ~14 GB |
| `test` | ~8 vCPU | ~10 GB |

Add ~2–4 GB headroom for the OS, Docker daemon, and Linux page cache /
Windows kernel pool. The repository's documented baseline is 32 GB / 16 vCPU
([README.md](../README.md)).

**Per-container live usage**

```bash
docker stats --no-stream
# Outputs: NAME, CPU %, MEM USAGE / LIMIT, MEM %, NET I/O, BLOCK I/O, PIDS
```

The `MEM USAGE / LIMIT` column is the most useful single number — set
warn/crit alerts as a percentage of the *limit* (not the host total) so
thresholds remain stage-agnostic.

**Suggested thresholds (per-container)**

| Metric | Warn | Critical |
|--------|------|----------|
| `MEM %` (RSS / limit) | > 80 % for > 10 min | > 95 % for > 2 min |
| `CPU %` (sustained) | > 80 % of allocated cores for > 15 min | > 95 % for > 5 min |

JVM containers (orchestration, optimize, connectors, identity, console,
web-modeler-restapi) have heap sizes set in the stage files via
`JAVA_TOOL_OPTIONS` / `JAVA_OPTIONS` / `ES_JAVA_OPTS`. Heap is typically
50–75 % of the container memory limit; the rest is reserved for off-heap
buffers (RocksDB, Lucene page cache, GC overhead). A healthy JVM stays
below the heap ceiling — sustained `MEM %` close to 100 % of the *limit*
indicates the off-heap budget is too tight, not that the heap is full.

**OOM kills (container exit code 137)**

A container killed by the kernel for exceeding its memory limit exits with
code 137. Detection:

```bash
docker inspect <container> --format '{{.State.ExitCode}} {{.State.OOMKilled}}'
# Example output: 137 true
```

This is the highest-priority alert: an OOM-killed container loses all
in-flight state, and Camunda services restarting in this loop will trigger
cascading readiness failures across the stack.

**Swap**

Swap usage should stay near zero. JVMs and Elasticsearch tolerate swap
poorly (GC pauses, query latency spikes). On Linux:

```bash
free -h
# Watch the "Swap:" row; "used" should be 0 or near-0
```

### 2.3 OS settings

These are check-once-on-host-prep items, not metrics — but a monitoring
system should still flag drift if they regress.

**Linux**

| Setting | Required value | How to check |
|---------|---------------|--------------|
| `vm.max_map_count` | ≥ `262144` (Elasticsearch) | `sysctl vm.max_map_count` |
| File descriptor limit (Docker daemon) | ≥ `65536` | `cat /proc/$(pidof dockerd)/limits \| grep "open files"` |
| NTP / chrony status | synchronized | `timedatectl status` (look for `System clock synchronized: yes`) or `chronyc tracking` |

If `vm.max_map_count` is too low, Elasticsearch fails to start with a clear
log message — but a passive check that runs once an hour catches accidental
host reboots into a default sysctl state.

**Windows**

Docker Desktop manages most kernel parameters internally inside its WSL2
backing distro. Two host-level concerns remain:

| Setting | Notes |
|---------|-------|
| Windows Time service (`w32time`) | Must be running and synchronized |
| WSL2 backing VHD size | Grows but does not shrink automatically; monitor disk under `%LOCALAPPDATA%\Docker\wsl\` |

Camunda timers are clock-driven. NTP drift > 1 second is operationally
visible (timer events fire late or twice).

### 2.4 Network exposure

Only ports `80` and `443` should be reachable on a non-loopback interface.
Everything else (`8060`, `8070`, `8083`, `8084`, `8086`, `8087`, `8088`,
`8075`, `1025`, `9100`, `9200`, `9300`, `9600`, `26500`, `2019`) binds to
`127.0.0.1` in `docker-compose.yaml` and is intended for local
diagnostics, scripts, and health probes only.

A monitor should alert if any of those ports become reachable from a LAN
peer — that indicates a misconfigured `docker-compose.override.yaml` or a
socket-level firewall change. From a remote host:

```bash
# Should return "connection refused" or time out:
nc -zv <camunda-host-ip> 9200
nc -zv <camunda-host-ip> 8088
```

### 2.5 TLS certificate expiry

Caddy auto-generates a self-signed certificate by default; **no expiry
monitoring is needed in that case** (Caddy regenerates as needed).

If `FULLCHAIN_PEM` and `PRIVATEKEY_PEM` are set in `.env` (corporate CA,
mkcert, Let's Encrypt-via-other-tool), the sysadmin owns renewal. Probe
the cert file directly:

```bash
openssl x509 -in /path/to/certs/cert.pem -noout -enddate
# notAfter=Jun  4 12:00:00 2026 GMT
```

Or end-to-end against the running proxy:

```bash
echo | openssl s_client -servername "${HOST}" -connect "${HOST}:443" 2>/dev/null \
  | openssl x509 -noout -enddate
```

**Suggested thresholds**

| Days until expiry | Severity |
|--------------------|----------|
| < 30 | Warn |
| < 7 | Critical |

---

## 3. Docker engine layer

### 3.1 Container health status

Every Camunda service in `docker-compose.yaml` has a `healthcheck:` block
and the `autoheal=true` label, so its `STATE.Health.Status` is either
`starting`, `healthy`, or `unhealthy`. Parseable output:

```bash
docker compose ps --format json
# Per-service JSON; the "Health" field is the value to alert on.

# One-liner: list any non-healthy containers
docker ps --filter "health=unhealthy" --format 'table {{.Names}}\t{{.Status}}'
```

Health-check intervals are defined per service and tuned for that service's
startup time; do not shorten them in monitoring (the container itself runs
the check at the configured interval — external probes only consume the
*result* via the Docker API).

**Suggested thresholds**

| Symptom | Severity |
|---------|----------|
| Any container `unhealthy` for > 5 min | Warn |
| Any container `unhealthy` for > 15 min | Critical |
| `orchestration`, `keycloak`, `elasticsearch`, or `reverse-proxy` `unhealthy` for > 2 min | Critical (these are user-impacting immediately) |

### 3.2 Restart loops

The `restart: unless-stopped` policy plus the `autoheal` sidecar
(`willfarrell/autoheal`, runs every 30 s) means an unhealthy container is
restarted automatically. The signal a sysadmin needs is **"the same
container has restarted more than N times in the last hour"** — that means
a service cannot stay healthy on its own.

```bash
docker inspect <container> \
  --format '{{.Name}} restarts={{.RestartCount}} exit={{.State.ExitCode}} oom={{.State.OOMKilled}}'
```

**Exit-code crib**

| Exit code | Meaning |
|-----------|---------|
| `0` | Clean stop |
| `1` | Application crash (read logs) |
| `137` | SIGKILL — almost always OOM (kernel; `OOMKilled=true` confirms) or a hard `docker kill` |
| `139` | SIGSEGV — JVM/native crash; rare, capture core if reproducible |
| `143` | SIGTERM (graceful shutdown, e.g. `docker compose down`) |

**Suggested threshold**

Restart count delta ≥ 5 within 1 hour for any single container → critical.

### 3.3 Autoheal noise vs. real failure

`autoheal` logs every restart it performs:

```bash
docker compose logs --tail=200 autoheal
```

A single line "restarting unhealthy container X" is normal during host
recovery (e.g. after a reboot). Repeated lines for the *same* container
within minutes are the alert-worthy signal — they mean the container goes
unhealthy almost immediately after restart. Investigate the affected
service's logs, not autoheal's.

### 3.4 Identity and Web Modeler RestAPI: management port not host-published

Both services run their Spring Boot Actuator on a *separate* internal port
that is not published to the host:

| Service | API port (host-published) | Management port (internal only) |
|---------|---------------------------|----------------------------------|
| identity | `8084 → 127.0.0.1:8084` | `8082` (`/actuator/health`) |
| web-modeler-restapi | `8081 → 127.0.0.1:8070` | `8091` (`/health/readiness`) |

This is intentional ([CLAUDE.md gotcha 2](../CLAUDE.md)) and means a
host-side `curl` to the published port will *not* reach the actuator.
Two ways to monitor these from outside the container:

```bash
# Option A — read the result of the in-container Docker healthcheck:
docker inspect --format='{{.State.Health.Status}}' identity
docker inspect --format='{{.State.Health.Status}}' web-modeler-restapi
# Returns: starting | healthy | unhealthy

# Option B — run the same probe as the healthcheck inside the container:
docker exec identity wget -q -O - http://localhost:8082/actuator/health
docker exec web-modeler-restapi wget -q -O - http://localhost:8091/health/readiness
```

Option A is preferred for unattended monitoring — Docker already runs the
HTTP probe every 30 seconds and caches the result; reading
`State.Health.Status` is cheap and consistent with §3.1's general advice.

---

## 4. Per-service probes

Every endpoint below is a plain HTTP `GET` returning `200 OK` on success
unless stated otherwise. Run on the same host as the stack; substitute
`{HOST}` with the value of `HOST` in `.env`, and `$ELASTIC_PASSWORD` with
the value from `.env`.

### 4.1 Orchestration (Zeebe + Operate + Tasklist)

Three management probes plus the gRPC gateway TCP port:

```bash
curl -fsS http://127.0.0.1:9600/actuator/health/liveness
curl -fsS http://127.0.0.1:9600/actuator/health/readiness
curl -fsS http://127.0.0.1:9600/actuator/health/startup

# Prometheus-format metrics scrape
curl -fsS http://127.0.0.1:9600/actuator/prometheus | head

# gRPC gateway TCP probe (no application-layer probe; client SDKs use this port)
nc -zv 127.0.0.1 26500
```

Liveness staying `DOWN` for > 5 minutes → critical. Readiness flapping
(toggling `UP`/`DOWN`) typically means the secondary storage (Elasticsearch
or `camunda-db`) is unhealthy — investigate those before orchestration.

### 4.2 Connectors

```bash
curl -fsS http://127.0.0.1:8086/actuator/health/readiness
curl -fsS http://127.0.0.1:8086/actuator/prometheus | head
```

A connector reports `DOWN` if its outbound dependency (e.g. an external
SaaS API) is unreachable. The container itself is still up — health is
about its *workload*, not its process state.

### 4.3 Optimize

```bash
curl -fsS http://127.0.0.1:8083/api/readyz
curl -fsS http://127.0.0.1:8083/actuator/prometheus | head
```

Optimize is fully dependent on Elasticsearch. If the ES cluster is
`yellow` or `red`, expect Optimize readiness to fail — alert on ES first
to suppress the cascading Optimize alerts.

### 4.4 Identity

The actuator port (`8082`) is not host-published. See §3.4 for the
explanation. Recommended probe:

```bash
docker inspect --format='{{.State.Health.Status}}' identity
# starting | healthy | unhealthy
```

Or, if your monitor must speak HTTP:

```bash
docker exec identity wget -q -O - http://localhost:8082/actuator/health
```

No metrics endpoint is exposed by default.

### 4.5 Keycloak

Keycloak's container port `18080` is not host-published; probe via the
reverse proxy:

```bash
# Liveness — any HTTP response confirms the process is up
curl -fskI "https://keycloak.${HOST}/auth/" | head -1

# Deeper functional probe — OIDC discovery doc must parse as JSON
curl -fsk "https://keycloak.${HOST}/auth/realms/camunda-platform/.well-known/openid-configuration" \
  | head -c 200
```

The OIDC discovery probe is the most useful single Keycloak check: if it
returns non-200 or non-JSON, **every Camunda UI login is broken**.

### 4.6 Elasticsearch

Cluster status is the headline metric. All Elasticsearch endpoints require
HTTP Basic auth.

```bash
# Cluster status — parseable JSON, look at .status (green | yellow | red)
curl -fsS -u "elastic:${ELASTIC_PASSWORD}" \
  http://127.0.0.1:9200/_cluster/health

# Index sizes, in bytes, JSON
curl -fsS -u "elastic:${ELASTIC_PASSWORD}" \
  'http://127.0.0.1:9200/_cat/indices?bytes=b&format=json'

# Per-node JVM, OS, FS, threadpool stats — JSON
curl -fsS -u "elastic:${ELASTIC_PASSWORD}" \
  'http://127.0.0.1:9200/_nodes/stats'

# Why are shards unassigned?
curl -fsS -u "elastic:${ELASTIC_PASSWORD}" \
  http://127.0.0.1:9200/_cluster/allocation/explain
```

**Suggested thresholds**

| Symptom | Severity |
|---------|----------|
| `.status == "yellow"` for > 30 min | Warn |
| `.status == "red"` (any duration) | Critical |
| `unassigned_shards > 0` for > 30 min | Warn |
| Disk usage on the ES data partition past `cluster.routing.allocation.disk.watermark.low` (85%) | Warn |
| Disk usage past `flood_stage` (95%) | Critical — indices go read-only, Camunda writes fail |

`9200` is bound to `127.0.0.1` on purpose. **Do not** publish it on a LAN
interface; the only auth in front of it is the static `elastic` password
from `.env`.

### 4.7 Console

```bash
curl -fsS http://127.0.0.1:9100/health/readiness

# Note: /prometheus, NOT /actuator/prometheus
curl -fsS http://127.0.0.1:9100/prometheus | head
```

Console aggregates other services' health internally (configured in
`.console/application.yaml.template`). That aggregation is for the Console
UI; **external monitoring should still probe each backend directly** so an
unrelated Console outage does not mask other failures.

### 4.8 Web Modeler REST API

The health port (`8091`) is not host-published — the host-bound `8070`
maps to container port `8081` (the user-facing API). See §3.4. Recommended
probe:

```bash
docker inspect --format='{{.State.Health.Status}}' web-modeler-restapi
```

Or via `docker exec`:

```bash
docker exec web-modeler-restapi \
  wget -q -O - http://localhost:8091/health/readiness
```

Metrics are not exposed by default
(`management.endpoints.web.exposure.include: health,info` in
`docker-compose.yaml`).

### 4.9 Web Modeler WebSockets

```bash
curl -fsS http://127.0.0.1:8060/up
```

No auth, no metrics. The WebSocket itself is established after Web Modeler
authentication via `web-modeler-restapi`; alerting on this endpoint
catches process death only.

### 4.10 Postgres (Identity / Keycloak DB)

The container is not host-published. Probe and size queries run via
`docker exec`:

```bash
# Liveness
docker exec postgres pg_isready -U "$POSTGRES_USER" -d "$POSTGRES_DB"

# Database size in bytes
docker exec postgres psql -U "$POSTGRES_USER" -d "$POSTGRES_DB" -At \
  -c "SELECT pg_database_size(current_database());"

# Active connections
docker exec postgres psql -U "$POSTGRES_USER" -d "$POSTGRES_DB" -At \
  -c "SELECT count(*) FROM pg_stat_activity;"
```

`$POSTGRES_USER` and `$POSTGRES_DB` come from `.env`.

### 4.11 Camunda DB (Postgres)

The Camunda core RDBMS for Zeebe / Operate / Tasklist secondary storage:

```bash
docker exec camunda-db pg_isready -U camunda -d camunda

docker exec camunda-db psql -U camunda -d camunda -At \
  -c "SELECT pg_database_size(current_database());"
```

**No automatic cleanup is configured here** — this database grows
monotonically with process instance history. Track the size trend and plan
archival when growth becomes a capacity concern. The 90-day Elasticsearch
retention ([CLAUDE.md gotcha 20](../CLAUDE.md)) does not apply to the
Camunda RDBMS; it only trims Zeebe records in `elasticsearch`.

### 4.12 Web Modeler DB (Postgres)

```bash
docker exec web-modeler-db pg_isready \
  -U "$WEBMODELER_DB_USER" -d "$WEBMODELER_DB_NAME"
```

`$WEBMODELER_DB_USER` and `$WEBMODELER_DB_NAME` come from `.env`.

### 4.13 Mailpit

Local-only test SMTP sink. Worth probing only because Web Modeler depends
on it for email flows:

```bash
nc -z 127.0.0.1 1025
# Optional UI for human inspection: http://127.0.0.1:8075
```

Alerting on Mailpit is rarely worth the noise. Skip it unless email flows
are operationally critical to your dev workflow.

### 4.14 Reverse proxy (Caddy)

```bash
# Caddy admin API — loopback only; returns the running config as JSON
curl -fsS http://127.0.0.1:2019/config/ | head

# End-to-end probe via the configured HOST
curl -fskI "https://${HOST}/" | head -1
```

The dashboard at `https://${HOST}/` renders a `/health` aggregator for
each subdomain; that page is for human operators, not for an external
monitor.

If Caddy is unhealthy, every UI is offline regardless of backend state —
treat reverse-proxy alerts as critical.

---

## 5. Logs

All services log to **stdout/stderr**, captured by the Docker daemon. There
is no persistent file logging or log rotation configured in this
repository.

```bash
# Tail one service
docker compose logs -f orchestration

# All services since 30 minutes ago
docker compose logs --since=30m

# Filter for errors
docker logs orchestration 2>&1 | grep -E 'ERROR|Exception|OOMKilled'
```

If your monitoring stack expects file-based ingestion (rsyslog, journald,
Filebeat, Fluent Bit, Vector), wire that in **out of band** — either by:

- configuring a Docker daemon log driver
  (e.g. `json-file` with `max-size`/`max-file` caps, or `syslog`,
  `journald`, `gelf`, `fluentd`)
- adding a sidecar log shipper to `docker-compose.override.yaml`

Do not modify `docker-compose.yaml` in this repository for that purpose;
keep logging integration in an override file so upstream updates merge
cleanly.

---

## 6. Stage-aware threshold reference

Container memory alerts should be computed against the *limit* in
`stages/<stage>.yaml`, not against the host total. Reference table for the
high-impact services (extracted from the stage files):

| Service | prod limit | dev limit | test limit | Heap (prod) |
|---------|-----------|-----------|------------|-------------|
| orchestration | 8192 MB / 4.0 CPU | 4096 MB / 2.0 CPU | 3072 MB / 1.5 CPU | `-Xms4500m -Xmx4500m` |
| elasticsearch | 4096 MB / 2.0 CPU | 2048 MB / 1.0 CPU | 1536 MB / 0.75 CPU | `-Xms2g -Xmx2g` (default; `dev`/`test` override via `ES_JAVA_OPTS`) |
| optimize | 3072 MB / 1.5 CPU | 1536 MB / 1.0 CPU | 1024 MB / 0.75 CPU | (no JVM tool opts in prod) |
| keycloak | 2048 MB / 1.5 CPU | 1024 MB / 1.0 CPU | 768 MB / 0.75 CPU | (Quarkus, no `-Xmx`) |
| camunda-db | 1536 MB / 1.0 CPU | 1024 MB / 0.5 CPU | 512 MB / 0.5 CPU | n/a (PostgreSQL) |
| connectors | 1024 MB / 1.0 CPU | 512 MB / 1.0 CPU | 384 MB / 0.75 CPU | varies |
| identity | 1024 MB / 1.0 CPU | 512 MB / 0.5 CPU | 384 MB / 0.5 CPU | varies |
| console | 1024 MB / 0.5 CPU | 512 MB / 0.5 CPU | 512 MB / 0.5 CPU | varies |
| web-modeler-restapi | 1024 MB / 1.0 CPU | 512 MB / 0.5 CPU | 384 MB / 0.5 CPU | varies |
| postgres | 1024 MB / 1.0 CPU | 512 MB / 0.5 CPU | 512 MB / 0.5 CPU | n/a |
| web-modeler-db | 512 MB / 0.5 CPU | 256 MB / 0.25 CPU | 256 MB / 0.25 CPU | n/a |
| reverse-proxy | 256 MB / 0.5 CPU | 128 MB / 0.25 CPU | 128 MB / 0.25 CPU | n/a (Go) |

For each entry, the recommended container alert is:

- Warn: RSS > 80 % of limit for > 10 min
- Critical: RSS > 95 % of limit for > 2 min, or any OOM exit (137)

These percentages are stage-independent; the absolute byte values follow
from the table.

---

## 7. Operational gotchas worth alerting on

These are configuration regressions that the running stack tolerates
silently for a while but eventually break user flows. Detection rules a
sysadmin can encode:

| Gotcha | Detection rule |
|--------|---------------|
| `HOST` set to a value containing uppercase letters ([CLAUDE.md 19](../CLAUDE.md)) | Read `.env` on the host; fail if `grep '^HOST=' .env` matches `[A-Z]` |
| Retention/ILM change rolled out but disk usage not dropping ([CLAUDE.md 21](../CLAUDE.md)) | Index count for `zeebe-record-*` not decreasing 24 h after policy change → manual delete required |
| Keycloak data persisted across a `HOST` change ([CLAUDE.md 5](../CLAUDE.md)) | Spike in 4xx from `keycloak.${HOST}` immediately after a `.env` edit; the `postgres` and `keycloak-theme` volumes likely need a wipe |
| Spring Boot CSRF/Origin or static-asset failures behind proxy ([CLAUDE.md 6, 7](../CLAUDE.md)) | Burst of HTTP 403 in `orchestration` / `optimize` / `identity` logs after a `Caddyfile` change |
| `/actuator/configprops` accidentally exposed ([CLAUDE.md 22](../CLAUDE.md)) | `curl -fsS http://127.0.0.1:9600/actuator/configprops` returning 200 → critical secrets-exposure alert |

---

## 8. Out of scope (covered elsewhere)

- **Backup operational signals** (last successful run, archive age, restore
  drill, encrypted-backup checks) → [backup-restore.md](backup-restore.md)
- **Resource sizing per stage** in detail → [stage_comparison.md](stage_comparison.md)
- **Configuration reference** (every setting, ILM policies, secrets
  management) → [project_configuration.md](project_configuration.md)
- **Upgrade procedures** that may shift monitoring baselines (new metrics,
  retired endpoints) → [cluster_upgrade.md](cluster_upgrade.md), `update_guide.md`
