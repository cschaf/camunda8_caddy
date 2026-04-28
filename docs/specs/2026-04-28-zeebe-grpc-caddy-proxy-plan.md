# Zeebe gRPC Reverse Proxy via Caddy — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add Caddy reverse proxy support for Zeebe gRPC on `zeebe.camunda.dev.local:443` with TLS termination at Caddy.

**Architecture:** Caddy terminates TLS from gRPC clients and forwards HTTP/2 cleartext (h2c) to the Zeebe gateway running on `orchestration:26500`. The `zeebe` subdomain is added to the hosts-file management scripts so it resolves to `127.0.0.1`.

**Tech Stack:** Caddy, Docker Compose, Zeebe gRPC, h2c

---

## Files That Change

| File | Responsibility |
|------|----------------|
| `Caddyfile.example` | Template for all Caddy routes; source of truth for site blocks |
| `Caddyfile` | Active Caddy configuration (rendered from template by setup-host) |
| `scripts/setup-host.sh` | Bash setup script; manages hosts file and Caddyfile rendering |
| `scripts/setup-host.ps1` | PowerShell setup script; Windows equivalent |
| `dashboard/index.html` | Landing page with service links and status LEDs |

---

### Task 1: Add zeebe site block to Caddyfile.example

**Files:**
- Modify: `Caddyfile.example:139-156`

- [ ] **Step 1: Add Zeebe gRPC Gateway site block**

Insert the following block after the `orchestration.camunda.dev.local` block and before the `webmodeler.camunda.dev.local` block in `Caddyfile.example`:

```caddy
# Zeebe gRPC Gateway
zeebe.localhost {
    reverse_proxy h2c://orchestration:26500 {
        flush_interval -1
    }
}

```

Rationale: `h2c://` forces HTTP/2 cleartext to the backend (required for gRPC). `flush_interval -1` disables response buffering so gRPC streaming works correctly. No `handle /health` block is needed because gRPC is not HTTP-browser-accessible.

- [ ] **Step 2: Verify the block placement**

The order in `Caddyfile.example` should now be:
1. `camunda.dev.local` (dashboard)
2. `keycloak.camunda.dev.local`
3. `identity.camunda.dev.local`
4. `console.camunda.dev.local`
5. `optimize.camunda.dev.local`
6. `orchestration.camunda.dev.local`
7. **NEW: `zeebe.localhost`**
8. `webmodeler.camunda.dev.local`

- [ ] **Step 3: Commit**

```bash
git add Caddyfile.example
git commit -m "config: add zeebe gRPC gateway site block to Caddyfile template"
```

---

### Task 2: Add zeebe site block to current Caddyfile

**Files:**
- Modify: `Caddyfile:145-163`

- [ ] **Step 1: Add the same block to the active Caddyfile**

Insert the Zeebe gRPC Gateway site block after the `orchestration.camunda.dev.local` block and before `webmodeler.camunda.dev.local`:

```caddy
# Zeebe gRPC Gateway
zeebe.camunda.dev.local {
    tls /certs/_wildcard.camunda.dev.local+1.pem /certs/_wildcard.camunda.dev.local+1-key.pem
    reverse_proxy h2c://orchestration:26500 {
        flush_interval -1
    }
}

```

Note: The active `Caddyfile` already has hardcoded `tls` directives for custom certificates (from a previous `setup-host` run). Match the same pattern as the other blocks.

- [ ] **Step 2: Verify Caddyfile syntax**

Check that the file is well-formed:

```bash
docker run --rm -v "$(pwd)/Caddyfile:/etc/caddy/Caddyfile:ro" caddy:latest caddy validate --config /etc/caddy/Caddyfile
```

Expected: `"valid Caddyfile"`

- [ ] **Step 3: Commit**

```bash
git add Caddyfile
git commit -m "config: add zeebe gRPC reverse proxy to active Caddyfile"
```

---

### Task 3: Update setup-host.sh

**Files:**
- Modify: `scripts/setup-host.sh:143`

- [ ] **Step 1: Add zeebe to SUBDOMAINS list**

Change line 143 from:

```bash
SUBDOMAINS="keycloak identity console optimize orchestration webmodeler"
```

To:

```bash
SUBDOMAINS="keycloak identity console optimize orchestration webmodeler zeebe"
```

- [ ] **Step 2: Commit**

```bash
git add scripts/setup-host.sh
git commit -m "config: add zeebe subdomain to setup-host script"
```

---

### Task 4: Update setup-host.ps1

**Files:**
- Modify: `scripts/setup-host.ps1:80`

- [ ] **Step 1: Add zeebe to $subdomains array**

Change line 80 from:

```powershell
$subdomains = @("keycloak", "identity", "console", "optimize", "orchestration", "webmodeler")
```

To:

```powershell
$subdomains = @("keycloak", "identity", "console", "optimize", "orchestration", "webmodeler", "zeebe")
```

- [ ] **Step 2: Commit**

```bash
git add scripts/setup-host.ps1
git commit -m "config: add zeebe subdomain to PowerShell setup-host script"
```

---

### Task 5: Add Zeebe gRPC endpoint to dashboard

**Files:**
- Modify: `dashboard/index.html:160-161`

- [ ] **Step 1: Add new "APIs & Endpoints" section**

Insert a new section after the `</section>` closing tag of the "Administration" section (around line 161) and before the `</main>` closing tag:

```html
                <section class="dashboard-section">
                    <h2 class="section-title">APIs &amp; Endpoints</h2>
                    <div class="grid">
                        <div class="card" style="cursor: default;">
                            <div class="card-accent"></div>
                            <div class="icon">
                                <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2">
                                    <path d="M10 13a5 5 0 0 0 7.54.54l3-3a5 5 0 0 0-7.07-7.07l-1.72 1.71"/>
                                    <path d="M14 11a5 5 0 0 0-7.54-.54l-3 3a5 5 0 0 0 7.07 7.07l1.71-1.71"/>
                                </svg>
                            </div>
                            <h2>Zeebe gRPC</h2>
                            <p>Workflow Engine API</p>
                            <span class="url">zeebe.{{env "HOST"}}:443</span>
                            <div class="status online"><span class="status-led"></span><span class="status-text">gRPC via TLS</span></div>
                        </div>
                    </div>
                </section>
```

Note: This card is not clickable (no `<a>` tag) because gRPC is not browser-accessible. It serves as documentation of the endpoint. The status is hardcoded as "online" with a green LED because the endpoint's availability is tied to Caddy and orchestration health, which are already monitored by other cards.

- [ ] **Step 2: Commit**

```bash
git add dashboard/index.html
git commit -m "ui: add Zeebe gRPC endpoint to dashboard"
```

---

### Task 6: Apply configuration and verify

**Files:**
- None (runtime verification)

- [ ] **Step 1: Run setup-host to update hosts file**

On Linux/macOS (or Git Bash on Windows):

```bash
bash scripts/setup-host.sh
```

On Windows (PowerShell as Administrator):

```powershell
pwsh -File scripts/setup-host.ps1
```

Expected output: "Updated hosts file (replaced *.localhost -> *.$HOST)" and "Updated Caddyfile"

Note: Re-running `setup-host` regenerates the Caddyfile from `Caddyfile.example`, so the zeebe block will be included automatically.

- [ ] **Step 2: Restart Caddy container**

```bash
docker compose restart reverse-proxy
```

Wait ~5 seconds for Caddy to reload:

```bash
docker compose logs reverse-proxy --tail 20
```

Expected: No errors. Caddy should report that it loaded the new configuration.

- [ ] **Step 3: Verify DNS resolution**

```bash
ping -c 1 zeebe.camunda.dev.local
```

Expected: `127.0.0.1` responds.

- [ ] **Step 4: Test with zbctl**

If `zbctl` is installed:

```bash
zbctl --address zeebe.camunda.dev.local:443 --tls status
```

Expected output: Cluster topology with broker count, partitions, and replication factor.

If `zbctl` is not installed, verify with `grpcurl` (if available):

```bash
grpcurl -proto gateway.proto zeebe.camunda.dev.local:443 gateway_protocol.Gateway/Topology
```

Or verify TLS handshake only:

```bash
openssl s_client -connect zeebe.camunda.dev.local:443 -servername zeebe.camunda.dev.local </dev/null
```

Expected: TLS handshake succeeds, certificate is presented for `*.camunda.dev.local` or `zeebe.camunda.dev.local`.

- [ ] **Step 5: Commit (if any final fixes needed)**

If no fixes are needed, there is nothing to commit in this task.

---

## Self-Review

**1. Spec coverage:**
- Caddyfile.example changes: Task 1 ✓
- Active Caddyfile changes: Task 2 ✓
- Setup-host script updates: Tasks 3 and 4 ✓
- Dashboard update: Task 5 ✓
- Testing instructions: Task 6 ✓
- TLS certificate clarification: Documented in spec, no code changes needed for orchestration ✓

**2. Placeholder scan:**
- No "TBD", "TODO", or vague requirements found.
- All code blocks contain exact content.
- All commands include expected output.

**3. Type consistency:**
- File paths match actual repository structure.
- Caddy directives (`h2c://`, `flush_interval`) are correct for Caddy v2.
- Subdomain naming follows existing pattern (`zeebe.localhost` in template, `zeebe.camunda.dev.local` when rendered).

**4. Gap check:**
- No gaps identified. All spec requirements have corresponding tasks.
