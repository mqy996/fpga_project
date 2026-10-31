# Runs after synthesis and before opt_design in the packaged Project Mode flow.
set frame_ram_cells [get_cells -quiet -hierarchical -filter {NAME =~ *u_frame_ram/mem_reg*}]
if {[llength $frame_ram_cells] > 0} {
    set_property DONT_TOUCH true $frame_ram_cells
    puts "Preserved [llength $frame_ram_cells] frame RAM cell(s) before opt_design."
} else {
    puts "No synthesized u_frame_ram/mem_reg cells matched the preservation filter."
}
