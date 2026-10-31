$ErrorActionPreference = "Stop"
$source = Join-Path $PSScriptRoot "fpga_param_cli.cpp"
$output = Join-Path $PSScriptRoot "fpga_param_cli.exe"
$compiler = (Get-Command g++ -ErrorAction Stop).Source
& $compiler -std=c++17 -O2 -Wall -Wextra $source -lws2_32 -o $output
if ($LASTEXITCODE -ne 0) { throw "C++ build failed" }
Write-Host "Built $output"
