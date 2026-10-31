set script_dir [file dirname [file normalize [info script]]]
set design_dir [file normalize [file join $script_dir ..]]
set workspace_root [file normalize [file join $design_dir .. .. ..]]
set expected_output_root [file normalize [file join $workspace_root results task004 final_bitstream]]

if {![string match "2025.1*" [version -short]]} {
    error "Vivado 2025.1 required; found [version -short]"
}
if {[llength $argv] != 1} {
    error "Usage: vivado -mode batch -source build_task004_final_bitstream.tcl -tclargs <run-output-dir>"
}

set output_dir [file normalize [lindex $argv 0]]
set root_prefix "[string tolower $expected_output_root]/"
if {![string match "${root_prefix}*" "[string tolower $output_dir]/"]} {
    error "Output must be a fresh run directory under $expected_output_root"
}
file mkdir $output_dir

set part_name xc7a100tcsg324-2
set top_name fpga_adc_udp_flash_param_top
set rtl_dir [file join $design_dir rtl]
set excluded_sources {
    fpga_minimal_demo_top.v fpga_adc_udp_merged_top.v network_stream_core.v
    sample_group_generator.v fifo_udp_payload_gen.v fifo_udp_stream_tx.v
    arp_request_tx.v udp_ipv4_tx.v
}

# Non-project flow: read sources/constraints, then explicitly synthesize and
# implement. This preserves the existing source selection without recreating
# or overwriting the shared 2025.1 project directory.
foreach source_file [lsort [glob [file join $rtl_dir *.v]]] {
    if {[lsearch -exact $excluded_sources [file tail $source_file]] < 0} {
        read_verilog $source_file
    }
}
read_xdc [file join $design_dir constraints fpga_adc_udp_flash_param.xdc]

synth_design -top $top_name -part $part_name

# Preserve the established RX frame RAM implementation workaround.
set frame_ram_cells [get_cells -quiet -hierarchical -filter {NAME =~ *u_frame_ram/mem_reg*}]
if {[llength $frame_ram_cells] > 0} {
    set_property DONT_TOUCH true $frame_ram_cells
}

opt_design
place_design
phys_opt_design
route_design

set setup_paths [get_timing_paths -quiet -delay_type max -max_paths 1]
if {[llength $setup_paths] == 0} {error "No setup timing path was reported"}
set setup_slack [get_property SLACK $setup_paths]
if {$setup_slack < 0.0} {
    phys_opt_design -directive AggressiveExplore
    route_design
}

write_checkpoint -force [file join $output_dir final_routed.dcp]
report_timing_summary -delay_type min_max -report_unconstrained \
    -file [file join $output_dir timing_summary.rpt]
report_utilization -hierarchical -file [file join $output_dir utilization.rpt]
report_drc -file [file join $output_dir drc.rpt]
report_cdc -details -file [file join $output_dir cdc.rpt]
report_methodology -file [file join $output_dir methodology.rpt]
report_io -file [file join $output_dir io.rpt]

set setup_paths [get_timing_paths -quiet -delay_type max -max_paths 1]
set hold_paths [get_timing_paths -quiet -delay_type min -max_paths 1]
if {[llength $setup_paths] == 0 || [llength $hold_paths] == 0} {
    error "Setup or hold timing paths are missing"
}
set setup_slack [get_property SLACK $setup_paths]
set hold_slack [get_property SLACK $hold_paths]
puts "Final setup slack: $setup_slack ns"
puts "Final hold slack: $hold_slack ns"
if {$setup_slack < 0.0 || $hold_slack < 0.0} {
    error "Timing failed; no final bitstream was written"
}

set drc_errors [get_drc_violations -quiet -filter {SEVERITY == Error}]
if {[llength $drc_errors] > 0} {
    error "DRC has [llength $drc_errors] error-severity violation(s); no final bitstream was written"
}

set cfgmem_parts [get_cfgmem_parts -filter {NAME == w25q128jvq-spi-x1_x2_x4 && COMPATIBLE_PARTS =~ *artix7*}]
if {[llength $cfgmem_parts] == 0 || [lsort -unique [get_property NAME $cfgmem_parts]] ne "w25q128jvq-spi-x1_x2_x4"} {
    error "Exact configuration memory w25q128jvq-spi-x1_x2_x4 is unavailable"
}

set bit_path [file join $output_dir fpga_adc_udp_flash_param_rate.bit]
write_bitstream -force -bin_file $bit_path
set bin_path [file join $output_dir fpga_adc_udp_flash_param_rate.bin]
source [file join $script_dir flash_image_guard.tcl]
check_flash_image $bin_path

set mcs_path [file join $output_dir fpga_adc_udp_flash_param_rate.mcs]
write_cfgmem -force -format mcs -interface SPIx4 -size 16 \
    -loadbit "up 0x000000 $bit_path" -file $mcs_path
check_flash_image $mcs_path

puts "BITSTREAM: $bit_path"
puts "BIN: $bin_path"
puts "MCS: $mcs_path"
puts "REPORTS: $output_dir"
