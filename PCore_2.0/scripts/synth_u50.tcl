set root [file dirname [file dirname [string map {\\ /} [info script]]]]
puts "Synthesis source root: $root"
set top [lindex $argv 0]
if {$top eq ""} {set top dea8_mxu_2row}
file mkdir [file join $root reports]
set f [open [file join $root rtl pcore2.f] r]
foreach line [split [read $f] "\n"] {
    set line [string trim $line]
    if {$line ne ""} {read_verilog -sv [file join $root rtl $line]}
}
close $f
read_xdc [file join $root scripts core_clock.xdc]
synth_design -top $top -part xcu50-fsvh2104-2-e -mode out_of_context
report_utilization -file [file join $root reports ${top}_utilization.rpt]
report_timing_summary -file [file join $root reports ${top}_synth_timing.rpt]
set dsps [llength [get_cells -hier -filter {REF_NAME == DSP48E2}]]
puts "RESOURCE_CHECK $top DSP48E2=$dsps"
if {$top eq "dea8_pe_2row" && $dsps != 1} {error "Expected one DSP per PE"}
if {$top eq "dea8_mxu_2row" && $dsps != 256} {error "Expected 256 DSPs per MXU"}
if {$top eq "dea8_matrix_engine_2row" && $dsps != 256} {error "Control/address logic must not infer extra DSPs"}
write_checkpoint -force [file join $root reports ${top}_synth.dcp]
