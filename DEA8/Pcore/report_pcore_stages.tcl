set root [file dirname [file normalize [info script]]]
set top [lindex $argv 0]
if {$top eq ""} {set top dea8_attention_matrix}
set report [file join $root reports ooc_$top]
open_checkpoint [file join $report synth.dcp]
set pre [get_cells -hier -regexp {.*add_pre_q2_reg.*}]
set sum [get_cells -hier -regexp {.*sum_q3_reg.*}]
if {[llength $pre]==0 || [llength $sum]==0} {error "D2/D3 registers missing"}
report_timing -from $pre -to $sum -max_paths 10 -file [file join $report d3_timing.rpt]
report_timing -to $pre -max_paths 10 -file [file join $report d2_timing.rpt]
