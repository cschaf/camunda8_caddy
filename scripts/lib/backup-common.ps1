$ErrorActionPreference = "Stop"

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$ProjectDir = Resolve-Path (Join-Path $ScriptDir "..\..")
if (-not $EnvFile) {
    $EnvFile = Join-Path $ProjectDir ".env"
}
$BackupBaseDir = Join-Path $ProjectDir "backups"
$LockDir = Join-Path $BackupBaseDir ".backup.lock"
$LockFile = Join-Path $LockDir "pid"

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
    if ($env:COMPOSE_FILE) {
        return "docker compose"
    }
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

    $skipNames = @('manifest.json', 'backup.log', 'restore.log')
    Get-ChildItem -Path $BackupDir -Recurse -File | Where-Object {
        $_.Name -notin $skipNames
    } | Sort-Object FullName | ForEach-Object {
        $rel = $_.FullName.Substring($BackupDir.ToString().TrimEnd('\', '/').Length + 1).Replace('\', '/')
        $manifest.files += @{
            name   = $rel
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
        $normalizedName = $fileEntry.name.Replace('/', [System.IO.Path]::DirectorySeparatorChar)
        $fpath = Join-Path $BackupDir $normalizedName
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
    param(
        [int]$RetentionDays = 7,
        [string]$BackupDir = $BackupBaseDir
    )
    Log "Cleaning up backups older than $RetentionDays days..."

    if (-not (Test-Path $BackupDir)) {
        Log "Backup directory does not exist yet, nothing to clean."
        return
    }

    $cutoff = (Get-Date).AddDays(-$RetentionDays)
    $oldBackups = Get-ChildItem -Path $BackupDir -Directory | Where-Object {
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

    while ($true) {
        try {
            New-Item -ItemType Directory -Path $LockDir -ErrorAction Stop | Out-Null
            $PID | Set-Content -Path $LockFile
            Log "Lock acquired: $LockDir"
            return
        }
        catch {
            $pidInFile = Get-Content $LockFile -ErrorAction SilentlyContinue
            $parsedPid = 0
            if ([int]::TryParse($pidInFile, [ref]$parsedPid)) {
                try {
                    $null = Get-Process -Id $parsedPid -ErrorAction Stop
                    Log "ERROR: Another backup/restore process is already running (PID: $parsedPid)"
                    exit 2
                }
                catch { }
            }

            Log "WARNING: Stale lock directory found, removing..."
            Remove-Item $LockDir -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}

function Release-Lock {
    if (Test-Path $LockDir) {
        $pidInFile = Get-Content $LockFile -ErrorAction SilentlyContinue
        if (-not $pidInFile -or $pidInFile -eq "$PID") {
            Remove-Item $LockDir -Recurse -Force
            Log "Lock released."
        }
        else {
            Log "WARNING: Lock not released because it is owned by PID: $pidInFile"
        }
    }
}

function Get-ComposeProjectName {
    if ($env:COMPOSE_PROJECT_NAME) {
        return $env:COMPOSE_PROJECT_NAME.ToLower()
    }
    $raw = (Split-Path -Leaf $ProjectDir).ToLower()
    return ($raw -replace '[^a-z0-9_-]', '')
}

function Get-ComposeVolumeName {
    param([string]$VolumeKey)
    return "$(Get-ComposeProjectName)_$VolumeKey"
}

function Get-RestoreStartTimestamp {
    return [DateTimeOffset]::UtcNow
}

function Cleanup-DanglingComposeVolumes {
    param(
        [DateTimeOffset]$RestoreStartedAt,
        [string]$ProjectName = (Get-ComposeProjectName)
    )

    Log "Cleaning up dangling Docker volumes from previous restore runs..."

    $dangling = @()
    try {
        $dangling = @(docker volume ls -q -f dangling=true 2>$null | Where-Object { $_ -and $_.Trim() -ne "" })
    }
    catch {
        Log "WARNING: Could not list dangling Docker volumes: $_"
        return
    }

    if ($dangling.Count -eq 0) {
        Log "No dangling Docker volumes found."
        return
    }

    $removed = 0
    foreach ($volumeName in $dangling) {
        if ($volumeName -eq "elastic-backup") {
            continue
        }

        $inspectRaw = $null
        try {
            $inspectRaw = docker volume inspect $volumeName 2>$null
        }
        catch {
            continue
        }
        if (-not $inspectRaw) {
            continue
        }

        try {
            $inspect = $inspectRaw | ConvertFrom-Json
            if ($inspect -is [System.Array]) {
                $inspect = $inspect[0]
            }
        }
        catch {
            continue
        }

        $labels = $inspect.Labels
        if (-not $labels) {
            continue
        }
        if ($labels.'com.docker.compose.project' -ne $ProjectName) {
            continue
        }

        $createdAt = $null
        try {
            $createdAt = [DateTimeOffset]::Parse($inspect.CreatedAt).ToUniversalTime()
        }
        catch {
            continue
        }
        if ($createdAt -gt $RestoreStartedAt.ToUniversalTime()) {
            continue
        }

        try {
            docker volume rm $volumeName 2>$null | Out-Null
            $removed++
            Log "Removed dangling volume: $volumeName"
        }
        catch {
            Log "WARNING: Could not remove dangling volume ${volumeName}: $_"
        }
    }

    Log "Dangling volume cleanup removed $removed volume(s)."
}

function Collect-ESState {
    param(
        [string]$Phase,
        [string]$OutputFile
    )

    Log "Collecting Elasticsearch state ($Phase)..."

    $esHost = if ($env:ES_HOST) { $env:ES_HOST } else { "localhost" }
    $esPort = if ($env:ES_PORT) { $env:ES_PORT } else { "9200" }
    $esUrl = "http://${esHost}:${esPort}"

    $health = $null
    try {
        $health = Invoke-RestMethod -Uri "${esUrl}/_cluster/health" -TimeoutSec 10 -ErrorAction Stop
    }
    catch {
        @{ phase = $Phase; reachable = $false } | ConvertTo-Json -Depth 10 | Set-Content -Path $OutputFile
        Log "  Elasticsearch not reachable."
        return
    }

    $pattern = '^(operate|tasklist|optimize|zeebe|camunda-|\.camunda|\.tasks)'

    $indicesRaw = @()
    try {
        $indicesRaw = Invoke-RestMethod -Uri "${esUrl}/_cat/indices?h=index,docs.count,store.size&format=json&expand_wildcards=all" -TimeoutSec 15
    }
    catch { }

    $dataStreamsRaw = $null
    try {
        $dataStreamsRaw = Invoke-RestMethod -Uri "${esUrl}/_data_stream?expand_wildcards=all" -TimeoutSec 10
    }
    catch { }

    $componentCounts = @{ operate = 0; tasklist = 0; optimize = 0; zeebe = 0; camunda = 0; other = 0 }
    $totalDocs = 0
    $indexList = @()
    foreach ($row in $indicesRaw) {
        $name = $row.index
        if (-not $name -or ($name -notmatch $pattern)) { continue }
        $docs = 0
        if ($row.'docs.count') {
            try { $docs = [int]$row.'docs.count' } catch { $docs = 0 }
        }
        $size = $row.'store.size'
        $indexList += @{ name = $name; docs = $docs; size = $size }
        $totalDocs += $docs
        if ($name -like 'operate*') { $componentCounts.operate++ }
        elseif ($name -like 'tasklist*') { $componentCounts.tasklist++ }
        elseif ($name -like 'optimize*') { $componentCounts.optimize++ }
        elseif ($name -like 'zeebe*') { $componentCounts.zeebe++ }
        elseif ($name -like 'camunda-*' -or $name -like '.camunda*') { $componentCounts.camunda++ }
        else { $componentCounts.other++ }
    }
    $indexList = @($indexList | Sort-Object { $_.name })

    $dataStreams = @()
    if ($dataStreamsRaw -and $dataStreamsRaw.data_streams) {
        foreach ($ds in $dataStreamsRaw.data_streams) {
            if ($ds.name -match $pattern) { $dataStreams += $ds.name }
        }
    }
    $dataStreams = @($dataStreams | Sort-Object)

    $state = @{
        phase = $Phase
        reachable = $true
        cluster = @{
            name = $health.cluster_name
            status = $health.status
            number_of_nodes = $health.number_of_nodes
            active_shards = $health.active_shards
        }
        indices = $indexList
        data_streams = $dataStreams
        component_counts = $componentCounts
        total_camunda_indices = $indexList.Count
        total_camunda_docs = $totalDocs
    }

    $state | ConvertTo-Json -Depth 10 | Set-Content -Path $OutputFile

    Log "  Cluster: $($health.cluster_name) ($($health.status), $($health.number_of_nodes) node(s))"
    Log "  Camunda indices: $($indexList.Count) ($totalDocs total docs)"
    Log "    operate=$($componentCounts.operate), tasklist=$($componentCounts.tasklist), optimize=$($componentCounts.optimize), zeebe=$($componentCounts.zeebe), camunda=$($componentCounts.camunda), other=$($componentCounts.other)"
    Log "  Data streams: $($dataStreams.Count)"
}

function Compare-ESState {
    param(
        [string]$BeforeFile,
        [string]$AfterFile
    )

    if (-not (Test-Path $BeforeFile) -or -not (Test-Path $AfterFile)) {
        Log "WARNING: ES state comparison skipped (missing state files)."
        return
    }

    try {
        $before = Get-Content $BeforeFile -Raw | ConvertFrom-Json
        $after  = Get-Content $AfterFile -Raw | ConvertFrom-Json
    }
    catch {
        Log "WARNING: Could not read state files for comparison: $_"
        return
    }

    Log "=== Elasticsearch state comparison (before -> after) ==="

    $beforeReach = if ($before.reachable) { "reachable" } else { "UNREACHABLE" }
    $afterReach  = if ($after.reachable)  { "reachable" } else { "UNREACHABLE" }
    Log "  Connectivity: $beforeReach -> $afterReach"

    if (-not $before.reachable -or -not $after.reachable) {
        Log "  (Skipping detailed comparison due to unreachable state)"
        Log "========================================================"
        return
    }

    Log "  Cluster status: $($before.cluster.status) -> $($after.cluster.status)"
    Log "  Nodes:          $($before.cluster.number_of_nodes) -> $($after.cluster.number_of_nodes)"
    Log "  Active shards:  $($before.cluster.active_shards) -> $($after.cluster.active_shards)"
    Log "  Camunda indices: $($before.total_camunda_indices) -> $($after.total_camunda_indices)"
    Log "  Camunda docs:    $($before.total_camunda_docs) -> $($after.total_camunda_docs)"

    foreach ($k in 'operate','tasklist','optimize','zeebe','camunda','other') {
        $bv = $before.component_counts.$k
        $av = $after.component_counts.$k
        Log ("    {0,-9} {1} -> {2}" -f $k, $bv, $av)
    }

    $beforeDsCount = 0
    if ($before.data_streams) { $beforeDsCount = @($before.data_streams).Count }
    $afterDsCount = 0
    if ($after.data_streams) { $afterDsCount = @($after.data_streams).Count }
    Log "  Data streams:    $beforeDsCount -> $afterDsCount"

    $beforeIdx = @{}
    foreach ($i in @($before.indices)) { if ($i.name) { $beforeIdx[$i.name] = $i } }
    $afterIdx = @{}
    foreach ($i in @($after.indices))  { if ($i.name) { $afterIdx[$i.name]  = $i } }

    $onlyBefore = @($beforeIdx.Keys | Where-Object { -not $afterIdx.ContainsKey($_) } | Sort-Object)
    $onlyAfter  = @($afterIdx.Keys  | Where-Object { -not $beforeIdx.ContainsKey($_) } | Sort-Object)
    $max = 20

    if ($onlyBefore.Count -gt 0) {
        Log "  Indices removed ($($onlyBefore.Count)):"
        $show = [Math]::Min($max, $onlyBefore.Count)
        for ($i = 0; $i -lt $show; $i++) {
            $n = $onlyBefore[$i]
            Log "    - $n ($($beforeIdx[$n].docs) docs)"
        }
        if ($onlyBefore.Count -gt $max) {
            Log "    ... and $($onlyBefore.Count - $max) more"
        }
    }

    if ($onlyAfter.Count -gt 0) {
        Log "  Indices added ($($onlyAfter.Count)):"
        $show = [Math]::Min($max, $onlyAfter.Count)
        for ($i = 0; $i -lt $show; $i++) {
            $n = $onlyAfter[$i]
            Log "    + $n ($($afterIdx[$n].docs) docs)"
        }
        if ($onlyAfter.Count -gt $max) {
            Log "    ... and $($onlyAfter.Count - $max) more"
        }
    }

    $common = @($beforeIdx.Keys | Where-Object { $afterIdx.ContainsKey($_) } | Sort-Object)
    $changed = @()
    foreach ($n in $common) {
        $bd = $beforeIdx[$n].docs
        $ad = $afterIdx[$n].docs
        if ($bd -ne $ad) {
            $changed += @{ name = $n; before = $bd; after = $ad }
        }
    }
    if ($changed.Count -gt 0) {
        Log "  Indices with doc count changes ($($changed.Count)):"
        $show = [Math]::Min($max, $changed.Count)
        for ($i = 0; $i -lt $show; $i++) {
            $c = $changed[$i]
            $delta = $c.after - $c.before
            $sign = if ($delta -ge 0) { '+' } else { '' }
            Log "    ~ $($c.name): $($c.before) -> $($c.after) ($sign$delta)"
        }
        if ($changed.Count -gt $max) {
            Log "    ... and $($changed.Count - $max) more"
        }
    }

    Log "========================================================"
}

function Cleanup-OnError {
    if ($?) { return }
    Log "ERROR: Script failed."
    Release-Lock
}
