set script_dir [file dirname [file normalize [info script]]]
set package_dir [file normalize [file join $script_dir ..]]
if {![string match "2025.1*" [version -short]]} {
    error "Vivado 2025.1 required; found [version -short]"
}

set project_dir [file join $package_dir vivado_project]
file mkdir $project_dir
create_project fpga_adc_udp_flash_param_minimal $project_dir \
    -part xc7a100tcsg324-2 -force
set_property target_language Verilog [current_project]
set_property simulator_language Mixed [current_project]
set_property XPM_LIBRARIES {XPM_CDC XPM_MEMORY XPM_FIFO} [current_project]

set rtl_files [lsort [glob [file join $package_dir rtl *.v]]]
if {[llength $rtl_files] != 39} {
    error "Expected the 39-file top-level RTL closure; found [llength $rtl_files]"
}
add_files -norecurse $rtl_files
add_files -fileset constrs_1 [file join $package_dir constraints fpga_adc_udp_flash_param.xdc]
set_property top fpga_adc_udp_flash_param_top [current_fileset]
update_compile_order -fileset sources_1
# Preserve the same frame-RAM inference workaround used by the validated
# non-project build when the packaged XPR is built from the GUI.
set preserve_script [file join $script_dir preserve_frame_ram.tcl]
add_files -fileset utils_1 $preserve_script
set preserve_file [get_files -of_objects [get_filesets utils_1] $preserve_script]
if {[llength $preserve_file] != 1} { error "Could not add the frame-RAM preservation hook to utils_1" }
set_property STEPS.OPT_DESIGN.TCL.PRE $preserve_file [get_runs impl_1]
puts "PROJECT_FILE=[file join $project_dir fpga_adc_udp_flash_param_minimal.xpr]"
puts "RTL_SOURCE_COUNT=[llength $rtl_files]"
close_project
