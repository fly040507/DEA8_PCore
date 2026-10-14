# V3 closure: reuse the verified compact No-Pblock flow without renaming RTL.
set root [file normalize [lindex $argv 0]]
set tag [lindex $argv 1]
if {$tag eq ""} {set tag v3_postroute}
set argv [list $root $tag 3.500]
source [file join $root implement_deqacc_compact.tcl]
# One bounded checkpoint refinement if repeat placement falls microscopically
# short of the owner's margin. Never change RTL or relax final operating clock.
set initial [get_property SLACK [lindex [get_timing_paths -delay_type max -max_paths 1] 0]]
if {$initial<0.5} {
    set dir [file join $root reports $tag]
    write_checkpoint -force [file join $dir before_margin_refine.dcp]
    set f [open [file join $dir refinement.txt] w]
    puts $f "Initial 4ns WNS: $initial\nOne bounded refinement: 3.450ns phys_opt AggressiveExplore + route Explore\nNo RTL changes; final operating clock stays 4.000ns."
    close $f
    create_clock -name core_clk -period 3.450 [get_ports clk]
    phys_opt_design -directive AggressiveExplore
    route_design -directive Explore
    report_timing_summary -delay_type min_max -max_paths 3 -file [file join $dir timing_optimization_target.rpt]
    create_clock -name core_clk -period 4.000 [get_ports clk]
    write_checkpoint -force [file join $dir routed.dcp]
    close_design
    set argv [list $root $tag 3.450 report_only]
    source [file join $root implement_deqacc_compact.tcl]
}
# Read STA from the same final 4ns routed design at full available precision.
set setup [lindex [get_timing_paths -delay_type max -max_paths 1] 0]
set hold [lindex [get_timing_paths -delay_type min -max_paths 1] 0]
set slack [get_property SLACK $setup]
set f [open [file join $root reports $tag margin_exact.txt] w]
puts $f "Clock_period_ns=[get_property PERIOD [get_clocks core_clk]]"
puts $f "Worst_setup_slack_ns=$slack"
puts $f "Worst_hold_slack_ns=[get_property SLACK $hold]"
puts $f "Margin_0p5_pass=[expr {$slack>=0.5}]"
puts $f "Startpoint=[get_property STARTPOINT_PIN $setup]"
puts $f "Endpoint=[get_property ENDPOINT_PIN $setup]"
close $f
puts "V3_CLOSURE margin=$slack meets_0p5=[expr {$slack>=0.5}]"
