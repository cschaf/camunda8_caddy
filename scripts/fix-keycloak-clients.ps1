# Fix Keycloak client redirect URIs - clears bad URIs and sets correct ones
# Run with: pwsh -File scripts/fix-keycloak-clients.ps1

param(
    [string]$KeycloakHost = "keycloak.localhost",
    [string]$Realm = "camunda-platform",
    [string]$AdminUser = "admin",
    [string]$AdminPassword = "admin"
)

$ErrorActionPreference = "Stop"

# Get admin token
$tokenUrl = "https://$KeycloakHost/auth/realms/master/protocol/openid-connect/token"
$tokenBody = @{
    grant_type = "password"
    username = $AdminUser
    password = $AdminPassword
    client_id = "admin-cli"
}

Write-Host "Getting admin token..."
$tokenResponse = Invoke-RestMethod -Uri $tokenUrl -Method Post -ContentType "application/x-www-form-urlencoded" -Body $tokenBody -SkipCertificateCheck
$accessToken = $tokenResponse.access_token
$headers = @{ Authorization = "Bearer $accessToken" }

# Clients to fix
$clientsToFix = @(
    "camunda-identity",
    "orchestration",
    "console",
    "optimize",
    "connectors",
    "web-modeler"
)

# Correct redirect URIs for each client
$correctUris = @{
    "camunda-identity" = @(
        "https://identity.localhost/auth/login-callback",
        "http://localhost:8084/auth/login-callback"
    )
    "orchestration" = @(
        "https://orchestration.localhost/sso-callback",
        "http://localhost:8088/sso-callback"
    )
    "console" = @(
        "https://console.localhost/",
        "http://localhost:8087/"
    )
    "optimize" = @(
        "https://optimize.localhost/api/authentication/callback",
        "http://localhost:8083/api/authentication/callback"
    )
    "connectors" = @()
    "web-modeler" = @(
        "https://webmodeler.localhost/login-callback",
        "http://localhost:8070/login-callback"
    )
}

foreach ($clientId in $clientsToFix) {
    Write-Host "`nFixing client: $clientId..."

    $clientsUrl = "https://$KeycloakHost/auth/admin/realms/$Realm/clients?clientId=$clientId"
    $clients = Invoke-RestMethod -Uri $clientsUrl -Method Get -Headers $headers -SkipCertificateCheck

    if ($clients.Count -eq 0) {
        Write-Host "  Client not found, skipping..."
        continue
    }

    $client = $clients[0]
    $clientUrl = "https://$KeycloakHost/auth/admin/realms/$Realm/clients/$($client.id)"

    # Get current client
    $currentClient = Invoke-RestMethod -Uri $clientUrl -Method Get -Headers $headers -SkipCertificateCheck

    Write-Host "  Current redirect URIs:"
    $currentClient.redirectUris | ForEach-Object { Write-Host "    $_" }

    # Set clean redirect URIs
    $uris = $correctUris[$clientId]
    $currentClient.redirectUris = $uris

    Write-Host "  New redirect URIs:"
    $uris | ForEach-Object { Write-Host "    $_" }

    # Update
    Invoke-RestMethod -Uri $clientUrl -Method Put -Headers $headers -ContentType "application/json" -Body ($currentClient | ConvertTo-Json -Depth 10) -SkipCertificateCheck
    Write-Host "  Updated!"
}

Write-Host "`nDone!"
