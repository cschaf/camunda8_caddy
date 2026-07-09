<#
.SYNOPSIS
    Creates a Camunda user in Keycloak with role-based permissions.

.DESCRIPTION
    Creates a user via the Keycloak Admin REST API and assigns Camunda-specific
    realm roles based on the specified role level.

    Credentials are read from .env (non-credential configuration) and
    .env-credentials (all secrets) in the project root.

.EXAMPLE
    pwsh -File scripts/add-camunda-user.ps1 -Username jdoe -Password "changeme" -Email "jdoe@example.com" -FirstName "John" -LastName "Doe" -Role NormalUser

.EXAMPLE
    pwsh -File scripts/add-camunda-user.ps1 -Username admin -Password "adminpass" -Email "admin@example.com" -FirstName "Admin" -LastName "User" -Role Admin

.NOTES
    By default the initial password is marked temporary, forcing the user to set
    a new password at first login. Pass -PermanentPassword to skip this
    (e.g. for service accounts).
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
    [string]$Role,

    [Parameter(Mandatory = $false)]
    [switch]$PermanentPassword
)

$ErrorActionPreference = "Stop"

# ---------------------------------------------------------------------------
# Helper: Read a key from .env (and .env-credentials, if present).
# Scans .env first, then .env-credentials — credentials live in
# .env-credentials, but HOST stays in .env. The order keeps any accidental
# overlap predictable (later wins, mirroring the other scripts).
# ---------------------------------------------------------------------------
function Get-EnvValue {
    param([string]$Key)
    $projectRoot = Resolve-Path (Join-Path $PSScriptRoot '..')
    $envFile         = Join-Path $projectRoot '.env'
    $credentialsFile = Join-Path $projectRoot '.env-credentials'

    if (-not (Test-Path $envFile) -and -not (Test-Path $credentialsFile)) {
        throw ".env (or .env-credentials) not found in $projectRoot"
    }

    foreach ($file in @($envFile, $credentialsFile)) {
        if (-not (Test-Path $file)) { continue }
        foreach ($line in Get-Content $file) {
            if ($line -match '^\s*#') { continue }
            if ($line -match "^${Key}=(.*)$") {
                return $matches[1].Trim()
            }
        }
    }
    throw "Key '$Key' not found in .env or .env-credentials"
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
        [string]$LastName,
        [bool]$Temporary
    )

    # Check if user already exists
    $existingUsers = Invoke-RestMethod -Uri "https://${BaseUrl}/auth/admin/realms/${Realm}/users?username=${Username}" -Method Get -Headers $Headers -SkipCertificateCheck
    if ($existingUsers.Count -gt 0) {
        throw "User '$Username' already exists (ID: $($existingUsers[0].id). Use Keycloak UI to delete first, or choose a different username."
    }

    $url = "https://${BaseUrl}/auth/admin/realms/${Realm}/users"
    $userRep = @{
        username  = $Username
        enabled   = $true
        email     = $Email
        firstName = $FirstName
        lastName  = $LastName
        credentials = @(@{
            type      = "password"
            value     = $Password
            temporary = $Temporary
        })
    }
    # The credential's "temporary" flag alone does not reliably force a password
    # change when the user is created inline via POST /users. Setting the
    # UPDATE_PASSWORD required action is what Keycloak actually evaluates at
    # login, so add it explicitly when a temporary password is requested.
    if ($Temporary) {
        $userRep["requiredActions"] = @("UPDATE_PASSWORD")
    }
    $body = $userRep | ConvertTo-Json -Depth 10

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
# Role mappings — specify exact role names from Keycloak
# ---------------------------------------------------------------------------
$roleMap = @{
    NormalUser = @("Default user role", "Orchestration", "Optimize", "Web Modeler")
    Admin      = @("Web Modeler", "ManagementIdentity", "Default user role", "Orchestration", "Optimize", "Web Modeler Admin", "Console")
}

# Camunda internal role mapping (camunda.security.authorizations.enabled=true requires explicit role assignment)
$camundaRoleMap = @{
    NormalUser = "readonly-admin"
    Admin      = "admin"
}

# ---------------------------------------------------------------------------
# Helper: Get orchestration client credentials token
# ---------------------------------------------------------------------------
function Get-OrchestrationToken {
    param([string]$KeycloakHost, [string]$ClientSecret)

    $tokenUrl = "https://${KeycloakHost}/auth/realms/camunda-platform/protocol/openid-connect/token"
    $tokenBody = @{
        grant_type    = "client_credentials"
        client_id     = "orchestration"
        client_secret = $ClientSecret
    }

    try {
        $response = Invoke-RestMethod -Uri $tokenUrl -Method Post -ContentType "application/x-www-form-urlencoded" -Body $tokenBody -SkipCertificateCheck
        return $response.access_token
    }
    catch {
        throw "Failed to get orchestration token: $_"
    }
}

# ---------------------------------------------------------------------------
# Helper: Assign user to Camunda internal role
# ---------------------------------------------------------------------------
function Add-CamundaRoleMember {
    param([string]$OrchestrationHost, [string]$Token, [string]$CamundaRole, [string]$Username)

    $url = "https://${OrchestrationHost}/v2/roles/${CamundaRole}/users/${Username}"
    try {
        Invoke-RestMethod -Uri $url -Method Put -Headers @{ Authorization = "Bearer $Token" } -SkipCertificateCheck -ErrorAction Stop | Out-Null
        Write-Host "  Assigned Camunda role: $CamundaRole"
    }
    catch {
        throw "Failed to assign Camunda role '$CamundaRole' to user '$Username': $_"
    }
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
$Realm = "camunda-platform"

# Read credentials from .env
$AdminUser = Get-EnvValue -Key "KEYCLOAK_ADMIN_USER"
$AdminPassword = Get-EnvValue -Key "KEYCLOAK_ADMIN_PASSWORD"
$CamundaHost = Get-EnvValue -Key "HOST"
$OrchestrationSecret = Get-EnvValue -Key "ORCHESTRATION_CLIENT_SECRET"
$KeycloakHost = "keycloak.${CamundaHost}"
$OrchestrationHost = "orchestration.${CamundaHost}"

$headers = @{ Authorization = "Bearer (placeholder)" }

Write-Host "Creating user '$Username' with role '$Role'..."

# Get token
$token = Get-AdminToken -KeycloakHost $KeycloakHost -AdminUser $AdminUser -AdminPassword $AdminPassword
$headers["Authorization"] = "Bearer $token"

# Create user
$temporaryPassword = -not $PermanentPassword
New-CamundaUser -BaseUrl $KeycloakHost -Headers $headers -Realm $Realm -Username $Username -Password $Password -Email $Email -FirstName $FirstName -LastName $LastName -Temporary $temporaryPassword
if ($temporaryPassword) {
    Write-Host "Password marked temporary - user must set a new password at first login"
}

# Find the created user (Keycloak may not return ID directly)
Start-Sleep -Milliseconds 500
$userId = Get-UserId -BaseUrl $KeycloakHost -Headers $headers -Realm $Realm -Username $Username
Write-Host "User created with ID: $userId"

# Assign Keycloak realm roles one at a time
$roleNames = $roleMap[$Role]
foreach ($roleName in $roleNames) {
    try {
        # Fetch role details to get the actual role object with its ID
        $roleUrl = "https://${KeycloakHost}/auth/admin/realms/${Realm}/roles/${roleName}"
        $roleResp = Invoke-RestMethod -Uri $roleUrl -Method Get -Headers $headers -SkipCertificateCheck -ErrorAction Stop
        # Build a clean role object from the response
        $roleBody = @{
            id          = "$($roleResp.id)"
            name        = "$($roleResp.name)"
            description = if ($roleResp.description) { "$($roleResp.description)" } else { "" }
            composite   = $roleResp.composite
            clientRole  = $roleResp.clientRole
            containerId = "$($roleResp.containerId)"
        } | ConvertTo-Json -Compress
        $assignUrl = "https://${KeycloakHost}/auth/admin/realms/${Realm}/users/${userId}/role-mappings/realm"
        Invoke-RestMethod -Uri $assignUrl -Method Post -Headers $headers -ContentType "application/json" -Body "[$roleBody]" -SkipCertificateCheck -ErrorAction Stop | Out-Null
        Write-Host "  Assigned Keycloak role: $roleName"
    }
    catch {
        Write-Host "  Failed to assign role: $roleName"
        Remove-CamundaUser -BaseUrl $KeycloakHost -Headers $headers -Realm $Realm -UserId $userId
        throw "Role assignment failed and user rolled back: $_"
    }
}

# Assign Camunda internal role (required because camunda.security.authorizations.enabled=true)
Write-Host "Assigning Camunda internal authorization role..."
$orchToken = Get-OrchestrationToken -KeycloakHost $KeycloakHost -ClientSecret $OrchestrationSecret
$camundaRole = $camundaRoleMap[$Role]
try {
    Add-CamundaRoleMember -OrchestrationHost $OrchestrationHost -Token $orchToken -CamundaRole $camundaRole -Username $Username
}
catch {
    Write-Host "  WARNING: Failed to assign Camunda internal role '$camundaRole': $_"
    Write-Host "  User was created in Keycloak but may not be able to access Operate/Tasklist."
    Write-Host "  To fix manually: add '$Username' to initialization.defaultRoles.$($Role.ToLower()).users in .orchestration/application.yaml and restart the orchestration container."
}

Write-Host "`nDone! User '$Username' created with role '$Role'."
