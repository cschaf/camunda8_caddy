# Camunda 8.10 AI Features and Agentic AI Configuration

This stack is prepared for the AI features of Camunda 8.10:

- **Hub Copilot** (BPMN, FEEL and form generation, AI-assisted element templates) - optional, see [Hub Copilot quick activation](#hub-copilot-quick-activation)
- AI Agent connector tasks in BPMN processes
- MCP Client connectors inside BPMN processes
- A2A Client connectors for agent-to-agent handoffs
- The built-in Orchestration Cluster MCP server for external AI clients

The runtime configuration is intentionally provider-neutral. Add only the LLM and MCP credentials needed for your environment.

## Runtime Components

| Capability | Service | Current Configuration |
|------------|---------|-----------------------|
| BPMN, FEEL and form Copilot | `hub` | `.hub/application-ai.yaml`, switched via `HUB_AI_ENABLED` (off by default) |
| AI Agent, MCP Client, A2A Client connectors | `connectors` | `camunda/connectors-bundle:${CAMUNDA_CONNECTORS_VERSION}` |
| Connector secrets | `connectors` | `connector-secrets.txt` with `CONNECTORS_SECRET` prefix |
| Orchestration Cluster MCP server | `orchestration` | `camunda.mcp.enabled: true` |
| BPMN modeling | `hub` (Camunda Hub) | Connected to local orchestration cluster |

## ProcessOS Harness (Early Access)

Camunda **ProcessOS** discovers existing processes, re-engineers them for AI and
generates executable Camunda solutions. In 8.10 it ships as **ProcessOS
Harness**: a governance process that runs on Camunda and drives an AI coding
agent in the builder's terminal (Claude Code CLI or GitHub Copilot CLI) through
four phases with SME review gates:

| Phase | Goal | Milestone |
|---|---|---|
| Scope | Define the process to re-engineer | Process scope defined |
| Discover | Derive the as-is process from files, systems and SMEs | As-is models finalized |
| Transform | Turn it into an agentic to-be process | To-be models finalized |
| Implement | Generate BPMN/DMN/forms, workers and tests | Executable solution generated |

**Status in this stack (checked 14.10.2026 against `camunda/hub:8.10.2` and the
8.10 docs):**

- ProcessOS is **not** a Hub feature. The Hub image has no ProcessOS module and
  no `camunda.hub.feature.*` flag for it. The only `process-os` strings in the
  image are inside the Hub Copilot prompts, which follow the modeling
  conventions of Camunda's reference repo `camunda/process-os` (for example
  `retries="3"` on service tasks, a 3-step error pattern, form-based user task
  assignment). That is Copilot behavior, not ProcessOS.
- Nothing in this repo has to be switched on. The stack can serve as the
  organization-wide Camunda cluster that hosts the governance process.
- Access is **early access** for Camunda Enterprise customers with trained
  builders or enabled partners. Ask the Camunda Customer Success Manager.
- **ProcessOS cannot be used yet without an archive from Camunda.** The public
  npm package `@camunda8/c8ctl-plugin-process-os` (0.4.0, 2026-10-12) is only
  the installer. Its README states that the distribution archives
  (`claudecode.zip`, `copilotcli.zip`) are not distributed publicly yet. Access
  to the Camunda hotfix registry does not include them.

### How it is delivered

ProcessOS Harness runs on the builder's own machine, not in this stack:

```bash
npm install -g @camunda8/cli@latest                 # c8ctl, alias c8
c8 load plugin @camunda8/c8ctl-plugin-process-os
# Download claudecode.zip or copilotcli.zip from the Camunda Download Center
# (Enterprise Releases), then inside a new project folder:
c8 os install claudecode --zip /path/to/claudecode.zip
git init && git add . && git commit -m "chore(job) commit process-os-harness setup"
# In Claude Code: /process-os-governance-start
```

Builder client requirements: c8ctl 4.0.0 or later, Node.js 22.18.0 or later,
npm with registry access, Git and the GitHub CLI, a local `c8run` cluster for
validating generated solutions, Camunda Desktop Modeler for reviews, Maven for
Java workers. Generated workers target Spring Boot, TypeScript or Python.

Windows: the Camunda docs list Windows only via WSL; the plugin README says it
also works natively. Use WSL, because that is the configuration Camunda tests.

### What this stack provides

| ProcessOS Harness need | Status here |
|---|---|
| Camunda cluster reachable across the organization (governance process, project state) | Available: `https://orchestration.{HOST}` (REST v2) behind Caddy |
| Tasklist for scope and phase-configuration forms | Available: `https://orchestration.{HOST}/tasklist` |
| c8ctl access to the cluster (deploy, start, jobs) | Not set up yet: needs an OAuth client-credentials client, see [Prepare c8ctl access](#prepare-c8ctl-access-to-this-cluster) |
| Exact cluster requirements of the governance process (connectors, forms, permissions) | Unknown until the distribution archive is available |
| Git repository per project | Outside this repo (any Git-compatible VCS) |
| AI platform for the coding agent | Outside this repo: whatever Claude Code / Copilot CLI support (Anthropic, Amazon Bedrock, Azure OpenAI, Ollama). Camunda recommends Opus-class models |
| Deployment of the generated solution | Normal deployment to this cluster (Hub or c8ctl) |

### Prepare c8ctl access to this cluster

This part can be prepared before the ProcessOS archive arrives. The builder's
c8ctl uses it to deploy, start and query the governance process.

1. **OAuth client.** Use a dedicated M2M client (for example `process-os`)
   instead of the platform client `orchestration`. `orchestration` would work
   technically (it has the `admin` role in `.orchestration/application.yaml`),
   but its secret belongs to the platform and should not be copied to builder
   machines. A dedicated client needs:
   - an `m2m` application in `.identity/application.yaml` with permissions on
     the `orchestration-api` audience (like `connectors`);
   - its secret in `.env-credentials` and in `scripts/generate-secrets.*`;
   - a role in Orchestration. Start with `admin` until the governance process's
     exact permissions are known, then narrow it down. Whether
     `camunda.security.initialization.defaultRoles` assigns it on an existing
     cluster is not verified; otherwise assign it once in Admin
     (`https://orchestration.{HOST}/admin`).

   Not implemented in this repo yet.
2. **Profile on the builder machine** via the environment variables c8ctl
   supports:
   ```bash
   export CAMUNDA_BASE_URL=https://orchestration.<HOST>
   export CAMUNDA_OAUTH_URL=https://keycloak.<HOST>/auth/realms/camunda-platform/protocol/openid-connect/token
   export CAMUNDA_CLIENT_ID=process-os
   export CAMUNDA_CLIENT_SECRET=<secret>
   export CAMUNDA_TOKEN_AUDIENCE=orchestration-api
   # Node does not trust the mkcert / self-signed proxy certificate by default:
   export NODE_EXTRA_CA_CERTS=/path/to/rootCA.pem
   c8 list pi   # connection test
   ```
   The builder machine must resolve and reach `orchestration.<HOST>` and
   `keycloak.<HOST>` (hosts file or DNS).

Out of scope in this release according to Camunda: production deployment and
lifecycle management, platform/CI setup, custom UIs beyond Camunda Forms,
process mining, shared memory across projects (each project keeps its own
private memory locally).

Planning figures from Camunda: about USD 300-600 in tokens and 6-8 hours per
journey from discovery to implementation. Camunda expects the first project to
run with a partner or a Camunda Forward Deployed Engineer and the Camunda
Academy learning path to be completed first.

Sources: [ProcessOS Harness overview](https://docs.camunda.io/docs/components/process-os-harness/overview/),
[Installation](https://docs.camunda.io/docs/components/process-os-harness/installation/),
[System requirements](https://docs.camunda.io/docs/components/process-os-harness/setup/system-requirements/),
[c8ctl plugin on npm](https://www.npmjs.com/package/@camunda8/c8ctl-plugin-process-os),
[c8ctl](https://github.com/camunda/c8ctl).

## Hub Copilot quick activation

Camunda Hub can generate BPMN, FEEL expressions and forms (Copilot, Alpha) and
assist with element templates. The feature is disabled by default and needs one
LLM provider. Activation is a configuration-only change:

1. `.env` - switch the feature on (and optionally pick provider and model):

   ```env
   HUB_AI_ENABLED=true
   HUB_COPILOT_PROVIDER=OPENAI
   HUB_COPILOT_MODEL_ID=gpt-4.1
   ```

2. `.env-credentials` - add the provider key (never commit that file):

   ```env
   HUB_COPILOT_API_KEY=sk-...
   ```

3. Restart: `bash scripts/start.sh` (or `docker compose restart hub`).

OpenAI-compatible gateways work the same way: set `HUB_COPILOT_ENDPOINT` in
`.env` (non-secret, passed through `docker-compose.yaml`) and keep the API key
in `.env-credentials`. Local models via Ollama need no key at all - set
`HUB_COPILOT_PROVIDER=OLLAMA` (plus optional `HUB_OLLAMA_MODEL_ID`).

### Langdock

[Langdock](https://docs.langdock.com/de/developer/overview/api-introduction)
exposes an OpenAI-compatible Chat Completions endpoint, so it works through the
`OPENAI` provider. EU base URL: `https://api.langdock.com/openai/eu/v1`.

`.env`:

```env
HUB_AI_ENABLED=true
HUB_COPILOT_PROVIDER=OPENAI
HUB_COPILOT_MODEL_ID=gpt-5.4-mini
HUB_COPILOT_ENDPOINT=https://api.langdock.com/openai/eu/v1
```

`.env-credentials` (never commit this file):

```env
HUB_COPILOT_API_KEY=<langdock-api-key>
```

List the model ids available to your key, then use one as
`HUB_COPILOT_MODEL_ID`:

```bash
curl -s https://api.langdock.com/openai/eu/v1/models \
  -H "Authorization: Bearer $LANGDOCK_API_KEY"
```

Only OpenAI and Azure OpenAI models are served on Langdock's `/openai/`
endpoint. Anthropic Claude models (for example Haiku 4.5) are served on
Langdock's Anthropic Messages endpoint (`/anthropic/eu/v1`), which Hub's
`ANTHROPIC` provider cannot target because it has no custom-endpoint option.
Use an OpenAI model via Langdock, or a direct Anthropic key for Claude.

| Provider | `HUB_COPILOT_PROVIDER` | Credentials in `.env-credentials` |
|----------|------------------------|-----------------------------------|
| OpenAI / OpenAI-compatible | `OPENAI` | `HUB_COPILOT_API_KEY`, optional `HUB_COPILOT_ENDPOINT` |
| Ollama (local, no cloud) | `OLLAMA` | none; optional `HUB_OLLAMA_BASE_URL`, `HUB_OLLAMA_MODEL_ID` |
| Anthropic | `ANTHROPIC` | `HUB_ANTHROPIC_API_KEY` + uncomment block |
| AWS Bedrock | `BEDROCK` | `HUB_BEDROCK_*` + uncomment block |
| Azure OpenAI | `AZURE_OPENAI` | `HUB_AZURE_OPENAI_*` + uncomment block |
| Azure AI | `AZURE_AI` | `HUB_AZURE_AI_*` + uncomment block |
| Google Vertex AI | `VERTEX_AI` | `HUB_VERTEX_*` + uncomment block |
| Hugging Face | `HUGGING_FACE` | `HUB_HF_*` + uncomment block |

Everything is pre-wired in `.hub/application-ai.yaml`, which `hub` loads in
addition to `.hub/application.yaml`. The full option list (temperature,
timeouts, separate providers per copilot, agent/sub-agent tuning) is in the
[Camunda Hub Copilot documentation](https://github.com/camunda/camunda-docs/blob/main/docs/self-managed/components/hub/configuration/copilot.md).

Notes:

- **Model strength matters.** Camunda recommends a GPT-4-class model for BPMN
  generation; weaker models often return invalid BPMN XML even after the
  built-in repair attempts.
- **Never leave provider credentials empty.** Hub refuses to start
  (`Binding to CopilotProperties failed`) when a provider block contains empty
  values - verified against `camunda/hub:8.10-rc1`. The prepared file
  therefore uses non-empty placeholder defaults (`not-configured`) that stay
  inert until you set a real key.
- The switch is Hub-only: processes, workers and connectors are unaffected.
  With `HUB_AI_ENABLED=false` (the default) the stack stays AI-free.

## Secret Naming

Connector secrets are loaded from `connector-secrets.txt`, which is mounted into the Connectors container as an environment file.

> **`.env-credentials` is for stack-internal credentials only.** Provider keys for OpenAI, Anthropic, Google Vertex, MCP clients, and other third-party AI services belong in `connector-secrets.txt` with the `CONNECTORS_SECRET_` prefix. They are not part of `.env-credentials` and are not generated by `scripts/generate-secrets.sh` / `.ps1`.

The connector runtime is configured with this prefix:

```yaml
camunda:
  connector:
    secret-provider:
      environment:
        prefix: "CONNECTORS_SECRET"
```

That means a BPMN connector field using:

```text
{{secrets.OPENAI_API_KEY}}
```

resolves this environment variable:

```env
CONNECTORS_SECRET_OPENAI_API_KEY=sk-...
```

Do not put real provider keys in `.env.example`, `connector-secrets.txt.example`, README snippets, BPMN fixtures, or committed documentation.

## LLM Provider Setup

Start with one provider. OpenAI-compatible endpoints are usually the fastest path for local validation, while Azure OpenAI, Amazon Bedrock, or Google Vertex AI are better fits when corporate identity, region, audit, or network controls are required.

### OpenAI

`connector-secrets.txt`:

```env
CONNECTORS_SECRET_OPENAI_API_KEY=sk-...
```

In the AI Agent connector template:

- Provider: OpenAI
- API key: `{{secrets.OPENAI_API_KEY}}`
- Model: the model approved for the environment
- Timeout: `PT60S`

### OpenAI-Compatible

Use this for providers or gateways that expose an OpenAI-compatible API.

In the AI Agent connector template:

- Provider: OpenAI-compatible
- API endpoint: provider base URL, for example `https://api.example.com/v1`
- API key: `{{secrets.OPENAI_API_KEY}}`, or leave blank when using custom headers
- Headers: add required gateway headers
- Query parameters: add provider-specific values such as API version or metadata
- Timeout: `PT60S`

### Azure OpenAI

`connector-secrets.txt`:

```env
CONNECTORS_SECRET_AZURE_OPENAI_API_KEY=...
```

In the AI Agent connector template:

- Provider: Azure OpenAI
- Endpoint: Azure OpenAI resource endpoint
- Authentication: API key or client credentials
- Model: Azure deployment ID
- Timeout: `PT60S`

### Amazon Bedrock

Use Bedrock when AWS IAM, region placement, or approved foundation models are required. Camunda 8.9 supports long-term API key authentication in addition to existing Bedrock authentication methods.

### Google Vertex AI

For local development, use service account credentials or Application Default Credentials. If a service account JSON is used as an environment variable, keep the JSON on one line in `connector-secrets.txt`.

## First AI Agent Process

Create the smallest process before introducing tool calling:

1. Start event
2. Service task with the AI Agent connector
3. User task for human review
4. End event

Recommended connector settings:

| Field | Value |
|-------|-------|
| Prompt input | Keep deterministic and include only required process variables |
| Model timeout | `PT60S` |
| Output variable | `aiResult` |
| Error path | Boundary error event or incident handling path |
| Human review | Required for the first iteration |

After this works, add an ad-hoc subprocess with a small set of allowed tools. Keep the first tool set narrow, for example one REST connector or one MCP tool, then expand after observing behavior.

## Hub Connector Template Import

Hub can add connector templates from the marketplace when changing a BPMN task type. In this stack, prefer connector templates that match `CAMUNDA_CONNECTORS_VERSION` and `CAMUNDA_HUB_VERSION`.

If the marketplace import fails with browser console messages such as:

```text
/api/internal/files 403
Failed to create file
Failed to import resource
COULD_NOT_IMPORT_RESOURCES
```

check `hub` first:

```bash
docker logs hub --since 15m
```

Warnings about `c3-navigation-appbar`, Statsig, or `ContextPad#getPad is deprecated` are not the root cause. The actionable failure is the `POST /api/internal/files` response. If the logs show successful authentication and some connector template files were created, the proxy and login path are working; Hub is rejecting only part of the imported template bundle.

For Camunda 8.9.6, import the AI Agent templates from the version-pinned connector repository URLs instead of URLs under `refs/heads/main` (replace `8.9.6` with the `CAMUNDA_CONNECTORS_VERSION` in use, e.g. `8.10.0` - the tag must exist in the `camunda/connectors` repository):

```text
https://raw.githubusercontent.com/camunda/connectors/8.9.6/connectors/agentic-ai/element-templates/agenticai-aiagent-outbound-connector.json
https://raw.githubusercontent.com/camunda/connectors/8.9.6/connectors/agentic-ai/element-templates/agenticai-aiagent-job-worker.json
```

After importing, refresh Hub and check the task type selector for `AI Agent Task` and `AI Agent Sub-process`. If a previous marketplace import partially succeeded, remove duplicate or partially imported connector templates in Hub before re-importing the version-pinned templates.

## Orchestration Cluster MCP Server

The Orchestration Cluster MCP server is enabled in `.orchestration/application.yaml`:

```yaml
camunda:
  mcp:
    enabled: true
```

It is exposed by the Orchestration REST port at `/mcp/cluster`.

### Local Direct HTTP

Use this when the MCP client runs on the Docker host and can connect to the loopback-bound Orchestration port:

```json
{
  "servers": {
    "camunda": {
      "type": "http",
      "url": "http://localhost:8088/mcp/cluster"
    }
  }
}
```

### HTTPS Through Caddy

Use this when the MCP client should connect through the same hostname and TLS path as browser users:

```json
{
  "servers": {
    "camunda": {
      "type": "http",
      "url": "https://orchestration.camunda.dev.local/mcp/cluster"
    }
  }
}
```

If `HOST` is changed, replace `camunda.dev.local` with the configured lowercase host.

### Authenticated Clients

For clients that cannot perform OAuth client credentials directly, use `c8ctl mcp-proxy` from the Camunda CLI. The proxy receives local STDIO MCP traffic, obtains OAuth tokens, and forwards calls to the remote MCP endpoint.

For local Docker Compose validation, direct HTTP is enough when the client is on the Docker host. For shared or production-like environments, use OIDC client credentials and restrict the client permissions to the minimum scopes and roles required.

## MCP Client Connector Inside BPMN

Use the MCP Client connector when a process or AI Agent should call a remote MCP server as a tool.

For a local call back into this same Camunda cluster, configure the connector runtime with a remote HTTP MCP client that targets:

```text
http://orchestration:8080/mcp/cluster
```

Use OAuth only when the target MCP server requires it. Store client secrets as connector secrets, for example:

```env
CONNECTORS_SECRET_MCP_CLIENT_SECRET=...
CONNECTORS_SECRET_MCP_API_KEY=...
```

## Network and Proxy Notes

The Connectors container has `host.docker.internal` available, so it can reach an LLM gateway or test MCP server running on the Docker host.

If the environment requires an outbound proxy, configure standard proxy environment variables on the `connectors` service or in an environment-specific Compose override:

```yaml
services:
  connectors:
    environment:
      HTTPS_PROXY: http://proxy.example.com:8080
      HTTP_PROXY: http://proxy.example.com:8080
      NO_PROXY: orchestration,keycloak,localhost,127.0.0.1
```

If the proxy or provider uses a private CA, mount a truststore and set:

```env
JAVAX_NET_SSL_TRUSTSTORE=/path/in/container/truststore.jks
JAVAX_NET_SSL_TRUSTSTOREPASSWORD=...
```

## Safety Guardrails

- Keep real LLM and MCP credentials only in `connector-secrets.txt` or an external secret manager.
- Use model timeouts on every AI Agent task.
- Start with human review before allowing AI-generated actions to complete a process automatically.
- Give AI agents a small, explicit tool set.
- Prefer read-only MCP tools first, then add write tools such as incident resolution or process creation after authorization is reviewed.
- Use Camunda authorizations to limit what connector clients and MCP clients can access.
- Do not expose direct service ports beyond loopback; route user and MCP traffic through Caddy or a controlled internal network path.
