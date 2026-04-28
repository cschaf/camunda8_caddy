#Requires -Version 7
param([switch]$Force)

$ErrorActionPreference = 'Stop'

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$EnvFile   = Join-Path $ScriptDir '..' '.env'
$EnvExample = Join-Path $ScriptDir '..' '.env.example'

if ((Test-Path $EnvFile) -and -not $Force) {
    Write-Error ".env already exists. Use -Force to overwrite."
    exit 1
}

function gen {
    $bytes = [System.Security.Cryptography.RandomNumberGenerator]::GetBytes(24)
    return ([System.BitConverter]::ToString($bytes)).Replace('-', '').ToLower()
}

function Get-EnvVal([string]$Key) {
    $line = Get-Content $EnvExample | Where-Object { $_ -match "^$Key=" } | Select-Object -First 1
    if (-not $line) { return '' }
    return $line.Substring($Key.Length + 1)
}

$renovateLine = (Get-Content $EnvExample | Where-Object { $_ -match '^# renovate:' } | Select-Object -First 1) ?? ''

$content = @"
## Image versions ##
$renovateLine
CAMUNDA_VERSION=$(Get-EnvVal 'CAMUNDA_VERSION')
CAMUNDA_CONNECTORS_VERSION=$(Get-EnvVal 'CAMUNDA_CONNECTORS_VERSION')
CAMUNDA_IDENTITY_VERSION=$(Get-EnvVal 'CAMUNDA_IDENTITY_VERSION')
CAMUNDA_OPERATE_VERSION=$(Get-EnvVal 'CAMUNDA_OPERATE_VERSION')
CAMUNDA_OPTIMIZE_VERSION=$(Get-EnvVal 'CAMUNDA_OPTIMIZE_VERSION')
CAMUNDA_TASKLIST_VERSION=$(Get-EnvVal 'CAMUNDA_TASKLIST_VERSION')
CAMUNDA_WEB_MODELER_VERSION=$(Get-EnvVal 'CAMUNDA_WEB_MODELER_VERSION')
CAMUNDA_CONSOLE_VERSION=$(Get-EnvVal 'CAMUNDA_CONSOLE_VERSION')
ELASTIC_VERSION=$(Get-EnvVal 'ELASTIC_VERSION')
KEYCLOAK_SERVER_VERSION=$(Get-EnvVal 'KEYCLOAK_SERVER_VERSION')
MAILPIT_VERSION=$(Get-EnvVal 'MAILPIT_VERSION')
POSTGRES_VERSION=$(Get-EnvVal 'POSTGRES_VERSION')

## Network Configuration ##
HOST=$(Get-EnvVal 'HOST')
KEYCLOAK_HOST=$(Get-EnvVal 'KEYCLOAK_HOST')

## Stage / Environment Label ##
STAGE=$(Get-EnvVal 'STAGE')

## Dashboard Banner ##
BANNER_DARKMODE=$(Get-EnvVal 'BANNER_DARKMODE')
BANNER_LIGHTMODE=$(Get-EnvVal 'BANNER_LIGHTMODE')

## Camunda License (Optional for non-production, required for production use) ##
# Keep the real key only in .env. For multi-line keys, use single quotes so
# docker compose and the bash start script keep the value as one variable.
# CAMUNDA_LICENSE_KEY='--------------- BEGIN CAMUNDA LICENSE KEY ---------------
# ... complete key from Camunda ...
# --------------- END CAMUNDA LICENSE KEY ---------------'

## Backup Configuration ##
BACKUP_STOP_TIMEOUT=$(Get-EnvVal 'BACKUP_STOP_TIMEOUT')
ES_HOST=$(Get-EnvVal 'ES_HOST')
ES_PORT=$(Get-EnvVal 'ES_PORT')
RESTORE_HEALTH_TIMEOUT=$(Get-EnvVal 'RESTORE_HEALTH_TIMEOUT')

## TLS Certificates (Optional) ##
FULLCHAIN_PEM=$(Get-EnvVal 'FULLCHAIN_PEM')
PRIVATEKEY_PEM=$(Get-EnvVal 'PRIVATEKEY_PEM')

## OIDC Client Configuration ##
ORCHESTRATION_CLIENT_ID=$(Get-EnvVal 'ORCHESTRATION_CLIENT_ID')
ORCHESTRATION_CLIENT_SECRET=$(gen)

CONNECTORS_CLIENT_ID=$(Get-EnvVal 'CONNECTORS_CLIENT_ID')
CONNECTORS_CLIENT_SECRET=$(gen)

CONSOLE_CLIENT_SECRET=$(gen)

OPTIMIZE_CLIENT_SECRET=$(gen)

CAMUNDA_IDENTITY_CLIENT_SECRET=$(gen)

## Database Configuration ##
POSTGRES_DB=$(Get-EnvVal 'POSTGRES_DB')
POSTGRES_USER=$(Get-EnvVal 'POSTGRES_USER')
POSTGRES_PASSWORD=$(gen)

WEBMODELER_DB_NAME=$(Get-EnvVal 'WEBMODELER_DB_NAME')
WEBMODELER_DB_USER=$(Get-EnvVal 'WEBMODELER_DB_USER')
WEBMODELER_DB_PASSWORD=$(gen)

## Keycloak Admin Credentials ##
KEYCLOAK_ADMIN_USER=$(Get-EnvVal 'KEYCLOAK_ADMIN_USER')
KEYCLOAK_ADMIN_PASSWORD=$(gen)

## Web Modeler Configuration ##
WEBMODELER_PUSHER_APP_ID=$(Get-EnvVal 'WEBMODELER_PUSHER_APP_ID')
WEBMODELER_PUSHER_KEY=$(gen)
WEBMODELER_PUSHER_SECRET=$(gen)

WEBMODELER_MAIL_FROM_ADDRESS=$(Get-EnvVal 'WEBMODELER_MAIL_FROM_ADDRESS')

## Demo User ##
DEMO_USER_PASSWORD=$(gen)

## Feature Flags ##
RESOURCE_AUTHORIZATIONS_ENABLED=$(Get-EnvVal 'RESOURCE_AUTHORIZATIONS_ENABLED')
"@

[System.IO.File]::WriteAllText($EnvFile, $content, [System.Text.Encoding]::UTF8)

# Restrict permissions on Windows (owner read/write only)
$acl = Get-Acl $EnvFile
$acl.SetAccessRuleProtection($true, $false)
$rule = New-Object System.Security.AccessControl.FileSystemAccessRule(
    [System.Security.Principal.WindowsIdentity]::GetCurrent().Name,
    'Read,Write', 'Allow'
)
$acl.AddAccessRule($rule)
Set-Acl $EnvFile $acl

Write-Host "Generated .env with strong random secrets."
Write-Host ""
Write-Host "Generated secrets for:"
Write-Host "  ORCHESTRATION_CLIENT_SECRET, CONNECTORS_CLIENT_SECRET, CONSOLE_CLIENT_SECRET"
Write-Host "  OPTIMIZE_CLIENT_SECRET, CAMUNDA_IDENTITY_CLIENT_SECRET"
Write-Host "  POSTGRES_PASSWORD, WEBMODELER_DB_PASSWORD"
Write-Host "  KEYCLOAK_ADMIN_PASSWORD, WEBMODELER_PUSHER_KEY, WEBMODELER_PUSHER_SECRET"
Write-Host "  DEMO_USER_PASSWORD"
Write-Host ""
Write-Host "Edit HOST in .env before starting the stack if needed."
