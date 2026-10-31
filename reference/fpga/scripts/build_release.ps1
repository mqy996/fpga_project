$ErrorActionPreference = "Stop"
$vivado = "D:\vitis\2025.1\Vivado\bin\vivado.bat"
# Some installations have a corrupted per-user Tcl Store.  Point Vivado at
# the read-only 2025.1 Tcl Store so batch builds remain reproducible.
$env:TCLLIBPATH = "D:/vitis/2025.1/Vivado/data/XilinxTclStore D:/vitis/2025.1/Vivado/data/XilinxTclStore/support D:/vitis/2025.1/Vivado/data/XilinxTclStore/support/appinit D:/vitis/2025.1/Vivado/data/XilinxTclStore/tclapp"
$tcl = Join-Path $PSScriptRoot "build_release.tcl"
& $vivado -mode batch -notrace -source $tcl
if ($LASTEXITCODE -ne 0) { throw "Vivado build failed" }
