$ErrorActionPreference = "Stop"

$repo = Resolve-Path (Join-Path $PSScriptRoot "..")
$composeText = Get-Content (Join-Path $repo "docker-compose.yaml") -Raw

function Assert-Contains {
    param(
        [string]$Text,
        [string]$Expected,
        [string]$Label
    )

    if (-not $Text.Contains($Expected)) {
        throw "Expected $Label to contain '$Expected'"
    }
}

$optimizeMatch = [regex]::Match(
    $composeText,
    "(?ms)^  optimize:.*?(?=^  [a-zA-Z0-9_-]+:|\z)"
)

if (-not $optimizeMatch.Success) {
    throw "Could not find optimize service in docker-compose.yaml"
}

$optimizeService = $optimizeMatch.Value

Assert-Contains -Text $optimizeService -Expected "CAMUNDA_IDENTITY_CLIENT_ID: optimize" -Label "optimize service"
Assert-Contains -Text $optimizeService -Expected 'CAMUNDA_IDENTITY_CLIENT_SECRET: ${OPTIMIZE_CLIENT_SECRET:?OPTIMIZE_CLIENT_SECRET is required}' -Label "optimize service"
Assert-Contains -Text $optimizeService -Expected "CAMUNDA_IDENTITY_AUDIENCE: optimize-api" -Label "optimize service"
Assert-Contains -Text $optimizeService -Expected 'CAMUNDA_IDENTITY_ISSUER: https://keycloak.${HOST:?HOST is required}/auth/realms/camunda-platform' -Label "optimize service"
Assert-Contains -Text $optimizeService -Expected 'CAMUNDA_IDENTITY_ISSUER_BACKEND_URL: http://${KEYCLOAK_HOST:?KEYCLOAK_HOST is required}:18080/auth/realms/camunda-platform' -Label "optimize service"
Assert-Contains -Text $optimizeService -Expected "CAMUNDA_IDENTITY_BASE_URL: http://identity:8084" -Label "optimize service"
