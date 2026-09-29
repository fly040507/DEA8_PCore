set root [file dirname [file normalize [info script]]]
set top [lindex $argv 0]
if {$top eq ""} {set top dea8_deqacc32_v3}
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
report_ram_utilization -file [file join $report ram.rpt]
write_checkpoint -force [file join $report synth.dcp]
puts "V3_OOC_COMPLETE top=$top part=xcu50-fsvh2104-2-e period=4.000 synthesis_only=1"
