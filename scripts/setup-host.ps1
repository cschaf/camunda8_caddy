# Setup script for configuring the Camunda Compose NVL environment
# Run this after cloning and before first start if you want to use a different hostname

param(
    [string]$HostsFile = "$env:SystemRoot\System32\drivers\etc\hosts"
)

$ErrorActionPreference = "Stop"

# Read HOST and optional TLS cert paths from .env (and .env-credentials, for
# consistency with the other scripts — none of the keys below live in
# .env-credentials today, but the order is preserved so future additions
# land predictably).
$projectRoot = Resolve-Path (Join-Path $PSScriptRoot '..')
$envFile         = Join-Path $projectRoot '.env'
$credentialsFile = Join-Path $projectRoot '.env-credentials'
if (-not (Test-Path $envFile) -and -not (Test-Path $credentialsFile)) {
    Write-Error ".env file not found. Run: cp .env.example .env"
}
$EnvHost = $null
$FULLCHAIN_PEM = $null
$PRIVATEKEY_PEM = $null
foreach ($file in @($envFile, $credentialsFile)) {
    if (-not (Test-Path $file)) { continue }
    foreach ($line in Get-Content $file) {
        if ($line -match '^\s*#') { continue }
        if ($line -match '^HOST=(.*)') { $EnvHost = $matches[1].Trim() }
        if ($line -match '^FULLCHAIN_PEM=(.*)') { $FULLCHAIN_PEM = $matches[1].Trim() }
        if ($line -match '^PRIVATEKEY_PEM=(.*)') { $PRIVATEKEY_PEM = $matches[1].Trim() }
    }
}
if (-not $EnvHost) {
    Write-Error "HOST not found in .env"
}

$useCustomTls = $FULLCHAIN_PEM -and $PRIVATEKEY_PEM
if ($useCustomTls) {
    Write-Host "Using custom TLS certificates:"
    Write-Host "  fullchain: $FULLCHAIN_PEM"
    Write-Host "  privatekey: $PRIVATEKEY_PEM"
} else {
    Write-Host "No custom TLS certificates configured — Caddy will generate self-signed certs"
}

Write-Host "Configuring for HOST=$EnvHost"

# Update Caddyfile — replace *.localhost with *.$EnvHost, and standalone localhost with $EnvHost
$CaddyfilePath = Join-Path $PSScriptRoot "..\Caddyfile"
$CaddyfileTemplatePath = Join-Path $PSScriptRoot "..\Caddyfile.example"
if (-not (Test-Path $CaddyfilePath)) {
    Write-Error "Caddyfile not found at $CaddyfilePath"
}
if (-not (Test-Path $CaddyfileTemplatePath)) {
    Write-Error "Caddyfile template not found at $CaddyfileTemplatePath"
}
$CaddyfileContent = Get-Content $CaddyfileTemplatePath -Raw
$updated = $CaddyfileContent -replace '\b(\w+)\.localhost\b', "`$1.$EnvHost"
$updated = $updated -replace '(?m)^localhost\b', $EnvHost

# Also replace any existing non-localhost hostname (e.g., camunda.dev.local -> camunda.prd.local)
# Extract the hostname from the first non-comment, non-blank site block line
$currentHost = ($CaddyfileContent -split "`n" | Where-Object { $_ -notmatch '^\s*#' -and $_ -notmatch '^\s*$' } | Select-Object -First 1) -replace '\s*\{.*', ''
if ($currentHost -and $currentHost -ne $EnvHost) {
    $escaped = [regex]::Escape($currentHost)
    # Replace subdomains (keycloak.oldhost -> keycloak.newhost) and bare hostname (oldhost -> newhost)
    $updated = $updated -replace "\b(\w+)\.$escaped", "`$1.$EnvHost"
    $updated = $updated -replace "\b$escaped\b", $EnvHost
}

# Strip any existing tls directives — prevents stale directives from persisting
# when switching between custom certs and auto-generated certs.
$updated = $updated -replace '(?m)^[ \t]*tls[ \t]+\S+[ \t]+\S+[ \t]*\r?\n', ''

# Add tls directive to each site block if custom certs are provided
if ($useCustomTls) {
    $tlsBlock = "tls $FULLCHAIN_PEM $PRIVATEKEY_PEM"
    # Insert tls directive only after top-level site block opening braces.
    # Top-level blocks start at column 0 (no leading whitespace), e.g.:
    #   keycloak.example.com {
    # Nested blocks (@options, handle, reverse_proxy) are indented and must NOT get a tls line.
    $updated = $updated -replace '(?m)^(\S[^\n]*\{[ \t]*\r?\n)', "`$1    $tlsBlock`n"
}

Set-Content -Path $CaddyfilePath -Value $updated -NoNewline
Write-Host "Updated Caddyfile (replaced *.localhost -> *.$EnvHost)$(if($useCustomTls){' + added tls directive'})"

# Update hosts file
$subdomains = @("keycloak", "identity", "console", "optimize", "orchestration", "webmodeler", "zeebe")
$hostsEntries = @("127.0.0.1 $EnvHost") + ($subdomains | ForEach-Object { "127.0.0.1 $_.$EnvHost" })
$hostsBlock = "# Camunda Compose NVL - $EnvHost`n" + ($hostsEntries -join "`n")

# Remove old Camunda entries and add new ones
$hostsLines = @()
if (Test-Path $HostsFile) {
    $hostsLines = Get-Content $HostsFile | Where-Object { $_ -notmatch '# Camunda Compose NVL' }
}
$hostsLines += $hostsBlock
Set-Content -Path $HostsFile -Value $hostsLines
Write-Host "Updated hosts file (replaced *.localhost -> *.$EnvHost)"

Write-Host "`nDone! Restart the stack with: pwsh -File scripts/start.ps1"
