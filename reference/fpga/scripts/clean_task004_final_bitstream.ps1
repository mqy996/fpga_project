param(
    [Parameter(Mandatory = $true)]
    [string]$RunDirectory
)

$ErrorActionPreference = "Stop"
$projectRoot = Split-Path -Parent $PSScriptRoot
$workspaceRoot = (Resolve-Path (Join-Path $projectRoot "..\..\..")).Path
$outputRoot = (Resolve-Path (Join-Path $workspaceRoot "results\task004\final_bitstream")).Path.TrimEnd('\')
$target = (Resolve-Path -LiteralPath $RunDirectory).Path
$prefix = $outputRoot + [System.IO.Path]::DirectorySeparatorChar

if (-not $target.StartsWith($prefix, [System.StringComparison]::OrdinalIgnoreCase)) {
    throw "Refusing to remove anything outside $outputRoot"
}
$relative = $target.Substring($prefix.Length)
if ($relative.Contains([System.IO.Path]::DirectorySeparatorChar) -or
    $relative.Contains([System.IO.Path]::AltDirectorySeparatorChar)) {
    throw "RunDirectory must be one direct child of $outputRoot"
}
if (-not (Test-Path -LiteralPath (Join-Path $target "vivado.jou")) -or
    -not (Test-Path -LiteralPath (Join-Path $target "fpga_adc_udp_flash_param_rate.bit"))) {
    throw "Directory does not contain the expected generated Vivado run files"
}

Remove-Item -LiteralPath $target -Recurse -Force
Write-Host "Removed generated run directory: $target"
