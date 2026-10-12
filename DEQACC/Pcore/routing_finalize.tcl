set root [file normalize [lindex $argv 0]]
set report [file join $root reports routing_R8]
open_checkpoint [file join $report final_250MHz.dcp]
report_timing -to [get_cells -hier -filter {NAME =~ *commit_write*reg* || NAME =~ *commit_meta*reg* || NAME =~ *commit_valid_reg*}] \
  -max_paths 10 -file [file join $report D10_top10.rpt]
set f [open [file join $report physical_cells.csv] w]
puts $f "cell,ref_name,site,clock_region"
# Batch queries avoid tens of thousands of slow per-cell Tcl object lookups.
set cells [get_cells -hier -filter {IS_PRIMITIVE == 1}]
set refs [get_property REF_NAME $cells]
set locs [get_property LOC $cells]
foreach c $cells ref $refs loc $locs {puts $f "$c,$ref,$loc"}
close $f
set f [open [file join $root reports routing_R0 stages_corrected.csv] w]
puts $f "stage,logic_ns,route_ns,total_ns"
foreach stage {D0 D1 D2 D3 D4 D5 D6 D7 D8 D9 ACC} {
    set input [open [file join $root reports routing_R0 ${stage}_top10.rpt] r]
    set text [read $input];close $input
    if {![regexp {Data Path Delay:\s+([0-9.]+)ns\s+\(logic ([0-9.]+)ns[^\n]*route ([0-9.]+)ns} $text all total logic route]} {
        error "Cannot parse R0 $stage"
    }
    puts $f "$stage,$logic,$route,$total"
}
close $f
set f [open [file join $report source_sha256.csv] w]
puts $f "file,sha256"
foreach name {rtl/DEQACC_3.3ns.sv rtl/DEQACC_3.3ns_lane.sv rtl/DEQACC_3.3ns_group2.sv rtl/dea8_acc_store.sv} {
    set hash [exec certutil -hashfile [file join $root $name] SHA256]
    regexp {\n([0-9a-fA-F]{64})\r?\n} $hash all digest
    puts $f "$name,$digest"
}
close $f
