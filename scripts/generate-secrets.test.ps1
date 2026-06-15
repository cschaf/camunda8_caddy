$ErrorActionPreference = "Stop"

$repo = Resolve-Path (Join-Path $PSScriptRoot "..")
$bashScriptText = Get-Content (Join-Path $repo "scripts/generate-secrets.sh") -Raw
$psScriptText = Get-Content (Join-Path $repo "scripts/generate-secrets.ps1") -Raw

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

Assert-Contains -Text $bashScriptText -Expected 'CAMUNDA_DB_NAME=$(get_val_or_default CAMUNDA_DB_NAME)' -Label "generate-secrets.sh"
Assert-Contains -Text $bashScriptText -Expected 'CAMUNDA_DB_USER=$(get_val_or_default CAMUNDA_DB_USER)' -Label "generate-secrets.sh"
Assert-Contains -Text $bashScriptText -Expected 'CAMUNDA_DB_PASSWORD=$CAMUNDA_DB_PASSWORD' -Label "generate-secrets.sh"
Assert-Contains -Text $bashScriptText -Expected '## Camunda License (Optional for non-production, required for production use) ##' -Label "generate-secrets.sh"
Assert-Contains -Text $bashScriptText -Expected "# CAMUNDA_LICENSE_KEY='--------------- BEGIN CAMUNDA LICENSE KEY ---------------" -Label "generate-secrets.sh"
Assert-Contains -Text $bashScriptText -Expected 'POSTGRES_PASSWORD, WEBMODELER_DB_PASSWORD, CAMUNDA_DB_PASSWORD' -Label "generate-secrets.sh"

Assert-Contains -Text $psScriptText -Expected 'CAMUNDA_DB_NAME=$(Get-EnvValOrDefault ''CAMUNDA_DB_NAME'')' -Label "generate-secrets.ps1"
Assert-Contains -Text $psScriptText -Expected 'CAMUNDA_DB_USER=$(Get-EnvValOrDefault ''CAMUNDA_DB_USER'')' -Label "generate-secrets.ps1"
Assert-Contains -Text $psScriptText -Expected 'CAMUNDA_DB_PASSWORD=$camundaDbPassword' -Label "generate-secrets.ps1"
Assert-Contains -Text $psScriptText -Expected '## Camunda License (Optional for non-production, required for production use) ##' -Label "generate-secrets.ps1"
Assert-Contains -Text $psScriptText -Expected "# CAMUNDA_LICENSE_KEY='--------------- BEGIN CAMUNDA LICENSE KEY ---------------" -Label "generate-secrets.ps1"
Assert-Contains -Text $psScriptText -Expected 'POSTGRES_PASSWORD, WEBMODELER_DB_PASSWORD, CAMUNDA_DB_PASSWORD' -Label "generate-secrets.ps1"

$tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("camunda-generate-secrets-test-" + [guid]::NewGuid().ToString("N"))
New-Item -ItemType Directory -Path (Join-Path $tempRoot "scripts") | Out-Null
try {
    Copy-Item -Path (Join-Path $repo ".env") -Destination (Join-Path $tempRoot ".env")
    Copy-Item -Path (Join-Path $repo "scripts/generate-secrets.ps1") -Destination (Join-Path $tempRoot "scripts/generate-secrets.ps1")

    & pwsh -NoProfile -File (Join-Path $tempRoot "scripts/generate-secrets.ps1") | Out-Null
    if ($LASTEXITCODE -ne 0) {
        throw "generate-secrets.ps1 exited with $LASTEXITCODE"
    }

    $generated = Get-Content (Join-Path $tempRoot ".env-credentials") -Raw
    foreach ($expected in @(
        "ORCHESTRATION_CLIENT_ID=orchestration",
        "CONNECTORS_CLIENT_ID=connectors",
        "POSTGRES_DB=bitnami_keycloak",
        "POSTGRES_USER=bn_keycloak",
        "CAMUNDA_DB_NAME=camunda",
        "CAMUNDA_DB_USER=camunda",
        "WEBMODELER_DB_NAME=web-modeler-db",
        "WEBMODELER_DB_USER=web-modeler-db-user",
        "KEYCLOAK_ADMIN_USER=admin",
        "WEBMODELER_PUSHER_APP_ID=web-modeler-app",
        "## Camunda License (Optional for non-production, required for production use) ##",
        "# CAMUNDA_LICENSE_KEY='--------------- BEGIN CAMUNDA LICENSE KEY ---------------"
    )) {
        Assert-Contains -Text $generated -Expected $expected -Label "generated .env-credentials"
    }
}
finally {
    Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
}
