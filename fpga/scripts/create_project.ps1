$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot "toolchain.ps1")
$packageRoot = Split-Path -Parent $PSScriptRoot
$projectDir = Join-Path $packageRoot "vivado_project"
$log = Join-Path $projectDir "create_project.log"
$journal = Join-Path $projectDir "create_project.jou"
$tcl = Join-Path $PSScriptRoot "create_project.tcl"
if (-not (Test-Path -LiteralPath $vivado)) { throw "Vivado 2025.1 not found at $vivado" }
New-Item -ItemType Directory -Force -Path $projectDir | Out-Null
Push-Location $packageRoot
try {
    & $vivado -mode batch -notrace -log $log -journal $journal -source $tcl
    if ($LASTEXITCODE -ne 0) { throw "Vivado project creation failed ($LASTEXITCODE)" }
    Write-Host "Project: $(Join-Path $projectDir 'fpga_adc_udp_flash_param_minimal.xpr')"
} finally {
    Pop-Location
}
