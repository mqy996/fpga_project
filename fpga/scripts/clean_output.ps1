param([Parameter(Mandatory=$true)][string]$RunDirectory)

$ErrorActionPreference = "Stop"
$packageRoot = Split-Path -Parent $PSScriptRoot
$outputRoot = [System.IO.Path]::GetFullPath((Join-Path $packageRoot "output")).TrimEnd('\')
$target = [System.IO.Path]::GetFullPath($RunDirectory)
$prefix = $outputRoot + [System.IO.Path]::DirectorySeparatorChar
if (-not $target.StartsWith($prefix, [System.StringComparison]::OrdinalIgnoreCase)) {
    throw "RunDirectory must be inside $outputRoot"
}
if ((Split-Path -Parent $target) -ne $outputRoot) { throw "Only one direct output child may be cleaned" }
if (-not (Test-Path -LiteralPath $target -PathType Container)) { throw "RunDirectory not found: $target" }
if (-not (Test-Path -LiteralPath (Join-Path $target "vivado.jou")) -or
    -not (Get-ChildItem -LiteralPath $target -Filter '*.bit' -File)) {
    throw "Refusing cleanup: expected this package's Vivado journal and bitstream"
}
Remove-Item -LiteralPath $target -Recurse -Force
Write-Host "Removed generated run: $target"
