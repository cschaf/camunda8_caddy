#Requires -Version 7

$ErrorActionPreference = 'Stop'

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$ProjectDir = Resolve-Path (Join-Path $ScriptDir '..')
$EnvFile         = Join-Path $ProjectDir '.env'
$CredentialsFile = Join-Path $ProjectDir '.env-credentials'

# Pass both .env (committed, non-secret config) and .env-credentials (gitignored,
# secrets) so docker compose can interpolate every ${VAR} reference in
# docker-compose.yaml — including the required ones like
# ORCHESTRATION_CLIENT_SECRET. The same flag pair is used by start.ps1.
# Use the splat pattern (`docker @ComposeArgs`) so PowerShell expands the
# array as separate arguments — the call-operator form `& $ComposeArgs` joins
# the array into a single command string and breaks.
$ComposeArgs = @(
    'compose',
    '--env-file', $EnvFile,
    '--env-file', $CredentialsFile,
    '-f', (Join-Path $ProjectDir 'docker-compose.yaml'),
    'down'
)
docker @ComposeArgs
