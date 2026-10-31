param([string]$ImagePath)

$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot "toolchain.ps1")
$packageRoot = Split-Path -Parent $PSScriptRoot
$script = Join-Path $PSScriptRoot "program_qspi_preserve_params.tcl"
if (-not (Test-Path -LiteralPath $vivado)) { throw "Vivado 2025.1 not found at $vivado" }
if ([string]::IsNullOrWhiteSpace($ImagePath)) {
    $ImagePath = Join-Path $packageRoot "bitstream\fpga_adc_udp_flash_param_rate.bin"
}
$image = (Resolve-Path -LiteralPath $ImagePath).Path
Push-Location $packageRoot
try {
    & $vivado -mode batch -notrace -source $script -tclargs $image
    if ($LASTEXITCODE -ne 0) { throw "Configuration flash programming failed ($LASTEXITCODE)" }
} finally {
    Pop-Location
}
