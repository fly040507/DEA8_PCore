# Controlled comparison: exact pre-Pblock synth DCP from the hard baseline.
set root [file normalize [lindex $argv 0]]
set baseline [lindex $argv 1]
set tag [lindex $argv 2]
set report [file join $root reports $tag]
set input [file join $root reports $baseline synthesized.dcp]
set fourlane [expr {[llength $argv]>3&&[lindex $argv 3] eq "fourlane"}]
if {[file exists $report]} {error "Use a fresh comparison tag"}
if {![file exists $input]} {error "Missing baseline pre-Pblock checkpoint"}
file mkdir $report
file copy [file join $root reports $baseline source_sha256.csv] [file join $report source_sha256.csv]
set f [open [file join $report experiment.txt] w]
set hash [exec certutil -hashfile $input SHA256]
if {![regexp {\n([0-9a-fA-F]{64})\r?\n} $hash unused digest]} {error "Checkpoint hash failed"}
set intervention [expr {$fourlane?"eight hard clock-region Pblocks, four same-row lanes each":"omit four hard Pblocks"}]
puts $f "Baseline: $baseline\nInput checkpoint: $input\nSHA256: $digest\nOnly intervention: $intervention\nNo re-synthesis, RTL changes, extra SLR constraint, seed change, or timing exceptions.\nFlow: opt_design; place_design Explore; phys_opt_design AggressiveExplore; route_design Explore"
close $f
open_checkpoint $input
if {[llength [get_pblocks -quiet]]} {error "Input checkpoint unexpectedly contains Pblocks"}
if {[llength [get_cells -hier -filter {IS_LOC_FIXED == 1}]]} {error "Input checkpoint has fixed cell LOCs"}
report_clocks -file [file join $report input_clocks.rpt]
if {$fourlane} {
    set cells [get_cells -hier -filter {IS_PRIMITIVE == 1}]
    set names [get_property NAME $cells]
    source [file join $root deqacc_v2_locality4lane.tcl]
    deqacc_v2_locality4lane::apply $report
}
write_xdc -force [file join $report input_constraints.xdc]
opt_design
place_design -directive Explore
write_checkpoint -force [file join $report placed.dcp]
report_timing_summary -delay_type min_max -max_paths 20 -file [file join $report timing_postplace.rpt]
phys_opt_design -directive AggressiveExplore
route_design -directive Explore
write_checkpoint -force [file join $report routed.dcp]
report_timing_summary -delay_type min_max -max_paths 30 -file [file join $report timing_summary_postroute.rpt]
report_route_status -file [file join $report route_status.rpt]
report_drc -file [file join $report drc.rpt]
report_design_analysis -congestion -file [file join $report congestion.rpt]
report_clock_utilization -file [file join $report clock_utilization.rpt]
set f [open [file join $report physical_cells.csv] w]
puts $f "cell,ref_name,site"
set cells [get_cells -hier -filter {IS_PRIMITIVE == 1}]
foreach cell $cells ref [get_property REF_NAME $cells] loc [get_property LOC $cells] {puts $f "$cell,$ref,$loc"}
close $f
puts "NO_PBLOCK_IMPLEMENTATION_COMPLETE $report"
