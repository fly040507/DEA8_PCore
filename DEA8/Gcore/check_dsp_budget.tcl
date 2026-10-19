# Leaf OOC resource check, not timing or full-chip implementation signoff.
set here [file dirname [file normalize [info script]]]
cd $here
file mkdir reports
set part xcu50-fsvh2104-2-e
create_project -in_memory -part $part
foreach file {ip/generated/gcore_rsqrt_ip/gcore_rsqrt_ip.xci ../Pcore/ip/generated/dea8_fpadd_ip/dea8_fpadd_ip.xci ../Pcore/ip/generated/dea8_fpmul_ip/dea8_fpmul_ip.xci} {
    read_ip $file
    set_property GENERATE_SYNTH_CHECKPOINT false [get_files $file]
    generate_target synthesis [get_files $file]
}
synth_design -top gcore_rsqrt_ip -part $part -mode out_of_context
set rsqrt_dsps [llength [get_cells -hier -filter {REF_NAME == DSP48E2}]]
report_utilization -file reports/rsqrt_utilization.rpt
close_design
read_verilog -sv ../Pcore/rtl/dea8_fp32_pkg.sv
read_verilog -sv rtl/gcore_fp_pkg.sv
read_verilog -sv rtl/dea8_gcore_dsp_alu.sv
read_verilog -sv rtl/dea8_gcore_fp_add.sv
read_verilog -sv rtl/dea8_gcore_fp_mul.sv
foreach top {dea8_gcore_fp_add dea8_gcore_fp_mul} {
    synth_design -top $top -part $part -mode out_of_context
    create_clock -name core_clk -period 4.000 [get_ports clk]
    if {[llength [get_cells -hier -quiet -filter {IS_BLACKBOX == 1}]]} {error "Unresolved official FP IP"}
    set count [llength [get_cells -hier -filter {REF_NAME == DSP48E2}]]
    if {$count != 2} { error "$top uses $count DSPs, expected 2" }
    report_utilization -file reports/${top}_utilization.rpt
    report_timing_summary -max_paths 20 -file reports/${top}_timing.rpt
    close_design
}
set total [expr {34*2 + 16*2 + $rsqrt_dsps}]
set f [open reports/dsp_budget.txt w]
puts $f "Leaf OOC synthesis; not a full GCore/system synthesis."
puts $f "FP32_ADD_DSP=2 FP32_MUL_DSP=2 RSQRT_DSP=$rsqrt_dsps"
puts $f "GCORE_STRUCTURAL_DSP=34*2+16*2+$rsqrt_dsps=$total"
puts $f "BUDGET=109, includes four-lane reduce and single rsqrt"
close $f
if {$total > 109} { error "GCore DSP budget exceeded: $total" }
puts "GCORE_DSP_BUDGET_PASS $total"
