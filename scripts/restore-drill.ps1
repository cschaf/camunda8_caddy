param(
    [Parameter(ValueFromRemainingArguments=$true)]
    [string[]]$CliArgs
)

$ErrorActionPreference = "Stop"

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$ProjectDir = Resolve-Path (Join-Path $ScriptDir "..")

. (Join-Path $ScriptDir "lib\drill-common.ps1")

function Show-Usage {
    Write-Host "Usage: $(Split-Path -Leaf $PSCommandPath) [backup-directory]"
    Write-Host ""
    Write-Host "Arguments:"
    Write-Host "  backup-directory   Path to backup directory (default: most recent under backups\)"
    Write-Host ""
    Write-Host "Environment:"
    Write-Host "  DRILL_PORT_OFFSET       Port offset for drill stack (default: 10000)"
    Write-Host "  DRILL_HOST              Hostname for drill stack (default: drill.localhost)"
    Write-Host "  DRILL_PROJECT_NAME      Compose project name (default: camunda-restoredrill)"
    Write-Host "  DRILL_KNOWN_PROJECT_ID  Optional project ID for smoke-test API check"
    exit 0
}

if ($CliArgs.Count -gt 0 -and ($CliArgs[0] -in "-h","--help")) {
    Show-Usage
}

$BackupDir = $null
if ($CliArgs.Count -gt 0) {
    $BackupDir = $CliArgs[0]
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
    Teardown-DrillStack
}
