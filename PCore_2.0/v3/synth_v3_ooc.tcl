set root [lindex $argv 1]
if {$root eq ""} {error "Pass the absolute source root as Tcl argument 2"}
set top [lindex $argv 0]
if {$top eq ""} {set top dea8_deqacc32_v4}
set report [file join $root reports ooc_$top]
file mkdir $report
set f [open [file join $root v3_all.f] r]
foreach line [split [read $f] "\n"] {
    set line [string trim $line]
    if {[string match "rtl/*" $line]} {read_verilog -sv [file join $root $line]}
}
close $f
read_xdc [file join $root core_clock.xdc]
synth_design -top $top -part xcu50-fsvh2104-2-e -mode out_of_context
report_utilization -hierarchical -file [file join $report utilization.rpt]
report_timing_summary -delay_type max -max_paths 10 -file [file join $report timing.rpt]
# Report current v4 arithmetic boundaries separately, including D0's actual
# upstream register path when the synthesized top contains the MXU.
foreach {stage pattern} {
    d0 {*mag_q0_reg*}
    d1 {*partial_q1_reg*}
    fp_prepare {*pre_q1_reg*}
    fp_addsub {*raw_q2_reg*}
    fp_normalize {*norm_q3_reg*}
    fp_pack {*result_value_reg*}
} {
    set endpoints [get_cells -quiet -hier -filter "NAME =~ $pattern"]
    if {[llength $endpoints]} {
        report_timing -to $endpoints -max_paths 3 -file [file join $report ${stage}_timing.rpt]
    }
}
set pre [get_cells -quiet -hier -regexp {.*add_pre_q2_reg.*}]
set sum [get_cells -quiet -hier -regexp {.*sum_q3_reg.*}]
if {[llength $pre] && [llength $sum]} {
    report_timing -from $pre -to $sum -max_paths 3 -file [file join $report d3_timing.rpt]
    report_timing -to $pre -max_paths 3 -file [file join $report d2_timing.rpt]
}
report_ram_utilization -file [file join $report ram.rpt]
write_checkpoint -force [file join $report synth.dcp]
puts "V3_OOC_COMPLETE top=$top part=xcu50-fsvh2104-2-e period=4.000 synthesis_only=1"
