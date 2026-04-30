#Requires -Version 7

$ErrorActionPreference = 'Stop'

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$ProjectDir = Resolve-Path (Join-Path $ScriptDir '..')
$EnvFile = Join-Path $ProjectDir '.env'
$LogFile = if ($env:MONITOR_LOG_FILE) { $env:MONITOR_LOG_FILE } else { Join-Path $ProjectDir 'monitor.log' }
$LogMaxSize = if ($env:MONITOR_LOG_MAX_SIZE) { [int]$env:MONITOR_LOG_MAX_SIZE } else { 10485760 }   # 10 MiB default
$LogMaxArchives = if ($env:MONITOR_LOG_MAX_ARCHIVES) { [int]$env:MONITOR_LOG_MAX_ARCHIVES } else { 5 }
$BackupLockDir = Join-Path $ProjectDir 'backups/.backup.lock'
$BackupLockFile = Join-Path $BackupLockDir 'pid'

function Rotate-LogIfNeeded {
    if (-not $LogFile) { return }
    if (-not (Test-Path $LogFile)) { return }

    $size = (Get-Item $LogFile).Length
    if ($size -le $LogMaxSize) { return }

    for ($i = $LogMaxArchives - 1; $i -ge 1; $i--) {
        $src = "$LogFile.$i"
        $dst = "$LogFile.$($i + 1)"
        if (Test-Path $src) {
            Move-Item -Force $src $dst
        }
    }

    Move-Item -Force $LogFile "$LogFile.1"
}

function Write-Log {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Message
    )

    $timestamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    $line = "[$timestamp] $Message"
    Write-Host $line
    if ($LogFile) {
        $dir = Split-Path -Parent $LogFile
        if (-not (Test-Path $dir)) {
            New-Item -ItemType Directory -Path $dir -Force | Out-Null
        }
        Add-Content -Path $LogFile -Value $line
    }
}

function Test-BackupOrRestoreRunning {
    if (-not (Test-Path $BackupLockFile)) {
        return $false
    }

    $pidText = Get-Content $BackupLockFile -Raw -ErrorAction SilentlyContinue
    if (-not $pidText) {
        return $false
    }

    $lockPid = $pidText.Trim()
    if (-not ($lockPid -match '^\d+$')) {
        return $false
    }

    $proc = Get-Process -Id $lockPid -ErrorAction SilentlyContinue
    return $null -ne $proc
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

Rotate-LogIfNeeded

if (Test-BackupOrRestoreRunning) {
    Write-Log 'Backup or restore is currently running. Skipping monitor check.'
    exit 0
}

if (-not (Test-Path $EnvFile)) {
    Write-Log 'ERROR: .env file not found. Run: cp .env.example .env'
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

$ComposeArgs = @(
    'compose',
    '-f', (Join-Path $ProjectDir 'docker-compose.yaml'),
    '-f', (Join-Path $ProjectDir "stages/$StageValue.yaml")
)

# Build expected service list (exclude one-shot init container)
$ExpectedServices = @(docker @ComposeArgs config --services 2>$null | Where-Object { $_ -and $_ -ne 'camunda-data-init' })

if ($ExpectedServices.Count -eq 0) {
    Write-Log 'ERROR: Could not determine expected services from docker compose config'
    exit 1
}

# Query running containers and parse health/state from JSON
$containerJson = docker @ComposeArgs ps --format json 2>$null

$containers = @()
if ($containerJson) {
    # Docker Compose v2 may emit a JSON array or one JSON object per line.
    $text = $containerJson -join "`n"
    try {
        $parsed = $text | ConvertFrom-Json -Depth 10
        if ($parsed -is [array]) {
            $containers = $parsed
        } else {
            $containers = @($parsed)
        }
    } catch {
        # Fallback: try each line individually
        $containers = @(
            foreach ($line in $containerJson) {
                try { $line | ConvertFrom-Json -Depth 10 } catch { $null }
            }
        ) | Where-Object { $null -ne $_ }
    }
}

$issues = @()
foreach ($service in $ExpectedServices) {
    $match = $containers | Where-Object { $_.Service -eq $service } | Select-Object -First 1

    if (-not $match) {
        $issues += "$service`: missing (not running)"
        continue
    }

    $state = $match.State
    $health = $match.Health

    if ($state -ne 'running') {
        $issues += "$service`: state is '$state' (expected 'running')"
        continue
    }

    if ($health -eq 'unhealthy') {
        $issues += "$service`: health is '$health'"
    }
}

if ($issues.Count -eq 0) {
    Write-Log "All $($ExpectedServices.Count) expected services are running and healthy."
    exit 0
}

Write-Log "Cluster health check failed for STAGE=$StageValue`:"
foreach ($issue in $issues) {
    Write-Log "  - $issue"
}

Write-Log 'Attempting to recover by running scripts/start.ps1...'
& (Join-Path $ProjectDir 'scripts/start.ps1')
if ($LASTEXITCODE -ne 0) {
    Write-Log "ERROR: scripts/start.ps1 exited with code $LASTEXITCODE"
    exit 1
}

Write-Log 'Recovery completed.'
