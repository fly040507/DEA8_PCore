set root [file normalize [lindex $argv 0]]
set baseline [lindex $argv 1]
set natural [lindex $argv 2]
set tag [lindex $argv 3]
set report [file join $root reports $tag]
if {[file exists $report]} {error "Use a fresh report tag"}
set input [file join $root reports $baseline synthesized.dcp]
set reference [file join $root reports $natural routed.dcp]
if {![file exists $input]||![file exists $reference]} {error "Missing baseline/natural DCP"}
file mkdir $report
file copy [file join $root reports $baseline source_sha256.csv] [file join $report source_sha256.csv]
set f [open [file join $report experiment_hashes.csv] w]
puts $f "input,sha256"
foreach p [list $input $reference [file join $root deqacc_v2_single_lane_soft.tcl] [file join $root implement_deqacc_v2_single_lane_soft.tcl]] {
    set text [exec certutil -hashfile $p SHA256]
    if {![regexp {\n([0-9a-fA-F]{64})\r?\n} $text unused hash]} {error "Hash error $p"}
    puts $f "$p,$hash"
}
close $f
source [file join $root deqacc_v2_single_lane_soft.tcl]
deqacc_v2_single_lane_soft::derive $reference $report
open_checkpoint $input
if {[llength [get_pblocks -quiet]]} {error "Synth baseline must have no Pblocks"}
if {[llength [get_cells -hier -filter {IS_LOC_FIXED == 1}]]} {error "Baseline fixed LOCs"}
deqacc_v2_single_lane_soft::apply $report
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
deqacc_v2_single_lane_soft::placement_report $report
puts "SINGLE_LANE_SOFT_IMPLEMENTATION_COMPLETE $report"
