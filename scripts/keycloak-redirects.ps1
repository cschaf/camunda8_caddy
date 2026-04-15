<#
.SYNOPSIS
    Manages Keycloak client redirect URIs for the Camunda Compose reverse proxy.

.DESCRIPTION
    This script updates the redirect URIs stored in Keycloak for each OIDC client.
    Redirect URIs tell Keycloak where to send the browser after a successful login.

    Keycloak caches redirect URIs strictly — if a browser gets redirected to a URI
    that is not in the client's allowed list, you get "Invalid redirect_uri" and the
    login fails.

    The script operates in two modes:

    -Merge (default): Adds the HTTPS proxy URLs to whatever redirect URIs already
     exist. Use this when you have been using direct localhost URLs and are now
     adding the reverse proxy. Safe to re-run; it never removes existing URIs.

    -Fix: Replaces all redirect URIs with a clean, known-good set covering both
     direct localhost access AND the proxy. Use this when the redirect URIs have
     been corrupted (e.g., too many duplicates, old staging URLs, entries from
     broken experiments) and you want a known baseline. This is the nuclear option.

.NOTES
    Prerequisites:
    - Keycloak must be running and accessible at keycloak.localhost (or via the
      configured $KeycloakHost). This means either your hosts file must resolve
      keycloak.localhost, or you are running on the same machine as the reverse proxy.
    - Admin credentials default to admin/admin (configure via -AdminUser / -AdminPassword).

.EXAMPLE
    # Add proxy URLs to existing redirect URIs (safe, additive)
    pwsh -File scripts/keycloak-redirects.ps1

.EXAMPLE
    # Same as above, explicit mode
    pwsh -File scripts/keycloak-redirects.ps1 -Mode Merge

.EXAMPLE
    # Reset all redirect URIs to the known-good set
    pwsh -File scripts/keycloak-redirects.ps1 -Mode Fix

.EXAMPLE
    # Run against a different Keycloak host (e.g., staging)
    pwsh -File scripts/keycloak-redirects.ps1 -KeycloakHost keycloak.staging.example.com
#>

param(
    [ValidateSet("Merge", "Fix")]
    [string]$Mode = "Merge",

    [string]$KeycloakHost = "keycloak.localhost",
    [string]$Realm = "camunda-platform",
    [string]$AdminUser = "admin",
    [string]$AdminPassword = "admin"
)

$ErrorActionPreference = "Stop"

# ---------------------------------------------------------------------------
# Redirect URI sets
# ---------------------------------------------------------------------------

# HTTPS URLs served by the Caddy reverse proxy (both modes use these)
$proxyUris = @{
    "camunda-identity" = @("https://identity.localhost/auth/login-callback")
    "console"          = @("https://console.localhost/")
    "orchestration"    = @("https://orchestration.localhost/sso-callback")
    "optimize"         = @("https://optimize.localhost/api/authentication/callback")
    "web-modeler"      = @("https://webmodeler.localhost/login-callback")
}

# Direct localhost URLs (only added in Fix mode as a fallback for direct access)
$localhostUris = @{
    "camunda-identity" = @("http://localhost:8084/auth/login-callback")
    "orchestration"    = @("http://localhost:8088/sso-callback")
    "console"          = @("http://localhost:8087/")
    "optimize"         = @("http://localhost:8083/api/authentication/callback")
    "web-modeler"      = @("http://localhost:8070/login-callback")
}

# Clients that have redirect URIs managed by this script
$allClients = @("camunda-identity", "orchestration", "console", "optimize", "web-modeler")

# connectors has no browser-facing redirect URIs — set to empty in Fix mode
$noRedirectClients = @("connectors")

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
        [hashtable]$Headers,
        [bool]$Merge
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

    if ($Merge) {
        # Union of existing URIs and new proxy URIs (no duplicates)
        $finalUris = $currentClient.redirectUris + $NewUris | Select-Object -Unique
    } else {
        # Replace with the target set
        $finalUris = $NewUris
    }

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

if ($Mode -eq "Fix") {
    Write-Host "Running in Fix mode - replacing all redirect URIs with known-good set`n"
    Write-Host "This will set BOTH localhost URLs (for direct access) AND proxy URLs.`n"
    $clientsToProcess = $allClients + $noRedirectClients

    foreach ($clientId in $clientsToProcess) {
        Write-Host "Fixing client: $clientId..."
        $uris = if ($localhostUris.ContainsKey($clientId)) {
            # Combine localhost + proxy URLs (both are valid targets)
            $localhostUris[$clientId] + $proxyUris[$clientId]
        } elseif ($noRedirectClients -contains $clientId) {
            # connectors: no browser-facing redirect
            @()
        } else {
            # Should not hit for current clients, but fallback to proxy only
            $proxyUris[$clientId]
        }
        Update-ClientRedirectUris -ClientId $clientId -NewUris $uris -Headers $headers -Merge $false
    }
} else {
    Write-Host "Running in Merge mode - adding proxy URLs to existing redirect URIs`n"
    Write-Host "Existing URIs are preserved; only proxy URLs are added.`n"

    foreach ($clientId in $allClients) {
        Write-Host "Updating client: $clientId..."
        Update-ClientRedirectUris -ClientId $clientId -NewUris $proxyUris[$clientId] -Headers $headers -Merge $true
    }
}

Write-Host "`nDone!"
