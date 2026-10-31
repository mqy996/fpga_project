$ErrorActionPreference = "Stop"

$root = Split-Path -Parent $PSScriptRoot
$xvlog = "D:\vitis\2025.1\Vivado\bin\xvlog.bat"
$xelab = "D:\vitis\2025.1\Vivado\bin\xelab.bat"
$xsim  = "D:\vitis\2025.1\Vivado\bin\xsim.bat"

foreach ($tool in @($xvlog, $xelab, $xsim)) {
    if (-not (Test-Path -LiteralPath $tool)) {
        throw "Vivado 2025.1 simulator tool not found: $tool"
    }
}

Push-Location $root
try {
    & $xvlog .\rtl\ad7606c_pipelined_controller.v `
        .\tb\tb_ad7606c_pipeline_1m.v .\tb\tb_ad7606c_frstdata_guard.v
    if ($LASTEXITCODE -ne 0) { throw "ADC pipeline xvlog failed ($LASTEXITCODE)" }

    & $xelab -debug typical tb_ad7606c_pipeline_1m -s tb_ad7606c_pipeline_1m_sim
    if ($LASTEXITCODE -ne 0) { throw "ADC pipeline xelab failed ($LASTEXITCODE)" }

    $simOutput = & $xsim tb_ad7606c_pipeline_1m_sim -runall 2>&1
    $simExitCode = $LASTEXITCODE
    $simText = $simOutput -join "`n"
    $simOutput | ForEach-Object { Write-Host $_ }

    if ($simExitCode -ne 0) { throw "ADC pipeline xsim failed ($simExitCode)" }
    if ($simText -match "(?im)^\s*Fatal:") { throw "ADC pipeline simulation reported a fatal error" }
    if ($simText -notmatch "PASS: 12 ordered V1..V8 frames at 1 MSPS") {
        throw "ADC pipeline simulation did not produce its PASS result"
    }

    & $xelab -debug typical tb_ad7606c_frstdata_guard -s tb_ad7606c_frstdata_guard_sim
    if ($LASTEXITCODE -ne 0) { throw "FRSTDATA guard xelab failed ($LASTEXITCODE)" }

    $guardOutput = & $xsim tb_ad7606c_frstdata_guard_sim -runall 2>&1
    $guardExitCode = $LASTEXITCODE
    $guardText = $guardOutput -join "`n"
    $guardOutput | ForEach-Object { Write-Host $_ }

    if ($guardExitCode -ne 0) { throw "FRSTDATA guard xsim failed ($guardExitCode)" }
    if ($guardText -match "(?im)^\s*Fatal:") { throw "FRSTDATA guard simulation reported a fatal error" }
    if ($guardText -notmatch "PASS: FRSTDATA mismatch rejected; no sample_valid was published") {
        throw "FRSTDATA mismatch test did not produce its PASS result"
    }
} finally {
    Pop-Location
}
