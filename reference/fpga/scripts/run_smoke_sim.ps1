$ErrorActionPreference = "Stop"
$root = Split-Path -Parent $PSScriptRoot
$xvlog = "D:\vitis\2025.1\Vivado\bin\xvlog.bat"
$xelab = "D:\vitis\2025.1\Vivado\bin\xelab.bat"
$xsim  = "D:\vitis\2025.1\Vivado\bin\xsim.bat"
Push-Location $root
try {
    & $xvlog .\rtl\led_status_blink.v .\tb\tb_led_status_blink.v
    if ($LASTEXITCODE -ne 0) { throw "LED blink xvlog failed" }
    & $xelab tb_led_status_blink -s tb_led_status_blink_sim
    if ($LASTEXITCODE -ne 0) { throw "LED blink xelab failed" }
    & $xsim tb_led_status_blink_sim -runall
    if ($LASTEXITCODE -ne 0) { throw "LED blink simulation failed" }

    & $xvlog .\rtl\config_validate.v .\tb\tb_config_validate.v
    if ($LASTEXITCODE -ne 0) { throw "config validation xvlog failed" }
    & $xelab tb_config_validate -s tb_config_validate_sim
    if ($LASTEXITCODE -ne 0) { throw "config validation xelab failed" }
    & $xsim tb_config_validate_sim -runall
    if ($LASTEXITCODE -ne 0) { throw "config validation simulation failed" }

    & $xvlog .\rtl\udp_ipv4_tx_runtime.v .\tb\tb_udp_ipv4_min_frame.v
    if ($LASTEXITCODE -ne 0) { throw "minimum Ethernet frame xvlog failed" }
    & $xelab tb_udp_ipv4_min_frame -s tb_udp_ipv4_min_frame_sim
    if ($LASTEXITCODE -ne 0) { throw "minimum Ethernet frame xelab failed" }
    & $xsim tb_udp_ipv4_min_frame_sim -runall
    if ($LASTEXITCODE -ne 0) { throw "minimum Ethernet frame simulation failed" }

    & $xvlog .\rtl\config_validate.v .\rtl\runtime_config_manager.v .\tb\tb_runtime_config_manager.v
    if ($LASTEXITCODE -ne 0) { throw "config manager xvlog failed" }
    & $xelab tb_runtime_config_manager -s tb_runtime_config_manager_sim
    if ($LASTEXITCODE -ne 0) { throw "config manager xelab failed" }
    & $xsim tb_runtime_config_manager_sim -runall
    if ($LASTEXITCODE -ne 0) { throw "config manager simulation failed" }

    & $xvlog .\rtl\reset_sync.v .\rtl\cdc_bit_sync.v .\tb\tb_cdc_status.v
    if ($LASTEXITCODE -ne 0) { throw "CDC xvlog failed" }
    & $xelab tb_cdc_status -s tb_cdc_status_sim
    if ($LASTEXITCODE -ne 0) { throw "CDC xelab failed" }
    & $xsim tb_cdc_status_sim -runall
    if ($LASTEXITCODE -ne 0) { throw "CDC simulation failed" }

    & $xvlog .\rtl\system_run_ctrl.v .\tb\tb_system_run_ctrl.v
    if ($LASTEXITCODE -ne 0) { throw "run-control xvlog failed" }
    & $xelab tb_system_run_ctrl -s tb_system_run_ctrl_sim
    if ($LASTEXITCODE -ne 0) { throw "run-control xelab failed" }
    & $xsim tb_system_run_ctrl_sim -runall
    if ($LASTEXITCODE -ne 0) { throw "run-control simulation failed" }

    & $xvlog .\rtl\ad7606c_parallel_controller.v .\tb\tb_ad7606c_500ksps.v
    if ($LASTEXITCODE -ne 0) { throw "ADC xvlog failed" }
    & $xelab tb_ad7606c_500ksps -s tb_ad7606c_500ksps_sim
    if ($LASTEXITCODE -ne 0) { throw "ADC xelab failed" }
    & $xsim tb_ad7606c_500ksps_sim -runall
    if ($LASTEXITCODE -ne 0) { throw "ADC simulation failed" }

    & $xvlog .\rtl\ad7606c_pipelined_controller.v .\tb\tb_ad7606c_pipeline_1m.v
    if ($LASTEXITCODE -ne 0) { throw "1 MSPS pipeline xvlog failed" }
    & $xelab tb_ad7606c_pipeline_1m -s tb_ad7606c_pipeline_1m_sim
    if ($LASTEXITCODE -ne 0) { throw "1 MSPS pipeline xelab failed" }
    & $xsim tb_ad7606c_pipeline_1m_sim -runall
    if ($LASTEXITCODE -ne 0) { throw "1 MSPS pipeline simulation failed" }

    & $xvlog -sv D:\vitis\2025.1\Vivado\data\ip\xpm\xpm_cdc\hdl\xpm_cdc.sv
    if ($LASTEXITCODE -ne 0) { throw "XPM CDC xvlog failed" }
    & $xvlog .\rtl\sample_rate_config_cdc.v .\tb\tb_sample_rate_config_cdc.v `
        D:\vitis\2025.1\Vivado\data\verilog\src\glbl.v
    if ($LASTEXITCODE -ne 0) { throw "sample-rate CDC xvlog failed" }
    & $xelab tb_sample_rate_config_cdc glbl -s tb_sample_rate_config_cdc_sim
    if ($LASTEXITCODE -ne 0) { throw "sample-rate CDC xelab failed" }
    & $xsim tb_sample_rate_config_cdc_sim -runall
    if ($LASTEXITCODE -ne 0) { throw "sample-rate CDC simulation failed" }

    & $xvlog .\rtl\run_control_cdc_bridge.v .\tb\tb_run_control_cdc_bridge.v D:\vitis\2025.1\Vivado\data\verilog\src\glbl.v
    if ($LASTEXITCODE -ne 0) { throw "run-control CDC xvlog failed" }
    & $xelab tb_run_control_cdc_bridge glbl -s tb_run_control_cdc_bridge_sim
    if ($LASTEXITCODE -ne 0) { throw "run-control CDC xelab failed" }
    & $xsim tb_run_control_cdc_bridge_sim -runall
    if ($LASTEXITCODE -ne 0) { throw "run-control CDC simulation failed" }
} finally {
    Pop-Location
}
