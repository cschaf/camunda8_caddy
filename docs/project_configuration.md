# Camunda 8.9 Docker Compose — Project Configuration

This document describes every configuration in this stack, explaining what each setting does, what the default would be, and why this stack's value was chosen. It serves as the authoritative reference for why the stack is configured the way it is.

**Target server:** Depends on environment stage — see [Resource Allocation](#3-resource-allocation)
**Architecture:** Self-managed Camunda 8.9 on Docker Compose
**Purpose:** Production-oriented single-node Docker Compose profile with configurable resource tiers (prod / dev / test)

> **Production readiness note:** This is a **single-node Docker Compose profile** — not a highly available production deployment. For production environments, Camunda recommends Kubernetes with Helm (see [Camunda Self-Managed Deployment Overview](https://docs.camunda.io/docs/next/self-managed/setup/overview/)). This profile is suitable for **non-production environments** such as development, testing, and staging. Review the [Development vs Production Trade-offs](#11-development-vs-production-trade-offs) section before using this in any environment where security, durability, or availability matter.

---

## Table of Contents

1. [Architecture Overview](#1-architecture-overview)
2. [Critical Concept: HOST vs KEYCLOAK_HOST](#2-critical-concept-host-vs-keycloak_host)
3. [Resource Allocation](#3-resource-allocation)
4. [Elasticsearch Configuration](#4-elasticsearch-configuration)
5. [Zeebe/Orchestration Configuration](#5-zeebeorchestration-configuration)
6. [Identity & Keycloak Configuration](#6-identity--keycloak-configuration)
7. [Secrets Management](#7-secrets-management)
8. [Per-Service Configuration Reference](#8-per-service-configuration-reference)
9. [Reverse Proxy (Caddy)](#9-reverse-proxy-caddy)
10. [Network Architecture](#10-network-architecture)
11. [Development vs Production Trade-offs](#11-development-vs-production-trade-offs)

---

## 1. Architecture Overview

This stack deploys a full Camunda 8.9 self-managed platform with:

| Component | Image | Purpose |
|-----------|-------|---------|
| **Orchestration** | `camunda/camunda:8.9.1` | Zeebe broker + Operate + Tasklist in one container |
| **Elasticsearch** | `docker.elastic.co/elasticsearch/elasticsearch:8.19.11` | Optimize analytics storage (Optimize requires ES/OpenSearch) |
| **camunda-db** | `postgres:${POSTGRES_VERSION}` | Camunda core operational data (Zeebe, Operate, Tasklist) |
| **Identity** | `camunda/identity:8.9.1` | Centralized identity, OIDC provider integration, role management |
| **Keycloak** | `bitnamilegacy/keycloak:26.3.2` | OIDC identity provider, realm/client setup, user authentication |
| **Optimize** | `camunda/optimize:8.9.1` | Process analytics and optimization |
| **Connectors** | `camunda/connectors-bundle:8.9.1` | Outbound integrations and webhooks |
| **Web Modeler** | `camunda/web-modeler-restapi:8.9.1` | BPMN process modeling (REST API serves UI + WebSockets) |
| **Console** | `camunda/console:8.9.26` | Cluster overview and management UI |
| **PostgreSQL** (×2) | `postgres:15-alpine3.22` | Identity/Keycloak DB + Web Modeler DB |
| **Caddy** | `caddy:2.11.2@sha256:25cdc846626b62d05f6b633b9b40c2c9f6ef89b515dc76133cefd920f7dbe562` | Reverse proxy with automatic HTTPS and subdomain routing |
| **Autoheal** | `willfarrell/autoheal@sha256:75c28b0020543e8eb49fe6514d012e7d2691f095dd622309d045da8647c8bb83` | Restarts labeled containers when Docker health checks mark them as unhealthy |

### Container Networks

Three Docker networks isolate traffic:

- **`camunda-platform`** — Main platform: orchestration, connectors, optimize, console, elasticsearch, keycloak, identity, web-modeler-restapi, camunda-db, reverse-proxy
- **`identity-network`** — Keycloak ↔ PostgreSQL (identity DB) ↔ Identity
- **`web-modeler`** — web-modeler-db ↔ mailpit ↔ web-modeler-restapi ↔ web-modeler-websockets; also connects to `camunda-platform` to reach orchestration and identity

---

## 2. Critical Concept: HOST vs KEYCLOAK_HOST

This distinction is the most important routing concept in the stack:

```
HOST=camunda.dev.local           # Browser-facing URLs (redirects, callbacks, UI)
KEYCLOAK_HOST=keycloak           # Internal container-to-container communication
```

**Why:** Inside a container, `localhost` refers to the container itself, not other containers. Using `keycloak` (the container name) allows Docker's internal DNS to resolve the actual Keycloak IP.

| Variable | Used by | Purpose |
|----------|---------|---------|
| `${HOST}` | Browser, Caddy, Spring Boot services | External URLs in redirect URIs, issuer URLs the browser sees |
| `${KEYCLOAK_HOST}` | Services inside containers | Token validation endpoints, JWKS lookups, OIDC back-channel calls |

**Example:**
```yaml
# Browser visits this (via ${HOST})
CAMUNDA_SECURITY_AUTHENTICATION_OIDC_AUTHORIZATIONURI: https://keycloak.camunda.dev.local/auth/realms/camunda-platform/...

# Container uses this (via ${KEYCLOAK_HOST})
CAMUNDA_SECURITY_AUTHENTICATION_OIDC_TOKENURI: http://keycloak:18080/auth/realms/.../token
```

**Rule of thumb:**
- `${HOST}` appears in URLs the **browser** visits (authorization endpoints, redirect URIs)
- `${KEYCLOAK_HOST}` appears in URLs for **service-to-service** token validation and JWKS lookups

---

## 3. Resource Allocation

Resources are managed through **environment stages**. The `STAGE` variable in `.env` selects a profile (`prod`, `dev`, or `test`) that Docker Compose merges on top of the base `docker-compose.yaml`. Each profile overrides `deploy.resources` limits and reservations, and for JVM services, scales heap sizes proportionally to prevent OOM kills.

For a complete side-by-side comparison of all stages, see [docs/stage_comparison.md](stage_comparison.md).

### Base (Production) Profile

The following table shows the **base** resource configuration — what the `prod` stage uses. This is the reference profile calibrated for a 16 vCPU / 32 GB RAM Linux server. The summed per-container CPU limits keep a small intentional CPU overcommit buffer, so treat them as aggregate caps rather than required physical cores.

| Service | CPU limit | Memory limit | Memory reservation | JVM Heap | Heap Rationale |
|---------|-----------|--------------|-------------------|----------|----------------|
| elasticsearch | 2.0 | 4G | 3G | `-Xms2g -Xmx2g` | 50% of limit (Lucene uses remaining for OS page cache); reduced because ES now serves Optimize only |
| orchestration | 4.0 | 8G | 4G | `-Xms4500m -Xmx4500m` | 57% of limit; Zeebe broker + embedded Operate/Tasklist; leaves 3.5G for RocksDB off-heap, Netty buffers, and OS page cache |
| optimize | 1.5 | 3G | 1536m | `-Xms2304m -Xmx2304m` | 75% of limit (2304m); JVM-based analytics service |
| keycloak | 1.5 | 2G | 512m | — | Quarkus-based, no JVM heap setting needed |
| connectors | 1.0 | 1G | 512m | `-Xmx768m` | 75% of limit; outbound integrations only |
| identity | 1.0 | 1G | 256m | `-Xms256m -Xmx768m` | 75% of limit; Spring Boot service |
| console | 0.5 | 1G | 512m | `-Xms256m -Xmx768m` | 75% of limit; Node.js but has a JVM sidecar for metrics |
| web-modeler-restapi | 1.0 | 1G | 512m | `-Xmx768m` | 75% of limit; Java REST API + webapp UI (8.9+) |
| postgres (identity) | 1.0 | 1G | 512m | — | No JVM; PostgreSQL manages own memory |
| postgres (web-modeler) | 0.5 | 512m | 256m | — | No JVM |
| camunda-db | 1.0 | 1536M | 768M | — | No JVM; core Camunda operational DB; handles all Zeebe, Operate, Tasklist data since 8.9 |
| reverse-proxy | 0.5 | 256m | 64m | — | Caddy Go process |
| web-modeler-websockets | 0.5 | 256m | 64m | — | Node.js WebSocket server |
| mailpit | 0.25 | 128m | 32m | — | Go SMTP server |

**Aggregate CPU limits:** ~17.75 cores, **Total limits:** ~27.2 GB, **Total reservations:** ~16.2 GB
Leaves ~15.7 GB headroom for the OS and burst.

> **Autoheal note:** `autoheal` is intentionally not part of the stage-based resource tables. It is a lightweight operational sidecar with no explicit `deploy.resources` overrides in this stack, so its footprint is negligible compared with the Camunda services it monitors.

### Reduced Profiles

| Stage | Target hardware | Total memory limits | Typical use |
|-------|----------------|---------------------|-------------|
| `dev` | 8 vCPU / 16 GB RAM workstation | ~15 GB | Local development on laptops or smaller VMs |
| `test` | 6 vCPU / 12 GB RAM host | ~11 GB | CI runners, integration test environments |

Reduced profiles halve (dev) or quarter (test) CPU and memory limits for heavy and medium services, and scale JVM heaps proportionally — Elasticsearch to 50% of its reduced limit, all other JVM services to 75%.

### Why 75% for JVM services?

JVM services (orchestration, connectors, optimize, web-modeler-restapi, console) use the HotSpot JVM with garbage collection. A heap set to 75% of the container limit leaves room for:
- Metaspace (class metadata)
- Thread stacks
- Off-heap buffers (Netty, etc.)
- GC overhead headroom

> **Exception — Orchestration at ~57%:** The Zeebe broker runs its RocksDB state store **off-heap** (via direct I/O), which can consume 1–2 GB+ under moderate load. The orchestration container's 8G limit and 4.5G heap leaves ~3.5G for RocksDB block cache, WAL buffers, and OS page cache — sufficient for sustained throughput. Do not reduce the heap below 4.5G without monitoring RocksDB I/O wait metrics.

### Why 50% for Elasticsearch?

Elasticsearch uses Lucene for full-text indexing. Lucene maintains an **off-heap OS page cache** for indexed segments. Setting the heap to 50% and leaving the other 50% free allows Lucene to cache hot index segments in memory, dramatically improving search performance. A heap that fills up causes GC pauses; a heap that's too small starves the JVM. 50% is the Elasticsearch-recommended balance.

---

## 4. Elasticsearch Configuration

Elasticsearch is retained for **Optimize**. Camunda core operational query data (Operate process instances, Tasklist user tasks, authorizations, and API search data) is stored in the dedicated `camunda-db` PostgreSQL service via RDBMS secondary storage. Elasticsearch still stores Optimize's own `optimize-*` indices and the Zeebe exporter's `zeebe-record-*` indices, which Optimize imports as its source data.

### Environment Variables in docker-compose.yaml

```yaml
environment:
  - bootstrap.memory_lock=true                     # Prevent Elasticsearch swapping
  - discovery.type=single-node                     # No clustering (single-node dev/prod)
  - xpack.security.enabled=true                    # Require Basic Auth for Elasticsearch API
  - cluster.max_shards_per_node=1000              # Realistic limit for single-node (was 3000)
  - "action.auto_create_index=.security*,zeebe-record*,operate-*,tasklist-*,optimize-*,camunda-*,web-modeler-*,identity-*"
  - indices.memory.index_buffer_size=20%           # Larger indexing buffer for write throughput
  - cluster.routing.allocation.disk.watermark.low=85%
  - cluster.routing.allocation.disk.watermark.high=90%
  - cluster.routing.allocation.disk.watermark.flood_stage=95%
  - indices.breaker.total.limit=75%                # Circuit breaker for aggregations
  - "ES_JAVA_OPTS=-Xms2g -Xmx2g"                  # 2 GB heap
```

### Setting Explanations

| Setting | Value | Default | Why |
|---------|-------|---------|-----|
| `bootstrap.memory_lock=true` | `true` | `false` | Lock Elasticsearch's memory at boot using `mlockall`. Prevents the OS from swapping ES pages to disk, which would cause catastrophic latency spikes. Elasticsearch is a latency-sensitive in-memory store. |
| `discovery.type=single-node` | `single-node` | `multi-node` | This stack runs a single Elasticsearch node. Multi-node would require a cluster with minimum master node quorum. `single-node` disables shard allocation fencing that would otherwise reject writes. |
| `xpack.security.enabled=true` | `true` | `true` | Security (Basic Auth) is enabled. All internal services authenticate with the `elastic` user and `ELASTIC_PASSWORD`. The host API on `127.0.0.1:9200` also requires credentials. Backup and restore scripts source the password from `.env`. |
| `cluster.max_shards_per_node=1000` | `1000` | `1000` | **Hard cap on the total number of shards this single node can hold.** The previous value of `3000` allowed Elasticsearch to create so many shards that the JVM heap was exhausted before the limit was reached, causing OOM and cluster instability. On an 8 GB single-node, each shard carries ~10–30 MB of heap overhead. 1000 shards is the Elasticsearch 8.x default and a realistic ceiling for this node size. |
| `cluster.routing.allocation.disk.watermark.low=85%` | `85%` | `85%` | Elasticsearch stops allocating shards to a node when disk usage reaches 85%. Gives operators time to add storage before the node goes read-only. |
| `cluster.routing.allocation.disk.watermark.high=90%` | `90%` | `90%` | Elasticsearch blocks shard allocation entirely above 90%. Combined with flood_stage at 95%, gives two warning thresholds before read-only lock. |
| `cluster.routing.allocation.disk.watermark.flood_stage=95%` | `95%` | `95%` | At 95%, Elasticsearch marks all indices on the node as read-only (`index.blocks.read_only_allow_delete`). Requires manual intervention to clear. The gap between 90% and 95% gives operators a window to react. |
| `indices.breaker.total.limit=75%` | `75%` | `70%` | The parent circuit breaker limit for all sub-breakers (fielddata, request, in-flight). 75% of JVM heap. Raised slightly from 70% because Optimize performs large aggregations that can approach the limit. If this trips, it causes `TooManyBookmarks` or aggregation failures in Optimize. |
| `ES_JAVA_OPTS=-Xms2g -Xmx2g` | `2g` | 50% of container | 2 GB heap (50% of the 4 GB limit) for Lucene to use the other ~2 GB as off-heap page cache. Scaled down proportionally in `dev` and `test` stages. |
| `action.auto_create_index=...` | Whitelist (Camunda patterns) | `true` | Prevents rogue services or typos from creating indices outside known patterns. A whitelist (instead of blanket `false`) is safer because Optimize and Web Modeler restapi may auto-create indices on first startup before their templates are registered. All known Camunda index prefixes are explicitly allowed: `zeebe-record*`, `operate-*`, `tasklist-*`, `optimize-*`, `camunda-*`, `web-modeler-*`, `identity-*`. |
| `indices.memory.index_buffer_size=20%` | `20%` | `10%` | The percentage of JVM heap reserved for the indexing buffer. A larger buffer allows Elasticsearch to batch more in-memory writes before flushing to disk, improving throughput for Camunda's high-volume event stream. 20% is appropriate given the 4 GB heap and write-heavy workload. |

### Index Lifecycle Management (ILM) and Data Retention

This stack creates two Elasticsearch index families:

- **Zeebe exporter** writes one index per record type per day (`zeebe-record-*`) so Optimize can import process, variable, incident, and user task data.
- **Optimize** maintains its own analytics indices under the `optimize-` prefix.

Without cleanup, these indices accumulate indefinitely. The old configuration had **no retention policies**, which led to:

1. **Shard exhaustion** — Each daily index defaults to 3 shards (Zeebe exporter). With ~15 record types, that is ~45 new shards per day. In 30 days: ~1,350 shards. The old `max_shards_per_node=3000` merely delayed the failure instead of preventing it.
2. **Disk bloat** — Zeebe exporter records and Optimize analytics data accumulate forever.
3. **Query degradation** — Elasticsearch must keep metadata for every shard in heap. Beyond ~500–800 shards on an 8 GB node, query latency degrades and the node becomes unstable.

**The fix: retention on each remaining Elasticsearch data family.**

| Component | Retention Mechanism | Minimum Age | What Gets Deleted |
|-----------|-------------------|-------------|-------------------|
| Zeebe Exporter | ILM policy on index templates | 90 days | Old `zeebe-record-*` daily indices |
| Optimize | Optimize's built-in cleanup | 365 days (configured in `.optimize/environment-config.yaml`) | Process data older than 365 days |

**Why two tiers?** Raw Zeebe exporter records are kept for 90 days as Optimize import source data. Optimize keeps analytical data for 365 days (12 months) so year-over-year comparisons and full annual trend reports remain possible. Operate and Tasklist query PostgreSQL through Camunda 8.9 RDBMS secondary storage, so their retention is no longer controlled by Elasticsearch archiver ILM in this stack.

**Shard reduction:** The Zeebe exporter and Optimize are configured with one shard per index. On a single-node deployment, multiple shards provide zero parallelism — the node cannot distribute shards to other nodes. Each additional shard only adds heap overhead (mappings, segments, bitsets). Reducing from 3 to 1 cuts total shard count by ~67%.

> **Note:** These settings only affect **newly created indices**. Existing indices retain their original shard count. The ILM policies are applied to index templates and will take effect on the next rollover or daily index creation. To force an immediate cleanup of old indices, use the Elasticsearch Delete Index API or reduce `minimum-age` temporarily in a dev environment.

### Previously Removed: `cluster.routing.allocation.disk.threshold_enabled=false`

The old configuration had `disk.threshold_enabled=false` which **completely disabled disk monitoring**. This meant Elasticsearch would keep writing until the disk was completely full, causing index corruption and complete failure. This has been removed — the watermark thresholds above now provide proper guardrails.

---

## 5. Zeebe/Orchestration Configuration

Configuration lives in `.orchestration/application.yaml`, mounted into the orchestration container.

### Thread Configuration

```yaml
camunda:
  system:
    cpu-thread-count: 4
    io-thread-count: 4
```

| Setting | Value | Default | Why |
|---------|-------|---------|-----|
| `camunda.system.cpu-thread-count` | `4` | `2` | Number of threads for processing workflow commands. With 4 CPU cores allocated, using 4 threads maximizes throughput. |
| `camunda.system.io-thread-count` | `4` | `2` | Number of threads for IO-bound operations (network, disk). Having 4 IO threads allows the broker to handle concurrent export/disk operations without blocking CPU threads. |

### Disk Watermarks

```yaml
camunda:
  data:
    primary-storage:
      disk:
        free-space:
          processing: 2GB
          replication: 1GB
```

| Setting | Value | Default | Why |
|---------|-------|---------|-----|
| `camunda.data.primary-storage.disk.free-space.processing` | `2GB` | `2GB` | Minimum free disk space before the broker rejects client commands and pauses processing. This is intentionally low enough for local/dev Docker volumes while still leaving space for log compaction and snapshots. |
| `camunda.data.primary-storage.disk.free-space.replication` | `1GB` | `1GB` | Minimum free disk space before the broker stops receiving replicated events. Camunda 8.9 validates that `processing` is greater than `replication`; `2GB/1GB` matches that rule and the upstream defaults. |

The free-space thresholds are not stage-specific. The `prod`, `dev`, and `test` overlays scale CPU/RAM/JVM heap, but they do not change Docker volume capacity. On the current Docker Desktop volume, Orchestration sees roughly 63 GB total and 38 GB free, so `2GB/1GB` leaves ample headroom.

### RDBMS Secondary Storage

In Camunda 8.9, core operational data (Zeebe records, Operate process instances, Tasklist user tasks, authorizations) is stored in PostgreSQL via `camunda.data.secondary-storage`. The Camunda 8.9 image auto-configures the exporter based on this setting — no manual `zeebe.broker.exporters` block is required.

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

| Setting | Value | Default | Why |
|---------|-------|---------|-----|
| `data.secondary-storage.type` | `rdbms` | `rdbms` (8.9+) | Tells the unified orchestration container to use PostgreSQL for Operate/Tasklist data and to auto-configure the exporter for RDBMS. |
| `data.secondary-storage.rdbms.url` | `jdbc:postgresql://camunda-db:5432/camunda` | (none) | JDBC URL pointing to the dedicated `camunda-db` container. |
| `data.secondary-storage.rdbms.username` | `camunda` | (none) | PostgreSQL user for the Camunda database. |
| `data.secondary-storage.rdbms.password` | `${CAMUNDA_DB_PASSWORD}` | (none) | Password injected from `.env`. |

**Why no manual exporter configuration?** Manually configuring `zeebe.broker.exporters.camunda` with `connect.type: rdbms` causes a startup error because the `CamundaExporter` class only supports `ELASTICSEARCH` and `OPENSEARCH`. The orchestration image auto-configures the correct exporter when `secondary-storage.type` is `rdbms`.

**Migration note:** There is **no automatic in-place migration path** from document-store secondary storage to RDBMS secondary storage in Camunda 8.9. Changing `camunda.data.secondary-storage.type` to `rdbms` on an existing installation starts reading Operate/Tasklist/API query data from the RDBMS backend; historical data that only exists in Elasticsearch/OpenSearch is not automatically moved. Plan this as a fresh secondary-store setup or a validated migration procedure in a non-production environment.

### PostgreSQL vs Elasticsearch: Decision Guide

Camunda 8 supports two backends for core operational data (Zeebe records, Operate process instances, Tasklist user tasks): **PostgreSQL (RDBMS)** and **Elasticsearch**. This stack uses **PostgreSQL** for core data and retains **Elasticsearch only for Optimize**, which still requires it.

#### PostgreSQL (RDBMS) — Current Stack Choice

| Aspect | Details |
|--------|---------|
| **Best for** | Smaller to medium deployments, teams with SQL expertise, simpler operational stacks |
| **Pros** | Simpler operations (one less technology); ACID transactions; smaller resource footprint; SQL is widely known |
| **Cons** | Less powerful for complex aggregations and full-text search; horizontal scaling is harder than Elasticsearch; newer feature support may lag behind ES |
| **When to choose** | Datenvolumen is manageable (e.g., < 1 Mio. Prozessinstanzen/Jahr); team has no Elasticsearch expertise; primary use case is operational process execution rather than deep historical analytics |

#### Elasticsearch

| Aspect | Details |
|--------|---------|
| **Best for** | Very large data volumes, complex analytics, full-text search on process variables |
| **Pros** | Excellent horizontal scalability; mature Camunda integration (longer in use); powerful aggregations and search; Optimize requires it anyway |
| **Cons** | Higher operational complexity (clustering, shards, ILM); larger RAM/CPU footprint; requires ES-specific expertise |
| **When to choose** | Millions of process instances; heavy historical data analysis; quarterly/year-over-year trend reporting; team already operates Elasticsearch |

#### Why This Stack Uses PostgreSQL + Elasticsearch

- **PostgreSQL (`camunda-db`)** handles all Camunda core operational data — Zeebe records, Operate instances, Tasklist user tasks, authorizations. This reduces resource pressure on Elasticsearch and simplifies operations for the primary workflow data.
- **Elasticsearch** is retained solely for **Optimize**, which has no RDBMS backend option. Optimize stores aggregated, compact analytical data, so the ES resource consumption is lower than it would be if ES also indexed all raw operational data.

**Rule of thumb:**
- Use **PostgreSQL** if you want a leaner stack and your data volumes are moderate.
- Use **Elasticsearch** if you expect massive scale, need advanced search/aggregations on process data, or already run ES clusters for Optimize and want a single backend.

> **Note:** In Camunda 8.9, switching from Elasticsearch to RDBMS (or back) is only possible on **fresh installations**. There is no migration tool — historical data remains in the old backend and becomes invisible to the new one.

### Operate and Tasklist Retention

Operate and Tasklist run on Camunda 8.9 RDBMS secondary storage in this stack. Their query data is stored in PostgreSQL (`camunda-db`), not in `operate-*` or `tasklist-*` Elasticsearch archive indices. For that reason, `.orchestration/application.yaml` intentionally does not configure `camunda.operate.archiver.*` or `camunda.tasklist.archiver.*` keys. Those archiver ILM settings are only relevant when Operate/Tasklist use Elasticsearch/OpenSearch as their secondary-storage backend.

### Optimize Data Retention

> **Note:** The `number_of_shards: 1` setting in `.optimize/environment-config.yaml` only reduces shard overhead per index — it does not delete old data. Retention is configured separately via `historyCleanup`.

History cleanup is pre-configured in `.optimize/environment-config.yaml`:

```yaml
historyCleanup:
  cronTrigger: '0 1 * * *'
  ttl: 'P365D'
  processDataCleanup:
    enabled: true
```

| Setting | Value | Description |
|---------|-------|-------------|
| `cronTrigger` | `0 1 * * *` | Runs daily at 01:00 UTC |
| `ttl` | `P365D` | Deletes process data older than 365 days (12 months, ISO 8601) |
| `processDataCleanup.enabled` | `true` | Enables automated cleanup |

Optimize keeps a longer retention than the orchestration components (365 days vs 90 days) because it serves analytical use cases — quarterly comparisons, year-over-year trend reports — and stores aggregated rather than raw data, so the disk impact of the longer window is small.

To change the retention period, edit `ttl` in `.optimize/environment-config.yaml` and restart the Optimize container. You can also configure this via the Optimize Admin UI at **Administration → History Cleanup**.

**Verifying the configuration:** After restarting Optimize, check the container logs for:
```
Initializing OptimizeCleanupScheduler
Starting cleanup scheduling
```
These messages confirm the scheduler is active. No errors or warnings related to `historyCleanup` should appear.

To test the cleanup job without waiting for the scheduled time, temporarily change `cronTrigger` to a near-future time (e.g. `*/5 * * * *` for every 5 minutes), restart the container, wait for the job to run, then revert the trigger.

Without this configuration, `optimize-*` indices grow indefinitely. Shard exhaustion is slowed by `number_of_shards: 1`, but not prevented.

### Snapshot Period

```yaml
camunda:
  data:
    primary-storage:
      snapshot-period: 5m
```

| Setting | Value | Default | Why |
|---------|-------|---------|-----|
| `camunda.data.primary-storage.snapshot-period` | `5m` | `5m` | Snapshots are taken every 5 minutes. A shorter period means more frequent snapshots but higher IO. 5m balances recovery time (RTO) against IO overhead. |

### Security and Authentication

```yaml
security:
  authentication:
    method: "oidc"
    unprotectedApi: false
  authorizations:
    enabled: true
```

| Setting | Value | Default | Why |
|---------|-------|---------|-----|
| `method` | `oidc` | — | OIDC authentication for all APIs |
| `unprotectedApi` | `false` | `false` | No endpoints are left unauthenticated |
| `authorizations.enabled` | `true` | `false` | Enables Camunda's resource-based authorization (users/groups can be scoped to specific process definitions). **Required for production** — prevents users from seeing processes they shouldn't access. |

### Unified Secondary Storage Configuration

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

| Setting | Value | Default | Why |
|---------|-------|---------|-----|
| `camunda.data.secondary-storage.type` | `rdbms` | varies by distribution/profile | Uses PostgreSQL for Camunda core operational query data instead of Elasticsearch/OpenSearch. |
| `camunda.data.secondary-storage.rdbms.url` | `jdbc:postgresql://camunda-db:5432/camunda` | none | Points Orchestration, Operate, Tasklist, and query APIs at the dedicated Camunda PostgreSQL database. |
| `camunda.data.secondary-storage.rdbms.username` | `camunda` | none | PostgreSQL user for the Camunda database. |
| `camunda.data.secondary-storage.rdbms.password` | `${CAMUNDA_DB_PASSWORD}` | none | Password injected from `.env`; no hardcoded fallback. |

---

## 6. Identity & Keycloak Configuration

### Identity Service (`identity:` in docker-compose.yaml)

Key environment variables passed to the identity container:

| Variable | Purpose |
|----------|---------|
| `IDENTITY_DATABASE_*` | PostgreSQL connection for Identity's own data |
| `VALUES_KEYCLOAK_INIT_*_SECRET` | Client secrets for the Keycloak initialization (creates OIDC clients in Keycloak) |
| `KEYCLOAK_ADMIN_USER/PASSWORD` | Admin credentials for the Keycloak Admin API (used during first startup to configure the realm) |
| `HOST`, `KEYCLOAK_HOST` | Public and internal hostnames for callback URL construction |
| `RESOURCE_PERMISSIONS_ENABLED` | Maps to `RESOURCE_AUTHORIZATIONS_ENABLED` in `.env` — enables Camunda's resource-based auth |
| `CAMUNDA_IDENTITY_CLIENT_SECRET` | OIDC client secret for the identity service itself (machine-to-machine) |
| `DEMO_USER_PASSWORD` | Password for the demo user account (replaces hardcoded "demo") |

### `.identity/application.yaml` — Key Settings

**Keycloak realm initialization:**
The identity service uses this file to:
1. Create OIDC clients in Keycloak (orchestration, connectors, optimize, console, web-modeler)
2. Configure client secrets, redirect URIs, and allowed origins
3. Set up the demo user with all required roles

**Hardcoded fallbacks removed:**
All `${VAR:default}` patterns have been removed. The stack now **fails fast** at startup if a required environment variable is missing, rather than silently using weak defaults like `admin`, `demo`, or `secret`.

**Demo user wiring:**
```yaml
users:
  - username: "demo"
    password: "${DEMO_USER_PASSWORD}"  # No hardcoded fallback
```

The demo user is assigned these roles:
- `ManagementIdentity` — Full access to Identity management
- `Optimize` — Access to Optimize
- `Web Modeler` — Access to Web Modeler
- `Web Modeler Admin` — Elevated Web Modeler access
- `Console` — Access to Console
- `Orchestration` — Access to Operate/Tasklist

### Keycloak Service Environment Variables

| Variable | Value | Why |
|----------|-------|-----|
| `KC_HTTP_PORT=18080` | Native Keycloak HTTP port | Current Keycloak/Bitnami 26+ setting for the HTTP listener; mirrors the legacy `KEYCLOAK_HTTP_PORT` value |
| `KC_HTTP_RELATIVE_PATH=/auth` | Native Keycloak relative path | Current Keycloak/Bitnami 26+ setting for serving Keycloak under `/auth`; mirrors the legacy `KEYCLOAK_HTTP_RELATIVE_PATH` value |
| `KC_HOSTNAME=https://keycloak.${HOST}/auth` | Canonical public issuer URL | Forces Keycloak's OIDC discovery and issued tokens to use the browser-facing HTTPS issuer, avoiding refresh-token failures such as `invalid_grant: Invalid token issuer` |
| `KC_PROXY_HEADERS=xforwarded` | Native proxy header setting | Current Keycloak/Bitnami 26+ setting that trusts Caddy's `X-Forwarded-*` headers |
| `KEYCLOAK_HTTP_PORT=18080` | Non-standard port | Avoids conflict with other services on 8080; matches `KEYCLOAK_HOST=keycloak` in the Docker network |
| `KEYCLOAK_HTTP_RELATIVE_PATH=/auth` | Required path | Keycloak requires this path prefix; the `KEYCLOAK_HOST=keycloak` means containers call `http://keycloak:18080/auth` |
| `KEYCLOAK_DATABASE_HOST=postgres` | Docker DNS name | Keycloak connects to the PostgreSQL container by name, not localhost |
| `KEYCLOAK_PROXY_HEADERS=xforwarded` | Legacy proxy header setting | Kept for compatibility with older Bitnami images; the active setting for Keycloak 26+ is `KC_PROXY_HEADERS` |

---

## 7. Secrets Management

### Generated Secrets (`scripts/generate-secrets.sh` / `.ps1`)

The `generate-secrets.sh` script creates a production-quality `.env` file:

- **Aborts if `.env` exists** unless `--force` is passed — prevents accidental overwrite of live secrets
- **Reads non-secret values from `.env.example`** — preserves image versions, HOST, KEYCLOAK_HOST, etc.
- **Generates 48-character hex secrets** using `openssl rand -hex 24` (bash) or `[System.Security.Cryptography.RandomNumberGenerator]::GetBytes(24)` (PowerShell)
- **Sets `chmod 600`** on the generated `.env` (bash only)

### Secrets Generated

| Secret | Used by | Purpose |
|--------|---------|---------|
| `ORCHESTRATION_CLIENT_SECRET` | Orchestration, Keycloak | OIDC client secret for Operate/Tasklist |
| `CONNECTORS_CLIENT_SECRET` | Connectors, Keycloak | OIDC client secret for outbound integrations |
| `CONSOLE_CLIENT_SECRET` | Console, Keycloak | OIDC client secret for Console |
| `OPTIMIZE_CLIENT_SECRET` | Optimize, Keycloak | OIDC client secret for Optimize |
| `CAMUNDA_IDENTITY_CLIENT_SECRET` | Identity, Keycloak | OIDC client secret for Identity service (m2m) |
| `POSTGRES_PASSWORD` | PostgreSQL (identity DB), Keycloak | Database password for Keycloak's PostgreSQL |
| `WEBMODELER_DB_PASSWORD` | PostgreSQL (web-modeler DB), web-modeler-restapi | Database password for Web Modeler's PostgreSQL |
| `KEYCLOAK_ADMIN_PASSWORD` | Keycloak | Keycloak admin console password |
| `WEBMODELER_PUSHER_KEY` | web-modeler-restapi, web-modeler-websockets | Pusher WebSocket authentication |
| `WEBMODELER_PUSHER_SECRET` | web-modeler-websockets | Pusher WebSocket authentication |
| `DEMO_USER_PASSWORD` | Identity (creates demo user) | Password for the demo user account |
| `ELASTIC_PASSWORD` | Elasticsearch, Optimize, orchestration, backup/restore scripts | Password for the Elasticsearch `elastic` user; used by Optimize and Zeebe Exporter for authenticated ES access |
| `CAMUNDA_DB_PASSWORD` | `camunda-db`, orchestration | Database password for the Camunda core PostgreSQL database |

### Why No Hardcoded Fallbacks?

Before this production readiness work, `.identity/application.yaml` contained fallbacks like:
```yaml
secret: ${CAMUNDA_IDENTITY_CLIENT_SECRET:demo-identity-secret}
password: "${KEYCLOAK_ADMIN_PASSWORD:admin}"
```

This means if the environment variable was missing, the service would start with `demo-identity-secret` or `admin`. In production, this is a security risk — you'd never know the weak secret was being used. Now the stack fails at startup with a clear error if any required secret is missing.

---

## 8. Per-Service Configuration Reference

### Orchestration

**Image:** `camunda/camunda:${CAMUNDA_VERSION}`

**Ports:** 26500 (Zeebe gRPC), 9600 (actuator/metrics), 8088 (Operate/Tasklist REST)

**Key env vars:**
- `CAMUNDA_SECURITY_AUTHENTICATION_OIDC_*` — All OIDC settings: issuer URL, token URL, JWKS URI, redirect URI, audiences, claims mapping
- `ZEEBE_BROKER_GATEWAY_SECURITY_AUTHENTICATION_IDENTITY_ISSUERBACKENDURL` — Internal URL for Zeebe's own auth (used for inter-broker communication)
- `CAMUNDA_IDENTITY_ISSUERBACKENDURL` — Internal URL for the identity service
- `CAMUNDA_IDENTITY_BASEURL` — Internal URL for identity service API calls
- `ELASTIC_PASSWORD` — Passed to the container; used by the Zeebe Elasticsearch Exporter and Camunda database Elasticsearch client for authenticated ES access

**OIDC URL split:**
```
Browser → https://keycloak.camunda.dev.local (via ${HOST})
Container → http://keycloak:18080 (via ${KEYCLOAK_HOST})
```

This distinction is critical: the browser must see the public HTTPS URL in the authorization request, but the container needs the internal HTTP URL to exchange the auth code for a token without a certificate error.

### Connectors

**Image:** `camunda/connectors-bundle:${CAMUNDA_CONNECTORS_VERSION}`

**Port:** 8086

**Key env vars:**
- `CAMUNDA_CLIENT_RESTADDRESS=http://orchestration:8080` — Internal REST endpoint for the Zeebe client
- `CAMUNDA_CLIENT_GRPCADDRESS=http://orchestration:26500` — Internal gRPC endpoint
- `CAMUNDA_CLIENT_AUTH_*` — OIDC credentials for authenticating to the Zeebe gateway

**Secrets:** Connectors reads additional secrets from `connector-secrets.txt` (gitignored env_file), which holds outbound connector secrets (e.g., HTTP basic auth credentials for external systems).

### Optimize

**Image:** `camunda/optimize:${CAMUNDA_OPTIMIZE_VERSION}`

**Port:** 8083 → container 8090

**Key env vars:**
- `OPTIMIZE_ELASTICSEARCH_HOST=elasticsearch` — Docker DNS name for ES
- `ELASTIC_PASSWORD` — Passed to Optimize container; also used in `.optimize/environment-config.yaml` for ES Basic Auth
- `SPRING_PROFILES_ACTIVE=ccsm` — "Camunda Cloud Self Managed" profile activates Optimize's self-managed mode
- `CAMUNDA_OPTIMIZE_IDENTITY_ISSUER_URL=https://keycloak.${HOST}/...` — Browser-facing issuer URL
- `CAMUNDA_OPTIMIZE_IDENTITY_ISSUER_BACKEND_URL=http://${KEYCLOAK_HOST}:18080/...` — Internal issuer URL
- `SERVER_FORWARD_HEADERS_STRATEGY=framework` — Required behind Caddy proxy for correct URL construction

**Important:** Optimize shares the platform `elasticsearch` container but maintains its own indices under the `optimize-` prefix. Camunda core data (Operate, Tasklist, Zeebe) is stored in PostgreSQL (`camunda-db`), so only Optimize uses Elasticsearch indices.

**Elasticsearch authentication:** Optimize connects to Elasticsearch with Basic Auth via `.optimize/environment-config.yaml`. The `generate-secrets` scripts create this file from `.optimize/environment-config.yaml.example`, substituting the generated `ELASTIC_PASSWORD`. The generated file is gitignored — never commit it.

### Identity

**Image:** `camunda/identity:${CAMUNDA_IDENTITY_VERSION}`

**Port:** 8084

**Key env vars:**
- `IDENTITY_DATABASE_HOST=postgres` — The PostgreSQL container for Identity's own data
- `VALUES_KEYCLOAK_INIT_*_SECRET` — Client secrets passed to Keycloak during realm initialization
- `RESOURCE_PERMISSIONS_ENABLED=${RESOURCE_AUTHORIZATIONS_ENABLED}` — Enables resource-based authorization

**Health check probe port:** Identity's health check uses port 8082 (actuator), which is different from the main server port 8084. This is why `healthcheck test: "http://localhost:8082/actuator/health"` works correctly.

### Keycloak

**Image:** `bitnamilegacy/keycloak:${KEYCLOAK_SERVER_VERSION}`

**Port:** 18080

Keycloak is the OIDC provider. On first startup, Identity calls the Keycloak Admin API (`KEYCLOAK_ADMIN_USER/PASSWORD`) to:
1. Create the `camunda-platform` realm
2. Create OIDC clients for each service with correct redirect URIs
3. Configure mappers for custom claims (user roles, client ID)

### Console

**Image:** `camunda/console:${CAMUNDA_CONSOLE_VERSION}`

**Ports:** 8087 (UI), 9100 (metrics)

**Key env vars:**
- `KEYCLOAK_BASE_URL=https://keycloak.${HOST}/auth` — Browser-facing URL
- `KEYCLOAK_INTERNAL_BASE_URL=http://${KEYCLOAK_HOST}:18080/auth` — Internal URL for Node.js service-to-service calls
- `NODE_ENV=production` — Runs Console in production mode (disables some dev-only features)

**Configuration:** Console reads its cluster layout from `.console/application.yaml`, which is generated from `.console/application.yaml.template` by the start scripts on every run. The template defines the components Console displays, including:

- **Orchestration cluster** (`id: orchestration`) — Zeebe gateway with `urls.grpc` and `urls.http`. These must use browser-accessible proxy addresses (`https://zeebe.${HOST}` for gRPC and `https://orchestration.${HOST}` for the REST API), not internal container DNS names.
- **Orchestration Admin** (`id: orchestrationIdentity`) — Renders the **Admin** application card in Console. Without this component the card appears with no link.
- **Operate**, **Tasklist**, **Optimize**, **Connectors**, **Identity**, **Keycloak**, **WebModeler** — Individual service cards with external URLs and internal readiness probes.

Console is **Node.js**, not Spring Boot. This means Spring Boot configuration gotchas (CSRF origin checking, `SERVER_FORWARD_HEADERS_STRATEGY`, font CORS issues) do not apply. It uses different env vars (`KEYCLOAK_BASE_URL` vs Spring's `issuer-url` style).

**Health checks and autoheal:** Console exposes its readiness probe on port 9100. Docker uses that probe to set the container health state, and the `autoheal` sidecar watches the `autoheal=true` label and restarts Console if it becomes `unhealthy` while still running.

### Autoheal

**Image:** `willfarrell/autoheal@sha256:75c28b0020543e8eb49fe6514d012e7d2691f095dd622309d045da8647c8bb83`

This digest pins the Docker Hub `willfarrell/autoheal:latest` image index that was current on 2026-04-29. Keep it pinned and update it deliberately after review instead of using the moving `latest` tag directly.

`autoheal` is a small operational sidecar that watches Docker health states over `/var/run/docker.sock`. When a labeled container transitions to `unhealthy`, `autoheal` issues a Docker restart for that container.

**Security risk accepted:** `autoheal` mounts `/var/run/docker.sock` so it can call the Docker API. Docker socket access is host-critical: if the `autoheal` container or its image supply chain is compromised, an attacker can effectively gain host-admin-level control by using the Docker daemon to start containers, mount host paths, or alter other containers. The stack keeps `autoheal` because it provides automatic recovery for containers that remain running but become `unhealthy`; this is an explicit operational tradeoff, not a security boundary.

**What it does in this stack:**
- Monitors services labeled with `autoheal=true`
- Restarts services whose Docker `healthcheck` status becomes `unhealthy`
- Complements `restart: unless-stopped`, which handles unexpected process exits

**What it does not do:**
- It does **not** restart containers stopped intentionally with `docker stop`
- It does **not** recreate containers removed by `docker compose down`
- It does **not** replace Docker restart policies; it only reacts to the `unhealthy` health state

**Operational implication:** For `autoheal` to be effective, a service must have both a meaningful Docker `healthcheck` and the `autoheal=true` label. This is why the reverse proxy now has its own health probe in addition to the application services.

### Host Recovery Guard

**Script:** `scripts/ensure-stack.sh`

This repository also includes a host-level guard script intended for cron on Linux hosts. It uses the same `.env` file and the same stage-aware Compose file selection as `scripts/start.sh`.

**What it does:**
- Resolves the active `STAGE` from `.env`
- Builds the expected service list from `docker compose config --services`
- Checks which services are currently running via `docker compose ps --services --status running`
- Starts only the expected services that are currently missing or stopped

**Why it exists:** Docker restart policies and `autoheal` are not sufficient for every host reboot or daemon-start ordering scenario. If the server comes back up and part of the Camunda stack is missing, `ensure-stack.sh` reconciles only the missing services back to the desired state without restarting healthy ones.

**Separation of responsibilities:**
- `restart: unless-stopped` handles unexpected process exits
- `autoheal` handles containers that are still running but become `unhealthy`
- `ensure-stack.sh` handles missing or stopped containers and boot-time stack recovery

**Example cron setup (every 30 minutes):**

```bash
crontab -e
```

Add:

```cron
*/30 * * * * cd /path/to/CamundaComposeNVL && bash scripts/ensure-stack.sh >> /var/log/camunda-ensure-stack.log 2>&1
```

This runs the guard twice per hour, writes timestamped output to a dedicated log file, and starts only the services that are missing or stopped.

### camunda-db

**Image:** `postgres:${POSTGRES_VERSION}`

**Port:** 5432 (internal)

**Purpose:** Dedicated PostgreSQL database for Camunda core operational data (Zeebe records, Operate process instances, Tasklist user tasks, and authorizations).

**Key env vars:**
- `POSTGRES_DB=camunda` — Database name
- `POSTGRES_USER=camunda` — Database user
- `POSTGRES_PASSWORD=${CAMUNDA_DB_PASSWORD}` — Password from `.env`

**Health check:** `pg_isready -U camunda -d camunda`

**Volumes:** `camunda-db:/var/lib/postgresql/data`

### Web Modeler

Three components:

| Component | Image | Port | JVM Heap | Purpose |
|-----------|-------|------|----------|---------|
| web-modeler-restapi | `camunda/web-modeler-restapi:8.9.1` | 8081 (internal) / 8070 (host) | `-Xmx768m` | Java REST API + serves webapp UI (8.9+) |
| web-modeler-websockets | `camunda/web-modeler-websockets:8.9.1` | 8060 | — | Node.js Pusher WebSocket server for real-time collaboration |
| web-modeler-db | `postgres:15-alpine3.22` | 5432 | — | PostgreSQL for Web Modeler's own data |

**Key env vars for web-modeler-restapi:**
- `RESTAPI_OAUTH2_TOKEN_ISSUER=https://keycloak.${HOST}/...` — Browser-facing issuer (used for JWT validation from webapp)
- `RESTAPI_OAUTH2_TOKEN_ISSUER_BACKEND_URL=http://${KEYCLOAK_HOST}:18080/...` — Internal issuer URL
- `RESTAPI_PUSHER_*` — Pusher configuration for WebSocket communication with the websockets service
- `CAMUNDA_MODELER_CLUSTERS_0_URL_WEBAPP=https://orchestration.${HOST}` — Points to the **Orchestration** UI (not Web Modeler itself), because Web Modeler connects to the Zeebe broker running in Orchestration. Uses the browser-reachable HTTPS proxy URL so it works from remote clients on the network, not just the Docker host machine.

**WebSocket via proxy:** When `webmodeler.camunda.dev.local` is served over HTTPS, the browser's Pusher client connects to `wss://webmodeler.camunda.dev.local/app/*`. Caddy proxies this to `web-modeler-websockets:8060`. See [Reverse Proxy section](#9-reverse-proxy-caddy) for the `handle /app/*` directive.

---

## 9. Reverse Proxy (Caddy)

**Image:** `caddy:2.11.2@sha256:25cdc846626b62d05f6b633b9b40c2c9f6ef89b515dc76133cefd920f7dbe562`

**Port:** 443 (HTTPS only)

The reverse proxy also defines a Docker health check against Caddy's local admin endpoint. That probe exists primarily so `autoheal` can distinguish a healthy proxy from one that is still running but no longer serving traffic correctly.

### Subdomain Routes

| Subdomain | Target Container | Notes |
|-----------|-----------------|-------|
| `camunda.dev.local` | Dashboard (`/srv/dashboard`) | Landing page with links to all services |
| `keycloak.camunda.dev.local` | `keycloak:18080` | Keycloak admin + OIDC provider |
| `identity.camunda.dev.local` | `identity:8084` | Identity UI |
| `console.camunda.dev.local` | `console:8080` | Console UI |
| `optimize.camunda.dev.local` | `optimize:8090` | Optimize UI |
| `orchestration.camunda.dev.local` | `orchestration:8080` | Operate + Tasklist UIs |
| `zeebe.camunda.dev.local` | `orchestration:26500` | Zeebe gRPC gateway (h2c) |
| `webmodeler.camunda.dev.local` | `web-modeler-restapi:8081` | Web Modeler UI + WebSocket |

### TLS Configuration

When `FULLCHAIN_PEM` and `PRIVATEKEY_PEM` are set in `.env`, the `setup-host` scripts inject a `tls <cert> <key>` directive into each top-level site block. When those variables are unset, Caddy auto-generates a self-signed certificate for all sites automatically — no explicit `tls` directive is needed in the Caddyfile template.

### Key Configuration Details

**1. Chrome 120+ Keycloak OIDC iframe workaround**

Chrome 120+ blocks cross-origin JavaScript cookie access in iframes. The OIDC `check_session_iframe` (`login-status-iframe.html`) uses `document.cookie` to read `KEYCLOAK_SESSION` from inside a `webmodeler.*` page context — Chrome blocks this, the iframe returns "error", and Keycloak returns `login_required`, clearing the token.

Fix: Caddy intercepts the `login-status-iframe.html` request and returns a mock that always responds "unchanged" to `postMessage`:
```
@check-session-iframe {
    path /auth/realms/camunda-platform/protocol/openid-connect/login-status-iframe.html
}
handle @check-session-iframe {
    header Content-Type "text/html; charset=utf-8"
    respond `<!DOCTYPE html><html><body><script>window.addEventListener("message",function(e){if(!e.data||e.data==="init")return;e.source.postMessage("unchanged",e.origin);});</script></body></html>` 200
}
```

This prevents the iframe from ever returning "error", so the token is never cleared prematurely.

**2. CORS preflight for Identity and Orchestration**

Spring Boot services reject OPTIONS requests without explicit CORS configuration. Caddy handles `@options` method preflight requests directly with `Access-Control-Allow-*` headers before proxying:

```caddy
@options { method OPTIONS }
handle @options {
    respond "OK" 200
    header Access-Control-Allow-Origin "*"
    header Access-Control-Allow-Methods "GET, POST, PUT, DELETE, OPTIONS"
    header Access-Control-Allow-Headers "Content-Type, Authorization, X-Requested-With, Accept, Origin"
    header Access-Control-Max-Age "3600"
}
```

**3. Origin header stripping for fonts**

CSS `@font-face` triggers `sec-fetch-mode: cors` in the browser. Spring Security sees `Origin: https://identity.camunda.dev.local` and rejects it because it doesn't match the backend's own URL. The fix:

```caddy
@static { path /static/* }
handle @static {
    reverse_proxy identity:8084 {
        header_up -Origin
    }
}
```

Removing the `Origin` header makes Spring Security treat the request as same-origin, allowing font files to be served.

**4. Orchestration Permissions-Policy cleanup**

Camunda 8.9 emits a broad `Permissions-Policy` header from the unified Orchestration web app. Some feature tokens in that header are experimental or browser-specific (`ambient-light-sensor`, `attribution-reporting`, `browsing-topics`, `language-detector`, `summarizer`, `translator`, and others), so Chromium-based browsers can log repeated console warnings when Tasklist or Operate loads.

The warnings are browser policy parsing noise, not an application failure. Caddy strips the header on the Orchestration route to keep Tasklist/Operate consoles readable:

```caddy
reverse_proxy orchestration:8080 {
    header_down -Permissions-Policy
}
```

**5. WebSocket proxying for Web Modeler**

```caddy
handle /app/* {
    reverse_proxy web-modeler-websockets:8060
}
```

Pusher's WebSocket connections use the `/app/*` path pattern. Caddy routes them to the websockets container while the rest of `webmodeler.camunda.dev.local` goes to the webapp.

**6. Forwarded headers for Optimize**

```caddy
reverse_proxy optimize:8090 {
    header_up X-Forwarded-Proto https
    header_up X-Forwarded-Host optimize.camunda.dev.local
}
```

Optimize needs `X-Forwarded-Proto: https` to correctly construct OAuth2 redirect URIs when behind the HTTPS proxy.

**7. Optimize Mixpanel browser warning**

Optimize 8.9.1's packaged frontend includes the standard Mixpanel loader in `index.html`:

```html
<script>
  ...
  e.src = "//cdn.mxpnl.com/libs/mixpanel-2-latest.min.js";
  ...
</script>
```

Browser privacy tools such as uBlock, AdBlock, or Brave Shields commonly block that request and log:

```text
mixpanel-2-latest.min.js:1 Failed to load resource: net::ERR_BLOCKED_BY_CLIENT
```

This message means the browser blocked the request before it reached the stack. It is not a Caddy routing failure, an Optimize health failure, or an Elasticsearch import problem. The Optimize page can still work because the inline Mixpanel stub is created before the external script load. To verify the server path, check that the services are healthy and that the public URL redirects to Keycloak with the Optimize callback URL:

```bash
docker compose ps optimize reverse-proxy
curl -k -I https://optimize.camunda.dev.local/
```

The expected HTTP response before login is a `302 Found` to `https://keycloak.camunda.dev.local/...` with `redirect_uri=https%3A%2F%2Foptimize.camunda.dev.local%2Fapi%2Fauthentication%2Fcallback`. If Optimize loads normally, the Mixpanel console message can be ignored or removed by allowing `cdn.mxpnl.com` for `optimize.camunda.dev.local`.

---

## 10. Network Architecture

### Port Map

Direct host binding is loopback-only (`127.0.0.1`) for local diagnostics and scripts. Browser/user access should use the HTTPS Caddy subdomains on port 443. The only intentionally public host port is Caddy's HTTPS listener.

| Service | Host Port | Container Port | Protocol | Access |
|---------|-----------|----------------|----------|--------|
| reverse-proxy | **443** | 443 | HTTPS | Public ingress for browser/user access |
| orchestration | 127.0.0.1:26500, 127.0.0.1:9600, **127.0.0.1:8088** | 26500, 9600, 8080 | gRPC/HTTP | Local diagnostics/scripts + via proxy |
| connectors | **127.0.0.1:8086** | 8080 | HTTP | Local diagnostics/scripts |
| optimize | **127.0.0.1:8083** | 8090 | HTTP | Local diagnostics/scripts + via proxy |
| identity | **127.0.0.1:8084** | 8084 | HTTP | Local diagnostics/scripts + via proxy |
| keycloak | (internal) | 18080 | HTTP | Via proxy only |
| elasticsearch | **127.0.0.1:9200**, 127.0.0.1:9300 | 9200, 9300 | HTTP/REST | Local backup/restore and diagnostics only |
| console | **127.0.0.1:8087**, 127.0.0.1:9100 | 8080, 9100 | HTTP | Local diagnostics/scripts + via proxy |
| web-modeler-restapi | **127.0.0.1:8070** | 8081 | HTTP | Local diagnostics/scripts + via proxy (serves UI + API since 8.9) |
| web-modeler-websockets | **127.0.0.1:8060** | 8060 | WebSocket | Local diagnostics/scripts + via proxy (webmodeler.dev.local/app/*) |
| mailpit | 127.0.0.1:1025, 127.0.0.1:8075 | 1025, 8025 | SMTP/HTTP | Local SMTP/UI diagnostics |

When adding a new service, publish host ports only if a host-side script or local diagnostic workflow needs them. Bind such ports to `127.0.0.1`. Public user-facing access should be routed through Caddy on port 443.

Elasticsearch requires Basic Auth on port `9200`. Direct access is bound to `127.0.0.1` for backup/restore scripts and diagnostics only. Do not expose `9200` on LAN interfaces.

### Docker DNS Resolution

Container names become DNS hostnames within Docker networks:
- `orchestration` → `orchestration:8080` (REST), `orchestration:26500` (gRPC)
- `keycloak` → `keycloak:18080`
- `identity` → `identity:8084`
- `elasticsearch` → `elasticsearch:9200`
- `postgres` → `postgres:5432`
- `camunda-db` → `camunda-db:5432`
- `web-modeler-db` → `web-modeler-db:5432`

### Extra Hosts

All services have `extra_hosts: host.docker.internal:host-gateway` which allows containers to reach services on the Docker host machine (e.g., a local SMTP server or VPN).

---

## 11. Development vs Production Trade-offs

Several settings are intentionally development-oriented and should be reviewed before production use.

### Security-Oriented Settings

| Setting | Current Value | Production Value | Risk if Left |
|---------|---------------|------------------|--------------|
| `/actuator/configprops` exposure | Disabled for runtime services | Keep disabled; if temporarily needed, use `show-values: NEVER` | Exposing config properties can leak OAuth client secrets, database passwords, and connector credentials |
| `LOGGING_LEVEL_IO_CAMUNDA_MODELER=INFO` | web-modeler-restapi | `INFO` | Keeps Web Modeler logging at production-appropriate verbosity |
| `xpack.security.enabled=true` | elasticsearch | `true` | Basic Auth required on Elasticsearch API |

### Data Durability Settings

| Setting | Current Value | Production Value | Risk if Left |
|---------|---------------|------------------|--------------|
| `number-of-replicas: 0` / `number_of_replicas: 0` | Zeebe exporter and Optimize Elasticsearch indices | `1` in multi-node ES clusters | Single-node Elasticsearch cannot allocate replicas; in a multi-node ES deployment, replicas improve durability and availability. |
| `discovery.type=single-node` | elasticsearch | multi-node cluster | No HA, single point of failure |
| `camunda.data.primary-storage.snapshot-period: 5m` | orchestration | `15m` | More frequent snapshots = more IO overhead |
| ILM / retention policies | Enabled — Zeebe exporter records (90d) and Optimize data (365d) | Disabled by default | Optimize keeps analytical data for 365 days to support quarterly and year-over-year analytics. Zeebe `zeebe-record-*` indices are retained for 90 days as Optimize import source data. Operate and Tasklist query data is stored in PostgreSQL (`camunda-db`) rather than Elasticsearch archive indices. |

### Network/TLS Settings

| Setting | Current Value | Production Value | Risk if Left |
|---------|---------------|------------------|--------------|
| `HOST=camunda.dev.local` | `.env` | Production hostname | Not accessible from other networks |
| Direct service ports | `127.0.0.1` bindings | Keep loopback-only or remove when unused | Exposing app, management, or Elasticsearch ports on LAN bypasses the Caddy ingress and increases attack surface |
| Self-signed TLS certs | Caddy auto-generated | Corporate CA or Let's Encrypt | Browser warnings, potential MITM |
| `KC_PROXY_HEADERS=xforwarded` / `KEYCLOAK_PROXY_HEADERS=xforwarded` | keycloak | Restrict to trusted proxies | Header injection risk if untrusted proxies can reach Keycloak |

### Secrets

| Secret | Current Value | Production Requirement |
|---------|---------------|----------------------|
| `KEYCLOAK_ADMIN_PASSWORD` | `admin` (in `.env.example`) | Strong random password |
| `DEMO_USER_PASSWORD` | `demo` (in `.env.example`) | Strong random password |
| `POSTGRES_PASSWORD` | `demo-postgres-password` | Strong random password |
| All `*_CLIENT_SECRET` | Weak demo values | Strong random passwords |

Management endpoint policy: expose only the endpoints needed for health checks and monitoring. `health`, `info`, `metrics`, and `prometheus` are acceptable where used by the stack. Do not expose `configprops` in committed configuration because this stack injects database passwords, OAuth client secrets, Keycloak admin credentials, and connector credentials via environment variables. If `configprops` is temporarily enabled for local debugging, use `show-values: NEVER`, keep the port loopback-only, and remove the setting before committing.

### Recommended Production Changes

1. **Run `scripts/generate-secrets.sh --force`** to regenerate all secrets with cryptographically random values
2. **Set `HOST`** to your actual production hostname (must be lowercase)
3. **Replace self-signed TLS certs** with certificates from a corporate CA or Let's Encrypt
4. **Set Elasticsearch-backed index replicas to `1`** for the Zeebe exporter and Optimize only when Elasticsearch has at least two data nodes
5. **Keep `/actuator/configprops` disabled** for all runtime services; if temporarily enabled for debugging, set `show-values: NEVER` and restrict access to localhost.
6. **Keep `LOGGING_LEVEL_IO_CAMUNDA_MODELER`** at `INFO`
7. **Consider multi-node Elasticsearch** for HA production deployments
