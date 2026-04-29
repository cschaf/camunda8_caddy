$ErrorActionPreference = "Stop"

$repo = Resolve-Path (Join-Path $PSScriptRoot "..")
$scriptText = Get-Content (Join-Path $repo "scripts/setup-host.sh") -Raw
$psScriptText = Get-Content (Join-Path $repo "scripts/setup-host.ps1") -Raw
$caddyfileTemplate = Get-Content (Join-Path $repo "Caddyfile.example") -Raw

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

Assert-Contains -Text $caddyfileTemplate -Expected '@console-fonts {'
Assert-Contains -Text $caddyfileTemplate -Expected 'path_regexp ^/assets/~@ibm/plex/.+\.woff2$'
Assert-Contains -Text $caddyfileTemplate -Expected 'handle @console-fonts {'
Assert-Contains -Text $caddyfileTemplate -Expected 'respond "Console font asset not bundled" 404'
