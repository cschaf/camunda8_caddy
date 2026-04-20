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
foreach ($line in Get-Content $EnvFile) {
    if ($line -match '^\s*#') { continue }
    if ($line -match '^\s*STAGE\s*=(.*)$') {
        $StageValue = $matches[1].Trim().ToLowerInvariant()
        break
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

Write-Host "Starting Camunda stack with STAGE=$StageValue"
docker compose -f (Join-Path $ProjectDir 'docker-compose.yaml') -f (Join-Path $ProjectDir "stages/$StageValue.yaml") up -d
