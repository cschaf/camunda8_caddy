$ErrorActionPreference = "Stop"

$repo = Resolve-Path (Join-Path $PSScriptRoot "..")
$scriptText = Get-Content (Join-Path $repo "scripts/setup-host.sh") -Raw
$psScriptText = Get-Content (Join-Path $repo "scripts/setup-host.ps1") -Raw

function Assert-Contains {
    param(
        [string]$Text,
        [string]$Expected
    )

    if (-not $Text.Contains($Expected)) {
        throw "Expected setup-host.sh to contain '$Expected'"
    }
}

Assert-Contains -Text $scriptText -Expected 'CADDYFILE_TEMPLATE="$PROJECT_DIR/Caddyfile.example"'
Assert-Contains -Text $scriptText -Expected 'cp "$CADDYFILE_TEMPLATE" "$CADDYFILE"'

Assert-Contains -Text $psScriptText -Expected '$CaddyfileTemplatePath = Join-Path $PSScriptRoot "..\Caddyfile.example"'
Assert-Contains -Text $psScriptText -Expected '$CaddyfileContent = Get-Content $CaddyfileTemplatePath -Raw'
