param([string]$OutputDirectory)

$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot "toolchain.ps1")
$packageRoot = Split-Path -Parent $PSScriptRoot
$outputRoot = Join-Path $packageRoot "output"
$tcl = Join-Path $PSScriptRoot "build_minimal.tcl"
if (-not (Test-Path -LiteralPath $vivado)) { throw "Vivado 2025.1 not found at $vivado" }

if ([string]::IsNullOrWhiteSpace($OutputDirectory)) {
    $OutputDirectory = Join-Path $outputRoot (Get-Date -Format "yyyyMMdd_HHmmss")
}
$outputFull = [System.IO.Path]::GetFullPath($OutputDirectory)
$outputRootFull = [System.IO.Path]::GetFullPath($outputRoot).TrimEnd('\')
$prefix = $outputRootFull + [System.IO.Path]::DirectorySeparatorChar
if (-not $outputFull.StartsWith($prefix, [System.StringComparison]::OrdinalIgnoreCase)) {
    throw "OutputDirectory must be below $outputRootFull"
}
if (Test-Path -LiteralPath $outputFull) { throw "Output directory already exists: $outputFull" }
New-Item -ItemType Directory -Path $outputFull | Out-Null

Push-Location $packageRoot
try {
    & $vivado -mode batch -notrace `
        -log (Join-Path $outputFull "vivado.log") `
        -journal (Join-Path $outputFull "vivado.jou") `
        -source $tcl -tclargs $outputFull
    if ($LASTEXITCODE -ne 0) { throw "Vivado build failed ($LASTEXITCODE)" }
    Write-Host "Bitstream output: $outputFull"
} finally {
    Pop-Location
}
