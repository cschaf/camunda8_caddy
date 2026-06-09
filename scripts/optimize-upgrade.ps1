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

Set-Location $ProjectDir

# The Optimize upgrade script lives at /optimize/upgrade/upgrade.sh inside
# the container. PowerShell on Windows does not rewrite leading slashes, so
# a single forward-slash path is enough.

Write-Host '>> Stopping the (currently broken) optimize service...'
docker compose stop optimize

Write-Host ''
Write-Host '>> Running Camunda Optimize schema upgrade one-shot...'
Write-Host '   This is safe to interrupt: the upgrade is a single ES'
Write-Host '   metadata write, but the in-flight restart loop is broken.'
Write-Host ''

# --no-deps  : don't start dependencies (we just stopped optimize, ES is up).
# --rm       : remove the one-shot container when it exits.
# -T         : disable pseudo-TTY so output is plain log lines.
& docker compose run --rm --no-deps -T `
  --entrypoint bash `
  optimize `
  /optimize/upgrade/upgrade.sh --skip-warning

Write-Host ''
Write-Host '>> Upgrade finished. Starting the regular optimize service...'
docker compose up -d optimize

Write-Host ''
Write-Host '>> Waiting for optimize to become healthy (timeout 120s)...'
$Attempts = 0
$MaxAttempts = 24
while ($Attempts -lt $MaxAttempts) {
    $Status = (docker compose ps --format '{{.Status}}' optimize 2>$null) -as [string]
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
