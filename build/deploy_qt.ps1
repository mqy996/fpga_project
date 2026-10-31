param([string]$QtRoot = $env:QT_ROOT)
$ErrorActionPreference = 'Stop'
$root=Split-Path -Parent $PSScriptRoot
if ([string]::IsNullOrWhiteSpace($QtRoot)) { $QtRoot='D:\Qt\6.8.3\mingw_64' }
$exe=Join-Path $root 'build_output/qt/QtControlHost_v6.exe'
$out=Join-Path $root 'build_output/qt_portable'
$tool=Join-Path $QtRoot 'bin/windeployqt.exe'
if (-not (Test-Path -LiteralPath $exe)) { throw 'Run build_qt.ps1 first.' }
if (-not (Test-Path -LiteralPath $tool)) { throw 'Set QT_ROOT to your Qt 6.8.3 installation.' }
New-Item -ItemType Directory -Path $out -Force | Out-Null
Copy-Item -LiteralPath $exe -Destination $out -Force
& $tool --release --compiler-runtime --no-translations --dir $out (Join-Path $out 'QtControlHost_v6.exe')
if ($LASTEXITCODE -ne 0) { throw 'windeployqt failed.' }
Write-Host "Portable program: $out"
