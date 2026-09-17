# Full W ingress and bank-control OOC smoke test, excluding MXU/DEQACC.
set here [file dirname [file normalize [info script]]]
set output [file join $here w_loader_synth]
file mkdir $output
set part xcu280-fsvh2892-2L-e
if {[info exists ::env(DEA8_SYNTH_PART)]} { set part $::env(DEA8_SYNTH_PART) }
foreach source {dea8_pcore_pkg.sv dea8_b_fifo.sv dea8_b_column_loader.sv dea8_w_tile_assembler.sv dea8_w_b_stream.sv dea8_stationary_loader.sv dea8_w_loader.sv} {
  read_verilog -sv [file join $here $source]
}
synth_design -top dea8_w_loader -part $part -mode out_of_context
create_clock -name clk -period 4.000 [get_ports clk]
report_utilization -hierarchical -file [file join $output hierarchy.rpt]
report_utilization -file [file join $output utilization.rpt]
report_timing_summary -file [file join $output timing_synth_only.rpt]
set brams [get_cells -hier -filter {REF_NAME =~ RAMB*}]
if {[llength $brams]==0} { error "W FIFO did not infer block RAM" }
set report [open [file join $output inference.txt] w]
puts $report "Full dea8_w_loader OOC: assembler, paired FIFO, column datapath, bank owner."
puts $report "Representative part: $part"
puts $report "Block RAM primitives: [llength $brams]"
foreach cell $brams { puts $report "$cell [get_property REF_NAME $cell]" }
puts $report "No placement/routing; no system frequency or timing signoff."
close $report
puts "W_LOADER_SYNTH_PASS primitives=[llength $brams]"
exit
