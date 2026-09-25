#Requires -Version 7

$ErrorActionPreference = 'Stop'

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$ProjectDir = Resolve-Path (Join-Path $ScriptDir '..')
$EnvFile = Join-Path $ProjectDir '.env'
$CredentialsFile = Join-Path $ProjectDir '.env-credentials'

function Write-Log {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Message
    )

    $timestamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    Write-Host "[$timestamp] $Message"
}

if (-not (Test-Path $EnvFile) -and -not (Test-Path $CredentialsFile)) {
    Write-Log "ERROR: .env file not found. Run: cp .env.example .env"
    exit 1
}

$StageValue = $null
foreach ($file in @($EnvFile, $CredentialsFile)) {
    if (-not (Test-Path $file)) { continue }
    foreach ($line in Get-Content $file) {
        if ($line -match '^\s*#') { continue }
        if ($line -match '^\s*STAGE\s*=(.*)$') {
            $StageValue = $matches[1].Trim().ToLowerInvariant()
            break
        }
    }
    if ($StageValue) { break }
}

if (-not $StageValue) {
    Write-Log 'ERROR: STAGE not found in .env. Expected one of: prod, dev, test'
    exit 1
}

if ($StageValue -notin @('prod', 'dev', 'test')) {
    Write-Log "ERROR: Unsupported STAGE '$StageValue'. Expected one of: prod, dev, test"
    exit 1
}

docker info *> $null
if ($LASTEXITCODE -ne 0) {
    Write-Log 'ERROR: Docker daemon is not reachable'
    exit 1
}

# Same DISPLAY_STAGE fallback as scripts/start.ps1, so a restarted service
# (e.g. hub's HUB_CLUSTER_TAG) gets the same configuration as on a normal start.
if ([string]::IsNullOrEmpty($env:DISPLAY_STAGE)) {
    $DisplayStageValue = $null
    if (Test-Path $EnvFile) {
        foreach ($line in Get-Content $EnvFile) {
            if ($line -match '^\s*DISPLAY_STAGE\s*=(.*)$') { $DisplayStageValue = $matches[1].Trim() }
        }
    }
    $env:DISPLAY_STAGE = if ([string]::IsNullOrEmpty($DisplayStageValue)) { $StageValue } else { $DisplayStageValue }
}

# Pass both env files so ${VAR} interpolation in docker-compose.yaml works
# (credentials live in .env-credentials, see scripts/start.ps1).
$ComposeArgs = @('compose')
foreach ($file in @($EnvFile, $CredentialsFile)) {
    if (Test-Path $file) { $ComposeArgs += @('--env-file', $file) }
}
$ComposeArgs += @(
    '-f', (Join-Path $ProjectDir 'docker-compose.yaml'),
    '-f', (Join-Path $ProjectDir "stages/$StageValue.yaml")
)

$configOutput = docker @ComposeArgs config --services 2>&1
if ($LASTEXITCODE -ne 0) {
    Write-Log 'ERROR: Could not determine expected services from docker compose config'
    $configOutput | ForEach-Object { Write-Log "  $_" }
    exit 1
}
# camunda-data-init is a one-shot init container that exits after its work;
# it is started as a dependency of orchestration and must not be restarted here.
$ExpectedServices = @($configOutput | Where-Object { $_ -and $_ -ne 'camunda-data-init' })
$RunningServices = @(docker @ComposeArgs ps --services --status running)
$RunningLookup = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)

foreach ($service in $RunningServices) {
    [void]$RunningLookup.Add($service)
}

$MissingServices = @()
foreach ($service in $ExpectedServices) {
    if (-not $RunningLookup.Contains($service)) {
        $MissingServices += $service
    }
}

if ($MissingServices.Count -eq 0) {
    Write-Log "All expected services are running for STAGE=$StageValue"
    exit 0
}

Write-Log "Detected missing or stopped services for STAGE=${StageValue}: $($MissingServices -join ', ')"
Write-Log 'Starting only the missing or stopped services'
& docker @ComposeArgs up -d @MissingServices
