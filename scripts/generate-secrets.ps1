#Requires -Version 7
<#
.SYNOPSIS
    Generates .env-credentials with strong random secrets.

.DESCRIPTION
    Reads non-credential defaults (HOST, STAGE, *_CLIENT_ID, etc.) from the
    committed .env so the generated file matches the active configuration.
    .env is NOT modified by this script — it is part of the repo and is
    expected to already exist when generate-secrets is run.
#>
param([switch]$Force)

$ErrorActionPreference = 'Stop'

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$EnvFile         = Join-Path $ScriptDir '..' '.env'
$CredentialsFile = Join-Path $ScriptDir '..' '.env-credentials'

if ((Test-Path $CredentialsFile) -and -not $Force) {
    Write-Error ".env-credentials already exists. Use -Force to overwrite."
    exit 1
}

if (-not (Test-Path $EnvFile)) {
    Write-Error ".env not found. It is part of the repo, so this should not happen."
    Write-Error "Re-clone the repository, or restore .env from your last commit."
    exit 1
}

function gen {
    $bytes = [System.Security.Cryptography.RandomNumberGenerator]::GetBytes(24)
    return ([System.BitConverter]::ToString($bytes)).Replace('-', '').ToLower()
}

# Read a single KEY=VALUE line from .env (non-credential source). Skips
# comments and blank lines. Returns '' if not found.
function Get-EnvVal([string]$Key) {
    $line = Get-Content $EnvFile | Where-Object { $_ -match "^$Key=" } | Select-Object -First 1
    if (-not $line) { return '' }
    return $line.Substring($Key.Length + 1)
}

# Pre-generate secrets that are written to .env-credentials
$elasticPassword         = gen
$postgresPassword        = gen
$camundaDbPassword       = gen
$webmodelerDbPassword    = gen
$keycloakAdminPassword   = gen
$webmodelerPusherKey     = gen
$webmodelerPusherSecret  = gen
$demoUserPassword        = gen

$content = @"
## Camunda Private Registry (Optional) ##
# Used by scripts/registry-info.{ps1,sh} to query Camunda's Harbor registry.
# Credentials are issued by Camunda to enterprise customers (robot accounts).
CAMUNDA_REGISTRY_USERNAME=$(Get-EnvVal 'CAMUNDA_REGISTRY_USERNAME')
CAMUNDA_REGISTRY_PASSWORD=$(gen)

## OIDC Client Configuration ##
ORCHESTRATION_CLIENT_ID=$(Get-EnvVal 'ORCHESTRATION_CLIENT_ID')
ORCHESTRATION_CLIENT_SECRET=$(gen)

CONNECTORS_CLIENT_ID=$(Get-EnvVal 'CONNECTORS_CLIENT_ID')
CONNECTORS_CLIENT_SECRET=$(gen)

CONSOLE_CLIENT_SECRET=$(gen)

OPTIMIZE_CLIENT_SECRET=$(gen)

CAMUNDA_IDENTITY_CLIENT_SECRET=$(gen)

## Elasticsearch Configuration ##
ELASTIC_PASSWORD=$elasticPassword

## Database Configuration ##
POSTGRES_DB=$(Get-EnvVal 'POSTGRES_DB')
POSTGRES_USER=$(Get-EnvVal 'POSTGRES_USER')
POSTGRES_PASSWORD=$postgresPassword

CAMUNDA_DB_NAME=$(Get-EnvVal 'CAMUNDA_DB_NAME')
CAMUNDA_DB_USER=$(Get-EnvVal 'CAMUNDA_DB_USER')
CAMUNDA_DB_PASSWORD=$camundaDbPassword

WEBMODELER_DB_NAME=$(Get-EnvVal 'WEBMODELER_DB_NAME')
WEBMODELER_DB_USER=$(Get-EnvVal 'WEBMODELER_DB_USER')
WEBMODELER_DB_PASSWORD=$webmodelerDbPassword

## Keycloak Admin Credentials ##
KEYCLOAK_ADMIN_USER=$(Get-EnvVal 'KEYCLOAK_ADMIN_USER')
KEYCLOAK_ADMIN_PASSWORD=$keycloakAdminPassword

## Web Modeler Configuration ##
WEBMODELER_PUSHER_APP_ID=$(Get-EnvVal 'WEBMODELER_PUSHER_APP_ID')
WEBMODELER_PUSHER_KEY=$webmodelerPusherKey
WEBMODELER_PUSHER_SECRET=$webmodelerPusherSecret

## Demo User ##
DEMO_USER_PASSWORD=$demoUserPassword
"@

[System.IO.File]::WriteAllText($CredentialsFile, $content, [System.Text.Encoding]::UTF8)

# Restrict permissions on Windows (owner read/write only)
$acl = Get-Acl $CredentialsFile
$acl.SetAccessRuleProtection($true, $false)
$rule = New-Object System.Security.AccessControl.FileSystemAccessRule(
    [System.Security.Principal.WindowsIdentity]::GetCurrent().Name,
    'Read,Write', 'Allow'
)
$acl.AddAccessRule($rule)
Set-Acl $CredentialsFile $acl

Write-Host 'Generated .env-credentials with strong random secrets.'
Write-Host ''
Write-Host 'Generated secrets for:'
Write-Host '  ORCHESTRATION_CLIENT_SECRET, CONNECTORS_CLIENT_SECRET, CONSOLE_CLIENT_SECRET'
Write-Host '  OPTIMIZE_CLIENT_SECRET, CAMUNDA_IDENTITY_CLIENT_SECRET'
Write-Host '  ELASTIC_PASSWORD'
Write-Host '  POSTGRES_PASSWORD, WEBMODELER_DB_PASSWORD, CAMUNDA_DB_PASSWORD'
Write-Host '  KEYCLOAK_ADMIN_PASSWORD, WEBMODELER_PUSHER_KEY, WEBMODELER_PUSHER_SECRET'
Write-Host '  DEMO_USER_PASSWORD'
Write-Host ''
Write-Host 'Edit HOST in .env before starting the stack if needed.'
