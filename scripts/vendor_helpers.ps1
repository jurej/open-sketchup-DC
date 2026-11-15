# Open DC - modern Dynamic Components for SketchUp
# Copyright (C) 2026 Jure Judež and contributors
# SPDX-License-Identifier: AGPL-3.0-or-later

# Vendors open_sketchup_helpers.rb from the framework repo and wraps it as
# OpenSketchupDC::OpenDC::Helpers. Re-run to update the vendored copy.
$ErrorActionPreference = 'Stop'

$srcPath = Join-Path $PSScriptRoot '..\..\open-sketchup-framework\src\open_sketchup_helpers.rb'
$outDir  = Join-Path $PSScriptRoot '..\plugins\OpenSketchupDC_OpenDC'
$outPath = Join-Path $outDir 'helpers.rb'

$src   = Get-Content -Raw $srcPath
$lines = $src -split "`r?`n"

$mi = [Array]::IndexOf($lines, 'module OpenSketchUpHelpers')
if ($mi -lt 0) { throw 'Could not find "module OpenSketchUpHelpers" in source.' }

$lastEnd = $lines.Count - 1
while ($lines[$lastEnd] -notmatch '^\s*end\s*$') { $lastEnd-- }

$body = $lines[($mi + 1)..($lastEnd - 1)]
$indented = $body | ForEach-Object { if ($_ -match '\S') { '    ' + $_ } else { '' } }

$out = @(
  '# Open DC - modern Dynamic Components for SketchUp'
  '# Copyright (C) 2026 Jure Judez and contributors'
  '# SPDX-License-Identifier: AGPL-3.0-or-later'
  ''
  '# Open SketchUp Framework - Helpers Module'
  '# Version: 0.3.0 - vendored copy wrapped as OpenSketchupDC::OpenDC::Helpers'
  '# Source: open-sketchup-framework/src/open_sketchup_helpers.rb'
  '# Regenerate with: powershell -File scripts/vendor_helpers.ps1'
  ''
  'module OpenSketchupDC'
  '  module OpenDC'
  '    module Helpers'
) + $indented + @(
  '    end'
  '  end'
  'end'
)

New-Item -ItemType Directory -Force -Path $outDir | Out-Null
Set-Content -Path $outPath -Value ($out -join "`r`n") -NoNewline
Write-Output "Wrote $outPath ($($out.Count) lines)"
