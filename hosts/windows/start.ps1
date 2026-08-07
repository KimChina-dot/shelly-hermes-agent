$ErrorActionPreference = "Stop"

$Root = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$EnvFile = Join-Path $Root ".env"
if (Test-Path $EnvFile) {
  Get-Content $EnvFile | ForEach-Object {
    $line = $_.Trim()
    if ($line -and -not $line.StartsWith("#")) {
      $pair = $line.Split("=", 2)
      if ($pair.Length -eq 2) { [Environment]::SetEnvironmentVariable($pair[0].Trim(), $pair[1].Trim(), "Process") }
    }
  }
}
if (-not $env:SHELLY_WORKSPACE) { $env:SHELLY_WORKSPACE = (Get-Location).Path }
Set-Location $Root
if (-not (Test-Path (Join-Path $Root "node_modules"))) { npm install }
npm run cli
