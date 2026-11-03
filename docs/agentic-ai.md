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

**Status (checked 03.11.2026 against the public docs, the public changelog and
npm):**

- ProcessOS is **not** a Hub feature and runs **outside** this stack. The Hub
  image has no ProcessOS module and no `camunda.hub.feature.*` flag for it.
  The only `process-os` strings in the Hub image are inside the Hub Copilot
  prompts (modeling conventions), which is Copilot behavior, not ProcessOS.
- This stack serves as the organization-wide **governance cluster**: a
  supported Camunda 8 release, SaaS or Self-Managed, reachable across the
  organization. Nothing has to be switched on; the builder's c8ctl needs an
  API client (see below).
- Access: Camunda Enterprise customers and partners with a signed partner
  agreement. The distribution archives are in the Camunda Download Center
  (`https://downloads.camunda.cloud/enterprise-release/`, Enterprise
  credentials). The public npm package `@camunda8/c8ctl-plugin-process-os` is
  only the installer.
- Releases: **1.0.0** (2026-10-13) is the stable release and requires c8ctl
  4.3.0 or later. `1.1.0-alpha.*` are previews of the next minor (alpha.1
  requires c8ctl 4.6.0).

> **Licensing:** the distribution archives are licensed by Camunda (Camunda
> License 1.0) and are not public. Never commit an archive, its installed
> files (for example the skills under `.claude/skills/` or `.github/skills/`)
> or descriptions of its internals to this repository. Run `c8 os install` only in a separate
> project folder with its own private Git repository, never in this repo.

### How it is delivered

ProcessOS Harness runs on the builder's own machine, not in this stack:

```bash
npm install -g @camunda8/cli@latest                 # c8ctl, alias c8 (4.3.0+)
c8 load plugin @camunda8/c8ctl-plugin-process-os
mkdir -p <my-project> && cd <my-project>            # NOT inside this repo
# Download the archive for your agent (claudecode or copilotcli) from the
# Camunda Download Center (Enterprise Releases), then:
c8 os install claudecode --zip /path/to/<archive>.zip
git init && git add . && git commit -m "chore(job) commit process-os-harness setup"
# In Claude Code (Opus-class model): /process-os-governance-start
```

Upgrades use `c8 os switch <target> --zip <file.zip>`; `c8 os uninstall`
removes the installation.

Builder machine requirements: Windows via WSL, macOS or Unix; Node.js 22.18.0
or later; c8ctl; Git and the GitHub CLI; Maven for Java workers; `c8run` for
validating generated solutions locally; Camunda Modeler for reviews; the AI
coding agent (Claude Code or GitHub Copilot CLI) with permission to run
commands, outbound network access and write access to the project repository.

### What this stack provides

| ProcessOS Harness need | Status here |
|---|---|
| Governance cluster reachable across the organization | `https://orchestration.{HOST}` (REST v2) behind Caddy |
| API client for the builder's c8ctl | Client `c8ctl` (M2M, audience `orchestration-api`, Orchestration role `admin`), see [c8ctl access](#c8ctl-access-to-this-cluster) |
| SME reviews | Tasklist at `https://orchestration.{HOST}/tasklist`; SMEs need a user with Tasklist access and permission to work on the governance process's user tasks |
| Git repository per project | Outside this repo (any Git-compatible VCS, private) |
| AI platform for the coding agent | Outside this repo: whatever Claude Code / Copilot CLI support (Anthropic, Amazon Bedrock, Azure OpenAI, Ollama). Camunda recommends Opus-class models |
| Deployment of the generated solution | Normal deployment to this cluster (Hub or c8ctl) |

### c8ctl access to this cluster

The stack provisions a dedicated machine-to-machine client **`c8ctl`** for the
Camunda 8 CLI and other builder tooling. It is separate from the platform
client `orchestration`, so its secret can be handed to builders and rotated
without touching the platform.

- Keycloak client: `.identity/application.yaml` (`orchestration.applications`,
  `type: m2m`, `read:*` / `write:*` on `orchestration-api`).
- Secret: `C8CTL_CLIENT_SECRET` in `.env-credentials`, generated by
  `scripts/generate-secrets.*`.
- Orchestration role: `admin` via
  `camunda.security.initialization.defaultRoles` in
  `.orchestration/application.yaml`. Narrow it down once the exact permissions
  the tooling needs are known.

**Existing installations** (`.env-credentials` created before the client was
added) must add the secret once before the next start; Compose stops with
`C8CTL_CLIENT_SECRET is required` otherwise:

```bash
echo "C8CTL_CLIENT_SECRET=$(openssl rand -hex 24)" >> .env-credentials
bash scripts/start.sh
```

**Profile on the builder machine:**

```bash
c8ctl add profile <name>   --baseUrl=https://orchestration.<HOST>   --oAuthUrl=https://keycloak.<HOST>/auth/realms/camunda-platform/protocol/openid-connect/token   --audience=orchestration-api   --clientId=c8ctl --clientSecret=<C8CTL_CLIENT_SECRET>
c8ctl --json get topology --profile <name>   # must list brokers / clusterSize
```

The builder machine must resolve and reach `orchestration.<HOST>` and
`keycloak.<HOST>` on port 443. Node.js does not use the OS trust store by
default: point `NODE_EXTRA_CA_CERTS` at the root CA of the proxy certificate
(corporate CA or the mkcert root), or c8ctl fails with a TLS error.

Out of scope in this release according to Camunda: production deployment and
lifecycle management, platform/CI setup, custom UIs beyond Camunda Forms,
process mining, shared memory across projects (each project keeps its own
private memory locally).

Planning figures from Camunda: 6-8 hours per journey; token cost about USD
300-600 for an explorative run on a small use case, 800-1,500+ for a
lift-and-shift of a medium process and 1,000-2,000+ for an AI transformation of
a medium-to-large process. Camunda expects the first project to
run with a partner or a Camunda Forward Deployed Engineer and the Camunda
Academy learning path to be completed first.

Sources: [ProcessOS Harness overview](https://docs.camunda.io/docs/components/process-os-harness/overview/),
[Installation](https://docs.camunda.io/docs/components/process-os-harness/installation/),
[Changelog](https://docs.camunda.io/docs/components/process-os-harness/changelog/),
[Project setup](https://docs.camunda.io/docs/components/process-os-harness/setup/project-setup/),
[System requirements](https://docs.camunda.io/docs/components/process-os-harness/setup/system-requirements/),
[c8ctl plugin on npm](https://www.npmjs.com/package/@camunda8/c8ctl-plugin-process-os),
[c8ctl](https://github.com/camunda/c8ctl) and its [command reference](https://github.com/camunda/c8ctl/blob/main/docs/command-reference.md).

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
        prefix: "CONNECTORS_SECRET_"
```

The runtime builds the lookup name as `prefix + name` without a separator, so the trailing underscore is required. Without it, `{{secrets.OPENAI_API_KEY}}` looks for `CONNECTORS_SECRETOPENAI_API_KEY` and fails with `Secret with name 'OPENAI_API_KEY' is not available`.

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
