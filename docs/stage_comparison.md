# Environment Stage Comparison

The stack supports three environment stages, selected via the `STAGE` variable in `.env`. Each stage applies a different resource profile that Docker Compose merges on top of the base `docker-compose.yaml`.

## Service Tiers

| Tier  | Services |
|-------|----------|
| Heavy | orchestration, elasticsearch |
| Medium | optimize, keycloak, connectors, identity, web-modeler-restapi |
| Light | postgres, web-modeler-db, console, web-modeler-webapp, web-modeler-websockets, mailpit, reverse-proxy |

## Stage Overview

| Stage | Target |
|-------|--------|
| **prod** | Full production-grade resources; mirrors the base `docker-compose.yaml` |
| **dev** | Reduced for developer workstations with fewer CPUs and less RAM |
| **test** | Compact for constrained test hosts |

## Resource Limits

### Heavy Tier

| Service | Stage | CPU Limit | Memory Limit | CPU Reservation | Memory Reservation | JVM Heap |
|---------|-------|-----------|--------------|-----------------|-------------------|----------|
| orchestration | prod | 4.0 | 8192M | 1.0 | 4096M | 4500m |
| orchestration | dev | 2.0 | 4096M | 0.5 | 2048M | 3072m |
| orchestration | test | 1.5 | 3072M | 0.25 | 1536M | 2304m |
| elasticsearch | prod | 4.0 | 8192M | 1.0 | 6144M | 4096m |
| elasticsearch | dev | 2.0 | 4096M | 0.5 | 3072M | 2048m |
| elasticsearch | test | 1.5 | 3072M | 0.25 | 2048M | 1536m |

### Medium Tier

| Service | Stage | CPU Limit | Memory Limit | CPU Reservation | Memory Reservation | JVM Heap |
|---------|-------|-----------|--------------|-----------------|-------------------|----------|
| optimize | prod | 1.5 | 3072M | 0.5 | 1536M | 2304m |
| optimize | dev | 1.0 | 1536M | 0.25 | 768M | 1152m |
| optimize | test | 0.75 | 1024M | 0.25 | 512M | 768m |
| keycloak | prod | 1.5 | 2048M | 0.5 | 512M | - |
| keycloak | dev | 1.0 | 1024M | 0.25 | 256M | - |
| keycloak | test | 0.75 | 768M | 0.25 | 256M | - |
| connectors | prod | 1.0 | 1024M | 0.25 | 512M | 768m |
| connectors | dev | 1.0 | 512M | 0.125 | 256M | 384m |
| connectors | test | 0.75 | 384M | 0.1 | 192M | 256m |
| identity | prod | 1.0 | 1024M | 0.25 | 256M | 768m |
| identity | dev | 0.5 | 512M | 0.125 | 256M | 384m |
| identity | test | 0.5 | 384M | 0.125 | 192M | 256m |
| web-modeler-restapi | prod | 1.0 | 1024M | 0.25 | 512M | 768m |
| web-modeler-restapi | dev | 0.5 | 512M | 0.125 | 256M | 384m |
| web-modeler-restapi | test | 0.5 | 384M | 0.125 | 192M | 256m |

### Light Tier

| Service | Stage | CPU Limit | Memory Limit | CPU Reservation | Memory Reservation |
|---------|-------|-----------|--------------|-----------------|-------------------|
| postgres | prod | 1.0 | 1024M | 0.25 | 512M |
| postgres | dev | 0.5 | 512M | 0.125 | 256M |
| postgres | test | 0.5 | 512M | 0.125 | 256M |
| web-modeler-db | prod | 0.5 | 512M | 0.1 | 256M |
| web-modeler-db | dev | 0.25 | 256M | 0.05 | 128M |
| web-modeler-db | test | 0.25 | 256M | 0.05 | 128M |
| console | prod | 0.5 | 1024M | 0.25 | 512M |
| console | dev | 0.5 | 512M | 0.125 | 256M |
| console | test | 0.5 | 512M | 0.125 | 256M |
| web-modeler-webapp | prod | 0.5 | 512M | 0.1 | 128M |
| web-modeler-webapp | dev | 0.5 | 256M | 0.05 | 64M |
| web-modeler-webapp | test | 0.25 | 256M | 0.05 | 64M |
| web-modeler-websockets | prod | 0.5 | 256M | 0.1 | 64M |
| web-modeler-websockets | dev | 0.25 | 128M | 0.05 | 32M |
| web-modeler-websockets | test | 0.25 | 128M | 0.05 | 32M |
| mailpit | prod | 0.25 | 128M | 0.05 | 32M |
| mailpit | dev | 0.25 | 128M | 0.05 | 32M |
| mailpit | test | 0.25 | 128M | 0.05 | 32M |
| reverse-proxy | prod | 0.5 | 256M | 0.1 | 64M |
| reverse-proxy | dev | 0.25 | 128M | 0.05 | 32M |
| reverse-proxy | test | 0.25 | 128M | 0.05 | 32M |

## JVM Heap Sizing

JVM heap sizes are scaled proportionally with memory limits to prevent OOM kills:

- **Elasticsearch:** 50% of memory limit (Lucene needs off-heap memory-mapped files)
- **All other JVM services:** 75% of memory limit

Services without a JVM heap column (keycloak, postgres, web-modeler-db, web-modeler-webapp, web-modeler-websockets, mailpit, reverse-proxy) do not run a Java VM.

## Total Footprint Estimates

| Stage | Aggregate CPU Limits | Total Memory Limits | Min Free RAM Needed |
|-------|----------------------|---------------------|---------------------|
| prod | ~17.75 cores | ~28 GB | ~32 GB (with OS overhead) |
| dev | ~10.5 cores | ~15 GB | ~16 GB (with OS overhead) |
| test | ~8.25 cores | ~11 GB | ~12 GB (with OS overhead) |

Aggregate CPU limits are the sum of each container's individual `deploy.resources.limits.cpus` values. They are not a guarantee that the host has that many physical cores available at once. The `prod` profile is still intended for a 16 vCPU / 32 GB host, and the current `~17.75` aggregate keeps only a small CPU overcommit buffer on the assumption that not every service will hit its limit simultaneously.

## Usage

```bash
# Set STAGE in .env, then start
bash scripts/start.sh

# Or on Windows
pwsh -File scripts/start.ps1
```
