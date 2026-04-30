# Camunda 8.9 Agentic AI Configuration

This stack is prepared for Camunda 8.9 agentic AI features:

- AI Agent connector tasks in BPMN processes
- MCP Client connectors inside BPMN processes
- A2A Client connectors for agent-to-agent handoffs
- The built-in Orchestration Cluster MCP server for external AI clients

The runtime configuration is intentionally provider-neutral. Add only the LLM and MCP credentials needed for your environment.

## Runtime Components

| Capability | Service | Current Configuration |
|------------|---------|-----------------------|
| AI Agent, MCP Client, A2A Client connectors | `connectors` | `camunda/connectors-bundle:${CAMUNDA_CONNECTORS_VERSION}` |
| Connector secrets | `connectors` | `connector-secrets.txt` with `CONNECTORS_SECRET` prefix |
| Orchestration Cluster MCP server | `orchestration` | `camunda.mcp.enabled: true` |
| BPMN modeling | `web-modeler-restapi` | Connected to local orchestration cluster |

## Secret Naming

Connector secrets are loaded from `connector-secrets.txt`, which is mounted into the Connectors container as an environment file.

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

## Web Modeler Connector Template Import

Web Modeler can add connector templates from the marketplace when changing a BPMN task type. In this stack, prefer connector templates that match `CAMUNDA_CONNECTORS_VERSION` and `CAMUNDA_WEB_MODELER_VERSION`.

If the marketplace import fails with browser console messages such as:

```text
/api/internal/files 403
Failed to create file
Failed to import resource
COULD_NOT_IMPORT_RESOURCES
```

check `web-modeler-restapi` first:

```bash
docker logs web-modeler-restapi --since 15m
```

Warnings about `c3-navigation-appbar`, Statsig, or `ContextPad#getPad is deprecated` are not the root cause. The actionable failure is the `POST /api/internal/files` response. If the logs show successful authentication and some connector template files were created, the proxy and login path are working; Web Modeler is rejecting only part of the imported template bundle.

For Camunda 8.9.1, import the AI Agent templates from the version-pinned connector repository URLs instead of URLs under `refs/heads/main`:

```text
https://raw.githubusercontent.com/camunda/connectors/8.9.1/connectors/agentic-ai/element-templates/agenticai-aiagent-outbound-connector.json
https://raw.githubusercontent.com/camunda/connectors/8.9.1/connectors/agentic-ai/element-templates/agenticai-aiagent-job-worker.json
```

After importing, refresh Web Modeler and check the task type selector for `AI Agent Task` and `AI Agent Sub-process`. If a previous marketplace import partially succeeded, remove duplicate or partially imported connector templates in Web Modeler before re-importing the version-pinned templates.

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
