$ErrorActionPreference = 'Stop'
$projectRoot = Split-Path -Parent $PSScriptRoot

function Resolve-FirstExistingPath([string[]]$paths, [string]$label) {
    foreach ($p in $paths) {
        if (Test-Path -LiteralPath $p) { return $p }
    }
    throw "Required build path for '$label' not found. Checked: $($paths -join ', ')"
}

$qtRoot = Resolve-FirstExistingPath @(
    'D:\Qt\6.8.3\mingw_64',
    'D:\project\FPGASTM32\Qt\6.8.3\mingw_64'
) 'Qt root'

$cmake = Resolve-FirstExistingPath @(
    'D:\vitis\2025.1\tps\win64\cmake-3.24.2\bin\cmake.exe',
    'D:\project\FPGASTM32\Qt\Tools\Tools\CMake_64\bin\cmake.exe'
) 'CMake'

$ninja = Resolve-FirstExistingPath @(
    'C:\Users\25651\miniconda3\Scripts\ninja.exe',
    'D:\vitis\2025.1\Vivado\bin\ninja.exe',
    'D:\project\FPGASTM32\Qt\Tools\Tools\Ninja\ninja.exe'
) 'Ninja'

$mingwBin = Resolve-FirstExistingPath @(
    'D:\Qt\Tools\Tools\mingw1310_64\bin',
    'D:\project\FPGASTM32\Qt\Tools\Tools\mingw1310_64\bin'
) 'MinGW bin'

$env:PATH = "$qtRoot\bin;$mingwBin;$env:PATH"
$buildDir = Join-Path $projectRoot 'build_v6'
& $cmake -S $projectRoot -B $buildDir -G Ninja `
    "-DCMAKE_MAKE_PROGRAM=$ninja" `
    "-DCMAKE_PREFIX_PATH=$qtRoot" `
    '-DCMAKE_BUILD_TYPE=Release' `
    '-DBUILD_TESTING=ON'
if ($LASTEXITCODE -ne 0) { throw 'CMake configure failed.' }
& $cmake --build $buildDir --config Release
if ($LASTEXITCODE -ne 0) { throw 'Release build failed.' }
foreach ($testName in @('protocol_tests.exe', 'controlclient_mock_tests.exe', 'monitor_math_tests.exe')) {
    # Run directly so the Qt and MinGW directories placed in PATH above are
    # inherited on Windows.  CTest launched by some CMake distributions drops
    # that process-local PATH and incorrectly reports 0xc0000135.
    & (Join-Path $buildDir $testName)
    if ($LASTEXITCODE -ne 0) { throw "Test failed: $testName" }
}
Write-Host "PASS: Release executable: $(Join-Path $buildDir 'QtControlHost_v6.exe')"
