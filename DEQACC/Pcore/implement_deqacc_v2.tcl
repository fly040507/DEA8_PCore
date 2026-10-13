# Full clocked OOC implementation; no functional RTL changes, no false paths
# or multicycle exceptions used to hide pipeline/forwarding failures.
set root [file normalize [lindex $argv 0]]
set tag [lindex $argv 1]
set report [file join $root reports $tag]
if {[file exists $report]} {error "Use a new implementation report tag"}
file mkdir $report
set sources {
    rtl/pcore_pkg.sv rtl/dea8_fp32_pkg.sv rtl/deqacc_v1_pkg.sv
    rtl/dea8_acc_store.sv rtl/deqacc_v2_fanout.sv rtl/deqacc_v2_scale_ingress.sv
    rtl/dequant_lane_v1.sv rtl/fp32_add_lane_v1.sv rtl/acc_slice_v1.sv
    rtl/deqacc_v1_control.sv rtl/DEQACC_V1.sv rtl/deqacc_v2_timing_shell.sv
}
set f [open [file join $report source_sha256.csv] w]
puts $f "file,sha256"
foreach name [concat $sources {core_clock.xdc deqacc_v2_locality.tcl implement_deqacc_v2.tcl}] {
    set hash [exec certutil -hashfile [file join $root $name] SHA256]
    regexp {\n([0-9a-fA-F]{64})\r?\n} $hash unused digest
    puts $f "$name,$digest"
}
close $f
foreach name $sources {read_verilog -sv [file join $root $name]}
read_xdc [file join $root core_clock.xdc]
synth_design -top deqacc_v2_timing_shell -part xcu50-fsvh2104-2-e -mode out_of_context -flatten_hierarchy rebuilt
write_checkpoint -force [file join $report synthesized.dcp]
set cells [get_cells -hierarchical -filter {IS_PRIMITIVE == 1}]
set names [get_property NAME $cells]
source [file join $root deqacc_v2_locality.tcl]
proc deqacc_v2_locality::primitives {pattern} {
    global cells names
    set result {}
    foreach cell $cells name $names {if {[regexp $pattern $name]} {lappend result $cell}}
    return $result
}
deqacc_v2_locality::apply core
opt_design
place_design -directive Explore
write_checkpoint -force [file join $report placed.dcp]
report_timing_summary -delay_type min_max -max_paths 20 -file [file join $report timing_postplace.rpt]
phys_opt_design -directive AggressiveExplore
route_design -directive Explore
# Save before report generation, even if timing is negative.
write_checkpoint -force [file join $report routed.dcp]
report_timing_summary -delay_type min_max -max_paths 30 -file [file join $report timing_summary_postroute.rpt]
report_route_status -file [file join $report route_status.rpt]
report_drc -file [file join $report drc.rpt]
report_design_analysis -congestion -file [file join $report congestion.rpt]
report_clock_utilization -file [file join $report clock_utilization.rpt]
set f [open [file join $report physical_cells.csv] w]
puts $f "cell,ref_name,site"
set placed_cells [get_cells -hierarchical -filter {IS_PRIMITIVE == 1}]
foreach cell $placed_cells ref [get_property REF_NAME $placed_cells] loc [get_property LOC $placed_cells] {
    puts $f "$cell,$ref,$loc"
}
close $f
puts "V2_IMPLEMENTATION_COMPLETE $report"
