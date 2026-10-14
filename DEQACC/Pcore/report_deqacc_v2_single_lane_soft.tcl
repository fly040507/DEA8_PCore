set root [file normalize [lindex $argv 0]]
set report [file join $root reports [lindex $argv 1]]
open_checkpoint [file join $report routed.dcp]
source [file join $root deqacc_v2_single_lane_soft.tcl]
deqacc_v2_single_lane_soft::placement_report $report [lrange $argv 2 end]
puts "SOFT_PLACEMENT_REPORT_COMPLETE $report"
