#Requires -Version 7
<#
.SYNOPSIS
    Wipe the local Camunda stack for a clean reinstall.

.DESCRIPTION
    Stops the stack and removes its containers, networks, data volumes and
    images, so the next start performs a fresh initialisation.

    Project files are NEVER touched: .env, .env-credentials,
    connector-secrets.txt, Caddyfile, certs/, secrets/, .hub/,
    .orchestration/ and backups/ stay exactly as they are.

    DESTRUCTIVE: by default all state is deleted (Zeebe, Postgres/Keycloak,
    Elasticsearch, Hub DB). Use -KeepVolumes to preserve the data volumes.
    You must type WIPE to confirm unless -Yes is passed.

.EXAMPLE
    pwsh -File scripts/cluster-wipe.ps1 -DryRun

.EXAMPLE
    pwsh -File scripts/cluster-wipe.ps1

.EXAMPLE
    pwsh -File scripts/cluster-wipe.ps1 -Yes -KeepVolumes

.EXAMPLE
    pwsh -File scripts/cluster-wipe.ps1 -Yes -PruneBuild
#>
param(
    [switch]$DryRun,
    [switch]$Yes,
    [switch]$KeepVolumes,
    [switch]$KeepImages,
    [switch]$PruneBuild
)

$ErrorActionPreference = 'Stop'

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$ProjectDir = Resolve-Path (Join-Path $ScriptDir '..')
$EnvFile = Join-Path $ProjectDir '.env'
$CredentialsFile = Join-Path $ProjectDir '.env-credentials'

foreach ($f in @($EnvFile, $CredentialsFile)) {
    if (-not (Test-Path $f)) {
        Write-Error "$f not found. This script keeps your env files and needs them to resolve the stack."
        exit 1
    }
}

$StageValue = $null
foreach ($line in Get-Content $EnvFile) {
    if ($line -match '^\s*#') { continue }
    if ($line -match '^\s*STAGE\s*=(.*)$') { $StageValue = $matches[1].Trim().ToLowerInvariant() }
}
if (-not $StageValue) {
    Write-Error "STAGE not found in $EnvFile"
    exit 1
}
$StageFile = Join-Path $ProjectDir "stages/$StageValue.yaml"
if (-not (Test-Path $StageFile)) {
    Write-Error "stage file not found: $StageFile"
    exit 1
}

# Splat pattern (docker @ComposeArgs ...) so PowerShell passes each element as a
# separate argument. Do NOT prepend 'docker' to the array.
$ComposeArgs = @(
    'compose',
    '--env-file', $EnvFile,
    '--env-file', $CredentialsFile,
    '-f', (Join-Path $ProjectDir 'docker-compose.yaml'),
    '-f', $StageFile
)

# Fixed container_name values from docker-compose.yaml (safety net for orphans
# that survived `compose down`).
$Containers = @(
    'camunda-data-init', 'orchestration', 'connectors', 'optimize', 'identity',
    'postgres', 'camunda-db', 'keycloak', 'elasticsearch', 'web-modeler-db',
    'mailpit', 'hub', 'hub-websockets', 'autoheal', 'reverse-proxy'
)

$deleteVolumes = -not $KeepVolumes
$deleteImages = -not $KeepImages

Write-Host 'Camunda cluster wipe'
Write-Host "  Project dir : $ProjectDir"
Write-Host "  STAGE       : $StageValue"
Write-Host "  Volumes     : $(if ($deleteVolumes) { 'DELETE (data loss)' } else { 'KEEP' })"
Write-Host "  Images      : $(if ($deleteImages) { 'DELETE' } else { 'KEEP' })"
Write-Host "  Build cache : $(if ($PruneBuild) { 'PRUNE (global)' } else { 'keep' })"
Write-Host ''
Write-Host 'Kept (never touched): .env, .env-credentials, connector-secrets.txt, Caddyfile,'
Write-Host '                      certs/, secrets/, .hub/, .orchestration/, backups/'
Write-Host ''

if ($DryRun) {
    $downPreview = @('down', '--remove-orphans')
    if ($deleteVolumes) { $downPreview += '--volumes' }
    if ($deleteImages) { $downPreview += '--rmi', 'all' }
    Write-Host "[dry-run] would run: docker $($ComposeArgs -join ' ') $($downPreview -join ' ')"
    Write-Host "[dry-run] would remove leftover containers: $($Containers -join ', ')"
    if ($deleteImages) { Write-Host "[dry-run] would remove images listed by: docker $($ComposeArgs -join ' ') config --images" }
    if ($deleteVolumes) { Write-Host '[dry-run] would remove the fixed-name volume: elastic-backup' }
    if ($PruneBuild) { Write-Host '[dry-run] would run: docker builder prune -af' }
    Write-Host '[dry-run] nothing changed.'
    exit 0
}

if (-not $Yes) {
    Write-Host "WARNING: This removes the stack's containers, networks and images."
    if ($deleteVolumes) {
        Write-Host '         It also DELETES the data volumes: Zeebe, Postgres/Keycloak,'
        Write-Host '         Elasticsearch and Hub DB. There is no undo.'
    }
    Write-Host ''
    $confirm = Read-Host 'Type WIPE to continue'
    if ($confirm -ne 'WIPE') {
        Write-Host 'Aborted.'
        exit 1
    }
}

$downFlags = @('down', '--remove-orphans')
if ($deleteVolumes) { $downFlags += '--volumes' }
if ($deleteImages) { $downFlags += '--rmi', 'all' }

Write-Host '>> Stopping and removing the stack...'
docker @ComposeArgs @downFlags
if ($LASTEXITCODE -ne 0) {
    Write-Warning "'docker compose down' returned non-zero; continuing with the cleanup steps."
}

Write-Host '>> Removing leftover containers...'
foreach ($c in $Containers) {
    docker inspect $c *> $null
    if ($LASTEXITCODE -eq 0) {
        docker rm -f $c *> $null
        if ($LASTEXITCODE -eq 0) { Write-Host "   removed container: $c" }
        else { Write-Host "   could not remove container: $c" }
    }
}

if ($deleteImages) {
    Write-Host '>> Removing stack images...'
    $images = docker @ComposeArgs config --images 2>$null | Select-Object -Unique
    if ($images) {
        foreach ($img in ($images -split "`r?`n")) {
            $img = $img.Trim()
            if (-not $img) { continue }
            docker rmi -f $img *> $null
            if ($LASTEXITCODE -eq 0) { Write-Host "   removed image: $img" }
            else { Write-Host "   skipped image (not present or in use): $img" }
        }
    }
    else {
        Write-Host "   (could not resolve images via 'docker compose config --images'; skipping)"
    }
}

if ($deleteVolumes) {
    # elastic-backup uses a fixed name (not project-prefixed); remove it explicitly
    # in case it outlived the compose project.
    docker volume rm elastic-backup *> $null
    if ($LASTEXITCODE -eq 0) { Write-Host '   removed volume: elastic-backup' }
}

if ($PruneBuild) {
    Write-Host '>> Pruning the global Docker build cache...'
    docker builder prune -af
}

Write-Host ''
Write-Host 'Done. The stack is wiped; your env files and configuration are untouched.'
Write-Host 'Fresh install:'
Write-Host '  pwsh -File scripts/setup-host.ps1   # as Administrator'
Write-Host '  pwsh -File scripts/start.ps1'
