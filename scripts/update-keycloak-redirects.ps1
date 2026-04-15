# Update Keycloak client redirect URIs for reverse proxy
# Run with: pwsh -File scripts/update-keycloak-redirects.ps1

param(
    [string]$KeycloakHost = "keycloak.localhost",
    [string]$KeycloakPort = "443",
    [string]$Realm = "camunda-platform",
    [string]$AdminUser = "admin",
    [string]$AdminPassword = "admin",
    [string]$ClientId = "camunda-identity",
    [string[]]$AdditionalRedirectUris = @(
        "https://identity.localhost/auth/login-callback",
        "https://console.localhost/auth/login-callback",
        "https://optimize.localhost/api/authentication/callback",
        "https://orchestration.localhost/sso-callback"
    )
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

Write-Host "Getting admin token from Keycloak..."
$tokenResponse = Invoke-RestMethod -Uri $tokenUrl -Method Post -ContentType "application/x-www-form-urlencoded" -Body $tokenBody -SkipCertificateCheck
$accessToken = $tokenResponse.access_token

# Get client by clientId
$clientsUrl = "https://$KeycloakHost/auth/admin/realms/$Realm/clients?clientId=$ClientId"
$headers = @{
    Authorization = "Bearer $accessToken"
}

Write-Host "Finding client '$ClientId'..."
$clients = Invoke-RestMethod -Uri $clientsUrl -Method Get -Headers $headers -SkipCertificateCheck

if ($clients.Count -eq 0) {
    Write-Error "Client '$ClientId' not found"
    exit 1
}

$client = $clients[0]
Write-Host "Found client with id: $($client.id)"

# Get current client details
$clientUrl = "https://$KeycloakHost/auth/admin/realms/$Realm/clients/$($client.id)"
$currentClient = Invoke-RestMethod -Uri $clientUrl -Method Get -Headers $headers -SkipCertificateCheck

# Add new redirect URIs
$currentRedirectUris = $currentClient.redirectUris
$baseRedirectUris = @(
    "/auth/login-callback",
    "/sso-callback",
    "/api/authentication/callback"
)

$newRedirectUris = $currentRedirectUris + $baseRedirectUris + $AdditionalRedirectUris | Select-Object -Unique

Write-Host "Current redirect URIs:"
$currentClient.redirectUris | ForEach-Object { Write-Host "  $_" }

Write-Host "`nNew redirect URIs:"
$newRedirectUris | ForEach-Object { Write-Host "  $_" }

# Update client
$updatedClient = $currentClient | Select-Object -Property * -ExcludeProperty rootUrl
$updatedClient.redirectUris = $newRedirectUris

Write-Host "`nUpdating client..."
Invoke-RestMethod -Uri $clientUrl -Method Put -Headers $headers -ContentType "application/json" -Body ($updatedClient | ConvertTo-Json -Depth 10) -SkipCertificateCheck

Write-Host "`nClient updated successfully!"
