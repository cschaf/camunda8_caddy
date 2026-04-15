<#
.SYNOPSIS
    Configures Keycloak OIDC client redirect URIs for the Caddy reverse proxy.

.DESCRIPTION
    After a fresh `docker compose up`, Keycloak is initialized with redirect URIs
    pointing to localhost (e.g. http://localhost:8088). This script replaces those
    with the correct HTTPS proxy URLs so that all services work when accessed via
    https://*.localhost behind Caddy.

    Keycloak caches redirect URIs strictly — if a browser gets redirected to a URI
    that is not in the client's allowed list, you get "Invalid redirect_uri" and the
    login fails.

    Run this ONCE after the first `docker compose up` of a fresh environment.
    It is safe to re-run.

    Prerequisites:
    - Caddy reverse proxy must be running so keycloak.localhost resolves
    - Admin credentials default to admin/admin

.EXAMPLE
    pwsh -File scripts/keycloak-redirects.ps1

.EXAMPLE
    # Run against a different Keycloak host
    pwsh -File scripts/keycloak-redirects.ps1 -KeycloakHost keycloak.staging.example.com
#>

param(
    [string]$KeycloakHost = "keycloak.localhost",
    [string]$Realm = "camunda-platform",
    [string]$AdminUser = "admin",
    [string]$AdminPassword = "admin"
)

$ErrorActionPreference = "Stop"

# Read HOST from .env (relative to script location)
$envFile = Join-Path $PSScriptRoot "..\.env"
if (Test-Path $envFile) {
    $envContent = Get-Content $envFile | Where-Object { $_ -notmatch '^\s*#' }
    foreach ($line in $envContent) {
        if ($line -match '^HOST=(.*)') { $ProxyDomain = $matches[1].Trim() }
    }
}
$LocalHost = $ProxyDomain  # direct-access URL uses same host value

# Per-service port mapping: "client-id" = port for direct localhost access
$localPorts = @{
    "camunda-identity" = 8084
    "console"         = 8087
    "orchestration"   = 8088
    "optimize"        = 8083
    "web-modeler"     = 8070
}

# Per-service subdomain prefix for proxy URLs (appended to $ProxyDomain)
$proxySubdomains = @{
    "camunda-identity" = "identity"
    "console"         = "console"
    "orchestration"   = "orchestration"
    "optimize"        = "optimize"
    "web-modeler"     = "webmodeler"
}

# Per-service callback path after the base URL
$callbackPaths = @{
    "camunda-identity" = "/auth/login-callback"
    "console"         = "/"
    "orchestration"   = "/sso-callback"
    "optimize"        = "/api/authentication/callback"
    "web-modeler"     = "/login-callback"
}

$allClients = $localPorts.Keys

# ---------------------------------------------------------------------------
# Helper functions
# ---------------------------------------------------------------------------

function Get-AdminToken {
    $tokenUrl = "https://$KeycloakHost/auth/realms/master/protocol/openid-connect/token"
    $tokenBody = @{
        grant_type = "password"
        username   = $AdminUser
        password   = $AdminPassword
        client_id  = "admin-cli"
    }

    Write-Host "Getting admin token from Keycloak..."
    $tokenResponse = Invoke-RestMethod -Uri $tokenUrl -Method Post -ContentType "application/x-www-form-urlencoded" -Body $tokenBody -SkipCertificateCheck
    return $tokenResponse.access_token
}

function Update-ClientRedirectUris {
    param(
        [string]$ClientId,
        [string[]]$NewUris,
        [hashtable]$Headers
    )

    $clientsUrl = "https://$KeycloakHost/auth/admin/realms/$Realm/clients?clientId=$ClientId"
    $clients = Invoke-RestMethod -Uri $clientsUrl -Method Get -Headers $Headers -SkipCertificateCheck

    if ($clients.Count -eq 0) {
        Write-Host "  Client '$ClientId' not found, skipping..."
        return
    }

    $client = $clients[0]
    Write-Host "  Found client with id: $($client.id)"

    $clientUrl = "https://$KeycloakHost/auth/admin/realms/$Realm/clients/$($client.id)"
    $currentClient = Invoke-RestMethod -Uri $clientUrl -Method Get -Headers $Headers -SkipCertificateCheck

    # Union of existing URIs and new proxy URIs (no duplicates)
    $finalUris = $currentClient.redirectUris + $NewUris | Select-Object -Unique

    Write-Host "  Current redirect URIs:"
    $currentClient.redirectUris | ForEach-Object { Write-Host "    $_" }

    Write-Host "  New redirect URIs:"
    $finalUris | ForEach-Object { Write-Host "    $_" }

    # Exclude rootUrl to avoid "Resource does not allow updating" errors
    $updatedClient = $currentClient | Select-Object -Property * -ExcludeProperty rootUrl
    $updatedClient.redirectUris = $finalUris

    Invoke-RestMethod -Uri $clientUrl -Method Put -Headers $Headers -ContentType "application/json" -Body ($updatedClient | ConvertTo-Json -Depth 10) -SkipCertificateCheck
    Write-Host "  Updated!"
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

$accessToken = Get-AdminToken
$headers = @{ Authorization = "Bearer $accessToken" }

Write-Host "Configuring Caddy proxy redirect URIs for Keycloak clients`n"

foreach ($clientId in $allClients) {
    Write-Host "Updating client: $clientId..."

    $port = $localPorts[$clientId]
    $subdomain = $proxySubdomains[$clientId]
    $callbackPath = $callbackPaths[$clientId]

    $localhostUri = "http://${LocalHost}:${port}${callbackPath}"
    $proxyUri = "https://${subdomain}.${ProxyDomain}${callbackPath}"
    $newUris = @($localhostUri, $proxyUri)

    Update-ClientRedirectUris -ClientId $clientId -NewUris $newUris -Headers $headers
}

Write-Host "`nDone!"
