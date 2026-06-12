#Requires -Version 7
<#
.SYNOPSIS
    Inspect Camunda's private Docker registry (Harbor v2 API): projects, repositories, tags.

.DESCRIPTION
    Reads CAMUNDA_REGISTRY_URL from .env and CAMUNDA_REGISTRY_USERNAME /
    CAMUNDA_REGISTRY_PASSWORD from .env-credentials, then queries the Harbor REST API.

    With no parameters, lists the newest tags for the images used by docker-compose.yaml.

.PARAMETER ListProjects
    List all projects (Harbor namespaces) visible to the configured account.

.PARAMETER Project
    Project name. Without -Repository, lists the repos in the project.

.PARAMETER Repository
    Repository name (e.g. "camunda/console"). Requires -Project. Lists the newest tags.

.PARAMETER Limit
    Number of tags to show per repository (default 10).

.EXAMPLE
    pwsh -File scripts/registry-info.ps1
    pwsh -File scripts/registry-info.ps1 -ListProjects
    pwsh -File scripts/registry-info.ps1 -Project hotfixes
    pwsh -File scripts/registry-info.ps1 -Project dockerhub-camunda -Repository camunda/console -Limit 20
#>

param(
    [switch]$ListProjects,
    [string]$Project,
    [string]$Repository,
    [int]$Limit = 10,
    [switch]$DebugRaw
)

$ErrorActionPreference = 'Stop'

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$ProjectDir = Resolve-Path (Join-Path $ScriptDir '..')
$EnvFile = Join-Path $ProjectDir '.env'
$CredentialsFile = Join-Path $ProjectDir '.env-credentials'

if (-not (Test-Path $EnvFile)) {
    Write-Error ".env file not found. It is part of the repo, so this should not happen."
    Write-Error "Re-clone the repository, or restore .env from your last commit."
    exit 1
}

if (-not (Test-Path $CredentialsFile)) {
    Write-Error ".env-credentials file not found."
    Write-Error "Run one of:"
    Write-Error "  pwsh -File scripts/generate-secrets.ps1             # generate strong random secrets"
    Write-Error "  Copy-Item .env-credentials.example .env-credentials  # copy the demo template"
    exit 1
}

$RegistryUrl = $null
$RegistryUser = $null
$RegistryPassword = $null
foreach ($line in Get-Content $EnvFile) {
    if ($line -match '^\s*#') { continue }
    if ($line -match '^\s*CAMUNDA_REGISTRY_URL\s*=(.*)$')      { $RegistryUrl      = $matches[1].Trim() }
}
foreach ($line in Get-Content $CredentialsFile) {
    if ($line -match '^\s*#') { continue }
    if ($line -match '^\s*CAMUNDA_REGISTRY_USERNAME\s*=(.*)$') { $RegistryUser     = $matches[1].Trim() }
    if ($line -match '^\s*CAMUNDA_REGISTRY_PASSWORD\s*=(.*)$') { $RegistryPassword = $matches[1].Trim() }
}

function Strip-Quotes([string]$value) {
    if ($null -eq $value) { return $null }
    return $value.Trim().Trim('"').Trim("'")
}

$RegistryUrl      = Strip-Quotes $RegistryUrl
$RegistryUser     = Strip-Quotes $RegistryUser
$RegistryPassword = Strip-Quotes $RegistryPassword

if (-not $RegistryUrl)      { Write-Error "CAMUNDA_REGISTRY_URL not set in .env"; exit 1 }
if (-not $RegistryUser)     { Write-Error "CAMUNDA_REGISTRY_USERNAME not set in .env-credentials"; exit 1 }
if (-not $RegistryPassword) { Write-Error "CAMUNDA_REGISTRY_PASSWORD not set in .env-credentials"; exit 1 }

$RegistryUrl = $RegistryUrl.TrimEnd('/')

$AuthBytes = [Text.Encoding]::UTF8.GetBytes("${RegistryUser}:${RegistryPassword}")
$Auth      = [Convert]::ToBase64String($AuthBytes)
$Headers   = @{ Authorization = "Basic $Auth" }

# Returns the parsed JSON body. Uses -AsHashtable so iteration semantics are
# predictable regardless of PowerShell version (PS 7.4+ wraps JSON arrays in
# List[PSObject] which doesn't always unroll cleanly via the pipeline).
function Invoke-RegistryApi([string]$Path) {
    $response = Invoke-WebRequest -Uri "$RegistryUrl/api/v2.0/$Path" -Headers $Headers
    if ($DebugRaw) {
        Write-Host "--- raw response from $Path (truncated to 800 chars) ---" -ForegroundColor DarkGray
        $preview = $response.Content
        if ($preview.Length -gt 800) { $preview = $preview.Substring(0, 800) + '...' }
        Write-Host $preview -ForegroundColor DarkGray
        Write-Host "--- end raw ---" -ForegroundColor DarkGray
    }
    return $response.Content | ConvertFrom-Json -Depth 50 -AsHashtable
}

# Some Harbor endpoints return either a JSON array or a paginated wrapper
# object ({ data: [...] } / { items: [...] }). Normalize to a flat array.
function ConvertTo-Array($value) {
    if ($null -eq $value) { return @() }
    if ($value -is [System.Collections.IList] -and -not ($value -is [System.Collections.IDictionary])) {
        return @($value)
    }
    if ($value -is [System.Collections.IDictionary]) {
        foreach ($key in @('data', 'items', 'projects', 'repositories', 'artifacts', 'results')) {
            if ($value.Contains($key) -and $value[$key] -is [System.Collections.IList]) {
                return @($value[$key])
            }
        }
    }
    return @($value)
}

# Harbor stores repos as "<project>/<repo>". Strip the leading "<project>/" so
# callers can copy-paste the full name from the repositories listing and still
# hit the artifacts endpoint, which expects the bare repo name.
function Get-BareRepoName([string]$ProjectName, [string]$RepoName) {
    $prefix = "$ProjectName/"
    if ($RepoName.StartsWith($prefix)) {
        return $RepoName.Substring($prefix.Length)
    }
    return $RepoName
}

function Show-Tags([string]$ProjectName, [string]$RepoName, [int]$Take) {
    $bareRepo       = Get-BareRepoName $ProjectName $RepoName
    $encodedProject = [uri]::EscapeDataString($ProjectName)
    $encodedRepo    = [uri]::EscapeDataString($bareRepo)
    $artifacts = ConvertTo-Array (Invoke-RegistryApi "projects/$encodedProject/repositories/$encodedRepo/artifacts?with_tag=true&page_size=$([Math]::Max($Take * 2, 20))")
    $tags = foreach ($a in $artifacts) {
        $artifactTags = ConvertTo-Array $a['tags']
        foreach ($t in $artifactTags) {
            [PSCustomObject]@{ Name = $t['name']; Pushed = $t['push_time'] }
        }
    }
    $tags | Sort-Object Pushed -Descending | Select-Object -First $Take
}

if ($ListProjects) {
    Write-Host "Projects on $RegistryUrl" -ForegroundColor Cyan
    $projects = ConvertTo-Array (Invoke-RegistryApi 'projects?page_size=100')
    $rows = foreach ($p in $projects) {
        [PSCustomObject]@{
            Name   = $p['name']
            Repos  = $p['repo_count']
            Public = if ($p.Contains('metadata') -and $p['metadata']) { $p['metadata']['public'] } else { $null }
        }
    }
    $rows | Sort-Object Name | Format-Table -AutoSize
    return
}

if ($Project -and -not $Repository) {
    Write-Host "Repositories in '$Project'" -ForegroundColor Cyan
    $encodedProject = [uri]::EscapeDataString($Project)
    $repos = ConvertTo-Array (Invoke-RegistryApi "projects/$encodedProject/repositories?page_size=100")
    $rows = foreach ($r in $repos) {
        [PSCustomObject]@{
            Name      = $r['name']
            Artifacts = $r['artifact_count']
            Updated   = $r['update_time']
        }
    }
    $rows | Sort-Object Name | Format-Table -AutoSize
    return
}

if ($Project -and $Repository) {
    $bareRepo = Get-BareRepoName $Project $Repository
    Write-Host "Tags for $Project/$bareRepo (newest $Limit)" -ForegroundColor Cyan
    Show-Tags -ProjectName $Project -RepoName $Repository -Take $Limit | Format-Table -AutoSize
    return
}

# Default: tags for the images referenced by docker-compose.yaml
$Defaults = @(
    @{ Project = 'dockerhub-camunda'; Repo = 'camunda/camunda' }
    @{ Project = 'dockerhub-camunda'; Repo = 'camunda/console' }
    @{ Project = 'dockerhub-camunda'; Repo = 'camunda/optimize' }
    @{ Project = 'dockerhub-camunda'; Repo = 'camunda/identity' }
    @{ Project = 'dockerhub-camunda'; Repo = 'camunda/connectors-bundle' }
    @{ Project = 'dockerhub-camunda'; Repo = 'camunda/web-modeler-restapi' }
    @{ Project = 'dockerhub-camunda'; Repo = 'camunda/web-modeler-webapp' }
    @{ Project = 'dockerhub-camunda'; Repo = 'camunda/web-modeler-websockets' }
    @{ Project = 'dockerhub-camunda'; Repo = 'camunda/keycloak' }
)

foreach ($entry in $Defaults) {
    Write-Host "=== $($entry.Project)/$($entry.Repo) (newest $Limit) ===" -ForegroundColor Cyan
    try {
        Show-Tags -ProjectName $entry.Project -RepoName $entry.Repo -Take $Limit | Format-Table -AutoSize
    }
    catch {
        Write-Host "  (error: $($_.Exception.Message))" -ForegroundColor Yellow
    }
}
