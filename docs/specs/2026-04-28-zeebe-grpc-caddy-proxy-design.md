# Zeebe gRPC Reverse Proxy via Caddy

## Overview

Add Caddy reverse proxy support for the Zeebe gRPC API (port 26500) so clients can connect via a dedicated subdomain (`zeebe.camunda.dev.local:443`) with TLS termination handled by Caddy.

## Context

The orchestration container currently exposes three ports:
- `26500` — Zeebe gRPC gateway
- `9600` — Spring Boot actuator/management
- `8080` — Operate/Tasklist REST API and UI (already proxied via `orchestration.camunda.dev.local`)

Ports 26500 and 9600 are bound directly to the host. This design adds Caddy proxying for gRPC on a dedicated subdomain.

## Architecture

### TLS Termination at Caddy

```
Client (zbctl / Java Client)
    |
    | TLS (HTTPS on port 443)
    v
zeebe.camunda.dev.local  [Caddy]
    |
    | HTTP/2 cleartext (h2c)
    v
orchestration:26500  [Zeebe Gateway]
```

Caddy handles all TLS. The backend (orchestration) receives plain HTTP/2 traffic. No TLS certificate needs to be mounted into or configured for the orchestration container.

## Changes

### 1. Caddyfile.example

Add a new site block for the Zeebe gRPC gateway:

```caddy
# Zeebe gRPC Gateway
zeebe.localhost {
    reverse_proxy h2c://orchestration:26500 {
        flush_interval -1
    }
}
```

The `h2c://` scheme forces HTTP/2 cleartext to the backend, which is required for gRPC. `flush_interval -1` disables response buffering so gRPC streaming works correctly.

### 2. Setup-Host Scripts

Add `zeebe` to the `SUBDOMAINS` list in both scripts so `zeebe.camunda.dev.local` resolves to `127.0.0.1`:

- `scripts/setup-host.sh`
- `scripts/setup-host.ps1`

### 3. Dashboard (optional)

Add a reference card in `dashboard/index.html` under a new "APIs & Endpoints" section so developers can discover the gRPC endpoint. No health check is attached since gRPC is not HTTP-browser-accessible.

## Testing

After running `setup-host` and restarting Caddy:

```bash
# With zbctl (TLS required)
zbctl --address zeebe.camunda.dev.local:443 --tls status

# With Java client:
# address=zeebe.camunda.dev.local:443, useTls=true
```

## TLS Certificate Note

The `FULLCHAIN_PEM` and `PRIVATEKEY_PEM` variables in `.env` are used **only by Caddy**. The orchestration container does not need these certificates for TLS-termination-at-proxy operation. Caddy mounts `./certs:/certs:ro` and presents the certificate to external clients.

If end-to-end TLS (Caddy -> orchestration encrypted) or direct TLS-to-orchestration is desired in the future, the Zeebe gateway would need to be explicitly configured with `zeebe.broker.gateway.security` settings in `application.yaml` and the certificate volume-mounted into the orchestration container.
