# Connecting a Spring Boot Worker to Zeebe

This guide shows how to run a Spring Boot Java application as an external Zeebe worker against this Camunda Docker Compose stack.

The example assumes:

- Camunda is exposed through Caddy on `https://*.camunda.dev.local`.
- Zeebe gRPC is exposed through `https://zeebe.camunda.dev.local:443`.
- Operate/Tasklist REST is exposed through `https://orchestration.camunda.dev.local`.
- Keycloak provides OIDC tokens at `https://keycloak.camunda.dev.local/auth/realms/camunda-platform`.
- The worker runs in its own Docker container.

## Network Model

The most important detail is name resolution from inside the worker container.

On the Docker host, entries such as this can work:

```text
127.0.0.1 zeebe.camunda.dev.local
```

Inside a Docker container, however, `127.0.0.1` means the worker container itself. It does not mean the host machine and it does not mean the Camunda reverse proxy. If the worker container resolves `zeebe.camunda.dev.local` to `127.0.0.1`, gRPC fails with an error similar to:

```text
Connection refused: zeebe.camunda.dev.local/127.0.0.1:443
```

For local Docker-to-host routing, use Docker's special `host-gateway` value. For a remote Camunda server, use the reachable IP address of that server.

## Docker Compose

Example `docker-compose.yaml` for the worker:

```yaml
services:
  camunda-utils-connector:
    build:
      context: .
    volumes:
      - ${CONFIG_FILE:-./src/main/resources/application-onpremise.yaml}:/app/application.yaml:ro
      - ${CERTS_DIR:-./certs}:/app/certs:ro
    extra_hosts:
      - "${CAMUNDA_HOST}:${CAMUNDA_HOST_GATEWAY}"
      - "keycloak.${CAMUNDA_HOST}:${CAMUNDA_HOST_GATEWAY}"
      - "orchestration.${CAMUNDA_HOST}:${CAMUNDA_HOST_GATEWAY}"
      - "zeebe.${CAMUNDA_HOST}:${CAMUNDA_HOST_GATEWAY}"
    environment:
      CAMUNDA_CLIENT_ID: ${CAMUNDA_CLIENT_ID}
      CAMUNDA_CLIENT_SECRET: ${CAMUNDA_CLIENT_SECRET}
    restart: unless-stopped
    deploy:
      replicas: ${REPLICAS:-1}

networks:
  default:
    name: camunda-utils-connector-network
```

## Environment File

Example `.env`:

```env
# Config file path. Use forward slashes on Windows.
CONFIG_FILE=C:/path/to/config/application-onpremise.yaml

# Replica count.
REPLICAS=1

# Certificates directory. Import all required *.crt and *.pem files into the JVM truststore
# from this directory during container startup.
CERTS_DIR=C:/path/to/certs

# Base Camunda host name.
CAMUNDA_HOST=camunda.dev.local

# Local Docker setup: route container traffic to the Docker host.
CAMUNDA_HOST_GATEWAY=host-gateway

# Dedicated machine-to-machine application created in Camunda Identity.
CAMUNDA_CLIENT_ID=camunda-utils-connector
CAMUNDA_CLIENT_SECRET=change-me
```

For a remote Camunda server, replace `host-gateway` with the server IP:

```env
CAMUNDA_HOST_GATEWAY=192.168.1.50
```

Do not use `127.0.0.1` for `CAMUNDA_HOST_GATEWAY` when the worker runs in Docker. It points back to the worker container itself.

The Compose `.env` file is used for variable interpolation by Docker Compose. It is not automatically passed to the Spring Boot process inside the container. If the Spring Boot configuration uses `${CAMUNDA_CLIENT_SECRET}`, pass it explicitly through the service `environment:` block as shown above.

## Create an API Account in Camunda Identity

Create a dedicated machine-to-machine application for the worker instead of reusing the built-in `orchestration` client. This gives the worker its own client ID and secret and makes rotation or revocation independent from the platform components.

1. Open Identity:

   ```text
   https://identity.camunda.dev.local
   ```

2. Log in with an administrative user that has the `ManagementIdentity` role.

3. Go to the Identity section for applications or API clients.

4. Create a new application:

   ```text
   Name: Camunda Utils Connector
   Client ID: camunda-utils-connector
   Type: Machine-to-machine / M2M / confidential client
   ```

5. Generate or copy the client secret.

6. Assign permissions for the Orchestration API:

   ```text
   Audience: orchestration-api
   Permissions: read:*, write:*
   ```

   A worker needs write access to activate and complete jobs. Read access is useful for topology and metadata calls.

7. Save the application and put the credentials into the worker `.env`:

   ```env
   CAMUNDA_CLIENT_ID=camunda-utils-connector
   CAMUNDA_CLIENT_SECRET=<secret-from-identity>
   ```

8. Use the same client ID in the Spring Boot configuration:

   ```yaml
   camunda:
     client:
       auth:
         client-id: ${CAMUNDA_CLIENT_ID}
         client-secret: ${CAMUNDA_CLIENT_SECRET}
         audience: orchestration-api
   ```

If the Identity UI creates the application in Keycloak but the worker still receives `401` or `403` responses, verify that the application has permissions for the `orchestration-api` audience and that the Spring Boot client requests the same audience.

## Spring Boot Configuration

Example `application.yaml`:

```yaml
debug:
  mode: true

server:
  port: 0
  tomcat:
    threads:
      max: 50
      min-spare: 10

logging:
  level:
    io:
      camunda: INFO
      camunda.zeebe: INFO

spring:
  threads:
    virtual:
      enabled: true

camunda:
  client:
    mode: self-managed
    enabled: true
    grpc-address: https://zeebe.camunda.dev.local:443
    rest-address: https://orchestration.camunda.dev.local
    prefer-rest-over-grpc: false

    auth:
      method: oidc
      client-id: ${CAMUNDA_CLIENT_ID}
      client-secret: ${CAMUNDA_CLIENT_SECRET}
      token-url: https://keycloak.camunda.dev.local/auth/realms/camunda-platform/protocol/openid-connect/token
      audience: orchestration-api

    worker:
      defaults:
        enabled: true
        stream-enabled: false
        tenant-ids:
          - <default>

common:
  security:
    auth-provider: "NoAuthentication"
    jwtValidTokensFilePath: ""
    jwtEncryptionKey: ""
```

Use an environment variable for `CAMUNDA_CLIENT_SECRET` instead of committing the secret into the YAML file.

## Certificates

The worker JVM must trust the certificate served by Caddy for `*.camunda.dev.local`.

Mount the certificate directory into the container:

```yaml
volumes:
  - ${CERTS_DIR:-./certs}:/app/certs:ro
```

The worker image should import the required `*.crt` or `*.pem` files into the JVM truststore before starting the application. A successful import typically logs messages like:

```text
Certificate was added to keystore
Certificate '<name>' imported successfully.
```

If name resolution works but the certificate is not trusted, the error changes from `Connection refused` to a TLS or PKIX validation error.

## Validation

Render the final Compose configuration:

```bash
docker compose config
```

Start the worker:

```bash
docker compose up -d --build
```

Check name resolution inside the worker container:

```bash
docker compose exec camunda-utils-connector getent hosts zeebe.camunda.dev.local
```

Expected for local Docker:

```text
<docker-host-gateway-ip> zeebe.camunda.dev.local
```

Expected for a remote Camunda server:

```text
<camunda-server-ip> zeebe.camunda.dev.local
```

It must not resolve to `127.0.0.1`.

Check that the token endpoint is reachable:

```bash
docker compose exec camunda-utils-connector curl -k https://keycloak.camunda.dev.local/auth/realms/camunda-platform/.well-known/openid-configuration
```

If the image does not include `curl`, run the same check from another temporary container in the same Docker network or add the tool to a debug image.

## Expected Startup Logs

When the Spring Boot application starts correctly, the Camunda client auto-configuration should create a Zeebe client and register the annotated job workers. Logs typically include:

```text
Creating zeebeClient using zeebeClientConfiguration
Configuring 1 Job worker(s)
Starting job worker
```

After that, the worker polls Zeebe for jobs of its configured job type.

## Troubleshooting

### Connection refused to 127.0.0.1

Symptom:

```text
Connection refused: zeebe.camunda.dev.local/127.0.0.1:443
```

Cause: the worker container resolves `zeebe.camunda.dev.local` to itself.

Fix: configure `extra_hosts` with `host-gateway` for local Docker or with the Camunda server IP for a remote setup.

### Legacy property warnings

If Spring logs warnings about legacy properties, update old Zeebe-specific properties to the current Camunda client layout:

```yaml
camunda:
  client:
    enabled: true
    grpc-address: https://zeebe.camunda.dev.local:443
    rest-address: https://orchestration.camunda.dev.local
    prefer-rest-over-grpc: false
    auth:
      token-url: https://keycloak.camunda.dev.local/auth/realms/camunda-platform/protocol/openid-connect/token
      audience: orchestration-api
    worker:
      defaults:
        enabled: true
        stream-enabled: false
```

### Token URL vs issuer URL

For this client configuration, use the token endpoint:

```text
https://keycloak.camunda.dev.local/auth/realms/camunda-platform/protocol/openid-connect/token
```

Do not use only the realm issuer URL in `token-url`.

### Remote server setup

When the worker runs on another server, `host-gateway` points to the worker server, not the Camunda server. Use the Camunda server IP instead:

```env
CAMUNDA_HOST_GATEWAY=192.168.1.50
```

Also ensure that TCP port `443` is reachable from the worker server to the Camunda server.
