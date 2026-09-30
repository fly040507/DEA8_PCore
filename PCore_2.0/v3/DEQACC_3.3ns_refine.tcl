set root [file normalize [lindex $argv 0]]
set report [file join $root reports DEQACC_3.3ns]
open_checkpoint [file join $report routed.dcp]
# Tighten optimization to 3.3 ns (never relax the required 4 ns period).
create_clock -name core_clk -period 3.300 [get_ports clk]
phys_opt_design -directive AggressiveExplore
route_design -directive Explore
report_timing_summary -delay_type min_max -max_paths 20 -file [file join $report refined_3p3_timing.rpt]
write_checkpoint -force [file join $report refined_3p3.dcp]
# Report the required operating point on the SAME routed netlist.
create_clock -name core_clk -period 4.000 [get_ports clk]
report_timing_summary -delay_type min_max -max_paths 20 -file [file join $report refined_250MHz_timing.rpt]
report_route_status -file [file join $report refined_route_status.rpt]
set csv [open [file join $report refined_stages.csv] w]
puts $csv "stage,logic_ns,route_ns,total_ns,slack_ns"
foreach {stage pattern} {
    D0_abs_lead {*magnitude_q_reg*} D1_normalize {*s0_reg*}
    D2_partial_prepare {*s1_reg*} D3_partial_response {*s2_reg*}
    D4_order {*order_q_reg*} D5_align {*align_q_reg*}
    D6_add_coarse {*raw_q_reg*} D7_control {*control_q_reg*}
    D8_normalize {*norm_q_reg*} D9_pack {*lane/result_value_reg*}
    ACC_storage {*acc_store*banks*}
} {
    set cells [get_cells -hier -filter "NAME =~ $pattern"]
    set text [report_timing -to $cells -max_paths 1 -return_string]
    set f [open [file join $report refined_${stage}.rpt] w];puts $f $text;close $f
    regexp {Data Path Delay:\s+([0-9.]+)ns\s+\(logic ([0-9.]+)ns.*route ([0-9.]+)ns} $text all total logic route
    set p [lindex [get_timing_paths -to $cells -max_paths 1] 0]
    puts $csv "$stage,$logic,$route,$total,[get_property SLACK $p]"
}
close $csv
write_checkpoint -force [file join $report final_250MHz.dcp]
