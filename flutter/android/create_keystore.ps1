# Generates the release signing keystore and android/key.properties.
# The keystore and key.properties are personal secrets: NEVER commit them.
# Usage:  powershell -File android\create_keystore.ps1
# Env overrides: SHELLY_KEYSTORE_PATH, SHELLY_KEYSTORE_PASSWORD, SHELLY_KEY_ALIAS

$ErrorActionPreference = "Stop"

$androidDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$keystorePath = if ($env:SHELLY_KEYSTORE_PATH) { $env:SHELLY_KEYSTORE_PATH } else { Join-Path $androidDir "shelly-release.jks" }
$storePassword = if ($env:SHELLY_KEYSTORE_PASSWORD) { $env:SHELLY_KEYSTORE_PASSWORD } else { Read-Host "Keystore password (min 6 chars)" }
$keyAlias = if ($env:SHELLY_KEY_ALIAS) { $env:SHELLY_KEY_ALIAS } else { "shelly" }
$keyPassword = $storePassword

if (Test-Path $keystorePath) {
    Write-Host "Keystore already exists at $keystorePath - not overwriting."
} else {
    $keytool = Join-Path $env:JAVA_HOME "bin\keytool.exe"
    if (-not (Test-Path $keytool)) { $keytool = "keytool" }
    & $keytool -genkeypair -v `
        -keystore $keystorePath `
        -alias $keyAlias `
        -keyalg RSA -keysize 2048 -validity 10950 `
        -storepass $storePassword -keypass $keyPassword `
        -dname "CN=Shelly Hermes, OU=Shelly, O=Shelly, C=CN"
    if ($LASTEXITCODE -ne 0) { throw "keytool failed" }
    Write-Host "Keystore written to $keystorePath"
}

$properties = @"
storeFile=$($keystorePath -replace '\\', '/')
storePassword=$storePassword
keyAlias=$keyAlias
keyPassword=$keyPassword
"@
Set-Content -Path (Join-Path $androidDir "key.properties") -Value $properties -Encoding ascii
Write-Host "android/key.properties written. Keep both files out of version control."
