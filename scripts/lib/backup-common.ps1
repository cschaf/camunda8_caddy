$ErrorActionPreference = "Stop"

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$ProjectDir = Resolve-Path (Join-Path $ScriptDir "..\..")
$EnvFile = Join-Path $ProjectDir ".env"
$BackupBaseDir = Join-Path $ProjectDir "backups"
$LockFile = Join-Path $BackupBaseDir ".backup.lock"

function Log {
    param([string]$Message)
    $msg = "[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')] $Message"
    Write-Host $msg
    if ($Global:LogFile) {
        Add-Content -Path $Global:LogFile -Value $msg
    }
}

function Load-Env {
    if (-not (Test-Path $EnvFile)) {
        Log "ERROR: .env file not found at $EnvFile"
        exit 1
    }

    Get-Content $EnvFile | ForEach-Object {
        if ($_ -match '^\s*([^#\s=]+)\s*=\s*(.*)\s*$') {
            $name = $matches[1]
            $value = $matches[2]
            # Remove surrounding quotes if present
            if ($value -match '^["''](.*)["'']$') {
                $value = $matches[1]
            }
            [Environment]::SetEnvironmentVariable($name, $value, "Process")
        }
    }
}

function Get-Stage {
    Load-Env
    $stage = ($env:STAGE -as [string]).ToLower().Trim()

    switch ($stage) {
        { $_ -in "prod","dev","test" } { return $_ }
        "" {
            Log "ERROR: STAGE not found in .env. Expected one of: prod, dev, test"
            exit 1
        }
        default {
            Log "ERROR: Unsupported STAGE '$stage'. Expected one of: prod, dev, test"
            exit 1
        }
    }
}

function Get-DockerComposeCmd {
    $stage = Get-Stage
    return "docker compose -f `"$ProjectDir\docker-compose.yaml`" -f `"$ProjectDir\stages\${stage}.yaml`""
}

function Check-ServicesHealth {
    $cmd = Get-DockerComposeCmd
    Log "Checking services health..."

    try {
        $services = Invoke-Expression "$cmd ps --format json" | ConvertFrom-Json -ErrorAction SilentlyContinue
        $unhealthy = $services | Where-Object {
            $_.Health -eq "unhealthy" -or ($_.State -ne "running" -and $_.State -ne "")
        }

        if ($unhealthy) {
            Log "WARNING: The following services are unhealthy or not running:"
            $unhealthy | ForEach-Object { Log "  - $($_.Service)" }
            return $false
        }
    }
    catch {
        Log "WARNING: Could not determine service health: $_"
        return $false
    }

    Log "All services are healthy."
    return $true
}

function Compute-Checksum {
    param([string]$File)
    if (-not (Test-Path $File)) {
        Log "ERROR: File not found for checksum: $File"
        exit 1
    }
    (Get-FileHash -Path $File -Algorithm SHA256).Hash.ToLower()
}

function Create-Manifest {
    param([string]$BackupDir)
    $manifestFile = Join-Path $BackupDir "manifest.json"
    Load-Env

    $timestamp = Split-Path -Leaf $BackupDir

    $manifest = @{
        timestamp = $timestamp
        versions = @{
            camunda = $env:CAMUNDA_VERSION
            elasticsearch = $env:ELASTIC_VERSION
            keycloak = $env:KEYCLOAK_SERVER_VERSION
            postgres = $env:POSTGRES_VERSION
        }
        source_host = $env:HOST
        files = @()
    }

    Get-ChildItem -Path $BackupDir -File | Where-Object { $_.Name -ne "manifest.json" } | ForEach-Object {
        $manifest.files += @{
            name = $_.Name
            sha256 = (Compute-Checksum -File $_.FullName)
        }
    }

    $manifest | ConvertTo-Json -Depth 10 | Set-Content -Path $manifestFile
    Log "Manifest created: $manifestFile"
}

function Verify-Manifest {
    param([string]$BackupDir)
    $manifestFile = Join-Path $BackupDir "manifest.json"

    if (-not (Test-Path $manifestFile)) {
        Log "ERROR: Manifest not found: $manifestFile"
        exit 1
    }

    $manifest = Get-Content $manifestFile | ConvertFrom-Json
    $errors = 0

    foreach ($fileEntry in $manifest.files) {
        $fpath = Join-Path $BackupDir $fileEntry.name
        if (-not (Test-Path $fpath)) {
            Log "ERROR: Missing file: $($fileEntry.name)"
            $errors++
            continue
        }
        $actual = Compute-Checksum -File $fpath
        if ($fileEntry.sha256 -ne $actual) {
            Log "ERROR: Checksum mismatch for $($fileEntry.name) (expected: $($fileEntry.sha256), actual: $actual)"
            $errors++
        }
    }

    if ($errors -gt 0) {
        Log "ERROR: Manifest verification failed with $errors error(s)"
        exit 1
    }

    Log "Manifest verification passed."
}

function Cleanup-OldBackups {
    param([int]$RetentionDays = 7)
    Log "Cleaning up backups older than $RetentionDays days..."

    if (-not (Test-Path $BackupBaseDir)) {
        Log "Backup directory does not exist yet, nothing to clean."
        return
    }

    $cutoff = (Get-Date).AddDays(-$RetentionDays)
    $oldBackups = Get-ChildItem -Path $BackupBaseDir -Directory | Where-Object {
        $_.Name -match '^\d{8}_\d{6}$' -and $_.LastWriteTime -lt $cutoff
    }

    $count = 0
    foreach ($dir in $oldBackups) {
        Log "Removing old backup: $($dir.FullName)"
        Remove-Item -Path $dir.FullName -Recurse -Force
        $count++
    }

    Log "Removed $count old backup(s)."
}

function Acquire-Lock {
    if (-not (Test-Path $BackupBaseDir)) {
        New-Item -ItemType Directory -Path $BackupBaseDir | Out-Null
    }

    if (Test-Path $LockFile) {
        $pidInFile = Get-Content $LockFile -ErrorAction SilentlyContinue
        try {
            $proc = Get-Process -Id $pidInFile -ErrorAction Stop
            Log "ERROR: Another backup/restore process is already running (PID: $pidInFile)"
            exit 2
        }
        catch {
            Log "WARNING: Stale lock file found, removing..."
            Remove-Item $LockFile -Force
        }
    }

    $PID | Set-Content -Path $LockFile
    Log "Lock acquired: $LockFile"
}

function Release-Lock {
    if (Test-Path $LockFile) {
        Remove-Item $LockFile -Force
        Log "Lock released."
    }
}

function Cleanup-OnError {
    if ($?) { return }
    Log "ERROR: Script failed."
    Release-Lock
}
