param(
    [Parameter(ValueFromRemainingArguments=$true)]
    [string[]]$CliArgs
)

$ErrorActionPreference = "Stop"

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$ProjectDir = Resolve-Path (Join-Path $ScriptDir "..")

. (Join-Path $ScriptDir "lib\drill-common.ps1")

function Show-Usage {
    Write-Host "Usage: $(Split-Path -Leaf $PSCommandPath) [OPTIONS] [backup-directory]"
    Write-Host ""
    Write-Host "Arguments:"
    Write-Host "  backup-directory   Path to backup directory (default: most recent under backups\)"
    Write-Host ""
    Write-Host "Options:"
    Write-Host "  --keep            Keep the drill stack running after completion or failure"
    Write-Host "  -h, --help        Show this help message"
    Write-Host ""
    Write-Host "Environment:"
    Write-Host "  DRILL_PORT_OFFSET       Port offset for drill stack (default: 10000)"
    Write-Host "  DRILL_HOST              Hostname for drill stack (default: drill.localhost)"
    Write-Host "  DRILL_PROJECT_NAME      Compose project name (default: camunda-restoredrill)"
    Write-Host "  DRILL_KNOWN_PROJECT_ID  Optional project ID for smoke-test API check"
    exit 0
}

$Keep = $false
$BackupDir = $null

$i = 0
while ($i -lt $CliArgs.Count) {
    $arg = $CliArgs[$i]
    switch ($arg) {
        "--keep" { $Keep = $true; $i++; break }
        { $_ -in "-h","--help" } { Show-Usage }
        default {
            if (-not $BackupDir) {
                $BackupDir = $arg
            } else {
                Write-Host "Unexpected argument: $arg"
                Show-Usage
            }
            $i++
        }
    }
}

if (-not $BackupDir) {
    $backupBase = Join-Path $ProjectDir "backups"
    $candidate = Get-ChildItem -Path $backupBase -Directory -ErrorAction SilentlyContinue | Where-Object { $_.Name -match '^\d{8}_\d{6}$' } | Sort-Object Name | Select-Object -Last 1
    if ($candidate) {
        $BackupDir = $candidate.FullName
    }
}

if (-not $BackupDir -or -not (Test-Path $BackupDir)) {
    Log-Drill "ERROR: No backup directory found."
    exit 1
}

$BackupDir = Resolve-Path $BackupDir
Log-Drill "Backup directory: $BackupDir"

try {
    Generate-DrillEnv
    Run-DrillStackUp -BackupDir $BackupDir
    $smokeOk = Run-SmokeTests
    if (-not $smokeOk) {
        Log-Drill "ERROR: Smoke tests failed."
        exit 1
    }
    Log-Drill "Restore drill completed successfully."
}
finally {
    if ($Keep) {
        Log-Drill "Keeping drill stack running for manual inspection (port offset: ${DrillPortOffset})"
        Log-Drill "Teardown later with: docker compose -p ${DrillProjectName} down --volumes --remove-orphans"
    } else {
        Teardown-DrillStack
    }
}
