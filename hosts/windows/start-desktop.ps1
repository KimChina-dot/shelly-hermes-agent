$ErrorActionPreference = "Stop"
$Root = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
Set-Location $Root
if (-not (Test-Path (Join-Path $Root "node_modules"))) { npm install }
npm run desktop -- @args
