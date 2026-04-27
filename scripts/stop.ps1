#Requires -Version 7

$ErrorActionPreference = 'Stop'

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$ProjectDir = Resolve-Path (Join-Path $ScriptDir '..')

docker compose -f (Join-Path $ProjectDir 'docker-compose.yaml') down
