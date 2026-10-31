source [file join [file dirname [info script]] flash_image_guard.tcl]
set d [file join [file dirname [info script]] .. output guard_test]
file mkdir $d
set f [open [file join $d edge.bin] wb];seek $f 8388607;puts -nonewline $f x;close $f
check_flash_image [file join $d edge.bin]
set f [open [file join $d edge.bin] ab];puts -nonewline $f x;close $f
if {![catch {check_flash_image [file join $d edge.bin]}]} {error "Overrun accepted"}
foreach {name records accept} {
 good {:02000004007F7B :01FFFF000001 :00000001FF} 1
 bad {:0200000400807A :0100000000FF :00000001FF} 0
 cross {:02000004007F7B :02FFFF00000000 :00000001FF} 0
} {
 set p [file join $d $name.mcs];set f [open $p w];foreach r $records {puts $f $r};close $f
 set failed [catch {check_flash_image $p}]
 if {$failed==$accept} {error "Boundary test failed: $name"}
}
puts "PASS: image address boundary tests"
puts "REQUESTED PART: [get_cfgmem_parts {w25q128jvq-spi-x1_x2_x4}]"
puts "INSTALLED W25Q128 PARTS: [get_cfgmem_parts *w25q128*]"
set exact [get_cfgmem_parts -filter {NAME == w25q128jvq-spi-x1_x2_x4 && COMPATIBLE_PARTS =~ *artix7*}]
puts "ARTIX7 EXACT: $exact"
if {[llength $exact]==0 || [lsort -unique [get_property NAME $exact]] ne "w25q128jvq-spi-x1_x2_x4"} {error "Exact compatible part unavailable"}
exit
