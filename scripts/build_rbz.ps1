# Builds dist/OpenSketchupDC_OpenDC_v<VERSION>.rbz (an .rbz is just a ZIP).
# Usage: powershell -File scripts/build_rbz.ps1
$ErrorActionPreference = 'Stop'

$root = Split-Path -Parent $PSScriptRoot
$dist = Join-Path $root 'dist'
New-Item -ItemType Directory -Force -Path $dist | Out-Null

# Read the version from the registration file.
$reg = Get-Content -Raw (Join-Path $root 'plugins\OpenSketchupDC_OpenDC\constants.rb')
if ($reg -notmatch 'VERSION = "([^"]+)"') { throw 'VERSION not found in constants.rb' }
$version = $Matches[1]

$staging = Join-Path $env:TEMP 'opendc_rbz_staging'
Remove-Item -Recurse -Force $staging -ErrorAction SilentlyContinue
New-Item -ItemType Directory -Force -Path $staging | Out-Null

Copy-Item (Join-Path $root 'plugins\OpenSketchupDC_OpenDC.rb') $staging
Copy-Item -Recurse (Join-Path $root 'plugins\OpenSketchupDC_OpenDC') $staging

$zip = Join-Path $dist "OpenSketchupDC_OpenDC_v$version.zip"
$rbz = [System.IO.Path]::ChangeExtension($zip, '.rbz')
Compress-Archive -Path "$staging\*" -DestinationPath $zip -Force
Move-Item $zip $rbz -Force
Remove-Item -Recurse -Force $staging

Write-Output "Built $rbz"
