$ErrorActionPreference = "Stop"

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$ProjectDir = Resolve-Path (Join-Path $ScriptDir "..")

# Pre-parse --env-file so backup-common.ps1 can honor it
$EnvFile = Join-Path $ProjectDir ".env"
$rawArgs = $args
for ($i = 0; $i -lt $rawArgs.Count; $i++) {
    if ($rawArgs[$i] -eq "--env-file" -and ($i + 1) -lt $rawArgs.Count) {
        $EnvFile = $rawArgs[$i + 1]
        $before = if ($i -gt 0) { $rawArgs[0..($i-1)] } else { @() }
        $after = if (($i + 2) -lt $rawArgs.Count) { $rawArgs[($i+2)..($rawArgs.Count-1)] } else { @() }
        $rawArgs = $before + $after
        break
    }
}

. (Join-Path $ScriptDir "lib\backup-common.ps1")

$TestMode = $false
$RetentionDays = 7
$CustomBackupDir = ""
$EncryptTo = ""
$CoreServices = @("postgres", "web-modeler-db", "elasticsearch", "mailpit", "reverse-proxy")
$AppServices = @()

function Show-Usage {
    Write-Host "Usage: $(Split-Path -Leaf $PSCommandPath) [OPTIONS]"
    Write-Host ""
    Write-Host "Options:"
    Write-Host "  --simulate          Simulate backup without modifying data (alias: --test)"
    Write-Host "  --retention-days N  Delete backups older than N days (default: 7)"
    Write-Host "  --backup-dir DIR    Base directory for backups (default: backups\)"
    Write-Host "  --encrypt-to ID     Also write encrypted backup archive for a gpg or age recipient"
    Write-Host "  --env-file FILE     Use a custom env file instead of .env"
    Write-Host "  -h, --help          Show this help message"
    exit 0
}

function Parse-Args {
    param([string[]]$CliArgs)
    for ($i = 0; $i -lt $CliArgs.Count; $i++) {
        $arg = $CliArgs[$i]
        switch ($arg) {
            "--simulate" { $script:TestMode = $true; break }
            "--test" { $script:TestMode = $true; break }
            "--retention-days" {
                $script:RetentionDays = [int]$CliArgs[$i + 1]
                $i++
                break
            }
            "--backup-dir" {
                $script:CustomBackupDir = $CliArgs[$i + 1]
                $i++
                break
            }
            "--encrypt-to" {
                $script:EncryptTo = $CliArgs[$i + 1]
                $i++
                break
            }
            "--env-file" { $i++; break }
            { $_ -in "-h","--help" } { Show-Usage }
            default {
                Write-Host "Unknown option: $arg"
                Show-Usage
            }
        }
    }
}

function Set-AppServicesFromCompose {
    param([string]$Cmd)

    $script:AppServices = @()
    $services = @(Invoke-Expression "$Cmd config --services" 2>> $Global:LogFile | Where-Object { $_ -and $_.Trim() -ne "" })
    if ($LASTEXITCODE -ne 0) {
        Log "ERROR: Could not derive service list from docker compose config"
        exit 1
    }

    foreach ($service in $services) {
        if ($script:CoreServices -notcontains $service) {
            $script:AppServices += $service
        }
    }

    if ($script:AppServices.Count -eq 0) {
        Log "Computed application stop list: (none)"
    }
    else {
        Log "Computed application stop list: $($script:AppServices -join ', ')"
    }
}

function New-EncryptedBackupArchive {
    param(
        [string]$BackupDir,
        [string]$BackupBaseDir,
        [string]$Recipient
    )

    $encryptedBaseDir = Join-Path (Split-Path -Parent $BackupBaseDir) "backups-encrypted"
    New-Item -ItemType Directory -Path $encryptedBaseDir -Force | Out-Null
    $backupName = Split-Path -Leaf $BackupDir
    $tmpTar = Join-Path $encryptedBaseDir "${backupName}.tar.gz.tmp"

    try {
        if (Get-Command gpg -ErrorAction SilentlyContinue) {
            $artifact = Join-Path $encryptedBaseDir "${backupName}.tar.gz.gpg"
            Log "Creating encrypted backup archive with gpg: $artifact"
            tar czf $tmpTar -C $BackupBaseDir $backupName
            if ($LASTEXITCODE -ne 0) {
                Log "ERROR: Could not create temporary archive for encryption"
                exit 1
            }
            gpg --batch --yes --encrypt --recipient $Recipient --output $artifact $tmpTar *>> $Global:LogFile
            if ($LASTEXITCODE -ne 0) {
                Log "ERROR: gpg encryption failed"
                exit 1
            }
            Log "Encrypted backup archive created: $artifact"
            return
        }

        if (Get-Command age -ErrorAction SilentlyContinue) {
            $artifact = Join-Path $encryptedBaseDir "${backupName}.tar.gz.age"
            Log "Creating encrypted backup archive with age: $artifact"
            tar czf $tmpTar -C $BackupBaseDir $backupName
            if ($LASTEXITCODE -ne 0) {
                Log "ERROR: Could not create temporary archive for encryption"
                exit 1
            }
            age -r $Recipient -o $artifact $tmpTar *>> $Global:LogFile
            if ($LASTEXITCODE -ne 0) {
                Log "ERROR: age encryption failed"
                exit 1
            }
            Log "Encrypted backup archive created: $artifact"
            return
        }

        Log "ERROR: --encrypt-to requires gpg or age in PATH"
        exit 1
    }
    finally {
        Remove-Item -Path $tmpTar -Force -ErrorAction SilentlyContinue
    }
}

function Main {
    Parse-Args -CliArgs $rawArgs

    Load-Env
    $stage = Get-Stage
    $cmd = Get-DockerComposeCmd
    $backupStopTimeout = 180
    if ($env:BACKUP_STOP_TIMEOUT) {
        if (-not [int]::TryParse($env:BACKUP_STOP_TIMEOUT, [ref]$backupStopTimeout) -or $backupStopTimeout -le 0) {
            Log "ERROR: BACKUP_STOP_TIMEOUT must be a positive integer (got: $($env:BACKUP_STOP_TIMEOUT))"
            exit 1
        }
    }
    elseif ($backupStopTimeout -le 0) {
        Log "ERROR: BACKUP_STOP_TIMEOUT must be a positive integer (got: $backupStopTimeout)"
        exit 1
    }

    $backupBaseDir = $BackupBaseDir
    if ($CustomBackupDir) {
        $backupBaseDir = $CustomBackupDir
        New-Item -ItemType Directory -Path $backupBaseDir -Force | Out-Null
    }

    New-Item -ItemType Directory -Path $backupBaseDir -Force | Out-Null
    $timestamp = Get-Date -Format "yyyyMMdd_HHmmss"
    $backupDir = Join-Path $backupBaseDir $timestamp
    $Global:LogFile = Join-Path $backupDir "backup.log"

    if ($TestMode) {
        Log "=== TEST MODE: Simulating backup without modifying data ==="
        $backupDir = Join-Path $backupBaseDir "TEST_$timestamp"
        $Global:LogFile = Join-Path $backupDir "backup.log"
    }

    New-Item -ItemType Directory -Path $backupDir -Force | Out-Null
    Set-AppServicesFromCompose -Cmd $cmd

    $appServicesStopped = $false
    $backupDirInProgress = $backupDir
    Acquire-Lock
    try {
        Log "Starting backup to $backupDir"
        Log "Stage: $stage"
        Log "Application service stop timeout: ${backupStopTimeout}s"

    # Check stack status
    Log "Checking stack status..."
    $runningContainers = @(Invoke-Expression "$cmd ps --filter status=running --format '{{.Name}}'" 2>> $Global:LogFile) | Where-Object { $_ -ne "" }
    if ($runningContainers.Count -eq 0) {
        Log "ERROR: Stack is not running (0 containers running). Start it first with scripts/start.ps1"
        exit 1
    }
    Log "Stack has $($runningContainers.Count) running container(s)."

    Check-ServicesHealth | Out-Null

        # Backup configs
        Log "Backing up configuration files..."
        $configArchive = Join-Path $backupDir "configs.tar.gz"
        if ($TestMode) {
            Log "[TEST] Would create config archive: $configArchive"
            Log "[TEST] Including: .env, connector-secrets.txt, Caddyfile, .*/application.yaml"
        }
        else {
            $configItems = @(
                (Join-Path $ProjectDir ".env"),
                (Join-Path $ProjectDir "connector-secrets.txt"),
                (Join-Path $ProjectDir "Caddyfile"),
                (Join-Path $ProjectDir ".orchestration\application.yaml"),
                (Join-Path $ProjectDir ".connectors\application.yaml"),
                (Join-Path $ProjectDir ".optimize\environment-config.yaml"),
                (Join-Path $ProjectDir ".identity\application.yaml"),
                (Join-Path $ProjectDir ".console\application.yaml")
        )
        $existingItems = $configItems | Where-Object { Test-Path $_ }
        if (-not $existingItems) {
            Log "ERROR: No config files found to back up"
            exit 1
        }
        else {
            $relPaths = $existingItems | ForEach-Object { (($_ -replace [regex]::Escape("$ProjectDir\"), "") -replace '\\', '/') }
            $tarResult = tar czf $configArchive -C $ProjectDir $relPaths 2>&1
            if ($LASTEXITCODE -ne 0) {
                Log "ERROR: Config archive failed: $tarResult"
                exit 1
            }
            else {
                Log "Configs backed up: $configArchive ($($existingItems.Count) files)"
            }
        }
    }

        # Orchestration stop + all backups while stopped + restart
        Log "Stopping application services for cold backup..."
        if ($TestMode) {
            Log "[TEST] Would collect Elasticsearch state to: $(Join-Path $backupDir 'backup-state.json')"
            if ($AppServices.Count -gt 0) {
                Log "[TEST] Would stop application services with timeout ${backupStopTimeout}s: $($AppServices -join ', ')"
            }
            else {
                Log "[TEST] No application services would be stopped"
            }
            Log "[TEST] Would backup Zeebe state from volume 'orchestration'"
            Log "[TEST] Would pg_dump Keycloak DB: $env:POSTGRES_DB"
            Log "[TEST] Would pg_dump Web Modeler DB: $env:WEBMODELER_DB_NAME"
            Log "[TEST] Would create Elasticsearch snapshot"
        }
        else {
            $backupStateFile = Join-Path $backupDir "backup-state.json"
            try { Collect-ESState -Phase "backup" -OutputFile $backupStateFile } catch { Log "WARNING: Backup state collection failed: $_" }

            Log "Stopping application services for consistent cold backup (timeout: ${backupStopTimeout}s)..."
            if ($AppServices.Count -gt 0) {
                Invoke-Expression "$cmd stop --timeout $backupStopTimeout $($AppServices -join ' ')" | Out-Null
                $appServicesStopped = $true
            }
            else {
                Log "No application services to stop."
            }
            Start-Sleep -Seconds 2

            Log "Backing up Zeebe state (volume: orchestration)..."
            $zeebeRetry = 0
            $zeebeMaxRetries = 3
            while ($zeebeRetry -lt $zeebeMaxRetries) {
                try {
                    $zeebeVol = Get-ComposeVolumeName 'orchestration'
                    docker run --rm `
                        -v "${zeebeVol}:/data" `
                        -v "${backupDir}:/backup" `
                        alpine tar czf /backup/orchestration.tar.gz -C /data . | Out-Null
                    Log "Zeebe state backed up."
                    break
                }
                catch {
                    $zeebeRetry++
                    if ($zeebeRetry -eq $zeebeMaxRetries) {
                        Log "ERROR: Zeebe state backup failed after $zeebeMaxRetries attempts: $_"
                        exit 1
                    }
                    else {
                        Log "WARNING: Zeebe backup failed, retrying in 5s... (attempt $zeebeRetry/$zeebeMaxRetries)"
                        Start-Sleep -Seconds 5
                    }
                }
            }

            Log "Backing up Keycloak database..."
            $outputFile = Join-Path $backupDir "keycloak.sql.gz"
            $tmpDumpFile = Join-Path $backupDir "keycloak.sql"
            try {
                & docker exec postgres pg_dump -Fc -U "$env:POSTGRES_USER" "$env:POSTGRES_DB" 2>> $Global:LogFile > $tmpDumpFile
                $pgDumpExit = $LASTEXITCODE
                if ($pgDumpExit -ne 0 -or -not (Test-Path $tmpDumpFile) -or (Get-Item $tmpDumpFile).Length -eq 0) {
                    Log "ERROR: Keycloak DB backup failed"
                    exit 1
                }
                gzip -c $tmpDumpFile > $outputFile
                if ($LASTEXITCODE -ne 0 -or -not (Test-Path $outputFile) -or (Get-Item $outputFile).Length -eq 0) {
                    Log "ERROR: Keycloak DB gzip failed"
                    exit 1
                }
                gzip -t $outputFile 2>> $Global:LogFile
                if ($LASTEXITCODE -ne 0) {
                    Log "ERROR: Keycloak DB backup produced invalid gzip"
                    exit 1
                }
            }
            finally {
                Remove-Item -Path $tmpDumpFile -Force -ErrorAction SilentlyContinue
            }
            Log "Keycloak DB backed up: $outputFile"

            Log "Backing up Web Modeler database..."
            $outputFile = Join-Path $backupDir "webmodeler.sql.gz"
            $tmpDumpFile = Join-Path $backupDir "webmodeler.sql"
            try {
                & docker exec web-modeler-db pg_dump -Fc -U "$env:WEBMODELER_DB_USER" "$env:WEBMODELER_DB_NAME" 2>> $Global:LogFile > $tmpDumpFile
                $pgDumpExit = $LASTEXITCODE
                if ($pgDumpExit -ne 0 -or -not (Test-Path $tmpDumpFile) -or (Get-Item $tmpDumpFile).Length -eq 0) {
                    Log "ERROR: Web Modeler DB backup failed"
                    exit 1
                }
                gzip -c $tmpDumpFile > $outputFile
                if ($LASTEXITCODE -ne 0 -or -not (Test-Path $outputFile) -or (Get-Item $outputFile).Length -eq 0) {
                    Log "ERROR: Web Modeler DB gzip failed"
                    exit 1
                }
                gzip -t $outputFile 2>> $Global:LogFile
                if ($LASTEXITCODE -ne 0) {
                    Log "ERROR: Web Modeler DB backup produced invalid gzip"
                    exit 1
                }
            }
            finally {
                Remove-Item -Path $tmpDumpFile -Force -ErrorAction SilentlyContinue
            }
            Log "Web Modeler DB backed up: $outputFile"

            Log "Creating Elasticsearch snapshot..."
            # Ensure the Docker volume has open permissions for the elasticsearch user
            try {
                docker run --rm -v "elastic-backup:/backup" alpine sh -c "chmod -R 777 /backup 2>/dev/null || true" 2>> $Global:LogFile | Out-Null
            }
            catch {
                Log "WARNING: Could not set volume permissions: $_"
            }

            $esRepoBody = '{"type":"fs","settings":{"location":"/usr/share/elasticsearch/backup","compress":true}}'
            $esHost = if ($env:ES_HOST) { $env:ES_HOST } else { "localhost" }
            $esPort = if ($env:ES_PORT) { $env:ES_PORT } else { "9200" }
            $esUrl = "http://${esHost}:${esPort}"
            try {
                Invoke-RestMethod -Uri "${esUrl}/_snapshot/backup-repo" -Method Put -ContentType "application/json" -Body $esRepoBody | Out-Null
                Log "Elasticsearch snapshot repo registered."
            }
            catch {
                Log "ERROR: Could not register snapshot repo: $_"
                exit 1
            }

            $snapshotName = "snapshot_$timestamp"
            $snapshotBody = '{"indices":"*,-.logs-*,-.ds-.logs-*,-ilm-history-*,-.ds-ilm-history-*","ignore_unavailable":true,"include_global_state":true,"feature_states":["none"]}'
            $snapshotInfoFile = Join-Path $backupDir "snapshot-info.json"
            $esSuccess = $false
            try {
                $response = Invoke-RestMethod -Uri "${esUrl}/_snapshot/backup-repo/${snapshotName}?wait_for_completion=true" -Method Put -ContentType "application/json" -Body $snapshotBody
                $response | ConvertTo-Json -Depth 10 | Set-Content -Path $snapshotInfoFile

                $state = $response.snapshot.state
                if ($state -ne "SUCCESS") {
                    Log "ERROR: Elasticsearch snapshot state: $state"
                    exit 1
                }
                else {
                    Log "Elasticsearch snapshot created successfully: $snapshotName"
                    $esSuccess = $true
                }
            }
            catch {
                Log "ERROR: Elasticsearch snapshot creation failed: $_"
                @{error=$_.Exception.Message} | ConvertTo-Json | Set-Content -Path $snapshotInfoFile
                exit 1
            }

            # Copy snapshot data from the Docker volume to the host backup directory
            Log "Copying snapshot data from Docker volume to backup directory..."
            $esBackupDir = Join-Path $backupDir "elasticsearch"
            New-Item -ItemType Directory -Path $esBackupDir -Force | Out-Null
            try {
                docker run --rm `
                    -v "elastic-backup:/source:ro" `
                    -v "${esBackupDir}:/dest" `
                    alpine sh -c 'cp -r /source/. /dest/' | Out-Null
                Log "Snapshot data copied to: $esBackupDir"
            }
            catch {
                Log "ERROR: Could not copy snapshot data from volume: $_"
                exit 1
            }

        }

        # Create manifest
        Log "Creating manifest..."
        if ($TestMode) {
            Log "[TEST] Would create manifest.json"
            if ($AppServices.Count -gt 0) {
                Log "[TEST] Would start application services: $($AppServices -join ', ')"
            }
            else {
                Log "[TEST] No application services would be started"
            }
        }
        else {
            Create-Manifest -BackupDir $backupDir
            if ($EncryptTo) {
                New-EncryptedBackupArchive -BackupDir $backupDir -BackupBaseDir $backupBaseDir -Recipient $EncryptTo
            }
            $backupDirInProgress = ""

            Log "Starting application services..."
            if ($AppServices.Count -gt 0) {
                Invoke-Expression "$cmd start $($AppServices -join ' ')" | Out-Null
                $appServicesStopped = $false
            }
            else {
                Log "No application services to start."
            }
            Start-Sleep -Seconds 2
        }

        # Cleanup old backups
        Log "Cleaning up old backups..."
        if ($TestMode) {
            Log "[TEST] Would delete backups older than $RetentionDays days from $backupBaseDir"
        }
        else {
            Cleanup-OldBackups -RetentionDays $RetentionDays -BackupDir $backupBaseDir
        }

        if ($TestMode) {
            Log "=== TEST MODE complete. Simulated backup: $backupDir ==="
            Remove-Item -Path $backupDir -Recurse -Force
        }
        else {
            Log "Backup completed successfully: $backupDir"
        }
    }
    catch {
        Log "ERROR: Backup failed: $_"
        if (-not $TestMode -and $backupDirInProgress -and (Test-Path $backupDirInProgress) -and ($backupDirInProgress -notlike "*_FAILED*")) {
            $failedDir = "${backupDirInProgress}_FAILED"
            $suffix = 1
            while (Test-Path $failedDir) {
                $failedDir = "${backupDirInProgress}_FAILED_$suffix"
                $suffix++
            }
            Log "Marking incomplete backup directory as failed: $failedDir"
            try {
                Move-Item -Path $backupDirInProgress -Destination $failedDir -ErrorAction Stop
                $backupDirInProgress = $failedDir
                $Global:LogFile = Join-Path $failedDir "backup.log"
                Log "Incomplete backup moved to: $failedDir"
            }
            catch {
                Log "WARNING: Could not mark incomplete backup directory as failed: $backupDirInProgress"
            }
        }
        if ($appServicesStopped -and $AppServices.Count -gt 0) {
            Log "Attempting to restart application services after failure..."
            try { Invoke-Expression "$cmd start $($AppServices -join ' ')" *>> $Global:LogFile } catch { }
        }
        exit 1
    }
    finally {
        Release-Lock
    }
}

Main
