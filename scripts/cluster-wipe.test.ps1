$ErrorActionPreference = "Stop"

$repo = Resolve-Path (Join-Path $PSScriptRoot "..")
$shText = Get-Content (Join-Path $repo "scripts/cluster-wipe.sh") -Raw
$psText = Get-Content (Join-Path $repo "scripts/cluster-wipe.ps1") -Raw

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

# Shared safety markers (files must be kept, destructive action gated).
foreach ($pair in @(@($shText, "cluster-wipe.sh"), @($psText, "cluster-wipe.ps1"))) {
    $text = $pair[0]
    $label = $pair[1]
    Assert-Contains -Text $text -Expected "Type WIPE" -Label $label
    Assert-Contains -Text $text -Expected "Kept (never touched)" -Label $label
    Assert-Contains -Text $text -Expected "DELETE (data loss)" -Label $label
    Assert-Contains -Text $text -Expected "elastic-backup" -Label $label
}

Assert-Contains -Text $shText -Expected "--keep-volumes" -Label "cluster-wipe.sh"
Assert-Contains -Text $shText -Expected "--prune-build" -Label "cluster-wipe.sh"
Assert-Contains -Text $psText -Expected "-KeepVolumes" -Label "cluster-wipe.ps1"
Assert-Contains -Text $psText -Expected "-PruneBuild" -Label "cluster-wipe.ps1"

# Dry run must change nothing and print the plan.
$out = & pwsh -NoProfile -File (Join-Path $repo "scripts/cluster-wipe.ps1") -DryRun 2>&1
if ($LASTEXITCODE -ne 0) {
    throw "cluster-wipe.ps1 -DryRun exited with $LASTEXITCODE"
}
$joined = ($out -join "`n")
if ($joined -notmatch '\[dry-run\]') {
    throw "Expected dry-run output. Got: $joined"
}
if ($joined -notmatch 'would run') {
    throw "Expected a dry-run plan. Got: $joined"
}

exit 0
