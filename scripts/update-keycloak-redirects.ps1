# Update Keycloak client redirect URIs for reverse proxy
# Run with: pwsh -File scripts/update-keycloak-redirects.ps1

param(
    [string]$KeycloakHost = "keycloak.localhost",
    [string]$KeycloakPort = "443",
    [string]$Realm = "camunda-platform",
    [string]$AdminUser = "admin",
    [string]$AdminPassword = "admin"
)

$ErrorActionPreference = "Stop"

# Map of clientId -> redirect URIs to add (merged with existing, not replaced)
$additionalUrisByClient = @{
    "camunda-identity" = @(
        "https://identity.localhost/auth/login-callback"
    )
    "console" = @(
        "https://console.localhost/"
    )
    "orchestration" = @(
        "https://orchestration.localhost/sso-callback"
    )
    "optimize" = @(
        "https://optimize.localhost/api/authentication/callback"
    )
    "web-modeler" = @(
        "https://webmodeler.localhost/login-callback"
    )
}

# Get admin token
$tokenUrl = "https://$KeycloakHost/auth/realms/master/protocol/openid-connect/token"
$tokenBody = @{
    grant_type = "password"
    username   = $AdminUser
    password   = $AdminPassword
    client_id  = "admin-cli"
}

Write-Host "Getting admin token from Keycloak..."
$tokenResponse = Invoke-RestMethod -Uri $tokenUrl -Method Post -ContentType "application/x-www-form-urlencoded" -Body $tokenBody -SkipCertificateCheck
$accessToken = $tokenResponse.access_token
$headers = @{ Authorization = "Bearer $accessToken" }

foreach ($clientId in $additionalUrisByClient.Keys) {
    Write-Host "`nUpdating client: $clientId..."

    $clientsUrl = "https://$KeycloakHost/auth/admin/realms/$Realm/clients?clientId=$clientId"
    $clients = Invoke-RestMethod -Uri $clientsUrl -Method Get -Headers $headers -SkipCertificateCheck

    if ($clients.Count -eq 0) {
        Write-Host "  Client '$clientId' not found, skipping..."
        continue
    }

    $client = $clients[0]
    Write-Host "  Found client with id: $($client.id)"

    $clientUrl = "https://$KeycloakHost/auth/admin/realms/$Realm/clients/$($client.id)"
    $currentClient = Invoke-RestMethod -Uri $clientUrl -Method Get -Headers $headers -SkipCertificateCheck

    $newUris = $currentClient.redirectUris + $additionalUrisByClient[$clientId] | Select-Object -Unique

    Write-Host "  Current redirect URIs:"
    $currentClient.redirectUris | ForEach-Object { Write-Host "    $_" }

    Write-Host "  New redirect URIs:"
    $newUris | ForEach-Object { Write-Host "    $_" }

    $updatedClient = $currentClient | Select-Object -Property * -ExcludeProperty rootUrl
    $updatedClient.redirectUris = $newUris

    Invoke-RestMethod -Uri $clientUrl -Method Put -Headers $headers -ContentType "application/json" -Body ($updatedClient | ConvertTo-Json -Depth 10) -SkipCertificateCheck
    Write-Host "  Updated!"
}

Write-Host "`nDone!"
