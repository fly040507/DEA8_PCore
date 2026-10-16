# Leaf OOC resource check, not timing or full-chip implementation signoff.
set here [file dirname [file normalize [info script]]]
cd $here
file mkdir reports
set part xcu50-fsvh2104-2-e
create_project -in_memory -part $part
read_ip ip/generated/gcore_rsqrt_ip/gcore_rsqrt_ip.xci
synth_ip [get_ips gcore_rsqrt_ip]
open_checkpoint ip/generated/gcore_rsqrt_ip/gcore_rsqrt_ip.dcp
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
    set count [llength [get_cells -hier -filter {REF_NAME == DSP48E2}]]
    if {$count != 2} { error "$top uses $count DSPs, expected 2" }
    report_utilization -file reports/${top}_utilization.rpt
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
