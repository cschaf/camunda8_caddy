<#
.SYNOPSIS
    Applies custom Camunda authorization permissions after stack startup.

.DESCRIPTION
    Camunda's built-in initialization only creates default roles with fixed permissions.
    This script patches those roles via the Camunda REST API to match the desired
    permission model for this environment.

    Currently applies:
      - readonly-admin: adds UPDATE_USER_TASK on PROCESS_DEFINITION
        so NormalUser accounts can complete tasks in Tasklist.

    Safe to re-run — uses PUT (idempotent).

.EXAMPLE
    pwsh -File scripts/camunda-authorizations.ps1
#>

$ErrorActionPreference = "Stop"

function Get-EnvValue {
    param([string]$Key)
    $envFile = Join-Path $PSScriptRoot "..\.env"
    $content = Get-Content $envFile | Where-Object { $_ -notmatch '^\s*#' }
    foreach ($line in $content) {
        if ($line -match "^${Key}=(.*)") { return $matches[1].Trim() }
    }
    throw "Key '$Key' not found in .env"
}

$CamundaHost   = Get-EnvValue -Key "HOST"
$OrchSecret    = Get-EnvValue -Key "ORCHESTRATION_CLIENT_SECRET"
$KeycloakHost  = "keycloak.${CamundaHost}"
$OrchHost      = "orchestration.${CamundaHost}"

# ---------------------------------------------------------------------------
# Get orchestration client credentials token
# ---------------------------------------------------------------------------
Write-Host "Getting orchestration token..."
$tokenResp = Invoke-RestMethod `
    -Uri "https://${KeycloakHost}/auth/realms/camunda-platform/protocol/openid-connect/token" `
    -Method Post `
    -ContentType "application/x-www-form-urlencoded" `
    -Body @{ grant_type = "client_credentials"; client_id = "orchestration"; client_secret = $OrchSecret } `
    -SkipCertificateCheck
$token = $tokenResp.access_token
$headers = @{ Authorization = "Bearer $token"; "Content-Type" = "application/json" }

# ---------------------------------------------------------------------------
# Helper: find authorization key for a given owner + resourceType
# ---------------------------------------------------------------------------
function Get-AuthorizationKey {
    param([string]$OwnerId, [string]$ResourceType)
    $body = @{ filter = @{ ownerId = $OwnerId; resourceType = $ResourceType } } | ConvertTo-Json -Depth 5
    $resp = Invoke-RestMethod `
        -Uri "https://${OrchHost}/v2/authorizations/search" `
        -Method Post -Headers $headers -Body $body -SkipCertificateCheck
    if ($resp.items.Count -eq 0) { throw "No authorization found for ownerId=$OwnerId resourceType=$ResourceType" }
    return $resp.items[0].authorizationKey
}

# ---------------------------------------------------------------------------
# Helper: update authorization permissions (idempotent PUT)
# ---------------------------------------------------------------------------
function Set-AuthorizationPermissions {
    param(
        [long]$AuthKey,
        [string]$OwnerId,
        [string]$OwnerType,
        [string]$ResourceType,
        [string]$ResourceId,
        [string[]]$Permissions
    )
    $body = @{
        ownerId         = $OwnerId
        ownerType       = $OwnerType
        resourceType    = $ResourceType
        resourceId      = $ResourceId
        permissionTypes = $Permissions
    } | ConvertTo-Json -Depth 5
    Invoke-RestMethod `
        -Uri "https://${OrchHost}/v2/authorizations/${AuthKey}" `
        -Method Put -Headers $headers -Body $body -SkipCertificateCheck | Out-Null
    Write-Host "  Updated: $OwnerId / $ResourceType -> $($Permissions -join ', ')"
}

# ---------------------------------------------------------------------------
# Apply authorization patches
# ---------------------------------------------------------------------------
Write-Host "Applying Camunda authorization patches..."

# readonly-admin: NormalUser needs UPDATE_USER_TASK to complete tasks in Tasklist
$key = Get-AuthorizationKey -OwnerId "readonly-admin" -ResourceType "PROCESS_DEFINITION"
Set-AuthorizationPermissions `
    -AuthKey     $key `
    -OwnerId     "readonly-admin" `
    -OwnerType   "ROLE" `
    -ResourceType "PROCESS_DEFINITION" `
    -ResourceId  "*" `
    -Permissions @("READ_PROCESS_INSTANCE", "READ_PROCESS_DEFINITION", "READ_USER_TASK", "UPDATE_USER_TASK")

Write-Host "`nDone!"
