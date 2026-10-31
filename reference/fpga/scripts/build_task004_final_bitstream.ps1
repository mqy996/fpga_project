param(
    [string]$OutputDirectory
)

$ErrorActionPreference = "Stop"
$vivado = "D:\vitis\2025.1\Vivado\bin\vivado.bat"
$projectRoot = Split-Path -Parent $PSScriptRoot
$workspaceRoot = (Resolve-Path (Join-Path $projectRoot "..\..\..")).Path
$outputRoot = Join-Path $workspaceRoot "results\task004\final_bitstream"
$tcl = Join-Path $PSScriptRoot "build_task004_final_bitstream.tcl"

if (-not (Test-Path -LiteralPath $vivado)) {
    throw "Vivado 2025.1 not found at $vivado"
}

if ([string]::IsNullOrWhiteSpace($OutputDirectory)) {
    $runName = Get-Date -Format "yyyyMMdd_HHmmss"
    $OutputDirectory = Join-Path $outputRoot $runName
}

$outputDirectoryFull = [System.IO.Path]::GetFullPath($OutputDirectory)
$outputRootFull = [System.IO.Path]::GetFullPath($outputRoot).TrimEnd('\')
$prefix = $outputRootFull + [System.IO.Path]::DirectorySeparatorChar
if (-not $outputDirectoryFull.StartsWith($prefix, [System.StringComparison]::OrdinalIgnoreCase)) {
    throw "OutputDirectory must be below $outputRootFull"
}
if (Test-Path -LiteralPath $outputDirectoryFull) {
    throw "Output directory already exists; use a fresh run directory: $outputDirectoryFull"
}
New-Item -ItemType Directory -Path $outputDirectoryFull | Out-Null

# Use the installed 2025.1 Tcl Store to avoid user-level Tcl package overrides.
$env:TCLLIBPATH = "D:/vitis/2025.1/Vivado/data/XilinxTclStore D:/vitis/2025.1/Vivado/data/XilinxTclStore/support D:/vitis/2025.1/Vivado/data/XilinxTclStore/support/appinit D:/vitis/2025.1/Vivado/data/XilinxTclStore/tclapp"

Push-Location $projectRoot
try {
    & $vivado -mode batch -notrace `
        -log (Join-Path $outputDirectoryFull "vivado.log") `
        -journal (Join-Path $outputDirectoryFull "vivado.jou") `
        -source $tcl -tclargs $outputDirectoryFull
    if ($LASTEXITCODE -ne 0) { throw "Vivado full implementation failed ($LASTEXITCODE)" }
    Write-Host "Final bitstream: $(Join-Path $outputDirectoryFull 'fpga_adc_udp_flash_param_rate.bit')"
} finally {
    Pop-Location
}
