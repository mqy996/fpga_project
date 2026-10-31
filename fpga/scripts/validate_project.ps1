$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot "toolchain.ps1")
$packageRoot = Split-Path -Parent $PSScriptRoot
$projectDir = Join-Path $packageRoot "vivado_project"
$log = Join-Path $projectDir "validate_project.log"
$journal = Join-Path $projectDir "validate_project.jou"
$tcl = Join-Path $PSScriptRoot "validate_project.tcl"
if (-not (Test-Path -LiteralPath $vivado)) { throw "Vivado 2025.1 not found at $vivado" }
Push-Location $packageRoot
try {
    & $vivado -mode batch -notrace -log $log -journal $journal -source $tcl
    if ($LASTEXITCODE -ne 0) { throw "Vivado project validation failed ($LASTEXITCODE)" }
} finally {
    Pop-Location
}
