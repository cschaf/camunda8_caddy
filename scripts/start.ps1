#Requires -Version 7

$ErrorActionPreference = 'Stop'

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$ProjectDir = Resolve-Path (Join-Path $ScriptDir '..')
$EnvFile = Join-Path $ProjectDir '.env'

if (-not (Test-Path $EnvFile)) {
    Write-Error ".env file not found. Run: cp .env.example .env"
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

# Pre-flight: run the Optimize schema upgrade one-shot before starting the
# stack. Optimize persists its schema version in Elasticsearch and refuses to
# start when the stored version is older than its own binary. The upgrade is
# non-destructive and idempotent (it logs "no update to perform" if the stored
# version is already at or above the new binary), so running it on every
# start is safe. If it fails for any reason (e.g. ES not yet up), log a
# warning and continue -- the regular start will surface the schema mismatch
# in the optimize container logs, and the operator can run
# `scripts\optimize-upgrade.ps1` manually to recover.
Write-Host '>> Pre-flight: Optimize schema check (idempotent)...'
$ComposeFile = Join-Path $ProjectDir 'docker-compose.yaml'
$StageFile   = Join-Path $ProjectDir "stages/$StageValue.yaml"
$OptimizeUpgrade = & docker compose -f $ComposeFile -f $StageFile `
    run --rm --no-deps -T `
    --entrypoint bash optimize `
    /optimize/upgrade/upgrade.sh --skip-warning
if ($LASTEXITCODE -ne 0) {
    Write-Warning 'Optimize schema pre-flight failed. Continuing with stack start.'
    Write-Warning 'If optimize does not come up, run: pwsh -File scripts\optimize-upgrade.ps1'
}

Write-Host "Starting Camunda stack with STAGE=$StageValue"
docker compose -f $ComposeFile -f $StageFile up -d
