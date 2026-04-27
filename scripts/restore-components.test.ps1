$ErrorActionPreference = "Stop"

$repo = Resolve-Path (Join-Path $PSScriptRoot "..")

function Assert-Contains {
    param(
        [string]$Text,
        [string]$Expected
    )

    if (-not $Text.Contains($Expected)) {
        throw "Expected output to contain '$Expected'. Output was:`n$Text"
    }
}

$bashRestore = Get-Content (Join-Path $repo "scripts/restore.sh") -Raw
Assert-Contains -Text $bashRestore -Expected "--components LIST"
Assert-Contains -Text $bashRestore -Expected "keycloak,webmodeler,elasticsearch,orchestration,configs"
Assert-Contains -Text $bashRestore -Expected "--rehost-keycloak"

$pwshHelp = & pwsh -NoProfile -File (Join-Path $repo "scripts/restore.ps1") --help 2>&1
if ($LASTEXITCODE -ne 0) {
    throw "restore.ps1 --help failed with exit code $LASTEXITCODE"
}

Assert-Contains -Text ($pwshHelp -join "`n") -Expected "--components LIST"
Assert-Contains -Text ($pwshHelp -join "`n") -Expected "keycloak,webmodeler,elasticsearch,orchestration,configs"
Assert-Contains -Text ($pwshHelp -join "`n") -Expected "--rehost-keycloak"
