param([string]$VivadoHome = $env:VIVADO_HOME)
$ErrorActionPreference = 'Stop'
if ([string]::IsNullOrWhiteSpace($VivadoHome)) {
    $found = Get-Command vivado.bat -ErrorAction SilentlyContinue
    if ($found) { $VivadoHome = Split-Path -Parent (Split-Path -Parent $found.Source) }
    elseif (Test-Path -LiteralPath 'D:\vitis\2025.1\Vivado') { $VivadoHome = 'D:\vitis\2025.1\Vivado' }
    else { throw 'Set VIVADO_HOME to your Vivado 2025.1 installation, or add its bin to PATH.' }
}
$script:vivado = Join-Path $VivadoHome 'bin/vivado.bat'
$script:xvlog = Join-Path $VivadoHome 'bin/xvlog.bat'
$script:xelab = Join-Path $VivadoHome 'bin/xelab.bat'
$script:xsim = Join-Path $VivadoHome 'bin/xsim.bat'
foreach ($p in @($vivado,$xvlog,$xelab,$xsim)) { if (-not (Test-Path -LiteralPath $p)) { throw "Missing tool: $p" } }
$tclRoot = (Join-Path $VivadoHome 'data/XilinxTclStore').Replace('\','/')
$env:TCLLIBPATH = (@($tclRoot,"$tclRoot/support","$tclRoot/support/appinit","$tclRoot/tclapp") | ForEach-Object { '{'+$_+'}' }) -join ' '
