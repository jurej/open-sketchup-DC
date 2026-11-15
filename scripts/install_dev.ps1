# Open DC - modern Dynamic Components for SketchUp
# Copyright (C) 2026 Jure Judež and contributors
# SPDX-License-Identifier: AGPL-3.0-or-later

# Copies the plugin into SketchUp's Plugins folder for development.
# Re-run after changes (or set up a junction for live editing).
# Usage: powershell -File scripts/install_dev.ps1 [-SketchUpVersion 2024]
param(
  [string]$SketchUpVersion = ""
)

$ErrorActionPreference = 'Stop'
$root   = Split-Path -Parent $PSScriptRoot
$src    = Join-Path $root 'plugins'
$suRoot = Join-Path $env:APPDATA 'SketchUp'

if (-not (Test-Path $suRoot)) {
  throw "SketchUp AppData folder not found at $suRoot. Is SketchUp installed?"
}

$versions = if ($SketchUpVersion) {
  @((Get-Item (Join-Path $suRoot "SketchUp $SketchUpVersion")))
} else {
  Get-ChildItem $suRoot -Directory | Where-Object { $_.Name -match '^SketchUp \d{4}' }
}

if (-not $versions) { throw "No SketchUp versions found under $suRoot." }

foreach ($v in $versions) {
  $pluginsDir = Join-Path $v.FullName 'SketchUp\Plugins'
  New-Item -ItemType Directory -Force -Path $pluginsDir | Out-Null

  Copy-Item (Join-Path $src 'OpenSketchupDC_OpenDC.rb') $pluginsDir -Force
  Copy-Item -Recurse (Join-Path $src 'OpenSketchupDC_OpenDC') $pluginsDir -Force

  Write-Output "Installed to $pluginsDir"
}

Write-Output "Restart SketchUp to load the extension."
