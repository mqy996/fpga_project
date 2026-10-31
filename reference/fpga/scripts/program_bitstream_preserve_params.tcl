# Vivado 2025.1 hardware-manager script. It programs only the address range
# represented by the BIN file. The script refuses any image reaching 0x800000.
set script_dir [file dirname [file normalize [info script]]]
set root_dir [file normalize [file join $script_dir ..]]
set image_file [file join $root_dir output release fpga_adc_udp_flash_param_rate.bin]
if {[llength $argv] >= 1} { set image_file [file normalize [lindex $argv 0]] }
if {![file exists $image_file]} { error "BIN does not exist: $image_file" }
source [file join $script_dir flash_image_guard.tcl]
if {![string match "2025.1*" [version -short]]} {error "Vivado 2025.1 required"}
check_flash_image $image_file

open_hw_manager
connect_hw_server -allow_non_jtag
set targets [get_hw_targets -quiet]
if {[llength $targets] == 0} { error "No JTAG target" }
open_hw_target [lindex $targets 0]
set devices [get_hw_devices -quiet xc7a100t*]
if {[llength $devices] != 1} { error "Expected exactly one XC7A100T" }
set dev [lindex $devices 0]
current_hw_device $dev
refresh_hw_device -update_hw_probes false $dev
set parts [get_cfgmem_parts -filter {NAME == w25q128jvq-spi-x1_x2_x4 && COMPATIBLE_PARTS =~ *artix7*}]
if {[llength $parts] == 0 || [lsort -unique [get_property NAME $parts]] ne "w25q128jvq-spi-x1_x2_x4"} { error "Exact W25Q128JV part unavailable" }
create_hw_cfgmem -hw_device $dev [lindex $parts 0]
set mem [get_property PROGRAM.HW_CFGMEM $dev]
set_property PROGRAM.ADDRESS_RANGE {use_file} $mem
set_property PROGRAM.FILES [list $image_file] $mem
set_property PROGRAM.PRM_FILE {} $mem
set_property PROGRAM.UNUSED_PIN_TERMINATION {pull-none} $mem
set_property PROGRAM.BLANK_CHECK 0 $mem
set_property PROGRAM.ERASE 1 $mem
set_property PROGRAM.CFG_PROGRAM 1 $mem
set_property PROGRAM.VERIFY 1 $mem
set_property PROGRAM.CHECKSUM 0 $mem
create_hw_bitstream -hw_device $dev [get_property PROGRAM.HW_CFGMEM_BITFILE $dev]
program_hw_devices $dev
refresh_hw_device $dev
program_hw_cfgmem -hw_cfgmem $mem
puts "PASS: programmed [file size $image_file] bytes below 0x800000; parameter A/B sectors were outside PROGRAM.ADDRESS_RANGE."
close_hw_target
disconnect_hw_server
close_hw_manager
exit
