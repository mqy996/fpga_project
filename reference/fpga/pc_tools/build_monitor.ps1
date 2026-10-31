$ErrorActionPreference = "Stop"
$source = Join-Path $PSScriptRoot "adc_udp_monitor.cpp"
$output = Join-Path $PSScriptRoot "adc_udp_monitor.exe"

$compiler = Get-Command g++ -ErrorAction Stop
& $compiler.Source -std=c++17 -O2 -Wall -Wextra $source -o $output -lws2_32
if ($LASTEXITCODE -ne 0) { throw "g++ build failed" }
Write-Host "Built $output"
