#Requires -Version 7

$ErrorActionPreference = 'Stop'

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$ProjectDir = Resolve-Path (Join-Path $ScriptDir '..')
$EnvFile = Join-Path $ProjectDir '.env'

function Write-Log {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Message
    )

    $timestamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    Write-Host "[$timestamp] $Message"
}

if (-not (Test-Path $EnvFile)) {
    Write-Log "ERROR: .env file not found. Run: cp .env.example .env"
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

$ComposeArgs = @(
    'compose',
    '-f', (Join-Path $ProjectDir 'docker-compose.yaml'),
    '-f', (Join-Path $ProjectDir "stages/$StageValue.yaml")
)

$ExpectedServices = @(docker @ComposeArgs config --services)
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
