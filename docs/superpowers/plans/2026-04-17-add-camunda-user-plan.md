# Add Camunda User PowerShell Script — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** PowerShell script that creates Camunda users via Keycloak Admin REST API with role-based permissions.

**Architecture:** Single script file that reads credentials from `.env`, authenticates to Keycloak Admin API, creates a user, and assigns Camunda-specific realm roles based on the requested role (`NormalUser` or `Admin`).

**Tech Stack:** PowerShell 5+, Keycloak Admin REST API, `.env` file parsing

---

## File Structure

- Create: `scripts/add-camunda-user.ps1`

---

## Tasks

### Task 1: Write the `add-camunda-user.ps1` script

**Files:**
- Create: `scripts/add-camunda-user.ps1`

- [ ] **Step 1: Write the script**

```powershell
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

    $url = "https://${BaseUrl}/auth/admin/realms/${Realm}/users"
    $body = @{
        username = $Username
        enabled  = $true
        email    = $Email
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
        # Keycloak returns 201 Created with no body; use Location header to find user ID
        return $true
    }
    catch {
        if ($_.Exception.Response.StatusCode -eq 409) {
            throw "User '$Username' already exists"
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
        return Invoke-RestMethod -Uri $url -Method Get -Headers $Headers -SkipCertificateCheck
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
        [array]$Roles
    )

    $url = "https://${BaseUrl}/auth/admin/realms/${Realm}/users/${UserId}/role-mappings/realm"
    $body = $Roles | ConvertTo-Json -Depth 10
    Invoke-RestMethod -Uri $url -Method Post -Headers $Headers -ContentType "application/json" -Body $body -SkipCertificateCheck
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
$Host = Get-EnvValue -Key "HOST"
$KeycloakHost = "keycloak.${Host}"

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

# Assign roles
$roleNames = $roleMap[$Role]
$rolesToAssign = @()
foreach ($roleName in $roleNames) {
    $role = Get-RealmRole -BaseUrl $KeycloakHost -Headers $headers -Realm $Realm -RoleName $roleName
    $rolesToAssign += $role
    Write-Host "  Found role: $roleName"
}

try {
    Add-UserRoleMappings -BaseUrl $KeycloakHost -Headers $headers -Realm $Realm -UserId $userId -Roles $rolesToAssign
    Write-Host "Roles assigned successfully."
}
catch {
    Write-Host "Role assignment failed, rolling back user..."
    Remove-CamundaUser -BaseUrl $KeycloakHost -Headers $headers -Realm $Realm -UserId $userId
    throw "Role assignment failed and user rolled back: $_"
}

Write-Host "`nDone! User '$Username' created with role '$Role'."
```

- [ ] **Step 2: Commit**

```bash
git add scripts/add-camunda-user.ps1
git commit -m "feat: add PowerShell script for creating Camunda users via Keycloak Admin API"
```

---

## Spec Coverage Check

- [x] Parameters: Username, Password, Email, FirstName, LastName, Role — all present
- [x] NormalUser role mapping: Orchestration, Optimize, Web Modeler, Console (excludes Keycloak/Identity)
- [x] Admin role mapping: ManagementIdentity, Orchestration, Optimize, Web Modeler, Web Modeler Admin, Console
- [x] Reads credentials from `.env`
- [x] Admin token via Keycloak Admin REST API
- [x] User creation via `POST /auth/admin/realms/{realm}/users`
- [x] Role UUID resolution via `GET /auth/admin/realms/{realm}/roles/{role-name}`
- [x] Role assignment via `POST /auth/admin/realms/{realm}/users/{user-id}/role-mappings/realm`
- [x] Rollback on failure (delete user if role assignment fails)
- [x] No placeholders in code

## Self-Review

All spec requirements are covered. No TBD/TODO placeholders. Roles match the spec exactly. Rollback logic is included.
