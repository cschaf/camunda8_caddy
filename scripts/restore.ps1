param(
    [Parameter(ValueFromRemainingArguments = $true)]
    [string[]]$CliArgs
)

$ErrorActionPreference = "Stop"

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$ProjectDir = Resolve-Path (Join-Path $ScriptDir "..")

# Pre-parse --env-file so backup-common.ps1 can honor it
$EnvFile = Join-Path $ProjectDir ".env"
for ($i = 0; $i -lt $CliArgs.Count; $i++) {
    if ($CliArgs[$i] -eq "--env-file" -and ($i + 1) -lt $CliArgs.Count) {
        $EnvFile = $CliArgs[$i + 1]
        $before = if ($i -gt 0) { $CliArgs[0..($i-1)] } else { @() }
        $after = if (($i + 2) -lt $CliArgs.Count) { $CliArgs[($i+2)..($CliArgs.Count-1)] } else { @() }
        $CliArgs = $before + $after
        break
    }
}

. (Join-Path $ScriptDir "lib\backup-common.ps1")

$BackupDir = ""
$Force = $false
$DryRun = $false
$CrossCluster = $false
$TestMode = $false
$CreatePreBackup = $true
$DeprecatedCreateBackupUsed = $false
$DecryptArchive = ""
$RehostKeycloak = $false
$RestoreComponents = "all"
$RestoreAll = $false
$RestoreKeycloak = $false
$RestoreWebmodeler = $false
$RestoreElasticsearch = $false
$RestoreOrchestration = $false
$RestoreConfigs = $false

function Show-Usage {
    Write-Host "Usage: $(Split-Path -Leaf $PSCommandPath) [OPTIONS] <backup-directory>"
    Write-Host ""
    Write-Host "Arguments:"
    Write-Host "  backup-directory   Path to backup directory (e.g., backups\20240115_120000)"
    Write-Host ""
    Write-Host "Options:"
    Write-Host "  --force           Skip all prompts"
    Write-Host "  --dry-run         Show what would be done without executing"
    Write-Host "  --cross-cluster   Enable cross-cluster restore (skips config overwrite)"
    Write-Host "  --no-pre-backup   Do not create a rollback backup before restoring"
    Write-Host "  --create-backup   Deprecated; pre-restore backups are enabled by default"
    Write-Host "  --decrypt FILE    Decrypt a .tar.gz.gpg or .tar.gz.age backup archive before restore"
    Write-Host "  --rehost-keycloak Patch restored Keycloak clients to the current HOST and local client secrets"
    Write-Host "  --components LIST Restore only selected components"
    Write-Host "                    Allowed: all,keycloak,webmodeler,elasticsearch,orchestration,configs"
    Write-Host "                    Example: --components keycloak,webmodeler"
    Write-Host "  --verify          Verify backup integrity without restoring"
    Write-Host "  --env-file FILE   Use a custom env file instead of .env"
    Write-Host "  -h, --help        Show this help message"
    exit 0
}

function Parse-Args {
    param([string[]]$CliArgs)
    for ($i = 0; $i -lt $CliArgs.Count; $i++) {
        $arg = $CliArgs[$i]
        switch ($arg) {
            "--force" { $script:Force = $true; break }
            "--dry-run" { $script:DryRun = $true; break }
            "--cross-cluster" { $script:CrossCluster = $true; break }
            "--create-backup" { $script:CreatePreBackup = $true; $script:DeprecatedCreateBackupUsed = $true; break }
            "--createBackup" { $script:CreatePreBackup = $true; $script:DeprecatedCreateBackupUsed = $true; break }
            "--no-pre-backup" { $script:CreatePreBackup = $false; break }
            "--decrypt" {
                if (($i + 1) -ge $CliArgs.Count) {
                    Write-Host "ERROR: --decrypt requires an encrypted archive path"
                    Show-Usage
                }
                $i++
                $script:DecryptArchive = $CliArgs[$i]
                break
            }
            "--rehost-keycloak" { $script:RehostKeycloak = $true; break }
            "--components" {
                if (($i + 1) -ge $CliArgs.Count) {
                    Write-Host "ERROR: --components requires a comma-separated list"
                    Show-Usage
                }
                $i++
                $script:RestoreComponents = $CliArgs[$i]
                break
            }
            "--verify" { $script:TestMode = $true; break }
            "--test" { $script:TestMode = $true; break }
            "--env-file" { $i++; break }
            { $_ -in "-h","--help" } { Show-Usage }
            { $_.StartsWith("-") } {
                Write-Host "Unknown option: $arg"
                Show-Usage
            }
            default {
                if (-not $script:BackupDir) {
                    $script:BackupDir = $arg
                } else {
                    Write-Host "Unexpected argument: $arg"
                    Show-Usage
                }
            }
        }
    }
}

function Expand-EncryptedBackupArchive {
    param([string]$Archive)

    if (-not [System.IO.Path]::IsPathRooted($Archive)) {
        $Archive = Join-Path $ProjectDir $Archive
    }
    if (-not (Test-Path $Archive)) {
        Log "ERROR: Encrypted backup archive not found: $Archive"
        exit 1
    }

    $archiveName = Split-Path -Leaf $Archive
    $stem = $archiveName -replace '\.tar\.gz\.gpg$', ''
    $stem = $stem -replace '\.tar\.gz\.age$', ''
    $destParent = Join-Path $BackupBaseDir "decrypted-${stem}-$(Get-Date -Format 'yyyyMMdd_HHmmss')"
    New-Item -ItemType Directory -Path $destParent -Force | Out-Null
    $tmpTar = Join-Path $destParent "archive.tar.gz"

    if ($Archive -like "*.tar.gz.gpg") {
        if (-not (Get-Command gpg -ErrorAction SilentlyContinue)) {
            Log "ERROR: --decrypt requires gpg for $Archive"
            exit 1
        }
        Log "Decrypting gpg backup archive: $Archive"
        gpg --batch --yes --decrypt --output $tmpTar $Archive | Out-Null
        if ($LASTEXITCODE -ne 0) {
            Log "ERROR: gpg decryption failed"
            exit 1
        }
    }
    elseif ($Archive -like "*.tar.gz.age") {
        if (-not (Get-Command age -ErrorAction SilentlyContinue)) {
            Log "ERROR: --decrypt requires age for $Archive"
            exit 1
        }
        Log "Decrypting age backup archive: $Archive"
        age -d -o $tmpTar $Archive | Out-Null
        if ($LASTEXITCODE -ne 0) {
            Log "ERROR: age decryption failed"
            exit 1
        }
    }
    else {
        Log "ERROR: --decrypt supports only .tar.gz.gpg and .tar.gz.age files"
        exit 1
    }

    tar xzf $tmpTar -C $destParent
    if ($LASTEXITCODE -ne 0) {
        Log "ERROR: Could not extract decrypted backup archive"
        exit 1
    }
    Remove-Item -Path $tmpTar -Force -ErrorAction SilentlyContinue

    $extractedDir = Get-ChildItem -Path $destParent -Directory | Sort-Object Name | Select-Object -First 1
    if (-not $extractedDir) {
        Log "ERROR: Decrypted archive did not contain a backup directory"
        exit 1
    }
    Log "Decrypted backup extracted to: $($extractedDir.FullName)"
    return $extractedDir.FullName
}

function Invoke-KeycloakRehost {
    if (-not $env:HOST) {
        Log "ERROR: HOST is required for --rehost-keycloak"
        exit 1
    }

    $sqlFile = Join-Path $ScriptDir "rehost-keycloak.sql"
    if (-not (Test-Path $sqlFile)) {
        Log "ERROR: Keycloak rehost SQL not found: $sqlFile"
        exit 1
    }

    Log "Rehosting Keycloak clients to HOST=$($env:HOST)..."
    Get-Content $sqlFile -Raw | docker exec -i postgres psql `
        -U "$env:POSTGRES_USER" `
        -d "$env:POSTGRES_DB" `
        -v "host=$($env:HOST)" `
        -v "connectors_secret=$($env:CONNECTORS_CLIENT_SECRET)" `
        -v "console_secret=$($env:CONSOLE_CLIENT_SECRET)" `
        -v "orchestration_secret=$($env:ORCHESTRATION_CLIENT_SECRET)" `
        -v "optimize_secret=$($env:OPTIMIZE_CLIENT_SECRET)" `
        -v "identity_secret=$($env:CAMUNDA_IDENTITY_CLIENT_SECRET)" | Out-Null
    if ($LASTEXITCODE -ne 0) {
        Log "ERROR: Keycloak rehost failed"
        exit 1
    }
    Log "Keycloak clients rehosted for HOST=$($env:HOST)."
}

function Set-RestoreComponents {
    $script:RestoreAll = $false
    $script:RestoreKeycloak = $false
    $script:RestoreWebmodeler = $false
    $script:RestoreElasticsearch = $false
    $script:RestoreOrchestration = $false
    $script:RestoreConfigs = $false

    $normalized = ($script:RestoreComponents.ToLowerInvariant() -replace '\s+', '')
    if (-not $normalized -or $normalized -eq "all") {
        $script:RestoreAll = $true
        $script:RestoreKeycloak = $true
        $script:RestoreWebmodeler = $true
        $script:RestoreElasticsearch = $true
        $script:RestoreOrchestration = $true
        $script:RestoreConfigs = $true
        $script:RestoreComponents = "all"
        return
    }

    foreach ($component in ($normalized -split ',')) {
        switch ($component) {
            "keycloak" { $script:RestoreKeycloak = $true }
            { $_ -in "webmodeler","web-modeler" } { $script:RestoreWebmodeler = $true }
            { $_ -in "elasticsearch","elastic" } { $script:RestoreElasticsearch = $true }
            { $_ -in "orchestration","zeebe" } { $script:RestoreOrchestration = $true }
            { $_ -in "configs","config","configuration" } { $script:RestoreConfigs = $true }
            "all" {
                $script:RestoreAll = $true
                $script:RestoreKeycloak = $true
                $script:RestoreWebmodeler = $true
                $script:RestoreElasticsearch = $true
                $script:RestoreOrchestration = $true
                $script:RestoreConfigs = $true
                $script:RestoreComponents = "all"
                return
            }
            default {
                Write-Host "ERROR: Unknown restore component: $component"
                Show-Usage
            }
        }
    }

    $script:RestoreComponents = $normalized
}

function Assert-CrossClusterVersion {
    param(
        [string]$Label,
        [string]$BackupVersion,
        [string]$CurrentVersion
    )

    if (-not $BackupVersion) {
        Log "ERROR: $Label version not found in manifest. Cannot verify cross-cluster compatibility."
        exit 1
    }
    if (-not $CurrentVersion) {
        Log "ERROR: $Label version not found in current environment. Cannot verify cross-cluster compatibility."
        exit 1
    }

    $backupMajorMinor = Get-SemverMajorMinor -Version $BackupVersion
    $currentMajorMinor = Get-SemverMajorMinor -Version $CurrentVersion
    if (-not $backupMajorMinor -or -not $currentMajorMinor) {
        Log "ERROR: $Label version is not a supported semantic version. Backup: $BackupVersion, Current: $CurrentVersion"
        exit 1
    }

    if ($backupMajorMinor -ne $currentMajorMinor) {
        Log "ERROR: $Label major.minor version mismatch. Backup: $BackupVersion, Current: $CurrentVersion"
        exit 1
    }
    if ($BackupVersion -ne $CurrentVersion) {
        Log "WARNING: $Label patch version differs. Backup: $BackupVersion, Current: $CurrentVersion"
    }
}

function Get-ComposeServiceHealthStatus {
    param([string]$Service)
    $cmd = Get-DockerComposeCmd

    try {
        $info = Invoke-Expression "$cmd ps `"$Service`" --format json" | ConvertFrom-Json
        if ($info -is [System.Array]) { $info = $info | Select-Object -First 1 }
        $status = $info.Health
        if (-not $status) { $status = $info.State }
        if ($status) { return $status }
    }
    catch { }
    return "unknown"
}

function Test-ServiceReadiness {
    param([string]$Service)

    switch ($Service) {
        "postgres" {
            docker exec postgres pg_isready -U "$env:POSTGRES_USER" *> $null
            return ($LASTEXITCODE -eq 0)
        }
        "web-modeler-db" {
            docker exec web-modeler-db pg_isready -U "$env:WEBMODELER_DB_USER" *> $null
            return ($LASTEXITCODE -eq 0)
        }
        "elasticsearch" {
            try {
                Invoke-RestMethod -Uri "http://localhost:9200/_cluster/health?wait_for_status=yellow&timeout=5s" -TimeoutSec 6 | Out-Null
                return $true
            }
            catch { return $false }
        }
        "orchestration" {
            try {
                Invoke-RestMethod -Uri "http://localhost:8088/actuator/health/readiness" -TimeoutSec 6 | Out-Null
                return $true
            }
            catch { return $false }
        }
        default { return $false }
    }
}

function Wait-ForService {
    param([string]$Service)
    $timeout = 300
    if ($env:RESTORE_HEALTH_TIMEOUT) {
        if (-not [int]::TryParse($env:RESTORE_HEALTH_TIMEOUT, [ref]$timeout) -or $timeout -le 0) {
            Log "ERROR: RESTORE_HEALTH_TIMEOUT must be a positive integer (got: $($env:RESTORE_HEALTH_TIMEOUT))"
            return $false
        }
    }
    $delay = 5
    $deadline = (Get-Date).AddSeconds($timeout)

    Log "Waiting up to ${timeout}s for $Service to be healthy..."
    while ((Get-Date) -le $deadline) {
        $status = Get-ComposeServiceHealthStatus -Service $Service
        if ($status -eq "healthy") {
            Log "$Service is healthy according to Docker Compose."
            return $true
        }
        if (Test-ServiceReadiness -Service $Service) {
            Log "$Service is ready according to direct readiness check."
            return $true
        }
        Start-Sleep -Seconds $delay
    }

    Log "ERROR: $Service did not become healthy within $timeout seconds"
    return $false
}

function Test-ArchiveSafePaths {
    param([string]$ArchivePath)

    $entries = tar tzf $ArchivePath 2>$null
    if ($LASTEXITCODE -ne 0) {
        Log "ERROR: Archive is not readable: $ArchivePath"
        exit 1
    }

    foreach ($entry in $entries) {
        $normalized = ($entry -replace '\\', '/')
        if ($normalized.StartsWith("/") -or $normalized -eq ".." -or $normalized.StartsWith("../") -or $normalized.Contains("/../")) {
            Log "ERROR: Unsafe tar path in ${ArchivePath}: $entry"
            exit 1
        }
    }
}

function Validate-RestoreInputs {
    param([string]$BackupDir)

    Log "Validating required restore artifacts..."
    $requiredFiles = @("manifest.json")
    if ($RestoreConfigs) { $requiredFiles += "configs.tar.gz" }
    if ($RestoreKeycloak) { $requiredFiles += "keycloak.sql.gz" }
    if ($RestoreWebmodeler) { $requiredFiles += "webmodeler.sql.gz" }
    if ($RestoreOrchestration) { $requiredFiles += "orchestration.tar.gz" }
    if ($RestoreElasticsearch) { $requiredFiles += "snapshot-info.json" }

    $missing = $false
    foreach ($rel in $requiredFiles) {
        $path = Join-Path $BackupDir $rel
        if (-not (Test-Path $path) -or (Get-Item $path).Length -eq 0) {
            Log "ERROR: Required backup artifact missing or empty: $rel"
            $missing = $true
        }
    }

    if ($RestoreElasticsearch) {
        $esBackupDir = Join-Path $BackupDir "elasticsearch"
        if (-not (Test-Path $esBackupDir) -or -not (Get-ChildItem -Path $esBackupDir -Recurse -File -ErrorAction SilentlyContinue | Select-Object -First 1)) {
            Log "ERROR: Required Elasticsearch snapshot directory is missing or empty: elasticsearch\"
            $missing = $true
        }
    }

    if ($missing) {
        exit 1
    }

    if ($RestoreKeycloak) {
        gzip -t (Join-Path $BackupDir "keycloak.sql.gz")
        if ($LASTEXITCODE -ne 0) { Log "ERROR: Keycloak dump is not valid gzip"; exit 1 }
    }

    if ($RestoreWebmodeler) {
        gzip -t (Join-Path $BackupDir "webmodeler.sql.gz")
        if ($LASTEXITCODE -ne 0) { Log "ERROR: Web Modeler dump is not valid gzip"; exit 1 }
    }

    if ($RestoreOrchestration) { Test-ArchiveSafePaths -ArchivePath (Join-Path $BackupDir "orchestration.tar.gz") }
    if ($RestoreConfigs) { Test-ArchiveSafePaths -ArchivePath (Join-Path $BackupDir "configs.tar.gz") }

    if ($RestoreElasticsearch) {
      try {
        $snapshotInfo = Get-Content (Join-Path $BackupDir "snapshot-info.json") -Raw | ConvertFrom-Json
        if (-not $snapshotInfo.snapshot -or $snapshotInfo.snapshot.state -ne "SUCCESS") {
            Log "ERROR: Snapshot state is not SUCCESS: $($snapshotInfo.snapshot.state)"
            exit 1
        }
        if (-not ($snapshotInfo.snapshot.name -or $snapshotInfo.snapshot.snapshot)) {
            Log "ERROR: Snapshot name missing from snapshot-info.json"
            exit 1
        }
    }
    catch {
        Log "ERROR: Elasticsearch snapshot metadata is not restorable: $_"
        exit 1
    }
    }

    Log "Required restore artifacts validated."
}

function Main {
    param([string[]]$CliArgs)

    Parse-Args -CliArgs $CliArgs
    Set-RestoreComponents

    if ($DecryptArchive) {
        $script:BackupDir = Expand-EncryptedBackupArchive -Archive $DecryptArchive
    }

    if (-not $BackupDir) {
        Write-Host "ERROR: Backup directory is required."
        Show-Usage
    }

    # Resolve relative path
    if (-not [System.IO.Path]::IsPathRooted($BackupDir)) {
        $BackupDir = Join-Path $ProjectDir $BackupDir
    }

    if (-not (Test-Path $BackupDir)) {
        Log "ERROR: Backup directory not found: $BackupDir"
        exit 1
    }

    Load-Env
    $stage = Get-Stage
    $cmd = Get-DockerComposeCmd
    $restoreStartedAt = Get-RestoreStartTimestamp

    $Global:LogFile = Join-Path $BackupDir "restore.log"
    New-Item -ItemType Directory -Path $BackupBaseDir -Force | Out-Null
    Acquire-Lock
    $stackDownForRestore = $false
    $preRestoreBackupPath = ""
    try {
        Log "Starting restore from: $BackupDir"
        Log "Stage: $stage"
        Log "Restore components: $RestoreComponents"
        if ($RehostKeycloak) { Log "Keycloak rehost: enabled" }
        if ($DeprecatedCreateBackupUsed) { Log "WARNING: --create-backup is deprecated; pre-restore backups are now created by default. Use --no-pre-backup to opt out." }

        # Pre-flight checks
        Log "Running pre-flight checks..."

        $manifestFile = Join-Path $BackupDir "manifest.json"
        if (-not (Test-Path $manifestFile)) {
            Log "ERROR: Manifest not found in backup directory"
            exit 1
        }

        if ($TestMode) {
            Log "=== TEST MODE: Verifying backup integrity ==="
            Verify-Manifest -BackupDir $BackupDir
            Validate-RestoreInputs -BackupDir $BackupDir
            Log "=== TEST MODE complete. Backup integrity verified. ==="
            exit 0
        }

        Verify-Manifest -BackupDir $BackupDir
        Validate-RestoreInputs -BackupDir $BackupDir

        if ($RehostKeycloak -and -not $RestoreKeycloak) {
            Log "ERROR: --rehost-keycloak requires the keycloak component to be restored."
            exit 1
        }

        $manifest = Get-Content $manifestFile | ConvertFrom-Json
        $sourceHost = $manifest.source_host
        $manifestElasticVersion = $manifest.versions.elasticsearch
        $manifestCamundaVersion = $manifest.versions.camunda

        # Cross-cluster checks
        if ($CrossCluster) {
            Log "Cross-cluster restore mode enabled."

            Assert-CrossClusterVersion -Label "Elasticsearch" -BackupVersion $manifestElasticVersion -CurrentVersion $env:ELASTIC_VERSION
            Assert-CrossClusterVersion -Label "Camunda" -BackupVersion $manifestCamundaVersion -CurrentVersion $env:CAMUNDA_VERSION

            if ($sourceHost -and $sourceHost -ne $env:HOST) {
                Log "WARNING: Source host mismatch. Backup from: $sourceHost, Current: $($env:HOST)"
            }
        }

        # Host mismatch warning
        if (-not $CrossCluster -and $sourceHost -and $sourceHost -ne $env:HOST) {
            Log "WARNING: This backup was created on a different host ($sourceHost)."
            Log "WARNING: Config restore may contain incorrect hostnames."
        }

        # Interactive warning
        if (-not $Force -and -not $DryRun) {
            Write-Host ""
            if ($RestoreAll) {
                Write-Host "WARNING: This will OVERWRITE ALL current data in the Camunda stack!"
            } else {
                Write-Host "WARNING: This will OVERWRITE selected Camunda data only: $RestoreComponents"
                Write-Host "Granular restores do not guarantee a globally consistent stack timestamp."
            }
            Write-Host "Backup: $BackupDir"
            Write-Host ""
            $response = Read-Host "Are you sure you want to continue? [y/N]"
            if ($response -notmatch '^[Yy]$') {
                Log "Restore aborted by user."
                exit 0
            }
        }
        elseif ($DryRun) {
            Log "=== DRY RUN MODE: Showing what would be done ==="
        }

        # Pre-restore backup
        if ($CreatePreBackup -and -not $DryRun -and -not $TestMode) {
            Release-Lock
            Log "Creating pre-restore backup of current state..."
            $preRestoreLog = Join-Path $BackupBaseDir "pre-restore-backup.log"
            try {
                & "$PSScriptRoot\backup.ps1" > $preRestoreLog 2>&1
                Log "Pre-restore backup completed. Log: $preRestoreLog"
                $preRestoreBackupPath = Get-Content $preRestoreLog -ErrorAction SilentlyContinue |
                    Select-String -Pattern "Backup completed successfully:" |
                    Select-Object -Last 1 |
                    ForEach-Object { $_.Line -replace '^.*Backup completed successfully: ', '' }
            }
            catch {
                Log "ERROR: Pre-restore backup failed. Aborting restore. Log: $preRestoreLog"
                Acquire-Lock
                exit 1
            }
            Acquire-Lock
        }
        elseif (-not $CreatePreBackup) {
            Log "Pre-restore backup disabled by --no-pre-backup."
        }

        # Collect pre-restore Elasticsearch state for later comparison
        $stateBefore = Join-Path $BackupDir "restore-state-before.json"
        $stateAfter  = Join-Path $BackupDir "restore-state-after.json"
        if ($DryRun) {
            if ($RestoreElasticsearch) { Log "[DRY-RUN] Would collect Elasticsearch state (before)" }
        }
        elseif ($RestoreElasticsearch) {
            try { Collect-ESState -Phase "before" -OutputFile $stateBefore } catch { Log "WARNING: Pre-restore state collection failed: $_" }
        }

        # Stop stack
        Log "Stopping Camunda stack..."
        if ($DryRun) {
            Log "[DRY-RUN] Would run: $cmd down --remove-orphans"
        }
        else {
            Invoke-Expression "$cmd down --remove-orphans" | Out-Null
            $stackDownForRestore = $true
        }

        # Remove volumes
        Log "Removing data volumes..."
        if ($DryRun) {
            if ($RestoreAll) {
                Log "[DRY-RUN] Would remove volumes: orchestration, elastic, postgres, postgres-web"
            } elseif ($RestoreOrchestration) {
                Log "[DRY-RUN] Would remove volume: orchestration"
            } else {
                Log "[DRY-RUN] Would keep existing Docker data volumes"
            }
            Log "[DRY-RUN] Would keep volume: keycloak-theme"
        }
        else {
            $volumes = @()
            if ($RestoreAll) {
                $volumes = @(
                    (Get-ComposeVolumeName "orchestration"),
                    (Get-ComposeVolumeName "elastic"),
                    (Get-ComposeVolumeName "postgres"),
                    (Get-ComposeVolumeName "postgres-web")
                )
            } elseif ($RestoreOrchestration) {
                $volumes = @((Get-ComposeVolumeName "orchestration"))
            }
            foreach ($vol in $volumes) {
                try {
                    docker volume rm $vol 2>$null | Out-Null
                }
                catch {
                    Log "WARNING: Could not remove volume $vol (may not exist)"
                }
            }
            if ($volumes.Count -gt 0) { Log "Volumes removed." } else { Log "No Docker data volumes removed for granular restore." }
        }

        # Start only the services needed for data restore.
        # Starting the full stack here allows Camunda apps to recreate indices
        # before the Elasticsearch snapshot restore runs.
        Log "Starting core services with fresh volumes..."
        $coreServices = @()
        if ($RestoreKeycloak) { $coreServices += "postgres" }
        if ($RestoreWebmodeler) { $coreServices += "web-modeler-db" }
        if ($RestoreElasticsearch) { $coreServices += "elasticsearch" }
        if ($DryRun) {
            if ($coreServices.Count -gt 0) {
                Log "[DRY-RUN] Would run: $cmd up -d $($coreServices -join ' ')"
            } else {
                Log "[DRY-RUN] No core services needed before data restore"
            }
        }
        else {
            if ($coreServices.Count -gt 0) {
                Invoke-Expression "$cmd up -d $($coreServices -join ' ')" | Out-Null
            }
        }

        # Wait for core services
        if (-not $DryRun) {
            if ($RestoreKeycloak -and -not (Wait-ForService -Service "postgres")) { exit 1 }
            if ($RestoreWebmodeler -and -not (Wait-ForService -Service "web-modeler-db")) { exit 1 }
            if ($RestoreElasticsearch -and -not (Wait-ForService -Service "elasticsearch")) { exit 1 }
            Log "Core services are healthy."
        }
        else {
            if ($coreServices.Count -gt 0) {
                Log "[DRY-RUN] Would wait for services to be healthy: $($coreServices -join ' ')"
            } else {
                Log "[DRY-RUN] No core services to wait for"
            }
        }

        # Restore Keycloak DB
        $keycloakBackup = Join-Path $BackupDir "keycloak.sql.gz"
        if (-not $RestoreKeycloak) {
            Log "Skipping Keycloak database restore."
        } elseif ($DryRun) {
            Log "Restoring Keycloak database..."
            Log "[DRY-RUN] Would restore Keycloak DB from: $keycloakBackup"
            if ($RehostKeycloak) { Log "[DRY-RUN] Would rehost Keycloak clients to HOST=$($env:HOST) and local client secrets" }
            Log "[DRY-RUN] Would run ANALYZE on Keycloak DB"
        }
        else {
            Log "Restoring Keycloak database..."
            if (Test-Path $keycloakBackup) {
                $pgStderrFile = [System.IO.Path]::GetTempFileName()
                $pgRestoreCmd = "gzip -d -c `"$keycloakBackup`" | docker exec -i postgres pg_restore -U `"$env:POSTGRES_USER`" -d `"$env:POSTGRES_DB`" --clean --if-exists"
                Invoke-Expression "$pgRestoreCmd 2>$pgStderrFile" | Out-Null
                if ($LASTEXITCODE -ne 0) {
                    Log "ERROR: Keycloak pg_restore failed (code: $LASTEXITCODE). stderr:"
                    Get-Content $pgStderrFile -ErrorAction SilentlyContinue | ForEach-Object { Log "  $_" }
                    Remove-Item $pgStderrFile -ErrorAction SilentlyContinue
                    exit 1
                }
                Remove-Item $pgStderrFile -ErrorAction SilentlyContinue
                Log "Keycloak database restored."
                if ($RehostKeycloak) {
                    Invoke-KeycloakRehost
                }
                # pg_restore does not restore planner statistics; run ANALYZE so the
                # first queries after restore use good plans instead of waiting for
                # autovacuum (see docs/backup-restore.md).
                Log "Refreshing Keycloak DB planner statistics (ANALYZE)..."
                docker exec postgres psql -U "$env:POSTGRES_USER" -d "$env:POSTGRES_DB" -c "ANALYZE;" 2>$null | Out-Null
                if ($LASTEXITCODE -ne 0) { Log "ERROR: ANALYZE on Keycloak DB failed"; exit 1 }
            }
            else {
                Log "ERROR: Keycloak backup not found."
                exit 1
            }
        }

        # Restore Web Modeler DB
        $webmodelerBackup = Join-Path $BackupDir "webmodeler.sql.gz"
        if (-not $RestoreWebmodeler) {
            Log "Skipping Web Modeler database restore."
        } elseif ($DryRun) {
            Log "Restoring Web Modeler database..."
            Log "[DRY-RUN] Would restore Web Modeler DB from: $webmodelerBackup"
            Log "[DRY-RUN] Would run ANALYZE on Web Modeler DB"
        }
        else {
            Log "Restoring Web Modeler database..."
            if (Test-Path $webmodelerBackup) {
                $pgStderrFile = [System.IO.Path]::GetTempFileName()
                $pgRestoreCmd = "gzip -d -c `"$webmodelerBackup`" | docker exec -i web-modeler-db pg_restore -U `"$env:WEBMODELER_DB_USER`" -d `"$env:WEBMODELER_DB_NAME`" --clean --if-exists"
                Invoke-Expression "$pgRestoreCmd 2>$pgStderrFile" | Out-Null
                if ($LASTEXITCODE -ne 0) {
                    Log "ERROR: Web Modeler pg_restore failed (code: $LASTEXITCODE). stderr:"
                    Get-Content $pgStderrFile -ErrorAction SilentlyContinue | ForEach-Object { Log "  $_" }
                    Remove-Item $pgStderrFile -ErrorAction SilentlyContinue
                    exit 1
                }
                Remove-Item $pgStderrFile -ErrorAction SilentlyContinue
                Log "Web Modeler database restored."
                Log "Refreshing Web Modeler DB planner statistics (ANALYZE)..."
                docker exec web-modeler-db psql -U "$env:WEBMODELER_DB_USER" -d "$env:WEBMODELER_DB_NAME" -c "ANALYZE;" 2>$null | Out-Null
                if ($LASTEXITCODE -ne 0) { Log "ERROR: ANALYZE on Web Modeler DB failed"; exit 1 }
            }
            else {
                Log "ERROR: Web Modeler backup not found."
                exit 1
            }
        }

        # Only core services are running at this point, so no Camunda apps can
        # recreate Elasticsearch indices before the snapshot restore.
        Log "Camunda application services remain stopped until restore is complete."
        if ($DryRun) {
            Log "[DRY-RUN] Would keep orchestration, identity, optimize, console, keycloak, and web-modeler app services stopped"
        }

        # Restore Elasticsearch
        if (-not $RestoreElasticsearch) {
            Log "Skipping Elasticsearch restore."
        } elseif ($DryRun) {
            Log "Restoring Elasticsearch snapshot..."
            Log "[DRY-RUN] Would restore Elasticsearch snapshot"
        }
        else {
            Log "Restoring Elasticsearch snapshot..."
            $snapshotInfoFile = Join-Path $BackupDir "snapshot-info.json"
            $snapshotName = $null
            if (Test-Path $snapshotInfoFile) {
                $snapshotInfo = Get-Content $snapshotInfoFile | ConvertFrom-Json
                if ($snapshotInfo.snapshot) {
                    $snapshotName = $snapshotInfo.snapshot.name
                }
            }
            if (-not $snapshotName) {
                $timestamp = Split-Path -Leaf $BackupDir
                $snapshotName = "snapshot_$timestamp"
            }

            # Copy snapshot data from host backup into the Docker volume before restoring
            $esBackupDir = Join-Path $BackupDir "elasticsearch"
            if (Test-Path $esBackupDir) {
                $esBackupVolume = if ($env:ES_BACKUP_VOLUME) { $env:ES_BACKUP_VOLUME } else { "elastic-backup" }
                Log "Copying snapshot data into Docker volume '$esBackupVolume'..."
                $snapshotCopyScript = @'
set -e
rm -rf /dest/.staging-*
staging="/dest/.staging-$$"
mkdir -p "$staging"
cp -r /source/. "$staging"/
find /dest -mindepth 1 -maxdepth 1 ! -name "$(basename "$staging")" -exec rm -rf {} +
mv "$staging"/* /dest/ 2>/dev/null || true
mv "$staging"/.[!.]* /dest/ 2>/dev/null || true
mv "$staging"/..?* /dest/ 2>/dev/null || true
rmdir "$staging"
'@
                docker run --rm `
                    -v "${esBackupDir}:/source:ro" `
                    -v "${esBackupVolume}:/dest" `
                    alpine sh -c $snapshotCopyScript *>> $Global:LogFile
                if ($LASTEXITCODE -eq 0) {
                    Log "Snapshot data copied to volume '$esBackupVolume'."
                }
                else {
                    Log "ERROR: Could not copy snapshot data to volume"
                    exit 1
                }
            }
            else {
                Log "ERROR: Elasticsearch backup directory not found at $esBackupDir."
                exit 1
            }

            Start-Sleep -Seconds 2

            $esHost = if ($env:ES_HOST) { $env:ES_HOST } else { "localhost" }
            $esPort = if ($env:ES_PORT) { $env:ES_PORT } else { "9200" }
            $esUrl = "http://${esHost}:${esPort}"

            $esRepoBody = '{"type":"fs","settings":{"location":"/usr/share/elasticsearch/backup","compress":true}}'
            try {
                Invoke-RestMethod -Uri "${esUrl}/_snapshot/backup-repo" -Method Put -ContentType "application/json" -Body $esRepoBody | Out-Null
                Log "Elasticsearch snapshot repo registered."
            }
            catch {
                Log "ERROR: Could not register snapshot repo: $_"
                exit 1
            }

            # Verify the snapshot exists BEFORE deleting any indices, so a wrong
            # or incomplete backup directory cannot wipe the live cluster.
            $snapshotExists = $false
            try {
                Invoke-RestMethod -Uri "${esUrl}/_snapshot/backup-repo/$snapshotName" -Method Get | Out-Null
                $snapshotExists = $true
            }
            catch {
                $snapshotExists = $false
            }
            if (-not $snapshotExists) {
                Log "ERROR: Snapshot '$snapshotName' not found in repository. Aborting before deleting any indices."
                exit 1
            }
            Log "Snapshot '$snapshotName' verified in repository."

            # Delete only Camunda-related indices and data streams, matching the
            # scope of what the snapshot restore will recreate. Using explicit
            # per-item deletes avoids needing to relax action.destructive_requires_name.
            $camundaPattern = '^(operate|tasklist|optimize|zeebe|camunda-|\.camunda|\.tasks)'

            Log "Clearing Camunda-related Elasticsearch indices..."
            $indexDeleteFailures = 0
            try {
                $catIndices = Invoke-RestMethod -Uri "${esUrl}/_cat/indices?h=index&expand_wildcards=all&format=json"
                foreach ($row in $catIndices) {
                    $idx = $row.index
                    if ($idx -match $camundaPattern) {
                        try {
                            Invoke-RestMethod -Uri "${esUrl}/$idx" -Method Delete | Out-Null
                        }
                        catch {
                            $indexDeleteFailures++
                            Log "WARNING: Could not delete Elasticsearch index ${idx}: $_"
                        }
                    }
                }
            }
            catch {
                Log "ERROR: Could not list Elasticsearch indices before delete: $_"
                exit 1
            }
            if ($indexDeleteFailures -gt 0) {
                Log "WARNING: $indexDeleteFailures Camunda-related Elasticsearch index delete request(s) failed; verifying remaining indices."
            }

            Log "Verifying deletion of Camunda-related Elasticsearch indices..."
            try {
                $remainingIndices = @(
                    Invoke-RestMethod -Uri "${esUrl}/_cat/indices?h=index&expand_wildcards=all&format=json" |
                        Where-Object { $_.index -match $camundaPattern } |
                        ForEach-Object { $_.index }
                )
            }
            catch {
                Log "ERROR: Could not verify Elasticsearch index deletion: $_"
                exit 1
            }
            if ($remainingIndices.Count -gt 0) {
                Log "ERROR: Camunda-related Elasticsearch indices remain after delete:"
                $remainingIndices | ForEach-Object { Log "  - $_" }
                exit 1
            }
            Log "All target indices cleared."

            Log "Clearing Camunda-related Elasticsearch data streams..."
            $dataStreamDeleteFailures = 0
            try {
                $dsResponse = Invoke-RestMethod -Uri "${esUrl}/_data_stream?expand_wildcards=all"
                if ($dsResponse.data_streams) {
                    foreach ($ds in $dsResponse.data_streams) {
                        if ($ds.name -match $camundaPattern) {
                            try {
                                Invoke-RestMethod -Uri "${esUrl}/_data_stream/$($ds.name)" -Method Delete | Out-Null
                            }
                            catch {
                                $dataStreamDeleteFailures++
                                Log "WARNING: Could not delete Elasticsearch data stream $($ds.name): $_"
                            }
                        }
                    }
                }
            }
            catch {
                Log "ERROR: Could not list Elasticsearch data streams before delete: $_"
                exit 1
            }
            if ($dataStreamDeleteFailures -gt 0) {
                Log "WARNING: $dataStreamDeleteFailures Camunda-related Elasticsearch data stream delete request(s) failed; verifying remaining data streams."
            }

            Log "Verifying deletion of Camunda-related Elasticsearch data streams..."
            try {
                $remainingDataStreams = @()
                $dsVerifyResponse = Invoke-RestMethod -Uri "${esUrl}/_data_stream?expand_wildcards=all"
                if ($dsVerifyResponse.data_streams) {
                    $remainingDataStreams = @(
                        $dsVerifyResponse.data_streams |
                            Where-Object { $_.name -match $camundaPattern } |
                            ForEach-Object { $_.name }
                    )
                }
            }
            catch {
                Log "ERROR: Could not verify Elasticsearch data stream deletion: $_"
                exit 1
            }
            if ($remainingDataStreams.Count -gt 0) {
                Log "ERROR: Camunda-related Elasticsearch data streams remain after delete:"
                $remainingDataStreams | ForEach-Object { Log "  - $_" }
                exit 1
            }
            Log "All target data streams cleared."
            Start-Sleep -Seconds 2

            Log "Restoring snapshot: $snapshotName"
            try {
                $restoreBody = '{"indices":"*,-.logs-*,-.ds-.logs-*,-ilm-history-*,-.ds-ilm-history-*","ignore_unavailable":true,"include_global_state":true}'
                $restoreResponse = Invoke-RestMethod -Uri "${esUrl}/_snapshot/backup-repo/$snapshotName/_restore?wait_for_completion=true" -Method Post -ContentType "application/json" -Body $restoreBody
                if (-not $restoreResponse.snapshot -or $restoreResponse.snapshot.shards.failed -ne 0) {
                    Log "ERROR: Elasticsearch restore failed shards: $($restoreResponse.snapshot.shards.failed)"
                    exit 1
                }
                Log "Elasticsearch snapshot restored successfully."
            }
            catch {
                Log "ERROR: Elasticsearch restore failed: $_"
                exit 1
            }
        }

        # Restore Zeebe state
        $orchBackup = Join-Path $BackupDir "orchestration.tar.gz"
        if (-not $RestoreOrchestration) {
            Log "Skipping Zeebe state restore."
        } elseif ($DryRun) {
            Log "Restoring Zeebe state..."
            Log "[DRY-RUN] Would run: $cmd create orchestration"
            Log "[DRY-RUN] Would restore Zeebe state from: $orchBackup"
        }
        else {
            Log "Restoring Zeebe state..."
            if (Test-Path $orchBackup) {
                $zeebeVol = Get-ComposeVolumeName 'orchestration'
                Invoke-Expression "$cmd create orchestration" *>> $Global:LogFile
                if ($LASTEXITCODE -ne 0) {
                    Log "ERROR: docker compose create orchestration failed"
                    throw "docker compose create orchestration failed"
                }
                docker volume inspect $zeebeVol *>> $Global:LogFile
                if ($LASTEXITCODE -ne 0) {
                    Log "ERROR: Zeebe volume '$zeebeVol' missing after compose create"
                    throw "Zeebe volume '$zeebeVol' missing after compose create"
                }
                docker run --rm `
                    -v "${zeebeVol}:/data" `
                    -v "${BackupDir}:/backup" `
                    alpine sh -c "cd /data && tar xzf /backup/orchestration.tar.gz"
                Log "Zeebe state restored."
            }
            else {
                Log "ERROR: Orchestration backup not found."
                exit 1
            }
        }

        # Restore configs
        if (-not $RestoreConfigs) {
            Log "Skipping configuration restore."
        } elseif ($CrossCluster) {
            Log "Cross-cluster mode: configs will NOT be overwritten."
            Log "Extracting configs to restored-configs/ for reference..."
            $configArchive = Join-Path $BackupDir "configs.tar.gz"
            if (-not $DryRun -and (Test-Path $configArchive)) {
                $restoredConfigsDir = Join-Path $BackupDir "restored-configs"
                New-Item -ItemType Directory -Path $restoredConfigsDir -Force | Out-Null
                tar xzf $configArchive -C $restoredConfigsDir
                Log "Configs extracted to: $restoredConfigsDir"
            }
        }
        else {
            Log "Restoring configuration files..."
            $configArchive = Join-Path $BackupDir "configs.tar.gz"
            if ($DryRun) {
                Log "[DRY-RUN] Would extract configs.tar.gz to project root"
            }
            else {
                if (Test-Path $configArchive) {
                    tar xzf $configArchive -C $ProjectDir
                    Log "Configuration files restored."
                }
                else {
                    Log "ERROR: Config backup not found."
                    exit 1
                }
            }
        }

        # Restart stack
        Log "Restarting stack..."
        if ($DryRun) {
            Log "[DRY-RUN] Would run: $cmd up -d"
        }
        else {
            Invoke-Expression "$cmd up -d" | Out-Null
            $stackDownForRestore = $false
            Start-Sleep -Seconds 5
        }

        # Health check
        Log "Waiting for all services to be healthy..."
        if ($DryRun) {
            Log "[DRY-RUN] Would check service health"
            Log "=== DRY RUN complete ==="
        }
        else {
            Start-Sleep -Seconds 10
            if (-not (Check-ServicesHealth)) {
                Log "ERROR: Some services are not healthy yet. Check with: docker compose ps"
                exit 1
            }

            # Collect post-restore state and compare to pre-restore state
            if ($RestoreElasticsearch) {
                try { Collect-ESState -Phase "after" -OutputFile $stateAfter } catch { Log "WARNING: Post-restore state collection failed: $_" }
                try { Compare-ESState -BeforeFile $stateBefore -AfterFile $stateAfter } catch { Log "WARNING: State comparison failed: $_" }
            }
            try { Cleanup-DanglingComposeVolumes -RestoreStartedAt $restoreStartedAt } catch { Log "WARNING: Dangling volume cleanup failed: $_" }

            Log "Restore completed successfully."
        }
    }
    finally {
        if ($stackDownForRestore) {
            Log "Attempting to restart stack after restore failure..."
            try { Invoke-Expression "$cmd up -d" *>> $Global:LogFile } catch { }
            if ($preRestoreBackupPath) {
                Log "ERROR: Restore failed. Stack may be inconsistent. Pre-restore backup stored at $preRestoreBackupPath; run: scripts/restore.ps1 --force $preRestoreBackupPath"
            }
            else {
                Log "ERROR: Restore failed. Stack may be inconsistent. Pre-restore backup unavailable; no rollback backup was created or its path could not be determined."
            }
        }
        Release-Lock
    }
}

Main -CliArgs $CliArgs
