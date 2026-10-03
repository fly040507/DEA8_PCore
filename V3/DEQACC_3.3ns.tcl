set root [file normalize [lindex $argv 0]]
set report [file join $root reports DEQACC_3.3ns]
file mkdir $report
set f [open [file join $root v3_all.f] r]
foreach line [split [read $f] "\n"] {
    set line [string trim $line]
    if {[string match "rtl/*" $line]} {read_verilog -sv [file join $root $line]}
}
close $f
read_xdc [file join $root core_clock.xdc]
synth_design -top DEQACC_3_3ns_timing_shell -part xcu50-fsvh2104-2-e -mode out_of_context
proc stage_reports {report prefix} {
    set csv [open [file join $report ${prefix}_stages.csv] w]
    puts $csv "stage,startpoint,endpoint,logic_ns,route_ns,total_ns,slack_ns"
    foreach {stage pattern} {
        D0_abs_lead {*magnitude_q_reg*}
        D1_normalize {*s0_reg*}
        D2_partial_prepare {*s1_reg*}
        D3_partial_response {*s2_reg*}
        D4_order {*order_q_reg*}
        D5_align {*align_q_reg*}
        D6_add_coarse {*raw_q_reg*}
        D7_control {*control_q_reg*}
        D8_normalize {*norm_q_reg*}
        D9_pack {*lane/result_value_reg*}
        D10_store {*acc_store*banks*}
    } {
        set cells [get_cells -quiet -hier -filter "NAME =~ $pattern"]
        if {![llength $cells]} {error "Missing stage endpoints: $stage"}
        set text [report_timing -to $cells -max_paths 1 -return_string]
        set out [open [file join $report ${prefix}_${stage}.rpt] w];puts $out $text;close $out
        set paths [get_timing_paths -quiet -to $cells -max_paths 1]
        if {![llength $paths]} {error "Missing timing path: $stage"}
        set p [lindex $paths 0]
        if {![regexp {Data Path Delay:\s+([0-9.]+)ns\s+\(logic ([0-9.]+)ns.*route ([0-9.]+)ns} $text all total logic route]} {
            error "Cannot parse delay for $stage"
        }
        puts $csv "$stage,[get_property STARTPOINT_PIN $p],[get_property ENDPOINT_PIN $p],$logic,$route,$total,[get_property SLACK $p]"
    }
    close $csv
    report_timing_summary -delay_type min_max -max_paths 20 -file [file join $report ${prefix}_timing.rpt]
    report_utilization -hierarchical -file [file join $report ${prefix}_utilization.rpt]
}
stage_reports $report synth
write_checkpoint -force [file join $report synth.dcp]
opt_design
place_design
phys_opt_design
route_design
stage_reports $report routed
report_route_status -file [file join $report route_status.rpt]
report_drc -file [file join $report drc.rpt]
write_checkpoint -force [file join $report routed.dcp]
