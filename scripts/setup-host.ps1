# Setup script for configuring the Camunda Compose NVL environment
# Run this after cloning and before first start if you want to use a different hostname

param(
    [string]$HostsFile = "$env:SystemRoot\System32\drivers\etc\hosts"
)

$ErrorActionPreference = "Stop"

# Read HOST from .env
$envFile = Join-Path $PSScriptRoot "..\.env"
if (-not (Test-Path $envFile)) {
    Write-Error ".env file not found. Run: cp .env.example .env"
}
$envContent = Get-Content $envFile | Where-Object { $_ -notmatch '^\s*#' }
$HOST = $null
foreach ($line in $envContent) {
    if ($line -match '^HOST=(.*)') { $HOST = $matches[1].Trim() }
}
if (-not $HOST) {
    Write-Error "HOST not found in .env"
}

Write-Host "Configuring for HOST=$HOST"

# Update Caddyfile — replace *.localhost with *.$HOST
$CaddyfilePath = Join-Path $PSScriptRoot "..\Caddyfile"
$CaddyfileContent = Get-Content $CaddyfilePath -Raw
$updated = $CaddyfileContent -replace '\b(\w+)\.localhost\b', "`$1.$HOST"
Set-Content -Path $CaddyfilePath -Value $updated -NoNewline
Write-Host "Updated Caddyfile (replaced *.localhost -> *.$HOST)"

# Update hosts file
$subdomains = @("keycloak", "identity", "console", "optimize", "orchestration", "webmodeler")
$hostsEntries = $subdomains | ForEach-Object { "127.0.0.1 $_.$HOST" }
$hostsBlock = "# Camunda Compose NVL - $HOST`n" + ($hostsEntries -join "`n")

# Remove old Camunda entries and add new ones
$hostsLines = @()
if (Test-Path $HostsFile) {
    $hostsLines = Get-Content $HostsFile | Where-Object { $_ -notmatch '# Camunda Compose NVL' }
}
$hostsLines += $hostsBlock
Set-Content -Path $HostsFile -Value $hostsLines
Write-Host "Updated hosts file (replaced *.localhost -> *.$HOST)"

Write-Host "`nDone! Restart Caddy or run: docker compose restart reverse-proxy"