$ErrorActionPreference = "Stop"
$vivado = "D:\Xilinx\2025.1\Vivado\bin\vivado.bat"
# Keep hardware-manager batch programming independent of a damaged user Tcl
# Store, matching the release-build environment.
$env:TCLLIBPATH = "D:/Xilinx/2025.1/Vivado/data/XilinxTclStore D:/Xilinx/2025.1/Vivado/data/XilinxTclStore/support D:/Xilinx/2025.1/Vivado/data/XilinxTclStore/support/appinit D:/Xilinx/2025.1/Vivado/data/XilinxTclStore/tclapp"
$script = Join-Path $PSScriptRoot "program_bitstream_preserve_params.tcl"
$image = if ($args.Count -gt 0) { (Resolve-Path $args[0]).Path } else { Join-Path (Split-Path $PSScriptRoot -Parent) "output\release\fpga_adc_udp_flash_param_rate.bin" }
& $vivado -mode batch -notrace -source $script -tclargs $image
if ($LASTEXITCODE -ne 0) { throw "Configuration flash programming failed" }
