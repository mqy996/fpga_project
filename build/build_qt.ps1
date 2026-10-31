param(
    [string]$QtRoot = $env:QT_ROOT,
    [string]$MingwBin = $env:MINGW_BIN,
    [string]$Cmake = 'cmake',
    [string]$Ninja = 'ninja'
)
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
if ([string]::IsNullOrWhiteSpace($QtRoot)) {
    foreach ($p in @('D:\Qt\6.8.3\mingw_64','D:\project\FPGASTM32\Qt\6.8.3\mingw_64')) { if (Test-Path -LiteralPath $p) { $QtRoot=$p; break } }
}
if ([string]::IsNullOrWhiteSpace($MingwBin)) {
    foreach ($p in @('D:\Qt\Tools\Tools\mingw1310_64\bin','D:\project\FPGASTM32\Qt\Tools\Tools\mingw1310_64\bin')) { if (Test-Path -LiteralPath $p) { $MingwBin=$p; break } }
}
if (-not $QtRoot -or -not $MingwBin) { throw 'Set QT_ROOT and MINGW_BIN, or supply -QtRoot and -MingwBin.' }
$env:PATH="$QtRoot\bin;$MingwBin;$env:PATH"
$source=Join-Path $root 'build_output/qt_source'
$build=Join-Path $root 'build_output/qt'
New-Item -ItemType Directory -Force -Path $source | Out-Null
Copy-Item -LiteralPath (Join-Path $root 'qt/src'),(Join-Path $root 'qt/tests') -Destination $source -Recurse -Force
# CMake requires this canonical filename; only generated build files use uppercase.
Copy-Item -LiteralPath (Join-Path $root 'qt/cmakelists.txt') -Destination (Join-Path $source 'CMakeLists.txt') -Force
& $Cmake -S $source -B $build -G Ninja "-DCMAKE_MAKE_PROGRAM=$Ninja" "-DCMAKE_PREFIX_PATH=$QtRoot" '-DCMAKE_BUILD_TYPE=Release' '-DBUILD_TESTING=ON'
if ($LASTEXITCODE -ne 0) { throw 'Qt configure failed.' }
& $Cmake --build $build --config Release
if ($LASTEXITCODE -ne 0) { throw 'Qt build failed.' }
foreach ($test in @('protocol_tests','controlclient_mock_tests','monitor_math_tests')) {
    & (Join-Path $build ($test+'.exe'))
    if ($LASTEXITCODE -ne 0) { throw "Test failed: $test" }
}
Write-Host "PASS: Qt build and all three existing tests: $build"
