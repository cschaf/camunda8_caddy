#Requires -Version 7

$ErrorActionPreference = 'Stop'

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$ProjectDir = Resolve-Path (Join-Path $ScriptDir '..')
$EnvFile = Join-Path $ProjectDir '.env'
$CredentialsFile = Join-Path $ProjectDir '.env-credentials'

if (-not (Test-Path $EnvFile)) {
    Write-Error ".env file not found. It is part of the repo, so this should not happen."
    Write-Error "Re-clone the repository, or restore .env from your last commit."
    exit 1
}

if (-not (Test-Path $CredentialsFile)) {
    Write-Error ".env-credentials file not found."
    Write-Error "Run one of:"
    Write-Error "  pwsh -File scripts/generate-secrets.ps1             # generate strong random secrets"
    Write-Error "  Copy-Item .env-credentials.example .env-credentials  # copy the demo template"
    exit 1
}

$StageValue = $null
$EnvHost = $null
$ElasticPassword = $null
$DisplayStageValue = $null
foreach ($line in Get-Content $EnvFile) {
    if ($line -match '^\s*#') { continue }
    if ($line -match '^\s*STAGE\s*=(.*)$') {
        $StageValue = $matches[1].Trim().ToLowerInvariant()
    }
    if ($line -match '^\s*HOST\s*=(.*)$') {
        $EnvHost = $matches[1].Trim()
    }
    if ($line -match '^\s*ELASTIC_PASSWORD\s*=(.*)$') {
        $ElasticPassword = $matches[1].Trim()
    }
    if ($line -match '^\s*DISPLAY_STAGE\s*=(.*)$') {
        $DisplayStageValue = $matches[1].Trim()
    }
}

# .env no longer holds the password; pull it from .env-credentials for the
# optimize template render. We use a quick regex scan instead of dot-sourcing
# (PSCore can dot-source KEY=VALUE files but it's a bit more ceremony).
if (-not $ElasticPassword) {
    foreach ($line in Get-Content $CredentialsFile) {
        if ($line -match '^\s*ELASTIC_PASSWORD\s*=(.*)$') {
            $ElasticPassword = $matches[1].Trim()
            break
        }
    }
}

if (-not $StageValue) {
    Write-Error "STAGE not found in .env. Expected one of: prod, dev, test"
    exit 1
}

if ($StageValue -notin @('prod', 'dev', 'test')) {
    Write-Error "Unsupported STAGE '$StageValue'. Expected one of: prod, dev, test"
    exit 1
}

$DisplayStage = if ([string]::IsNullOrEmpty($DisplayStageValue)) { $StageValue } else { $DisplayStageValue }

# Render console config from template
$ConsoleTemplate = Join-Path $ProjectDir '.console/application.yaml.template'
$ConsoleConfig   = Join-Path $ProjectDir '.console/application.yaml'
if ((Test-Path $ConsoleTemplate) -and $EnvHost) {
    $content = Get-Content $ConsoleTemplate -Raw
    $content = $content.Replace('${HOST}', $EnvHost).Replace('${DISPLAY_STAGE}', $DisplayStage)
    $content | Set-Content $ConsoleConfig -NoNewline
}

# Render optimize config from template
$OptimizeTemplate = Join-Path $ProjectDir '.optimize/environment-config.yaml.example'
$OptimizeConfig   = Join-Path $ProjectDir '.optimize/environment-config.yaml'
if ((Test-Path $OptimizeTemplate) -and $ElasticPassword) {
    $content = Get-Content $OptimizeTemplate -Raw
    $content = $content.Replace('ELASTIC_PASSWORD_PLACEHOLDER', $ElasticPassword)
    $content | Set-Content $OptimizeConfig -NoNewline
}

# Pre-flight: bring Elasticsearch up first so the Optimize schema check has
# something to talk to, then run the schema upgrade one-shot, then start the
# rest of the stack.
#
# Optimize persists its schema version in Elasticsearch and refuses to start
# when the stored version is older than its own binary. The upgrade is
# non-destructive and idempotent (it logs "no update to perform" if the stored
# version is already at or above the new binary), so running it on every
# start is safe. The upgrade MUST happen after ES is healthy but before
# optimize starts; otherwise either the pre-flight cannot reach ES (fresh
# start) or optimize boots with a stale schema and restart-loops until the
# operator manually runs the recovery script.
#
# `docker compose up -d elasticsearch` is idempotent: it is a no-op if ES is
# already running. The final `up -d` below will not restart the healthy ES.

Write-Host '>> Starting Elasticsearch (pre-flight dependency)...'
$ComposeFile = Join-Path $ProjectDir 'docker-compose.yaml'
$StageFile   = Join-Path $ProjectDir "stages/$StageValue.yaml"
# Pass both .env (committed, non-secret config) and .env-credentials (gitignored,
# secrets) so ${VAR} interpolation in docker-compose.yaml works for both.
# NOTE: do NOT prepend 'docker' to this array. PowerShell's `&` call operator
# on a native executable joins array elements into a single command string,
# so `& $ComposeBase ...` becomes a single command name. Use `docker @ComposeArgs`
# (splat) instead — that is the pattern used by monitor.ps1 / ensure-stack.ps1
# and is the one PowerShell splits correctly.
$ComposeArgs = @(
    'compose',
    '--env-file', $EnvFile,
    '--env-file', $CredentialsFile,
    '-f', $ComposeFile,
    '-f', $StageFile
)
docker @ComposeArgs up -d elasticsearch | Out-Null

Write-Host '>> Waiting for Elasticsearch to become healthy (timeout 300s)...'
$Attempts = 0
$MaxAttempts = 60
$EsHealthy = $false
while ($Attempts -lt $MaxAttempts) {
    $Status = (docker @ComposeArgs ps --format '{{.Status}}' elasticsearch 2>$null) -as [string]
    if ($Status -and $Status -match '\(healthy\)') {
        $EsHealthy = $true
        break
    }
    $Attempts += 1
    Start-Sleep -Seconds 5
}

if (-not $EsHealthy) {
    Write-Warning 'Elasticsearch did not become healthy in time. Skipping Optimize pre-flight.'
    Write-Warning 'If optimize does not come up, run: pwsh -File scripts\optimize-upgrade.ps1'
} else {
    Write-Host '>> Pre-flight: Optimize schema check (idempotent)...'
    docker @ComposeArgs run --rm --no-deps -T `
        --entrypoint bash optimize `
        /optimize/upgrade/upgrade.sh --skip-warning
    if ($LASTEXITCODE -ne 0) {
        Write-Warning 'Optimize schema pre-flight failed. Continuing with stack start.'
        Write-Warning 'If optimize does not come up, run: pwsh -File scripts\optimize-upgrade.ps1'
    }
}

Write-Host "Starting Camunda stack with STAGE=$StageValue"
docker @ComposeArgs up -d
