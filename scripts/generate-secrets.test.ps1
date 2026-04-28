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

Assert-Contains -Text $bashScriptText -Expected 'CAMUNDA_DB_NAME=$(get_val CAMUNDA_DB_NAME)' -Label "generate-secrets.sh"
Assert-Contains -Text $bashScriptText -Expected 'CAMUNDA_DB_USER=$(get_val CAMUNDA_DB_USER)' -Label "generate-secrets.sh"
Assert-Contains -Text $bashScriptText -Expected 'CAMUNDA_DB_PASSWORD=$(gen)' -Label "generate-secrets.sh"
Assert-Contains -Text $bashScriptText -Expected 'POSTGRES_PASSWORD, WEBMODELER_DB_PASSWORD, CAMUNDA_DB_PASSWORD' -Label "generate-secrets.sh"

Assert-Contains -Text $psScriptText -Expected 'CAMUNDA_DB_NAME=$(Get-EnvVal ''CAMUNDA_DB_NAME'')' -Label "generate-secrets.ps1"
Assert-Contains -Text $psScriptText -Expected 'CAMUNDA_DB_USER=$(Get-EnvVal ''CAMUNDA_DB_USER'')' -Label "generate-secrets.ps1"
Assert-Contains -Text $psScriptText -Expected 'CAMUNDA_DB_PASSWORD=$(gen)' -Label "generate-secrets.ps1"
Assert-Contains -Text $psScriptText -Expected 'POSTGRES_PASSWORD, WEBMODELER_DB_PASSWORD, CAMUNDA_DB_PASSWORD' -Label "generate-secrets.ps1"
