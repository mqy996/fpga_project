$ErrorActionPreference = 'Stop'
$bin = 'D:\Xilinx\2025.1\Vivado\bin'
Push-Location (Split-Path $PSScriptRoot -Parent)
try {
    & "$bin\xvlog.bat" -sv -work work D:/Xilinx/2025.1/Vivado/data/ip/xpm/xpm_cdc/hdl/xpm_cdc.sv
    if ($LASTEXITCODE) { throw 'XPM compilation failed' }
    & "$bin\xvlog.bat" D:/Xilinx/2025.1/Vivado/data/verilog/src/glbl.v rtl/flash_spi_byte_master.v rtl/flash_param_manager.v rtl/flash_config_cdc_bridge.v tb/tb_flash_boot.v
    if ($LASTEXITCODE) { throw 'xvlog failed' }
    & "$bin\xelab.bat" -rangecheck tb_flash_boot glbl -s flash_boot_sim
    if ($LASTEXITCODE) { throw 'xelab failed' }
    $result = & "$bin\xsim.bat" flash_boot_sim -runall 2>&1
    $result | Write-Output
    if ($LASTEXITCODE -or ($result -match 'Fatal:|Error:|Error-|\$error') -or -not ($result -match 'PASS: handover')) { throw 'Flash simulation failed' }
    & "$bin\xvlog.bat" rtl/runtime_payload_length.v tb/tb_runtime_payload_length.v
    if ($LASTEXITCODE) { throw 'payload length compilation failed' }
    & "$bin\xelab.bat" tb_runtime_payload_length -s payload_length_sim
    if ($LASTEXITCODE) { throw 'payload length elaboration failed' }
    $result = & "$bin\xsim.bat" payload_length_sim -runall 2>&1
    $result | Write-Output
    if ($LASTEXITCODE -or ($result -match 'Fatal:|Error:') -or -not ($result -match 'PASS: 720')) { throw 'payload length test failed' }
} finally { Pop-Location }
