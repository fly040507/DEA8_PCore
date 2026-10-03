# Read-only netlist reporting: do not re-optimize or overwrite the checkpoint.
set root [file normalize [lindex $argv 0]]
set report [file join $root reports DEQACC_3.3ns]
open_checkpoint [file join $report final_250MHz.dcp]
report_utilization -hierarchical -file [file join $report final_utilization.rpt]
report_drc -file [file join $report final_drc.rpt]
