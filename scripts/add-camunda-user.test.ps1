$ErrorActionPreference = "Stop"

$repo = Resolve-Path (Join-Path $PSScriptRoot "..")
$scriptText = Get-Content (Join-Path $repo "scripts/add-camunda-user.sh") -Raw

function Assert-Contains {
    param(
        [string]$Text,
        [string]$Expected
    )

    if (-not $Text.Contains($Expected)) {
        throw "Expected add-camunda-user.sh to contain '$Expected'"
    }
}

Assert-Contains -Text $scriptText -Expected "check_host_resolution()"
Assert-Contains -Text $scriptText -Expected 'ERROR: Cannot resolve ${label} host'
Assert-Contains -Text $scriptText -Expected "Run: bash scripts/setup-host.sh"
Assert-Contains -Text $scriptText -Expected "KEYCLOAK_HOST=keycloak is the internal Docker hostname"
Assert-Contains -Text $scriptText -Expected 'KEYCLOAK_HOST="keycloak.${HOST}"'
Assert-Contains -Text $scriptText -Expected 'check_host_resolution "Keycloak" "$KEYCLOAK_HOST"'
Assert-Contains -Text $scriptText -Expected 'check_host_resolution "Orchestration" "$ORCHESTRATION_HOST"'
Assert-Contains -Text $scriptText -Expected "Keycloak token endpoint returned non-JSON"
Assert-Contains -Text $scriptText -Expected "Response body preview"
