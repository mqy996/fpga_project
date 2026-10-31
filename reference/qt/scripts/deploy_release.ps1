$ErrorActionPreference = 'Stop'
$projectRoot = Split-Path -Parent $PSScriptRoot

function Resolve-FirstExistingPath([string[]]$paths, [string]$label) {
    foreach ($p in $paths) {
        if (Test-Path -LiteralPath $p) { return $p }
    }
    throw "Required path for '$label' not found. Checked: $($paths -join ', ')"
}

$qtRoot = Resolve-FirstExistingPath @(
    'D:\Qt\6.8.3\mingw_64',
    'D:\project\FPGASTM32\Qt\6.8.3\mingw_64'
) 'Qt root'

$windeployqt = Join-Path $qtRoot 'bin\windeployqt.exe'
$exe = Join-Path $projectRoot 'build_v6\QtControlHost_v6.exe'
$dist = Join-Path $projectRoot 'dist\QtControlHost_v6'
if (-not (Test-Path -LiteralPath $exe)) { throw "Release executable not found: $exe. Run scripts\build_release.ps1 first." }
if (-not (Test-Path -LiteralPath $windeployqt)) { throw "windeployqt not found: $windeployqt" }
New-Item -ItemType Directory -Force -Path $dist | Out-Null
Copy-Item -Force $exe (Join-Path $dist 'QtControlHost_v6.exe')
& $windeployqt --release --compiler-runtime --no-translations --dir $dist (Join-Path $dist 'QtControlHost_v6.exe')
if ($LASTEXITCODE -ne 0) { throw 'windeployqt failed.' }
Copy-Item -Force (Join-Path $projectRoot 'README.md') $dist
Write-Host "PASS: Portable release directory: $dist"
