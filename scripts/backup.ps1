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
$AppServices = @(
    "orchestration",
    "connectors",
    "optimize",
    "identity",
    "keycloak",
    "web-modeler-restapi",
    "web-modeler-webapp",
    "web-modeler-websockets",
    "console"
)

function Show-Usage {
    Write-Host "Usage: $(Split-Path -Leaf $PSCommandPath) [OPTIONS]"
    Write-Host ""
    Write-Host "Options:"
    Write-Host "  --simulate          Simulate backup without modifying data (alias: --test)"
    Write-Host "  --retention-days N  Delete backups older than N days (default: 7)"
    Write-Host "  --backup-dir DIR    Base directory for backups (default: backups\)"
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
            "--env-file" { $i++; break }
            { $_ -in "-h","--help" } { Show-Usage }
            default {
                Write-Host "Unknown option: $arg"
                Show-Usage
            }
        }
    }
}

function Main {
    Parse-Args -Args $rawArgs

    Load-Env
    $stage = Get-Stage
    $cmd = Get-DockerComposeCmd

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

    $appServicesStopped = $false
    Acquire-Lock
    try {
        Log "Starting backup to $backupDir"
        Log "Stage: $stage"

    # Check stack status
    Log "Checking stack status..."
    $runningContainers = @(Invoke-Expression "$cmd ps --filter status=running --format '{{.Name}}'" 2>$null) | Where-Object { $_ -ne "" }
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
            Log "[TEST] Would stop application services: $($AppServices -join ', ')"
            Log "[TEST] Would backup Zeebe state from volume 'orchestration'"
            Log "[TEST] Would pg_dump Keycloak DB: $env:POSTGRES_DB"
            Log "[TEST] Would pg_dump Web Modeler DB: $env:WEBMODELER_DB_NAME"
            Log "[TEST] Would create Elasticsearch snapshot"
            Log "[TEST] Would start application services: $($AppServices -join ', ')"
        }
        else {
            $backupStateFile = Join-Path $backupDir "backup-state.json"
            try { Collect-ESState -Phase "backup" -OutputFile $backupStateFile } catch { Log "WARNING: Backup state collection failed: $_" }

            Log "Stopping application services for consistent cold backup..."
            Invoke-Expression "$cmd stop --timeout 60 $($AppServices -join ' ')" | Out-Null
            $appServicesStopped = $true
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
            $pgDumpCmd = "docker exec postgres pg_dump -Fc -U `"$env:POSTGRES_USER`" `"$env:POSTGRES_DB`""
            $outputFile = Join-Path $backupDir "keycloak.sql.gz"
            Invoke-Expression "$pgDumpCmd | gzip > `"$outputFile`""
            if ($LASTEXITCODE -ne 0 -or -not (Test-Path $outputFile) -or (Get-Item $outputFile).Length -eq 0) {
                Log "ERROR: Keycloak DB backup failed"
                exit 1
            }
            Log "Keycloak DB backed up: $outputFile"

            Log "Backing up Web Modeler database..."
            $pgDumpCmd = "docker exec web-modeler-db pg_dump -Fc -U `"$env:WEBMODELER_DB_USER`" `"$env:WEBMODELER_DB_NAME`""
            $outputFile = Join-Path $backupDir "webmodeler.sql.gz"
            Invoke-Expression "$pgDumpCmd | gzip > `"$outputFile`""
            if ($LASTEXITCODE -ne 0 -or -not (Test-Path $outputFile) -or (Get-Item $outputFile).Length -eq 0) {
                Log "ERROR: Web Modeler DB backup failed"
                exit 1
            }
            Log "Web Modeler DB backed up: $outputFile"

            Log "Creating Elasticsearch snapshot..."
            # Ensure the Docker volume has open permissions for the elasticsearch user
            try {
                docker run --rm -v "elastic-backup:/backup" alpine sh -c "chmod -R 777 /backup 2>/dev/null || true" | Out-Null
            }
            catch {
                Log "WARNING: Could not set volume permissions: $_"
            }

            $esRepoBody = '{"type":"fs","settings":{"location":"/usr/share/elasticsearch/backup","compress":true}}'
            try {
                Invoke-RestMethod -Uri "http://localhost:9200/_snapshot/backup-repo" -Method Put -ContentType "application/json" -Body $esRepoBody | Out-Null
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
                $response = Invoke-RestMethod -Uri "http://localhost:9200/_snapshot/backup-repo/${snapshotName}?wait_for_completion=true" -Method Put -ContentType "application/json" -Body $snapshotBody
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

            Log "Starting application services..."
            Invoke-Expression "$cmd start $($AppServices -join ' ')" | Out-Null
            $appServicesStopped = $false
            Start-Sleep -Seconds 2
        }

        # Create manifest
        Log "Creating manifest..."
        if ($TestMode) {
            Log "[TEST] Would create manifest.json"
        }
        else {
            Create-Manifest -BackupDir $backupDir
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
        if ($appServicesStopped) {
            Log "Attempting to restart application services after failure..."
            try { Invoke-Expression "$cmd start $($AppServices -join ' ')" | Out-Null } catch { }
        }
        exit 1
    }
    finally {
        Release-Lock
    }
}

Main
