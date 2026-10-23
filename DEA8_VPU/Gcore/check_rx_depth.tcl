# Isolated RX comparison only; not a full GCore or timing check.
set here [file dirname [file normalize [info script]]]
cd $here
create_project -in_memory -part xcu50-fsvh2104-2-e
foreach source {
    ../Pcore/rtl/pcore_pkg.sv ../Pcore/rtl/dea8_tile_link_pkg.sv
    ../Pcore/rtl/dea8_fp32_pkg.sv rtl/gcore_pkg.sv rtl/gcore_fp_pkg.sv
    rtl/dea8_gcore_fifo.sv rtl/dea8_gcore_packet_rx.sv
} {read_verilog -sv $source}
set f [open reports/rx_depth_comparison.txt w]
puts $f "Isolated eight-port packet RX, U50 OOC. No timing signoff."
foreach depth {4 8} {
    synth_design -top dea8_gcore_packet_rx -mode out_of_context -generic DEPTH=$depth -part xcu50-fsvh2104-2-e
    report_utilization -file reports/rx_depth_${depth}.rpt
    set luts [llength [get_cells -quiet -hier -filter {REF_NAME =~ LUT*}]]
    set ffs [llength [get_cells -quiet -hier -filter {REF_NAME =~ FD*}]]
    set dsps [llength [get_cells -quiet -hier -filter {REF_NAME == DSP48E2}]]
    puts $f "DEPTH=$depth LUT_PRIMITIVES=$luts FF_PRIMITIVES=$ffs DSP=$dsps report=rx_depth_${depth}.rpt"
    if {$dsps != 0} {error "Unexpected RX arithmetic DSPs: $dsps"}
    close_design
}
close $f
puts "GCORE_RX_DEPTH_PASS"
