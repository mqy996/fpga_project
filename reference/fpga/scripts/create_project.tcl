set script_dir [file dirname [file normalize [info script]]]
set root_dir [file normalize [file join $script_dir ..]]
if {![string match "2025.1*" [version -short]]} {error "Vivado 2025.1 required"}
set build_dir [file join $root_dir build_2025_1]
file mkdir $build_dir

create_project adc_udp_flash_param_rate $build_dir \
    -part xc7a100tcsg324-2 -force
set_property target_language Verilog [current_project]
set_property simulator_language Mixed [current_project]
set_property XPM_LIBRARIES {XPM_CDC XPM_MEMORY XPM_FIFO} [current_project]

foreach f [lsort [glob [file join $root_dir rtl *.v]]] {
    if {[file tail $f] ni {fpga_minimal_demo_top.v fpga_adc_udp_merged_top.v network_stream_core.v sample_group_generator.v fifo_udp_payload_gen.v fifo_udp_stream_tx.v arp_request_tx.v udp_ipv4_tx.v}} {
        read_verilog $f
    }
}
read_xdc [file join $root_dir constraints fpga_adc_udp_flash_param.xdc]
set_property top fpga_adc_udp_flash_param_top [current_fileset]
update_compile_order -fileset sources_1
puts "Project: [file join $build_dir adc_udp_flash_param_rate.xpr]"
