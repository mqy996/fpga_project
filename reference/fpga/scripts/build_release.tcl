set script_dir [file dirname [file normalize [info script]]]
set root_dir [file normalize [file join $script_dir ..]]
source [file join $script_dir create_project.tcl]
source [file join $script_dir flash_image_guard.tcl]

# Keep the configuration-memory model explicit.  Do not silently fall back to
# the older W25Q128FV entry, which is not the part fitted on this board.
set cfgmem_parts [get_cfgmem_parts -filter {NAME == w25q128jvq-spi-x1_x2_x4 && COMPATIBLE_PARTS =~ *artix7*}]
if {[llength $cfgmem_parts] == 0 || [lsort -unique [get_property NAME $cfgmem_parts]] ne "w25q128jvq-spi-x1_x2_x4"} {
    error "Exact configuration memory w25q128jvq-spi-x1_x2_x4 is unavailable"
}
set output_dir [file join $root_dir output staging_rate_[clock seconds]]
file mkdir $output_dir

synth_design -top fpga_adc_udp_flash_param_top -part xc7a100tcsg324-2
# The RX frame RAM read port is intentionally always enabled.  Prevent
# opt_design power gating from folding the asynchronously-asserted reset of a
# downstream consumer back into RAMB18 ENBWREN (REQP-1840).
set frame_ram_cells [get_cells -quiet -hierarchical -filter {NAME =~ *u_frame_ram/mem_reg*}]
if {[llength $frame_ram_cells] > 0} {
    set_property DONT_TOUCH true $frame_ram_cells
}
opt_design
place_design
phys_opt_design
route_design
write_checkpoint -force [file join $output_dir routed_before_physopt.dcp]
if {[get_property SLACK [get_timing_paths -delay_type max -max_paths 1]] < 0} {
    phys_opt_design -directive AggressiveExplore
    route_design
}

report_timing_summary -delay_type min_max -report_unconstrained \
    -file [file join $output_dir timing_summary.rpt]
report_utilization -hierarchical -file [file join $output_dir utilization.rpt]
report_drc -file [file join $output_dir drc.rpt]
report_cdc -details -file [file join $output_dir cdc.rpt]
report_methodology -file [file join $output_dir methodology.rpt]
report_io -file [file join $output_dir io.rpt]
write_bitstream -force -bin_file \
    [file join $output_dir fpga_adc_udp_flash_param_rate.bit]

set bin_path [file join $output_dir fpga_adc_udp_flash_param_rate.bin]
if {![file exists $bin_path]} { error "BIN output was not generated" }
check_flash_image $bin_path
set mcs_path [file join $output_dir fpga_adc_udp_flash_param_rate.mcs]
write_cfgmem -force -format mcs -interface SPIx4 -size 16 \
    -loadbit "up 0x000000 [file join $output_dir fpga_adc_udp_flash_param_rate.bit]" -file $mcs_path
check_flash_image $mcs_path

set setup_slack [get_property SLACK \
    [get_timing_paths -delay_type max -max_paths 1]]
set hold_slack [get_property SLACK \
    [get_timing_paths -delay_type min -max_paths 1]]
puts "Setup slack: $setup_slack ns"
puts "Hold slack: $hold_slack ns"
if {$setup_slack < 0.0 || $hold_slack < 0.0} {
    error "Timing failed"
}
set release_dir [file join $root_dir output release]
file mkdir $release_dir
foreach f [glob [file join $output_dir *]] {file copy -force $f $release_dir}
close_project
