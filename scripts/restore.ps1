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
$CreateBackup = $false

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
    Write-Host "  --create-backup   Create a fresh backup before restoring"
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
            "--create-backup" { $script:CreateBackup = $true; break }
            "--createBackup" { $script:CreateBackup = $true; break }
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

function Wait-ForService {
    param([string]$Service)
    $cmd = Get-DockerComposeCmd
    $retries = 60
    $delay = 5

    Log "Waiting for $Service to be healthy..."
    for ($i = 1; $i -le $retries; $i++) {
        try {
            $info = Invoke-Expression "$cmd ps `"$Service`" --format json" | ConvertFrom-Json
            $status = $info.Health
            if (-not $status) { $status = $info.State }
            if ($status -eq "healthy") {
                Log "$Service is healthy."
                return $true
            }
        }
        catch { }
        Start-Sleep -Seconds $delay
    }

    Log "ERROR: $Service did not become healthy within $($retries * $delay) seconds"
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
    $requiredFiles = @(
        "manifest.json",
        "configs.tar.gz",
        "keycloak.sql.gz",
        "webmodeler.sql.gz",
        "orchestration.tar.gz",
        "snapshot-info.json"
    )

    $missing = $false
    foreach ($rel in $requiredFiles) {
        $path = Join-Path $BackupDir $rel
        if (-not (Test-Path $path) -or (Get-Item $path).Length -eq 0) {
            Log "ERROR: Required backup artifact missing or empty: $rel"
            $missing = $true
        }
    }

    $esBackupDir = Join-Path $BackupDir "elasticsearch"
    if (-not (Test-Path $esBackupDir) -or -not (Get-ChildItem -Path $esBackupDir -Recurse -File -ErrorAction SilentlyContinue | Select-Object -First 1)) {
        Log "ERROR: Required Elasticsearch snapshot directory is missing or empty: elasticsearch\"
        $missing = $true
    }

    if ($missing) {
        exit 1
    }

    gzip -t (Join-Path $BackupDir "keycloak.sql.gz")
    if ($LASTEXITCODE -ne 0) { Log "ERROR: Keycloak dump is not valid gzip"; exit 1 }

    gzip -t (Join-Path $BackupDir "webmodeler.sql.gz")
    if ($LASTEXITCODE -ne 0) { Log "ERROR: Web Modeler dump is not valid gzip"; exit 1 }

    Test-ArchiveSafePaths -ArchivePath (Join-Path $BackupDir "orchestration.tar.gz")
    Test-ArchiveSafePaths -ArchivePath (Join-Path $BackupDir "configs.tar.gz")

    try {
        $snapshotInfo = Get-Content (Join-Path $BackupDir "snapshot-info.json") -Raw | ConvertFrom-Json
        if (-not $snapshotInfo.snapshot -or $snapshotInfo.snapshot.state -ne "SUCCESS") {
            Log "ERROR: Snapshot state is not SUCCESS: $($snapshotInfo.snapshot.state)"
            exit 1
        }
        if (-not $snapshotInfo.snapshot.name) {
            Log "ERROR: Snapshot name missing from snapshot-info.json"
            exit 1
        }
    }
    catch {
        Log "ERROR: Elasticsearch snapshot metadata is not restorable: $_"
        exit 1
    }

    Log "Required restore artifacts validated."
}

function Main {
    param([string[]]$CliArgs)

    Parse-Args -CliArgs $CliArgs

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
    try {
        Log "Starting restore from: $BackupDir"
        Log "Stage: $stage"

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

        $manifest = Get-Content $manifestFile | ConvertFrom-Json
        $sourceHost = $manifest.source_host
        $manifestElasticVersion = $manifest.versions.elasticsearch
        $manifestCamundaVersion = $manifest.versions.camunda

        # Cross-cluster checks
        if ($CrossCluster) {
            Log "Cross-cluster restore mode enabled."

            if ($manifestElasticVersion) {
                if ($manifestElasticVersion -ne $env:ELASTIC_VERSION) {
                    Log "ERROR: Elasticsearch version mismatch. Backup: $manifestElasticVersion, Current: $($env:ELASTIC_VERSION)"
                    exit 1
                }
            } else {
                Log "ERROR: Elasticsearch version not found in manifest. Cannot verify cross-cluster compatibility."
                exit 1
            }

            if ($manifestCamundaVersion) {
                if ($manifestCamundaVersion -ne $env:CAMUNDA_VERSION) {
                    Log "ERROR: Camunda version mismatch. Backup: $manifestCamundaVersion, Current: $($env:CAMUNDA_VERSION)"
                    exit 1
                }
            } else {
                Log "ERROR: Camunda version not found in manifest. Cannot verify cross-cluster compatibility."
                exit 1
            }

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
            Write-Host "WARNING: This will OVERWRITE ALL current data in the Camunda stack!"
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
        if ($CreateBackup -and -not $DryRun -and -not $TestMode) {
            Release-Lock
            Log "Creating pre-restore backup of current state..."
            $preRestoreLog = Join-Path $BackupBaseDir "pre-restore-backup.log"
            try {
                & "$PSScriptRoot\backup.ps1" > $preRestoreLog 2>&1
                Log "Pre-restore backup completed. Log: $preRestoreLog"
            }
            catch {
                Log "ERROR: Pre-restore backup failed. Aborting restore. Log: $preRestoreLog"
                Acquire-Lock
                exit 1
            }
            Acquire-Lock
        }

        # Collect pre-restore Elasticsearch state for later comparison
        $stateBefore = Join-Path $BackupDir "restore-state-before.json"
        $stateAfter  = Join-Path $BackupDir "restore-state-after.json"
        if ($DryRun) {
            Log "[DRY-RUN] Would collect Elasticsearch state (before)"
        }
        else {
            try { Collect-ESState -Phase "before" -OutputFile $stateBefore } catch { Log "WARNING: Pre-restore state collection failed: $_" }
        }

        # Stop stack
        Log "Stopping Camunda stack..."
        if ($DryRun) {
            Log "[DRY-RUN] Would run: $cmd down --remove-orphans"
        }
        else {
            Invoke-Expression "$cmd down --remove-orphans" | Out-Null
        }

        # Remove volumes
        Log "Removing data volumes..."
        if ($DryRun) {
            Log "[DRY-RUN] Would remove volumes: orchestration, elastic, postgres, postgres-web"
            Log "[DRY-RUN] Would keep volume: keycloak-theme"
        }
        else {
            $volumes = @(
                (Get-ComposeVolumeName "orchestration"),
                (Get-ComposeVolumeName "elastic"),
                (Get-ComposeVolumeName "postgres"),
                (Get-ComposeVolumeName "postgres-web")
            )
            foreach ($vol in $volumes) {
                try {
                    docker volume rm $vol 2>$null | Out-Null
                }
                catch {
                    Log "WARNING: Could not remove volume $vol (may not exist)"
                }
            }
            Log "Volumes removed."
        }

        # Start only the services needed for data restore.
        # Starting the full stack here allows Camunda apps to recreate indices
        # before the Elasticsearch snapshot restore runs.
        Log "Starting core services with fresh volumes..."
        if ($DryRun) {
            Log "[DRY-RUN] Would run: $cmd up -d postgres web-modeler-db elasticsearch"
        }
        else {
            Invoke-Expression "$cmd up -d postgres web-modeler-db elasticsearch" | Out-Null
        }

        # Wait for core services
        if (-not $DryRun) {
            if (-not (Wait-ForService -Service "postgres")) { exit 1 }
            if (-not (Wait-ForService -Service "web-modeler-db")) { exit 1 }
            if (-not (Wait-ForService -Service "elasticsearch")) { exit 1 }
            Log "Core services are healthy."
        }
        else {
            Log "[DRY-RUN] Would wait for postgres, web-modeler-db, elasticsearch to be healthy"
        }

        # Restore Keycloak DB
        Log "Restoring Keycloak database..."
        $keycloakBackup = Join-Path $BackupDir "keycloak.sql.gz"
        if ($DryRun) {
            Log "[DRY-RUN] Would restore Keycloak DB from: $keycloakBackup"
            Log "[DRY-RUN] Would run ANALYZE on Keycloak DB"
        }
        else {
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
        Log "Restoring Web Modeler database..."
        $webmodelerBackup = Join-Path $BackupDir "webmodeler.sql.gz"
        if ($DryRun) {
            Log "[DRY-RUN] Would restore Web Modeler DB from: $webmodelerBackup"
            Log "[DRY-RUN] Would run ANALYZE on Web Modeler DB"
        }
        else {
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
        Log "Restoring Elasticsearch snapshot..."
        if ($DryRun) {
            Log "[DRY-RUN] Would restore Elasticsearch snapshot"
        }
        else {
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
                try {
                    docker run --rm `
                        -v "${esBackupDir}:/source:ro" `
                        -v "${esBackupVolume}:/dest" `
                        alpine sh -c 'rm -rf /dest/* && cp -r /source/. /dest/' | Out-Null
                    Log "Snapshot data copied to volume '$esBackupVolume'."
                }
                catch {
                    Log "ERROR: Could not copy snapshot data to volume: $_"
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
            try {
                $catIndices = Invoke-RestMethod -Uri "${esUrl}/_cat/indices?h=index&expand_wildcards=all&format=json"
                foreach ($row in $catIndices) {
                    $idx = $row.index
                    if ($idx -match $camundaPattern) {
                        try {
                            Invoke-RestMethod -Uri "${esUrl}/$idx" -Method Delete | Out-Null
                        }
                        catch {
                            # Already gone; ignore
                        }
                    }
                }
            }
            catch {
                # If listing fails, continue; restore will surface a clearer error
            }

            Log "Clearing Camunda-related Elasticsearch data streams..."
            try {
                $dsResponse = Invoke-RestMethod -Uri "${esUrl}/_data_stream?expand_wildcards=all"
                if ($dsResponse.data_streams) {
                    foreach ($ds in $dsResponse.data_streams) {
                        if ($ds.name -match $camundaPattern) {
                            try {
                                Invoke-RestMethod -Uri "${esUrl}/_data_stream/$($ds.name)" -Method Delete | Out-Null
                            }
                            catch {
                                # Already gone; ignore
                            }
                        }
                    }
                }
            }
            catch {
                # No data streams endpoint or nothing to delete
            }
            Start-Sleep -Seconds 2

            Log "Restoring snapshot: $snapshotName"
            try {
                $restoreBody = '{"indices":"*,-.logs-*,-.ds-.logs-*,-ilm-history-*,-.ds-ilm-history-*","ignore_unavailable":true,"include_global_state":true}'
                $restoreResponse = Invoke-RestMethod -Uri "${esUrl}/_snapshot/backup-repo/$snapshotName/_restore?wait_for_completion=true" -Method Post -ContentType "application/json" -Body $restoreBody
                if (-not $restoreResponse.snapshot -or $restoreResponse.snapshot.state -ne "SUCCESS") {
                    Log "ERROR: Elasticsearch restore state: $($restoreResponse.snapshot.state)"
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
        Log "Restoring Zeebe state..."
        $orchBackup = Join-Path $BackupDir "orchestration.tar.gz"
        if ($DryRun) {
            Log "[DRY-RUN] Would run: $cmd create orchestration"
            Log "[DRY-RUN] Would restore Zeebe state from: $orchBackup"
        }
        else {
            if (Test-Path $orchBackup) {
                $zeebeVol = Get-ComposeVolumeName 'orchestration'
                Invoke-Expression "$cmd create orchestration" | Out-Null
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
        if ($CrossCluster) {
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
            try { Collect-ESState -Phase "after" -OutputFile $stateAfter } catch { Log "WARNING: Post-restore state collection failed: $_" }
            try { Compare-ESState -BeforeFile $stateBefore -AfterFile $stateAfter } catch { Log "WARNING: State comparison failed: $_" }
            try { Cleanup-DanglingComposeVolumes -RestoreStartedAt $restoreStartedAt } catch { Log "WARNING: Dangling volume cleanup failed: $_" }

            Log "Restore completed successfully."
        }
    }
    finally {
        Release-Lock
    }
}

Main -CliArgs $CliArgs
