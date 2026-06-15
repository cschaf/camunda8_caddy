$ErrorActionPreference = "Stop"

$repo = Resolve-Path (Join-Path $PSScriptRoot "..")
$templateText = Get-Content (Join-Path $repo ".console/application.yaml.template") -Raw
$bashStartText = Get-Content (Join-Path $repo "scripts/start.sh") -Raw
$psStartText = Get-Content (Join-Path $repo "scripts/start.ps1") -Raw

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

$expectedVariables = @(
    "CAMUNDA_VERSION",
    "CAMUNDA_CONSOLE_VERSION",
    "CAMUNDA_OPERATE_VERSION",
    "CAMUNDA_TASKLIST_VERSION",
    "CAMUNDA_OPTIMIZE_VERSION",
    "CAMUNDA_IDENTITY_VERSION",
    "KEYCLOAK_SERVER_VERSION",
    "CAMUNDA_WEB_MODELER_VERSION",
    "CAMUNDA_CONNECTORS_VERSION"
)

foreach ($variable in $expectedVariables) {
    Assert-Contains -Text $templateText -Expected "`${$variable}" -Label ".console/application.yaml.template"
    Assert-Contains -Text $bashStartText -Expected "`$$variable" -Label "scripts/start.sh"
    Assert-Contains -Text $psStartText -Expected "'$variable'" -Label "scripts/start.ps1"
}

Assert-Contains -Text $psStartText -Expected '$content = $content.Replace("`${$key}", $EnvValues[$key])' -Label "scripts/start.ps1"
