$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$ProjectDir = Resolve-Path (Join-Path $ScriptDir "..")

$DrillDir = Join-Path $ProjectDir "backups\.drill"
$DrillEnv = Join-Path $DrillDir ".env.drill"
$DrillPorts = Join-Path $DrillDir "ports.yaml"
$DrillProjectName = if ($env:DRILL_PROJECT_NAME) { $env:DRILL_PROJECT_NAME } else { "camunda-restoredrill" }
$DrillHost = if ($env:DRILL_HOST) { $env:DRILL_HOST } else { "drill.localhost" }
$DrillPortOffset = if ($env:DRILL_PORT_OFFSET) { [int]$env:DRILL_PORT_OFFSET } else { 10000 }

function Log-Drill {
    param([string]$Message)
    Write-Host "[drill] $Message"
}

function Generate-DrillEnv {
    $sourceEnv = Join-Path $ProjectDir ".env"
    if (-not (Test-Path $sourceEnv)) {
        Log-Drill "ERROR: .env not found at $sourceEnv"
        exit 1
    }

    New-Item -ItemType Directory -Path $DrillDir -Force | Out-Null
    Copy-Item -Path $sourceEnv -Destination $DrillEnv -Force

    $content = Get-Content $DrillEnv
    $content = $content -replace '^HOST=.*', "HOST=$DrillHost"
    if (-not ($content -match '^HOST=')) {
        $content += "HOST=$DrillHost"
    }
    $content = $content -replace '^COMPOSE_PROJECT_NAME=.*', "COMPOSE_PROJECT_NAME=$DrillProjectName"
    if (-not ($content -match '^COMPOSE_PROJECT_NAME=')) {
        $content += "COMPOSE_PROJECT_NAME=$DrillProjectName"
    }
    $esPort = 9200 + $DrillPortOffset
    $content = $content -replace '^ES_PORT=.*', "ES_PORT=$esPort"
    if (-not ($content -match '^ES_PORT=')) {
        $content += "ES_PORT=$esPort"
    }
    $content = $content -replace '^ES_BACKUP_VOLUME=.*', "ES_BACKUP_VOLUME=elastic-backup-drill"
    if (-not ($content -match '^ES_BACKUP_VOLUME=')) {
        $content += "ES_BACKUP_VOLUME=elastic-backup-drill"
    }
    Set-Content -Path $DrillEnv -Value $content

    $offset = $DrillPortOffset
    $portsYaml = @"
services:
  orchestration:
    ports:
      - "$((26500 + $offset)):26500"
      - "$((9600 + $offset)):9600"
      - "$((8088 + $offset)):8080"
  connectors:
    ports:
      - "$((8086 + $offset)):8080"
  optimize:
    ports:
      - "$((8083 + $offset)):8090"
  identity:
    ports:
      - "$((8084 + $offset)):8084"
  elasticsearch:
    ports:
      - "$((9200 + $offset)):9200"
      - "$((9300 + $offset)):9300"
  web-modeler-db:
    ports:
      - "$((1025 + $offset)):1025"
      - "$((8075 + $offset)):8025"
  web-modeler-webapp:
    ports:
      - "$((8070 + $offset)):8070"
  web-modeler-websockets:
    ports:
      - "$((8060 + $offset)):8060"
  console:
    ports:
      - "$((8087 + $offset)):8080"
      - "$((9100 + $offset)):9100"
  reverse-proxy:
    ports:
      - "$((443 + $offset)):443"
"@
    Set-Content -Path $DrillPorts -Value $portsYaml

    Log-Drill "Generated drill env: $DrillEnv"
    Log-Drill "Generated port remap: $DrillPorts"
}

function Run-DrillStackUp {
    param([string]$BackupDir)

    $env:ENV_FILE = $DrillEnv
    $env:COMPOSE_FILE = "$ProjectDir\docker-compose.yaml;$ProjectDir\stages\drill.yaml;$DrillPorts"
    $env:ES_BACKUP_VOLUME = "elastic-backup-drill"

    Log-Drill "Running restore.ps1 against drill stack..."
    & "$ScriptDir\..\restore.ps1" --force --no-pre-backup --env-file "$DrillEnv" "$BackupDir"
}

function Run-SmokeTests {
    $offset = $DrillPortOffset
    $keycloakPort = 18080 + $offset
    $orchestrationPort = 8088 + $offset
    $webmodelerPort = 8070 + $offset

    $timeout = 120
    $interval = 5

    Log-Drill "Running smoke tests (timeout ${timeout}s)..."

    $keycloakUrl = "http://localhost:${keycloakPort}/auth/realms/camunda-platform"
    $elapsed = 0
    $keycloakOk = $false
    while ($elapsed -lt $timeout) {
        try {
            $response = Invoke-WebRequest -Uri $keycloakUrl -UseBasicParsing -TimeoutSec 5 -ErrorAction Stop
            if ($response.StatusCode -eq 200) {
                Log-Drill "  Keycloak realm: OK"
                $keycloakOk = $true
                break
            }
        } catch { }
        Start-Sleep -Seconds $interval
        $elapsed += $interval
    }
    if (-not $keycloakOk) {
        Log-Drill "  Keycloak realm: FAILED"
        return $false
    }

    $orchUrl = "http://localhost:${orchestrationPort}/actuator/health"
    $elapsed = 0
    $orchOk = $false
    while ($elapsed -lt $timeout) {
        try {
            $response = Invoke-WebRequest -Uri $orchUrl -UseBasicParsing -TimeoutSec 5 -ErrorAction Stop
            $json = $response.Content | ConvertFrom-Json
            if ($json.status -eq "UP") {
                Log-Drill "  Orchestration health: OK"
                $orchOk = $true
                break
            }
        } catch { }
        Start-Sleep -Seconds $interval
        $elapsed += $interval
    }
    if (-not $orchOk) {
        Log-Drill "  Orchestration health: FAILED"
        return $false
    }

    $wmUrl = "http://localhost:${webmodelerPort}/health/readiness"
    $elapsed = 0
    $wmOk = $false
    while ($elapsed -lt $timeout) {
        try {
            $response = Invoke-WebRequest -Uri $wmUrl -UseBasicParsing -TimeoutSec 5 -ErrorAction Stop
            if ($response.StatusCode -eq 200) {
                Log-Drill "  Web Modeler readiness: OK"
                $wmOk = $true
                break
            }
        } catch { }
        Start-Sleep -Seconds $interval
        $elapsed += $interval
    }
    if (-not $wmOk) {
        Log-Drill "  Web Modeler readiness: FAILED"
        return $false
    }

    if ($env:DRILL_KNOWN_PROJECT_ID) {
        $projUrl = "http://localhost:${webmodelerPort}/internal-api/projects/$($env:DRILL_KNOWN_PROJECT_ID)"
        $elapsed = 0
        $projOk = $false
        while ($elapsed -lt $timeout) {
            try {
                $response = Invoke-WebRequest -Uri $projUrl -UseBasicParsing -TimeoutSec 5 -ErrorAction Stop
                if ($response.StatusCode -eq 200) {
                    Log-Drill "  Known project API: OK"
                    $projOk = $true
                    break
                }
            } catch { }
            Start-Sleep -Seconds $interval
            $elapsed += $interval
        }
        if (-not $projOk) {
            Log-Drill "  Known project API: FAILED"
            return $false
        }
    }

    Log-Drill "All smoke tests passed."
    return $true
}

function Teardown-DrillStack {
    Log-Drill "Tearing down drill stack..."
    $cmd = "docker compose -p $DrillProjectName"
    try { Invoke-Expression "$cmd down --volumes --remove-orphans" | Out-Null } catch { }

    try {
        docker volume prune --filter label=com.docker.compose.project=$DrillProjectName --force 2>$null | Out-Null
    } catch { }

    if (Test-Path $DrillDir) {
        Remove-Item -Path $DrillDir -Recurse -Force
        Log-Drill "Removed drill temp directory: $DrillDir"
    }

    Log-Drill "Teardown complete."
}
