<#
.SYNOPSIS
    Creates a Camunda user in Keycloak with role-based permissions.

.DESCRIPTION
    Creates a user via the Keycloak Admin REST API and assigns Camunda-specific
    realm roles based on the specified role level.

    Credentials are read from .env in the project root.

.EXAMPLE
    pwsh -File scripts/add-camunda-user.ps1 -Username jdoe -Password "changeme" -Email "jdoe@example.com" -FirstName "John" -LastName "Doe" -Role NormalUser

.EXAMPLE
    pwsh -File scripts/add-camunda-user.ps1 -Username admin -Password "adminpass" -Email "admin@example.com" -FirstName "Admin" -LastName "User" -Role Admin
#>

param(
    [Parameter(Mandatory = $true)]
    [string]$Username,

    [Parameter(Mandatory = $true)]
    [string]$Password,

    [Parameter(Mandatory = $true)]
    [string]$Email,

    [Parameter(Mandatory = $true)]
    [string]$FirstName,

    [Parameter(Mandatory = $true)]
    [string]$LastName,

    [Parameter(Mandatory = $true)]
    [ValidateSet("NormalUser", "Admin")]
    [string]$Role
)

$ErrorActionPreference = "Stop"

# ---------------------------------------------------------------------------
# Helper: Read .env
# ---------------------------------------------------------------------------
function Get-EnvValue {
    param([string]$Key)
    $envFile = Join-Path $PSScriptRoot "..\.env"
    if (-not (Test-Path $envFile)) {
        throw ".env file not found at $envFile"
    }
    $content = Get-Content $envFile | Where-Object { $_ -notmatch '^\s*#' }
    foreach ($line in $content) {
        if ($line -match "^${Key}=(.*)") {
            return $matches[1].Trim()
        }
    }
    throw "Key '$Key' not found in .env"
}

# ---------------------------------------------------------------------------
# Helper: Get admin access token
# ---------------------------------------------------------------------------
function Get-AdminToken {
    param([string]$KeycloakHost, [string]$AdminUser, [string]$AdminPassword)

    $tokenUrl = "https://${KeycloakHost}/auth/realms/master/protocol/openid-connect/token"
    $tokenBody = @{
        grant_type = "password"
        username   = $AdminUser
        password   = $AdminPassword
        client_id  = "admin-cli"
    }

    Write-Host "Getting admin token from Keycloak..."
    try {
        $response = Invoke-RestMethod -Uri $tokenUrl -Method Post -ContentType "application/x-www-form-urlencoded" -Body $tokenBody -SkipCertificateCheck
        return $response.access_token
    }
    catch {
        throw "Failed to get admin token: $_"
    }
}

# ---------------------------------------------------------------------------
# Helper: Create user
# ---------------------------------------------------------------------------
function New-CamundaUser {
    param(
        [string]$BaseUrl,
        [hashtable]$Headers,
        [string]$Realm,
        [string]$Username,
        [string]$Password,
        [string]$Email,
        [string]$FirstName,
        [string]$LastName
    )

    # Check if user already exists
    $existingUsers = Invoke-RestMethod -Uri "https://${BaseUrl}/auth/admin/realms/${Realm}/users?username=${Username}" -Method Get -Headers $Headers -SkipCertificateCheck
    if ($existingUsers.Count -gt 0) {
        throw "User '$Username' already exists (ID: $($existingUsers[0].id). Use Keycloak UI to delete first, or choose a different username."
    }

    $url = "https://${BaseUrl}/auth/admin/realms/${Realm}/users"
    $body = @{
        username  = $Username
        enabled   = $true
        email     = $Email
        firstName = $FirstName
        lastName  = $LastName
        credentials = @(@{
            type      = "password"
            value     = $Password
            temporary = $false
        })
    } | ConvertTo-Json -Depth 10

    try {
        $response = Invoke-RestMethod -Uri $url -Method Post -Headers $Headers -ContentType "application/json" -Body $body -SkipCertificateCheck
        return $true
    }
    catch {
        if ($_.Exception.Response.StatusCode -eq 409) {
            throw "User '$Username' already exists. Use Keycloak UI to delete first, or choose a different username."
        }
        throw "Failed to create user: $_"
    }
}

# ---------------------------------------------------------------------------
# Helper: Find user by username
# ---------------------------------------------------------------------------
function Get-UserId {
    param([string]$BaseUrl, [hashtable]$Headers, [string]$Realm, [string]$Username)

    $url = "https://${BaseUrl}/auth/admin/realms/${Realm}/users?username=${Username}"
    $users = Invoke-RestMethod -Uri $url -Method Get -Headers $Headers -SkipCertificateCheck
    if ($users.Count -eq 0) {
        throw "User '$Username' not found"
    }
    return $users[0].id
}

# ---------------------------------------------------------------------------
# Helper: Delete user
# ---------------------------------------------------------------------------
function Remove-CamundaUser {
    param([string]$BaseUrl, [hashtable]$Headers, [string]$Realm, [string]$UserId)

    $url = "https://${BaseUrl}/auth/admin/realms/${Realm}/users/${UserId}"
    Invoke-RestMethod -Uri $url -Method Delete -Headers $Headers -SkipCertificateCheck
}

# ---------------------------------------------------------------------------
# Helper: Get role by name
# ---------------------------------------------------------------------------
function Get-RealmRole {
    param([string]$BaseUrl, [hashtable]$Headers, [string]$Realm, [string]$RoleName)

    $url = "https://${BaseUrl}/auth/admin/realms/${Realm}/roles/${RoleName}"
    try {
        $response = Invoke-RestMethod -Uri $url -Method Get -Headers $Headers -SkipCertificateCheck -ErrorAction Stop
        # Return only the fields Keycloak needs as a plain hashtable
        return @{
            id          = "$($response.id)"
            name        = "$($response.name)"
            description = "$($response.description)"
            composite   = ($response.composite -eq $true)
            clientRole  = ($response.clientRole -eq $true)
            containerId = "$($response.containerId)"
        }
    }
    catch {
        throw "Role '$RoleName' not found in Keycloak: $_"
    }
}

# ---------------------------------------------------------------------------
# Helper: Assign roles to user
# ---------------------------------------------------------------------------
function Add-UserRoleMappings {
    param(
        [string]$BaseUrl,
        [hashtable]$Headers,
        [string]$Realm,
        [string]$UserId,
        [object]$Role
    )

    $url = "https://${BaseUrl}/auth/admin/realms/${Realm}/users/${UserId}/role-mappings/realm"
    $body = @($Role) | ConvertTo-Json -Depth 10
    Invoke-RestMethod -Uri $url -Method Post -Headers $Headers -ContentType "application/json" -Body $body -SkipCertificateCheck -ErrorAction Stop
}

# ---------------------------------------------------------------------------
# Role mappings
# ---------------------------------------------------------------------------
$roleMap = @{
    NormalUser = @("Orchestration", "Optimize", "Web Modeler", "Console")
    Admin      = @("ManagementIdentity", "Orchestration", "Optimize", "Web Modeler", "Web Modeler Admin", "Console")
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
$Realm = "camunda-platform"

# Read credentials from .env
$AdminUser = Get-EnvValue -Key "KEYCLOAK_ADMIN_USER"
$AdminPassword = Get-EnvValue -Key "KEYCLOAK_ADMIN_PASSWORD"
$CamundaHost = Get-EnvValue -Key "HOST"
$KeycloakHost = "keycloak.${CamundaHost}"

$headers = @{ Authorization = "Bearer (placeholder)" }

Write-Host "Creating user '$Username' with role '$Role'..."

# Get token
$token = Get-AdminToken -KeycloakHost $KeycloakHost -AdminUser $AdminUser -AdminPassword $AdminPassword
$headers["Authorization"] = "Bearer $token"

# Create user
New-CamundaUser -BaseUrl $KeycloakHost -Headers $headers -Realm $Realm -Username $Username -Password $Password -Email $Email -FirstName $FirstName -LastName $LastName

# Find the created user (Keycloak may not return ID directly)
Start-Sleep -Milliseconds 500
$userId = Get-UserId -BaseUrl $KeycloakHost -Headers $headers -Realm $Realm -Username $Username
Write-Host "User created with ID: $userId"

# Assign roles one at a time
$roleNames = $roleMap[$Role]
foreach ($roleName in $roleNames) {
    $role = Get-RealmRole -BaseUrl $KeycloakHost -Headers $headers -Realm $Realm -RoleName $roleName
    try {
        $url = "https://${KeycloakHost}/auth/admin/realms/${Realm}/users/${userId}/role-mappings/realm"
        $body = @(@{
            id          = $role.id
            name        = $role.name
            description = $role.description
            composite   = $role.composite
            clientRole  = $role.clientRole
            containerId = $role.containerId
        }) | ConvertTo-Json -Depth 10
        Invoke-RestMethod -Uri $url -Method Post -Headers $headers -ContentType "application/json" -Body $body -SkipCertificateCheck -ErrorAction Stop
        Write-Host "  Assigned role: $roleName"
    }
    catch {
        Write-Host "  Failed to assign role: $roleName"
        Remove-CamundaUser -BaseUrl $KeycloakHost -Headers $headers -Realm $Realm -UserId $userId
        throw "Role assignment failed and user rolled back: $_"
    }
}

Write-Host "`nDone! User '$Username' created with role '$Role'."
