#Requires -Version 7

<#
.SYNOPSIS
    Run the Camunda Optimize schema upgrade against the existing
    Elasticsearch data after a patch upgrade of the Optimize image.

.DESCRIPTION
    Required after a patch upgrade of Optimize (e.g. 8.9.1 -> 8.9.6) when
    the stored schema version in ES no longer matches the new binary.
    Optimize refuses to start in that case and restart-loops with:

        "The database Optimize schema version [X] doesn't match the
         current Optimize version [Y]. Please make sure to run the
         Upgrade first."

    The script:
      1. Stops the broken `optimize` service.
      2. Runs the bundled upgrade one-shot in a transient container that
         inherits the service's env config and joins the same network.
      3. Restarts the regular `optimize` service and waits for it to be
         healthy.

    The upgrade is non-destructive: ES metadata is updated in place, no
    indices are dropped, no Optimize data is lost. It is safe to re-run
    idempotently.
#>

$ErrorActionPreference = 'Stop'

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$ProjectDir = Resolve-Path (Join-Path $ScriptDir '..')
$EnvFile = Join-Path $ProjectDir '.env'
$CredentialsFile = Join-Path $ProjectDir '.env-credentials'

Set-Location $ProjectDir

if (-not (Test-Path $EnvFile)) {
    Write-Error ".env file not found. It is part of the repo, so this should not happen."
    exit 1
}

if (-not (Test-Path $CredentialsFile)) {
    Write-Error ".env-credentials file not found."
    Write-Error "Run one of:"
    Write-Error "  pwsh -File scripts/generate-secrets.ps1"
    Write-Error "  Copy-Item .env-credentials.example .env-credentials"
    exit 1
}

# Use the same stage overlay as scripts/start.ps1. Without it, "up -d optimize"
# would recreate optimize and its dependencies (elasticsearch, identity,
# keycloak, postgres) with the base resource profile instead of the stage one.
$StageValue = $null
$DisplayStageValue = $null
foreach ($line in Get-Content $EnvFile) {
    if ($line -match '^\s*#') { continue }
    if ($line -match '^\s*STAGE\s*=(.*)$') { $StageValue = $matches[1].Trim().ToLowerInvariant() }
    if ($line -match '^\s*DISPLAY_STAGE\s*=(.*)$') { $DisplayStageValue = $matches[1].Trim() }
}
if ($StageValue -notin @('prod', 'dev', 'test')) {
    Write-Error "Unsupported or missing STAGE '$StageValue' in .env. Expected one of: prod, dev, test"
    exit 1
}
if ([string]::IsNullOrEmpty($env:DISPLAY_STAGE)) {
    $env:DISPLAY_STAGE = if ([string]::IsNullOrEmpty($DisplayStageValue)) { $StageValue } else { $DisplayStageValue }
}

$ComposeArgs = @(
    'compose',
    '--env-file', $EnvFile,
    '--env-file', $CredentialsFile,
    '-f', (Join-Path $ProjectDir 'docker-compose.yaml'),
    '-f', (Join-Path $ProjectDir "stages/$StageValue.yaml")
)

# The Optimize upgrade script lives at /optimize/upgrade/upgrade.sh inside
# the container. PowerShell on Windows does not rewrite leading slashes, so
# a single forward-slash path is enough.

Write-Host '>> Stopping the (currently broken) optimize service...'
docker @ComposeArgs stop optimize

Write-Host ''
Write-Host '>> Running Camunda Optimize schema upgrade one-shot...'
Write-Host '   This is safe to interrupt: the upgrade is a single ES'
Write-Host '   metadata write, but the in-flight restart loop is broken.'
Write-Host ''

# --no-deps  : don't start dependencies (we just stopped optimize, ES is up).
# --rm       : remove the one-shot container when it exits.
# -T         : disable pseudo-TTY so output is plain log lines.
docker @ComposeArgs run --rm --no-deps -T `
  --entrypoint bash `
  optimize `
  /optimize/upgrade/upgrade.sh --skip-warning

Write-Host ''
Write-Host '>> Upgrade finished. Starting the regular optimize service...'
# --no-deps: only (re)start optimize; its dependencies are already running.
docker @ComposeArgs up -d --no-deps optimize

Write-Host ''
Write-Host '>> Waiting for optimize to become healthy (timeout 120s)...'
$Attempts = 0
$MaxAttempts = 24
while ($Attempts -lt $MaxAttempts) {
    $Status = (docker @ComposeArgs ps --format '{{.Status}}' optimize 2>$null) -as [string]
    if ($Status -and $Status -match '\(healthy\)') {
        Write-Host "   optimize is healthy: $Status"
        exit 0
    }
    if ($Status -and $Status -match '(?i)(exited|dead|restarting)') {
        Write-Host "   optimize is NOT healthy: $Status"
        Write-Host '   Run: docker compose logs --tail=100 optimize'
        exit 1
    }
    $Attempts += 1
    Start-Sleep -Seconds 5
}

Write-Host '   Timed out waiting for optimize to become healthy.'
Write-Host '   Run: docker compose logs --tail=100 optimize'
exit 1
