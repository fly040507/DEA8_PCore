# Out-of-context inference smoke test, not board-level timing signoff.
# Override the representative part through DEA8_SYNTH_PART if needed.
set here [file dirname [file normalize [info script]]]
set output [file join $here b_fifo_synth]
file mkdir $output
set part xcu280-fsvh2892-2L-e
if {[info exists ::env(DEA8_SYNTH_PART)]} { set part $::env(DEA8_SYNTH_PART) }
if {[llength [get_parts -quiet $part]] != 1} { error "Part not installed: $part" }
read_verilog -sv [file join $here dea8_pcore_pkg.sv]
read_verilog -sv [file join $here dea8_b_fifo.sv]
synth_design -top dea8_b_fifo -part $part -mode out_of_context
create_clock -name clk -period 4.000 [get_ports clk]
report_utilization -file [file join $output utilization.rpt]
report_timing_summary -file [file join $output timing_synth_only.rpt]
set brams [get_cells -hier -filter {REF_NAME =~ RAMB*}]
if {[llength $brams] == 0} { error "B FIFO did not infer block RAM" }
set report [open [file join $output inference.txt] w]
puts $report "Representative part: $part"
puts $report "B FIFO payload=136 depth=64; synchronous clear; cached head"
puts $report "Block RAM primitive count: [llength $brams]"
foreach cell $brams {
  puts $report "$cell [get_property REF_NAME $cell]"
}
puts $report "Synthesis inference only; no placement/routing or system timing signoff."
close $report
puts "B_FIFO_SYNTH_PASS primitives=[llength $brams]"
exit
