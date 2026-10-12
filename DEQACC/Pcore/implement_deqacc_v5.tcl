set root [file normalize [lindex $argv 0]]
set report [file join $root reports ooc_dea8_deqacc32_v5]
open_checkpoint [file join $report synth.dcp]
# OOC internal timing only. No I/O pins or board interface budget claimed.
opt_design
place_design
phys_opt_design
report_timing_summary -file [file join $report placed_timing.rpt]
route_design
report_timing_summary -delay_type min_max -max_paths 10 -file [file join $report routed_timing.rpt]
report_route_status -file [file join $report route_status.rpt]
report_drc -file [file join $report routed_drc.rpt]
write_checkpoint -force [file join $report routed.dcp]
