# Same implementation flow for every routing-only candidate. All evidence stays
# in the independent DEQACC project, never in the frozen DEA8 tree.
set root [file normalize [lindex $argv 0]]
set variant [lindex $argv 1]
if {$variant eq ""} {error "Expected report variant"}
set report [file join $root reports routing_$variant]
file mkdir $report
if {[llength $argv] > 2} {
    open_checkpoint [file join $root reports routing_R3 synth.dcp]
} else {
set source_list [open [file join $root pcore_all.f] r]
foreach line [split [read $source_list] "\n"] {
    set line [string trim $line]
    if {[string match "rtl/*" $line]} {read_verilog -sv [file join $root $line]}
}
close $source_list
read_xdc [file join $root core_clock.xdc]
synth_design -top DEQACC_3_3ns_timing_shell -part xcu50-fsvh2104-2-e -mode out_of_context
write_checkpoint -force [file join $report synth.dcp]
report_utilization -hierarchical -file [file join $report synth_utilization.rpt]
}
if {[llength $argv] > 2} {source [file join $root routing_groups.xdc]}
opt_design
place_design
phys_opt_design
route_design
write_checkpoint -force [file join $report routed.dcp]
# Match the existing refinement strategy, with the same final 250 MHz check.
create_clock -name core_clk -period 3.300 [get_ports clk]
phys_opt_design -directive AggressiveExplore
route_design -directive Explore
report_timing_summary -delay_type min_max -max_paths 20 -file [file join $report timing_3p3.rpt]
create_clock -name core_clk -period 4.000 [get_ports clk]
write_checkpoint -force [file join $report final_250MHz.dcp]
report_timing_summary -delay_type min_max -max_paths 20 -file [file join $report timing_250MHz.rpt]
report_route_status -file [file join $report route_status.rpt]
report_drc -file [file join $report drc.rpt]
report_utilization -hierarchical -file [file join $report utilization.rpt]
report_high_fanout_nets -max_nets 50 -timing -load_types -file [file join $report fanout.rpt]
report_design_analysis -congestion -file [file join $report congestion.rpt]
set csv [open [file join $report stages.csv] w]
puts $csv "stage,logic_ns,route_ns,total_ns,slack_ns,startpoint,endpoint"
foreach {stage pattern} {
    D0 {*magnitude_q_reg*} D1 {*s0_reg*} D2 {*s1_reg*} D3 {*s2_reg*}
    D4 {*order_q_reg*} D5 {*align_q_reg*} D6 {*raw_q_reg*}
    D7 {*control_q_reg*} D8 {*norm_q_reg*} D9 {*lane/result_value_reg*}
    ACC {*acc_store*banks*}
} {
    set cells [get_cells -quiet -hier -filter "NAME =~ $pattern"]
    if {![llength $cells]} {error "Missing stage endpoints: $stage"}
    set text [report_timing -to $cells -max_paths 10 -return_string]
    set f [open [file join $report ${stage}_top10.rpt] w];puts $f $text;close $f
    if {![regexp {Data Path Delay:\s+([0-9.]+)ns\s+\(logic ([0-9.]+)ns[^\n]*route ([0-9.]+)ns} $text all total logic route]} {
        error "Cannot parse stage $stage"
    }
    set p [lindex [get_timing_paths -to $cells -max_paths 1] 0]
    puts $csv "$stage,$logic,$route,$total,[get_property SLACK $p],[get_property STARTPOINT_PIN $p],[get_property ENDPOINT_PIN $p]"
}
close $csv
set f [open [file join $report physical_cells.csv] w]
puts $f "cell,ref_name,site,clock_region"
foreach c [get_cells -hier -filter {IS_PRIMITIVE == 1}] {
    set sites [get_sites -quiet -of_objects $c]
    set region ""
    if {[llength $sites]} {set region [get_property CLOCK_REGION [lindex $sites 0]]}
    puts $f "$c,[get_property REF_NAME $c],[get_property LOC $c],$region"
}
close $f
write_checkpoint -force [file join $report final_250MHz.dcp]
