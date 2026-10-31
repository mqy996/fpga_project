$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$bin = 'D:\vitis\2025.1\Vivado\bin'
foreach ($tool in @('xvlog.bat','xelab.bat','xsim.bat')) {
  $path = Join-Path $bin $tool
  if (-not (Test-Path -LiteralPath $path)) { throw "Vivado tool not found: $path" }
}
Push-Location $root
try {
  & (Join-Path $bin 'xvlog.bat') .\rtl\led_status_blink.v .\tb\tb_led_status_blink.v
  if ($LASTEXITCODE) { throw 'LED xvlog failed' }
  & (Join-Path $bin 'xelab.bat') tb_led_status_blink -s tb_led_status_blink_sim
  if ($LASTEXITCODE) { throw 'LED xelab failed' }
  $result = & (Join-Path $bin 'xsim.bat') tb_led_status_blink_sim -runall 2>&1
  $result | Write-Output
  if ($LASTEXITCODE -or -not (($result -join "`n").Contains('[TB][PASS]'))) { throw 'LED simulation failed' }
} finally { Pop-Location }
