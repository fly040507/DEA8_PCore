set root [file normalize [lindex $argv 0]]
open_checkpoint [file join $root reports routing_R3 final_250MHz.dcp]
puts "SLRS [get_slrs]"
foreach slr [get_slrs] {
    puts "$slr REGIONS [get_clock_regions -of_objects $slr]"
}
foreach region [get_clock_regions] {
    set slices [get_sites -of_objects $region -filter {SITE_TYPE =~ SLICE*}]
    set brams [get_sites -of_objects $region -filter {SITE_TYPE == RAMB36E2}]
    puts "REGION $region SLICES [llength $slices] BRAMS [llength $brams]"
}
for {set g 0} {$g < 8} {incr g} {
    set cells [get_cells -hier -regexp ".*groups\\\[$g\\\].arithmetic/.*"]
    set sites [get_sites -of_objects $cells]
    puts "GROUP $g REGIONS [lsort -unique [get_property CLOCK_REGION $sites]]"
}
