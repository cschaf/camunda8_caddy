#Requires -Version 7

$ErrorActionPreference = 'Stop'

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$ProjectDir = Resolve-Path (Join-Path $ScriptDir '..')
$EnvFile = Join-Path $ProjectDir '.env'

if (-not (Test-Path $EnvFile)) {
    Write-Error ".env file not found. Run: cp .env.example .env"
    exit 1
}

$StageValue = $null
$EnvHost = $null
$ElasticPassword = $null
foreach ($line in Get-Content $EnvFile) {
    if ($line -match '^\s*#') { continue }
    if ($line -match '^\s*STAGE\s*=(.*)$') {
        $StageValue = $matches[1].Trim().ToLowerInvariant()
    }
    if ($line -match '^\s*HOST\s*=(.*)$') {
        $EnvHost = $matches[1].Trim()
    }
    if ($line -match '^\s*ELASTIC_PASSWORD\s*=(.*)$') {
        $ElasticPassword = $matches[1].Trim()
    }
    if ($StageValue -and $EnvHost -and $ElasticPassword) { break }
}

if (-not $StageValue) {
    Write-Error "STAGE not found in .env. Expected one of: prod, dev, test"
    exit 1
}

if ($StageValue -notin @('prod', 'dev', 'test')) {
    Write-Error "Unsupported STAGE '$StageValue'. Expected one of: prod, dev, test"
    exit 1
}

# Render console config from template
$ConsoleTemplate = Join-Path $ProjectDir '.console/application.yaml.template'
$ConsoleConfig   = Join-Path $ProjectDir '.console/application.yaml'
if ((Test-Path $ConsoleTemplate) -and $EnvHost) {
    $content = Get-Content $ConsoleTemplate -Raw
    $content = $content.Replace('${HOST}', $EnvHost)
    $content | Set-Content $ConsoleConfig -NoNewline
}

# Render optimize config from template
$OptimizeTemplate = Join-Path $ProjectDir '.optimize/environment-config.yaml.example'
$OptimizeConfig   = Join-Path $ProjectDir '.optimize/environment-config.yaml'
if ((Test-Path $OptimizeTemplate) -and $ElasticPassword) {
    $content = Get-Content $OptimizeTemplate -Raw
    $content = $content.Replace('ELASTIC_PASSWORD_PLACEHOLDER', $ElasticPassword)
    $content | Set-Content $OptimizeConfig -NoNewline
}

Write-Host "Starting Camunda stack with STAGE=$StageValue"
docker compose -f (Join-Path $ProjectDir 'docker-compose.yaml') -f (Join-Path $ProjectDir "stages/$StageValue.yaml") up -d
