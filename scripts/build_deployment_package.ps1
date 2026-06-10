#Requires -Version 7
<#
.SYNOPSIS
    Builds a deployment zip for the Camunda 8 Self-Managed stack.

.DESCRIPTION
    Copies a curated list of project files (configs, scripts, docs,
    dashboard assets) into a timestamped zip under build/. The zip can
    be unzipped on a target host to recreate a working copy of the
    project, after which the operator follows the "First Start Setup"
    section in README.md (fresh install) or docs/update_guide.md
    (updating an existing deployment).

    The file list is a whitelist: anything not explicitly listed is
    excluded. A safety-net pass after the copy step additionally
    removes any AI-tooling artifact that may have slipped in via a
    wildcard (e.g. CLAUDE.md, AGENT.md, .claude/, .worktrees/).

    Files that are intentionally NOT included:
      - Local secrets and rendered configs:
          .env, Caddyfile, connector-secrets.txt, certs/,
          .optimize/environment-config.yaml, .console/application.yaml
      - AI assistant artifacts:
          CLAUDE.md, AGENT.md, AGENTS.md, GEMINI.md, .claude/,
          .playwright-mcp/
      - Dev / runtime:
          .worktrees/, backups/, tests/, *.log, *.har, monitor.log*
      - VCS metadata: .git/

.PARAMETER OutputDir
    Directory to write the zip into. Defaults to './build' (relative
    to the project root). Created if it does not exist.

.PARAMETER ProjectRoot
    Project root to read from. Defaults to the parent of this
    script's directory (the CamundaComposeNVL repo root).

.EXAMPLE
    pwsh -File scripts/build_deployment_package.ps1

    Creates build/camunda-deployment-<timestamp>.zip from the project
    files in the repo.

.EXAMPLE
    pwsh -File scripts/build_deployment_package.ps1 -OutputDir ./dist

    Writes the zip into ./dist/ instead of ./build/.
#>
[CmdletBinding()]
param(
    [string]$OutputDir = 'build',
    [string]$ProjectRoot
)

$ErrorActionPreference = 'Stop'

# --- Resolve project root ------------------------------------------------
if (-not $ProjectRoot) {
    $ProjectRoot = Resolve-Path (Join-Path $PSScriptRoot '..')
} else {
    $ProjectRoot = Resolve-Path $ProjectRoot
}

if (-not (Test-Path (Join-Path $ProjectRoot 'docker-compose.yaml'))) {
    throw "Project root '$ProjectRoot' does not contain docker-compose.yaml. Pass -ProjectRoot to point at the repo root."
}

# --- Resolve output directory -------------------------------------------
if (-not [System.IO.Path]::IsPathRooted($OutputDir)) {
    $OutputDir = Join-Path $ProjectRoot $OutputDir
}
if (-not (Test-Path $OutputDir)) {
    New-Item -ItemType Directory -Path $OutputDir -Force | Out-Null
}

# --- File whitelist ------------------------------------------------------
# Concrete file paths (relative to project root):
$Files = [System.Collections.Generic.List[string]]::new()

# Top-level entry points
$Files.AddRange([string[]]@(
    'README.md'
    '.env.example'
    '.gitignore'
    'docker-compose.yaml'
    'Caddyfile.example'
    'connector-secrets.txt.example'
))

# Config templates only. The rendered counterparts are gitignored because
# they contain real secrets; never pick them up.
$Files.AddRange([string[]]@(
    '.orchestration/application.yaml'
    '.identity/application.yaml'
    '.connectors/application.yaml'
    '.optimize/environment-config.yaml.example'
    '.console/application.yaml.template'
))

# Operator docs
$Files.AddRange([string[]]@(
    'docs/project_configuration.md'
    'docs/cluster_upgrade.md'
    'docs/update_guide.md'
    'docs/backup-restore.md'
    'docs/stage_comparison.md'
    'docs/agentic-ai.md'
    'docs/monitoring.md'
))

# Directory trees (copied recursively)
$Directories = @(
    'scripts'
    'stages'
    'dashboard'
)

# --- Sanity check the whitelist -----------------------------------------
$Missing = [System.Collections.Generic.List[string]]::new()
foreach ($rel in ($Files + $Directories)) {
    if (-not (Test-Path (Join-Path $ProjectRoot $rel))) {
        $Missing.Add($rel)
    }
}
if ($Missing.Count -gt 0) {
    Write-Warning ('The following expected paths were not found in the project root and will be skipped:')
    foreach ($m in $Missing) { Write-Warning "  - $m" }
}

# --- Stage files into a temp directory ----------------------------------
$Timestamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$StagingDir = Join-Path ([System.IO.Path]::GetTempPath()) "camunda-deploy-$Timestamp"
New-Item -ItemType Directory -Path $StagingDir -Force | Out-Null

try {
    foreach ($rel in $Files) {
        $src = Join-Path $ProjectRoot $rel
        $dst = Join-Path $StagingDir $rel
        $dstParent = Split-Path -Parent $dst
        if (-not (Test-Path $dstParent)) {
            New-Item -ItemType Directory -Path $dstParent -Force | Out-Null
        }
        Copy-Item -Path $src -Destination $dst -Force
    }

    foreach ($dir in $Directories) {
        $srcDir = Join-Path $ProjectRoot $dir
        if (-not (Test-Path $srcDir)) { continue }
        # Copy the *contents* of the source directory into <staging>/<dir>/.
        # Using Get-ChildItem | Copy-Item avoids Copy-Item's habit of nesting
        # the source basename under the destination (i.e. <staging>/scripts/scripts/).
        $dstDir = Join-Path $StagingDir $dir
        if (-not (Test-Path $dstDir)) {
            New-Item -ItemType Directory -Path $dstDir -Force | Out-Null
        }
        Get-ChildItem -Path $srcDir -Force | Copy-Item -Destination $dstDir -Recurse -Force
    }

    # --- Safety net: strip anything AI-tooling-related -------------------
    $Forbidden = @(
        'CLAUDE.md', 'AGENT.md', 'AGENTS.md', 'GEMINI.md',
        '.claude', '.playwright-mcp', '.worktrees',
        'docs/superpowers', 'docs/specs',
        'backups', 'backups-encrypted', 'tests',
        'monitor.log', 'monitor.log.*',
        '.git'
    )
    $Stripped = [System.Collections.Generic.List[string]]::new()
    foreach ($name in $Forbidden) {
        $path = Join-Path $StagingDir $name
        if (Test-Path $path) {
            Remove-Item -Path $path -Recurse -Force
            $Stripped.Add($name)
        }
    }

    # --- Build the zip ---------------------------------------------------
    $ZipName = "camunda-deployment-$Timestamp.zip"
    $ZipPath = Join-Path $OutputDir $ZipName
    if (Test-Path $ZipPath) {
        Remove-Item $ZipPath -Force
    }
    Compress-Archive -Path (Join-Path $StagingDir '*') -DestinationPath $ZipPath -CompressionLevel Optimal

    # --- Summary ---------------------------------------------------------
    $FileCount = (Get-ChildItem -Path $StagingDir -Recurse -File | Measure-Object).Count
    $SizeBytes = (Get-Item $ZipPath).Length
    $SizeMb = [math]::Round($SizeBytes / 1MB, 2)
    Write-Host ''
    Write-Host 'Deployment package built:' -ForegroundColor Green
    Write-Host "  Path:   $ZipPath"
    Write-Host "  Size:   $SizeMb MB ($SizeBytes bytes)"
    Write-Host "  Files:  $FileCount"
    if ($Stripped.Count -gt 0) {
        Write-Host ''
        Write-Host 'Stripped (safety-net pass):' -ForegroundColor Yellow
        foreach ($s in $Stripped) { Write-Host "  - $s" }
    }
    Write-Host ''
    Write-Host 'Extract on the target host and follow README.md (First Start Setup)'
    Write-Host 'or docs/update_guide.md (existing deployment).'
}
finally {
    if (Test-Path $StagingDir) {
        Remove-Item -Path $StagingDir -Recurse -Force
    }
}
