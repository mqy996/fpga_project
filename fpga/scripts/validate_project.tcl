set script_dir [file dirname [file normalize [info script]]]
set package_dir [file normalize [file join $script_dir ..]]
if {![string match "2025.1*" [version -short]]} {
    error "Vivado 2025.1 required; found [version -short]"
}
set xpr [file join $package_dir vivado_project fpga_adc_udp_flash_param_minimal.xpr]
if {![file exists $xpr]} { error "Project file not found: $xpr" }
open_project $xpr
if {[get_property PART [current_project]] ne "xc7a100tcsg324-2"} {
    error "Unexpected project part: [get_property PART [current_project]]"
}
set sources [get_files -of_objects [get_filesets sources_1]]
set missing {}
foreach source $sources {
    set path [get_property NAME $source]
    if {![file exists $path]} { lappend missing $path }
}
if {[llength $sources] != 39} { error "Expected 39 RTL sources; found [llength $sources]" }
if {[llength $missing] > 0} { error "Missing project sources: $missing" }
if {[get_property top [get_filesets sources_1]] ne "fpga_adc_udp_flash_param_top"} {
    error "Unexpected top module: [get_property top [get_filesets sources_1]]"
}
set constraints [get_files -of_objects [get_filesets constrs_1]]
if {[llength $constraints] != 1 || ![file exists [get_property NAME [lindex $constraints 0]]]} {
    error "Project XDC is missing or unresolved"
}
set run_hook [get_property STEPS.OPT_DESIGN.TCL.PRE [get_runs impl_1]]
if {[llength $run_hook] != 1 || ![file exists $run_hook]} {
    error "Project Mode frame-RAM preservation hook is missing or unresolved: $run_hook"
}
puts "PASS: Vivado [version -short], part [get_property PART [current_project]], top fpga_adc_udp_flash_param_top, 39 RTL sources, one XDC."
puts "PROJECT_MODE_OPT_HOOK=[file tail $run_hook]"
close_project
exit
