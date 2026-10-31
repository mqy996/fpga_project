# Shared by image generation and hardware programming. Upper bound is exclusive.
set FLASH_BITSTREAM_LIMIT 0x800000
proc check_flash_image {path} {
    global FLASH_BITSTREAM_LIMIT
    if {![file exists $path]} {error "Image missing: $path"}
    set ext [string tolower [file extension $path]]
    if {$ext eq ".bin"} {
        set end [file size $path]
        if {$end <= 0 || $end > $FLASH_BITSTREAM_LIMIT} {error "BIN outside startup partition"}
    } elseif {$ext eq ".mcs"} {
        set f [open $path r]; set lines [split [read $f] \n]; close $f
        set base 0; set end 0; set eof 0
        foreach line $lines {
            set line [string trim $line]
            if {$line eq ""} continue
            if {$eof || ![regexp {^:([0-9A-Fa-f]+)$} $line -> hex]} {error "Invalid MCS record"}
            set bytes {}; set sum 0
            foreach pair [regexp -all -inline {..} $hex] {scan $pair %x b; lappend bytes $b; incr sum $b}
            set n [lindex $bytes 0]
            if {[string length $hex] != 2*($n+5) || ($sum & 255)!=0} {error "Invalid MCS length/checksum"}
            set addr [expr {([lindex $bytes 1]<<8)|[lindex $bytes 2]}]
            set type [lindex $bytes 3]
            switch $type {
                0 {set stop [expr {$base+$addr+$n}]; if {$stop>$FLASH_BITSTREAM_LIMIT} {error "MCS enters parameter partition"}; set end [expr {max($end,$stop)}]}
                1 {if {$n!=0} {error "Invalid EOF"}; set eof 1}
                2 - 4 {if {$n!=2 || $addr!=0} {error "Invalid extended address"}; set base [expr {(([lindex $bytes 4]<<8)|[lindex $bytes 5]) << ($type==2?4:16)}]}
                default {error "Unsupported MCS record type $type"}
            }
        }
        if {!$eof || $end==0} {error "Empty or incomplete MCS"}
    } else {error "Only BIN/MCS supported"}
    # Even conservatively rounding to 64 KiB erase blocks cannot enter A/B.
    if {(($end+65535)/65536)*65536 > $FLASH_BITSTREAM_LIMIT} {error "Erase range crosses boundary"}
    puts "SAFE: $path, exclusive end [format 0x%X $end]"
    return $end
}
