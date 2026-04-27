# Camunda 8.8 Docker Compose — Project Configuration

This document describes every configuration in this stack, explaining what each setting does, what the default would be, and why this stack's value was chosen. It serves as the authoritative reference for why the stack is configured the way it is.

**Target server:** Depends on environment stage — see [Resource Allocation](#3-resource-allocation)
**Architecture:** Self-managed Camunda 8.8 on Docker Compose
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

This stack deploys a full Camunda 8.8 self-managed platform with:

| Component | Image | Purpose |
|-----------|-------|---------|
| **Orchestration** | `camunda/camunda:8.8.21` | Zeebe broker + Operate + Tasklist in one container |
| **Elasticsearch** | `docker.elastic.co/elasticsearch/elasticsearch:8.17.10` | Process instance data, export data, Operate/Tasklist/Optimize storage |
| **Identity** | `camunda/identity:8.8.10` | Centralized identity, OIDC provider integration, role management |
| **Keycloak** | `bitnamilegacy/keycloak:26.3.2` | OIDC identity provider, realm/client setup, user authentication |
| **Optimize** | `camunda/optimize:8.8.8` | Process analytics and optimization |
| **Connectors** | `camunda/connectors-bundle:8.8.10` | Outbound integrations and webhooks |
| **Web Modeler** | `camunda/web-modeler:*:8.8.12` | BPMN process modeling (REST API + WebApp + WebSockets) |
| **Console** | `camunda/console:8.8.133` | Cluster overview and management UI |
| **PostgreSQL** (×2) | `postgres:15-alpine3.22` | Identity/Keycloak DB + Web Modeler DB |
| **Caddy** | `caddy:latest` | Reverse proxy with automatic HTTPS and subdomain routing |
| **Autoheal** | `willfarrell/autoheal:latest` | Restarts labeled containers when Docker health checks mark them as unhealthy |

### Container Networks

Three Docker networks isolate traffic:

- **`camunda-platform`** — Main platform: orchestration, connectors, optimize, console, elasticsearch, keycloak, identity, web-modeler-restapi, web-modeler-webapp, reverse-proxy
- **`identity-network`** — Keycloak ↔ PostgreSQL (identity DB) ↔ Identity
- **`web-modeler`** — web-modeler-db ↔ mailpit ↔ web-modeler-restapi ↔ web-modeler-websockets ↔ web-modeler-webapp; also connects to `camunda-platform` to reach orchestration and identity

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
| elasticsearch | 4.0 | 8G | 6G | `-Xms4g -Xmx4g` | 50% of limit (Lucene uses remaining for OS page cache) |
| orchestration | 4.0 | 8G | 4G | `-Xms4500m -Xmx4500m` | 57% of limit; Zeebe broker + embedded Operate/Tasklist; leaves 3.5G for RocksDB off-heap, Netty buffers, and OS page cache |
| optimize | 1.5 | 3G | 1536m | `-Xms2304m -Xmx2304m` | 75% of limit (2304m); JVM-based analytics service |
| keycloak | 1.5 | 2G | 512m | — | Quarkus-based, no JVM heap setting needed |
| connectors | 1.0 | 1G | 512m | `-Xmx768m` | 75% of limit; outbound integrations only |
| identity | 1.0 | 1G | 256m | `-Xms256m -Xmx768m` | 75% of limit; Spring Boot service |
| console | 0.5 | 1G | 512m | `-Xms256m -Xmx768m` | 75% of limit; Node.js but has a JVM sidecar for metrics |
| web-modeler-restapi | 1.0 | 1G | 512m | `-Xmx768m` | 75% of limit; Java REST API |
| postgres (identity) | 1.0 | 1G | 512m | — | No JVM; PostgreSQL manages own memory |
| web-modeler-webapp | 0.5 | 512m | 128m | — | Node.js React app |
| postgres (web-modeler) | 0.5 | 512m | 256m | — | No JVM |
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

### Environment Variables in docker-compose.yaml

```yaml
environment:
  - bootstrap.memory_lock=true                     # Prevent Elasticsearch swapping
  - discovery.type=single-node                     # No clustering (single-node dev/prod)
  - xpack.security.enabled=false                   # No TLS/auth for internal ES
  - cluster.max_shards_per_node=1000              # Realistic limit for single-node (was 3000)
  - "action.auto_create_index=.security*,zeebe-record*,operate-*,tasklist-*,optimize-*,camunda-*,web-modeler-*,identity-*"
  - indices.memory.index_buffer_size=20%           # Larger indexing buffer for write throughput
  - cluster.routing.allocation.disk.watermark.low=85%
  - cluster.routing.allocation.disk.watermark.high=90%
  - cluster.routing.allocation.disk.watermark.flood_stage=95%
  - indices.breaker.total.limit=75%                # Circuit breaker for aggregations
  - "ES_JAVA_OPTS=-Xms4g -Xmx4g"                  # 4 GB heap
```

### Setting Explanations

| Setting | Value | Default | Why |
|---------|-------|---------|-----|
| `bootstrap.memory_lock=true` | `true` | `false` | Lock Elasticsearch's memory at boot using `mlockall`. Prevents the OS from swapping ES pages to disk, which would cause catastrophic latency spikes. Elasticsearch is a latency-sensitive in-memory store. |
| `discovery.type=single-node` | `single-node` | `multi-node` | This stack runs a single Elasticsearch node. Multi-node would require a cluster with minimum master node quorum. `single-node` disables shard allocation fencing that would otherwise reject writes. |
| `xpack.security.enabled=false` | `false` | `true` | Security (TLS + auth) is disabled for this internal-only service. All access is through Camunda services on the internal Docker network. In production multi-node setups, you'd enable this. |
| `cluster.max_shards_per_node=1000` | `1000` | `1000` | **Hard cap on the total number of shards this single node can hold.** The previous value of `3000` allowed Elasticsearch to create so many shards that the JVM heap was exhausted before the limit was reached, causing OOM and cluster instability. On an 8 GB single-node, each shard carries ~10–30 MB of heap overhead. 1000 shards is the Elasticsearch 8.x default and a realistic ceiling for this node size. |
| `cluster.routing.allocation.disk.watermark.low=85%` | `85%` | `85%` | Elasticsearch stops allocating shards to a node when disk usage reaches 85%. Gives operators time to add storage before the node goes read-only. |
| `cluster.routing.allocation.disk.watermark.high=90%` | `90%` | `90%` | Elasticsearch blocks shard allocation entirely above 90%. Combined with flood_stage at 95%, gives two warning thresholds before read-only lock. |
| `cluster.routing.allocation.disk.watermark.flood_stage=95%` | `95%` | `95%` | At 95%, Elasticsearch marks all indices on the node as read-only (`index.blocks.read_only_allow_delete`). Requires manual intervention to clear. The gap between 90% and 95% gives operators a window to react. |
| `indices.breaker.total.limit=75%` | `75%` | `70%` | The parent circuit breaker limit for all sub-breakers (fielddata, request, in-flight). 75% of JVM heap. Raised slightly from 70% because Optimize performs large aggregations that can approach the limit. If this trips, it causes `TooManyBookmarks` or aggregation failures in Optimize. |
| `ES_JAVA_OPTS=-Xms4g -Xmx4g` | `4g` | 50% of container | 4 GB heap (50% of the 8 GB limit) for Lucene to use the other ~4 GB as off-heap page cache. Scaled down proportionally in `dev` and `test` stages. |
| `action.auto_create_index=...` | Whitelist (Camunda patterns) | `true` | Prevents rogue services or typos from creating indices outside known patterns. A whitelist (instead of blanket `false`) is safer because Optimize and Web Modeler restapi may auto-create indices on first startup before their templates are registered. All known Camunda index prefixes are explicitly allowed: `zeebe-record*`, `operate-*`, `tasklist-*`, `optimize-*`, `camunda-*`, `web-modeler-*`, `identity-*`. |
| `indices.memory.index_buffer_size=20%` | `20%` | `10%` | The percentage of JVM heap reserved for the indexing buffer. A larger buffer allows Elasticsearch to batch more in-memory writes before flushing to disk, improving throughput for Camunda's high-volume event stream. 20% is appropriate given the 4 GB heap and write-heavy workload. |

### Index Lifecycle Management (ILM) and Data Retention

Camunda 8 creates a large number of time-based indices:

- **Zeebe exporter** writes one index per record type per day (`zeebe-record-*`)
- **Operate** archives completed process instances to dated indices (`operate-list-view-*`, `operate-operation-*`)
- **Tasklist** archives similarly (`tasklist-list-view-*`, `tasklist-operation-*`)
- **Optimize** maintains its own time-based indices under the `optimize-` prefix

Without cleanup, these indices accumulate indefinitely. The old configuration had **no retention policies**, which led to:

1. **Shard exhaustion** — Each daily index defaults to 3 shards (Zeebe exporter). With ~15 record types, that is ~45 new shards per day. In 30 days: ~1,350 shards. The old `max_shards_per_node=3000` merely delayed the failure instead of preventing it.
2. **Disk bloat** — Archived process data, historical variables, and incident records accumulate forever.
3. **Query degradation** — Elasticsearch must keep metadata for every shard in heap. Beyond ~500–800 shards on an 8 GB node, query latency degrades and the node becomes unstable.

**The fix: ILM + retention everywhere.**

| Component | Retention Mechanism | Minimum Age | What Gets Deleted |
|-----------|-------------------|-------------|-------------------|
| Zeebe Exporter | ILM policy on index templates | 90 days | Old `zeebe-record-*` daily indices |
| Camunda Exporter | History retention policy | 90 days | Old Camunda unified history indices |
| Operate | Archiver ILM | 90 days | Archived `operate-*` indices older than 90 days |
| Tasklist | Archiver ILM | 90 days | Archived `tasklist-*` indices older than 90 days |
| Optimize | Optimize's built-in cleanup | 365 days (configured in `.optimize/environment-config.yaml`) | Process data older than 365 days |

**Why two tiers?** Orchestration components (Zeebe, Camunda Exporter, Operate, Tasklist) keep operational data for 90 days — enough for incident follow-up, instance history lookups, and Operate/Tasklist troubleshooting. Optimize keeps aggregated analytical data for 365 days (12 months) so year-over-year comparisons and full annual trend reports remain possible. Optimize stores aggregated, compact data; the disk impact at low process volumes (a few thousand instances/year) stays in the single-GB range.

**Shard reduction:** All exporters and Optimize are now configured with `numberOfShards: 1`. On a single-node deployment, multiple shards provide zero parallelism — the node cannot distribute shards to other nodes. Each additional shard only adds heap overhead (mappings, segments, bitsets). Reducing from 3 to 1 cuts total shard count by ~67%.

> **Note:** These settings only affect **newly created indices**. Existing indices retain their original shard count. The ILM policies are applied to index templates and will take effect on the next rollover or daily index creation. To force an immediate cleanup of old indices, use the Elasticsearch Delete Index API or reduce `minimumAge` temporarily in a dev environment.

### Previously Removed: `cluster.routing.allocation.disk.threshold_enabled=false`

The old configuration had `disk.threshold_enabled=false` which **completely disabled disk monitoring**. This meant Elasticsearch would keep writing until the disk was completely full, causing index corruption and complete failure. This has been removed — the watermark thresholds above now provide proper guardrails.

---

## 5. Zeebe/Orchestration Configuration

Configuration lives in `.orchestration/application.yaml`, mounted into the orchestration container.

### Thread Configuration

```yaml
threads:
  cpuThreadCount: "4"
  ioThreadCount: "4"
```

| Setting | Value | Default | Why |
|---------|-------|---------|-----|
| `cpuThreadCount` | `4` | `2` (was `3`) | Number of threads for processing workflow commands. With 4 CPU cores allocated, using 4 threads maximizes throughput. The Zeebe upstream default is 2; this stack previously used 3. |
| `ioThreadCount` | `4` | `2` (was `3`) | Number of threads for IO-bound operations (network, disk). Having 4 IO threads allows the broker to handle many concurrent export/disk operations without blocking the CPU threads. The Zeebe upstream default is 2; this stack previously used 3. |

### Disk Watermarks

```yaml
data:
  diskUsageCommandWatermark: 0.85
  diskUsageReplicationWatermark: 0.90
  freeSpace:
    processing: 2GB
    replication: 3GB
```

| Setting | Value | Default | Why |
|---------|-------|---------|-----|
| `diskUsageCommandWatermark` | `0.85` | `0.80` | Broker refuses new commands when disk usage exceeds 85%. Prevents the broker from accepting work it cannot complete. Set to 85% (not lower) to give Elasticsearch enough disk space for its own writes. |
| `diskUsageReplicationWatermark` | `0.90` | `0.85` | Partition replication is rejected above 90%. Gives replication slightly more headroom than command processing. |
| `freeSpace.processing` | `2GB` | `10GB` | Minimum free disk space for the processing partition. If less than 2GB is available, the broker pauses processing. Set low (2GB) for development servers with limited storage. |
| `freeSpace.replication` | `3GB` | `10GB` | Minimum free disk space for replication. Set to 3GB to account for snapshot replication requiring temporary disk space. |

### Exporter Bulk Size

```yaml
exporters:
  elasticsearch:
    args:
      bulk:
        size: 1000
```

| Setting | Value | Default | Why |
|---------|-------|---------|-----|
| `bulk.size` | `1000` | `1000` | The Elasticsearch exporter batches records before flushing. A value of `1000` means "flush when the batch reaches 1000 records OR the flush interval expires." The old dev value of `1` wrote every event individually, causing Lucene segment explosion and rapid index count growth. 1000 is a production-appropriate batch size that balances latency (flush every ~1s under moderate load) with index efficiency. |

### Exporter Index Shards

```yaml
exporters:
  elasticsearch:
    args:
      index:
        numberOfShards: 1
        numberOfReplicas: 0
  CamundaExporter:
    args:
      index:
        numberOfShards: 1
        numberOfReplicas: 0
```

| Setting | Value | Default | Why |
|---------|-------|---------|-----|
| `elasticsearch.index.numberOfShards` | `1` | `3` | The Zeebe Elasticsearch exporter creates one index per record type per day. The upstream default of 3 shards per index is designed for multi-node clusters where shards are distributed for parallelism. On a single-node deployment, 3 shards provide zero benefit — the node cannot distribute work across itself. Each shard consumes heap for mappings, segments, and caches. Setting this to 1 reduces total shard count by ~67%. |
| `elasticsearch.index.numberOfReplicas` | `0` | `0` | No replica on a single-node cluster. A replica would reside on the same node as the primary — no failover benefit, but double the disk and heap consumption. Explicitly set for consistency with the CamundaExporter and as protection against default changes in future Camunda versions. |
| `CamundaExporter.index.numberOfShards` | `1` | `3` | Same rationale as above. The Camunda Exporter (new unified exporter in 8.6+) also defaults to 3 shards. Setting it to 1 on a single-node stack eliminates redundant heap overhead. |
| `CamundaExporter.index.numberOfReplicas` | `0` | `0` | No replicas on a single-node cluster. A replica would live on the same node as the primary, providing no failover benefit while doubling disk and heap usage. |

### Exporter Data Retention (Zeebe Elasticsearch Exporter)

```yaml
exporters:
  elasticsearch:
    args:
      retention:
        enabled: true
        minimumAge: 90d
        policyName: zeebe-record-retention-policy
```

| Setting | Value | Default | Why |
|---------|-------|---------|-----|
| `retention.enabled` | `true` | `false` | Enables an Elasticsearch Index Lifecycle Management (ILM) policy that is automatically created and attached to all index templates generated by the exporter. Without this, `zeebe-record-*` indices grow forever. |
| `retention.minimumAge` | `90d` | `30d` | Indices older than 90 days are deleted by the ILM policy. 90 days covers an entire quarter of operational history — enough for incident follow-up, audits, and process-instance lookups in Operate/Tasklist — while still bounding shard growth. Adjust based on your compliance requirements. |
| `retention.policyName` | `zeebe-record-retention-policy` | `zeebe-record-retention-policy` | The name of the ILM policy created in Elasticsearch. Can be changed if you manage multiple Camunda clusters on the same ES instance. |

### Camunda Exporter History Retention

```yaml
exporters:
  CamundaExporter:
    args:
      history:
        retention:
          enabled: true
          minimumAge: 90d
          policyName: camunda-retention-policy
```

| Setting | Value | Default | Why |
|---------|-------|---------|-----|
| `history.retention.enabled` | `true` | `false` | The Camunda Exporter writes historical process data to time-based indices. Enabling retention ensures these indices are deleted automatically after the minimum age, preventing unbounded disk growth. |
| `history.retention.minimumAge` | `90d` | `30d` | Matches the Zeebe exporter retention period so all Camunda historical data has a consistent 90-day lifecycle. |
| `history.retention.policyName` | `camunda-retention-policy` | (empty) | The ILM policy name for Camunda Exporter indices. Distinct from the Zeebe exporter policy to allow independent tuning. |

### Operate Archiver ILM

```yaml
camunda:
  operate:
    archiver:
      ilmEnabled: true
      ilmMinAgeForDeleteArchivedIndices: 90d
```

| Setting | Value | Default | Why |
|---------|-------|---------|-----|
| `archiver.ilmEnabled` | `true` | `false` | Operate's archiver moves completed process instances from active indices to archived indices (e.g., `operate-list-view-2024.01.01`). Without ILM, these archived indices accumulate indefinitely. Enabling ILM attaches a deletion policy to archived indices. |
| `archiver.ilmMinAgeForDeleteArchivedIndices` | `90d` | (none) | Archived indices older than 90 days are deleted. Matches the Zeebe and Camunda exporter retention so archived Operate data is never deleted while the raw records still exist. |

### Tasklist Archiver ILM

```yaml
camunda:
  tasklist:
    archiver:
      ilmEnabled: true
      ilmMinAgeForDeleteArchivedIndices: 90d
```

| Setting | Value | Default | Why |
|---------|-------|---------|-----|
| `archiver.ilmEnabled` | `true` | `false` | Same mechanism as Operate. Tasklist archives completed user tasks and process instances to dated indices. ILM ensures these do not grow without bound. |
| `archiver.ilmMinAgeForDeleteArchivedIndices` | `90d` | (none) | 90-day retention for Tasklist archives, consistent with Operate and the exporters. |

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
data:
  snapshotPeriod: 5m
```

| Setting | Value | Default | Why |
|---------|-------|---------|-----|
| `snapshotPeriod` | `5m` | `5m` | snapshots are taken every 5 minutes. A shorter period means more frequent snapshots but higher IO. 5m is a standard production interval that balances recovery time (RTO) against IO overhead. |

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

### Database Configuration

```yaml
database:
  index:
    numberOfReplicas: 0
```

| Setting | Value | Default | Why |
|---------|-------|---------|-----|
| `numberOfReplicas` | `0` | `1` | Elasticsearch index replica count for Camunda's own database indices. 0 because this is a single-node ES with no replica target. In a clustered production setup with 3+ ES nodes, this would be set to `1`. |

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
| `KEYCLOAK_HTTP_PORT=18080` | Non-standard port | Avoids conflict with other services on 8080; matches `KEYCLOAK_HOST=keycloak` in the Docker network |
| `KEYCLOAK_HTTP_RELATIVE_PATH=/auth` | Required path | Keycloak requires this path prefix; the `KEYCLOAK_HOST=keycloak` means containers call `http://keycloak:18080/auth` |
| `KEYCLOAK_DATABASE_HOST=postgres` | Docker DNS name | Keycloak connects to the PostgreSQL container by name, not localhost |
| `KEYCLOAK_PROXY_HEADERS=xforwarded` | Trust proxy headers | Required when behind Caddy reverse proxy; tells Keycloak to read `X-Forwarded-Proto` and `X-Forwarded-Host` headers to construct correct URLs in OIDC responses |

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
| `WEBMODELER_PUSHER_KEY` | web-modeler-webapp, web-modeler-websockets | Pusher WebSocket authentication |
| `WEBMODELER_PUSHER_SECRET` | web-modeler-websockets | Pusher WebSocket authentication |
| `DEMO_USER_PASSWORD` | Identity (creates demo user) | Password for the demo user account |

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
- `SPRING_PROFILES_ACTIVE=ccsm` — "Camunda Cloud Self Managed" profile activates Optimize's self-managed mode
- `CAMUNDA_OPTIMIZE_IDENTITY_ISSUER_URL=https://keycloak.${HOST}/...` — Browser-facing issuer URL
- `CAMUNDA_OPTIMIZE_IDENTITY_ISSUER_BACKEND_URL=http://${KEYCLOAK_HOST}:18080/...` — Internal issuer URL
- `SERVER_FORWARD_HEADERS_STRATEGY=framework` — Required behind Caddy proxy for correct URL construction

**Important:** Optimize shares the platform `elasticsearch` container but maintains its own indices under the `optimize-` prefix — it does not use the same index namespace as Operate, Tasklist, or the Zeebe exporter.

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

Console is **Node.js**, not Spring Boot. This means Spring Boot configuration gotchas (CSRF origin checking, `SERVER_FORWARD_HEADERS_STRATEGY`, font CORS issues) do not apply. It uses different env vars (`KEYCLOAK_BASE_URL` vs Spring's `issuer-url` style).

**Health checks and autoheal:** Console exposes its readiness probe on port 9100. Docker uses that probe to set the container health state, and the `autoheal` sidecar watches the `autoheal=true` label and restarts Console if it becomes `unhealthy` while still running.

### Autoheal

**Image:** `willfarrell/autoheal:latest`

`autoheal` is a small operational sidecar that watches Docker health states over `/var/run/docker.sock`. When a labeled container transitions to `unhealthy`, `autoheal` issues a Docker restart for that container.

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

### Web Modeler

Three components:

| Component | Image | Port | JVM Heap | Purpose |
|-----------|-------|------|----------|---------|
| web-modeler-restapi | `camunda/web-modeler-restapi:8.8.12` | 8091 | `-Xmx768m` | Java REST API + database access |
| web-modeler-webapp | `camunda/web-modeler-webapp:8.8.12` | 8070 | — | Node.js React UI |
| web-modeler-websockets | `camunda/web-modeler-websockets:8.8.12` | 8060 | — | Node.js Pusher WebSocket server for real-time collaboration |
| web-modeler-db | `postgres:15-alpine3.22` | 5432 | — | PostgreSQL for Web Modeler's own data |

**Key env vars for web-modeler-restapi:**
- `RESTAPI_OAUTH2_TOKEN_ISSUER=https://keycloak.${HOST}/...` — Browser-facing issuer (used for JWT validation from webapp)
- `RESTAPI_OAUTH2_TOKEN_ISSUER_BACKEND_URL=http://${KEYCLOAK_HOST}:18080/...` — Internal issuer URL
- `RESTAPI_PUSHER_*` — Pusher configuration for WebSocket communication with the websockets service
- `CAMUNDA_MODELER_CLUSTERS_0_URL_WEBAPP=https://orchestration.${HOST}` — Points to the **Orchestration** UI (not Web Modeler itself), because Web Modeler connects to the Zeebe broker running in Orchestration. Uses the browser-reachable HTTPS proxy URL so it works from remote clients on the network, not just the Docker host machine.

**WebSocket via proxy:** When `webmodeler.camunda.dev.local` is served over HTTPS, the browser's Pusher client connects to `wss://webmodeler.camunda.dev.local/app/*`. Caddy proxies this to `web-modeler-websockets:8060`. See [Reverse Proxy section](#9-reverse-proxy-caddy) for the `handle /app/*` directive.

---

## 9. Reverse Proxy (Caddy)

**Image:** `caddy:latest`

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
| `webmodeler.camunda.dev.local` | `web-modeler-webapp:8070` | Web Modeler UI + WebSocket |

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

**4. WebSocket proxying for Web Modeler**

```caddy
handle /app/* {
    reverse_proxy web-modeler-websockets:8060
}
```

Pusher's WebSocket connections use the `/app/*` path pattern. Caddy routes them to the websockets container while the rest of `webmodeler.camunda.dev.local` goes to the webapp.

**5. Forwarded headers for Optimize**

```caddy
reverse_proxy optimize:8090 {
    header_up X-Forwarded-Proto https
    header_up X-Forwarded-Host optimize.camunda.dev.local
}
```

Optimize needs `X-Forwarded-Proto: https` to correctly construct OAuth2 redirect URIs when behind the HTTPS proxy.

---

## 10. Network Architecture

### Port Map

| Service | Host Port | Container Port | Protocol | Access |
|---------|-----------|----------------|----------|--------|
| orchestration | 26500, 9600, **8088** | 26500, 9600, 8080 | gRPC/HTTP | Direct + via proxy |
| connectors | **8086** | 8080 | HTTP | Direct + via proxy |
| optimize | **8083** | 8090 | HTTP | Direct + via proxy |
| identity | **8084** | 8084 | HTTP | Direct + via proxy |
| keycloak | **18080** | 18080 | HTTP | Direct + via proxy |
| elasticsearch | **9200**, 9300 | 9200, 9300 | HTTP/REST | Direct (no proxy) |
| console | **8087**, 9100 | 8080, 9100 | HTTP | Via proxy |
| web-modeler-webapp | **8070** | 8070 | HTTP | Via proxy |
| web-modeler-websockets | **8060** | 8060 | WebSocket | Via proxy (webmodeler.dev.local/app/*) |
| mailpit | 1025, 8075 | 1025, 8025 | SMTP/HTTP | Direct (SMTP for web-modeler-restapi) |

### Docker DNS Resolution

Container names become DNS hostnames within Docker networks:
- `orchestration` → `orchestration:8080` (REST), `orchestration:26500` (gRPC)
- `keycloak` → `keycloak:18080`
- `identity` → `identity:8084`
- `elasticsearch` → `elasticsearch:9200`
- `postgres` → `postgres:5432`
- `web-modeler-db` → `web-modeler-db:5432`

### Extra Hosts

All services have `extra_hosts: host.docker.internal:host-gateway` which allows containers to reach services on the Docker host machine (e.g., a local SMTP server or VPN).

---

## 11. Development vs Production Trade-offs

Several settings are intentionally development-oriented and should be reviewed before production use.

### Security-Oriented Settings

| Setting | Current Value | Production Value | Risk if Left |
|---------|---------------|------------------|--------------|
| `MANAGEMENT_ENDPOINT_CONFIGPROPS_SHOW_VALUES=ALWAYS` | All services | `NEVER` | Exposes all config including secrets in `/actuator/configprops` |
| `LOGGING_LEVEL_IO_CAMUNDA_MODELER=DEBUG` | web-modeler-restapi | `INFO` | Verbose logging, performance impact |
| `xpack.security.enabled=false` | elasticsearch | `true` | No authentication on Elasticsearch API |

### Data Durability Settings

| Setting | Current Value | Production Value | Risk if Left |
|---------|---------------|------------------|--------------|
| `numberOfReplicas: 0` | orchestration, optimize | `1` | Single failure loses data |
| `discovery.type=single-node` | elasticsearch | multi-node cluster | No HA, single point of failure |
| `snapshotPeriod: 5m` | orchestration | `15m` | More frequent snapshots = more IO overhead |
| ILM / retention policies | Enabled — Zeebe, Camunda, Operate, Tasklist (90d); Optimize (365d) | Disabled by default | Two-tier retention: orchestration data (Zeebe records, Camunda history, Operate/Tasklist archives) is kept for 90 days for incident follow-up and operational history; Optimize is pre-configured in `.optimize/environment-config.yaml` for 365 days to support quarterly and year-over-year analytics. Without retention, historical index data volume grows indefinitely and leads to shard exhaustion, heap pressure, and cluster instability (Operate/Optimize stop displaying data). |

### Network/TLS Settings

| Setting | Current Value | Production Value | Risk if Left |
|---------|---------------|------------------|--------------|
| `HOST=camunda.dev.local` | `.env` | Production hostname | Not accessible from other networks |
| Self-signed TLS certs | Caddy auto-generated | Corporate CA or Let's Encrypt | Browser warnings, potential MITM |
| `KEYCLOAK_PROXY_HEADERS=xforwarded` | keycloak | Restrict to trusted proxies | Header injection risk if untrusted proxies can reach Keycloak |

### Secrets

| Secret | Current Value | Production Requirement |
|---------|---------------|----------------------|
| `KEYCLOAK_ADMIN_PASSWORD` | `admin` (in `.env.example`) | Strong random password |
| `DEMO_USER_PASSWORD` | `demo` (in `.env.example`) | Strong random password |
| `POSTGRES_PASSWORD` | `demo-postgres-password` | Strong random password |
| All `*_CLIENT_SECRET` | Weak demo values | Strong random passwords |

### Recommended Production Changes

1. **Run `scripts/generate-secrets.sh --force`** to regenerate all secrets with cryptographically random values
2. **Set `HOST`** to your actual production hostname (must be lowercase)
3. **Replace self-signed TLS certs** with certificates from a corporate CA or Let's Encrypt
4. **Set `xpack.security.enabled=true`** in Elasticsearch and configure credentials
5. **Set `numberOfReplicas=1`** in orchestration and optimize for data durability
6. **Remove `MANAGEMENT_ENDPOINT_CONFIGPROPS_SHOW_VALUES=ALWAYS`** from all services
7. **Change `LOGGING_LEVEL_IO_CAMUNDA_MODELER`** from `DEBUG` to `INFO`
8. **Consider multi-node Elasticsearch** for HA production deployments
