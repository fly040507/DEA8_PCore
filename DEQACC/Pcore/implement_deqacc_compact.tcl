# Compact real P&R: seven stage timing, key interfaces, global resources.
set root [file normalize [lindex $argv 0]]
set tag [lindex $argv 1]
set report [file join $root reports $tag]
set report_only [expr {[llength $argv]>3&&[lindex $argv 3] eq "report_only"}]
if {!$report_only&&[file exists $report]} {error "Use a new report tag"}
if {!$report_only} {file mkdir $report}
set sources {
    rtl/pcore_pkg.sv rtl/dea8_fp32_pkg.sv rtl/deqacc_v1_pkg.sv
    rtl/dea8_acc_store.sv rtl/deqacc_v2_fanout.sv rtl/deqacc_v2_scale_ingress.sv
    rtl/dequant_lane_v1.sv rtl/fp32_add_lane_v1.sv rtl/acc_slice_v1.sv
    rtl/deqacc_v1_control.sv rtl/DEQACC_V1.sv rtl/deqacc_v2_timing_shell.sv
}
if {!$report_only} {
set manifest [open [file join $report source_sha256.csv] w]
puts $manifest "file,sha256"
foreach file [concat $sources {core_clock.xdc implement_deqacc_compact.tcl}] {
    set text [exec certutil -hashfile [file join $root $file] SHA256]
    if {![regexp {\n([0-9a-fA-F]{64})\r?\n} $text unused hash]} {error "Hash failure"}
    puts $manifest "$file,$hash"
}
close $manifest
foreach file $sources {read_verilog -sv [file join $root $file]}
read_xdc [file join $root core_clock.xdc]
set target_period 4.000
if {[llength $argv]>2} {set target_period [lindex $argv 2]}
if {$target_period>4.000||$target_period<=0} {error "Optimization period must not relax 4ns"}
set f [open [file join $report optimization_target.txt] w]
puts $f "Implementation period: $target_period ns\nFinal reported operating period: 4.000 ns\nRequired operating margin: WNS >= +0.500 ns"
close $f
puts "COMPACT_STEP synth_start tag=$tag"
synth_design -top deqacc_v2_timing_shell -part xcu50-fsvh2104-2-e -mode out_of_context -flatten_hierarchy rebuilt
create_clock -name core_clk -period $target_period [get_ports clk]
write_checkpoint -force [file join $report synthesized.dcp]
puts "COMPACT_STEP place_start"
opt_design
place_design -directive Explore
phys_opt_design -directive AggressiveExplore
puts "COMPACT_STEP route_start"
route_design -directive Explore
report_timing_summary -delay_type min_max -max_paths 3 -file [file join $report timing_optimization_target.rpt]
create_clock -name core_clk -period 4.000 [get_ports clk]
write_checkpoint -force [file join $report routed.dcp]
} else {open_checkpoint [file join $report routed.dcp]}
report_timing_summary -delay_type min_max -max_paths 7 -file [file join $report timing_summary_postroute.rpt]
report_route_status -file [file join $report route_status.rpt]
report_utilization -file [file join $report utilization.rpt]
report_utilization -hierarchical -hierarchical_depth 1 -file [file join $report core_utilization.rpt]
report_drc -file [file join $report drc.rpt]
set cells [get_cells -hier -filter {IS_PRIMITIVE == 1}]
set names [get_property NAME $cells];set refs [get_property REF_NAME $cells]
proc select {pattern} {
    global cells names refs
    set result {}
    foreach cell $cells name $names ref $refs {
        if {[regexp $pattern $name]} {
            if {[string first "_reg" $pattern]>=0&&![regexp {^(FD|SRL)} $ref]} {continue}
            lappend result $cell
        }
    }
    return $result
}
set Q0 [select {^core/physical_regions.*quant/(mag_q|lead_q|base_q|sign_q|zero_q|bad_q|valid_q)_reg}]
set Q1 [select {^core/physical_regions.*quant/(partial_value|out_valid)_reg}]
set A0 [select {^core/physical_regions.*add/order_q_reg}]
set A1 [select {^core/physical_regions.*add/arithmetic_q_reg}]
set A2 [select {^core/physical_regions.*add/candidates_q_reg}]
set A3 [select {^core/physical_regions.*add/(result_value|out_valid)_reg}]
set C [select {^core/physical_regions.*\.c_q_reg}]
set control [select {^core/control/.*}]
set memory [select {^core/memory/.*}]
set out [open [file join $report stages.csv] w]
puts $out "stage,logic_ns,route_ns,total_ns,slack_ns,logic_levels,startpoint,endpoint"
proc measure {name to {from {}}} {
    global out report
    if {![llength $to]} {error "Missing sequential group $name"}
    set options [list -to $to -max_paths 1 -delay_type max -path_type full -input_pins]
    if {[llength $from]} {lappend options -from $from}
    set text [report_timing {*}$options -return_string]
    if {![regexp {Data Path Delay:\s+([0-9.]+)ns\s+\(logic ([0-9.]+)ns[^\n]*route ([0-9.]+)ns} $text unused total logic route]} {error "Missing timing group $name"}
    set pathopts [list -to $to -max_paths 1 -delay_type max]
    if {[llength $from]} {lappend pathopts -from $from}
    set path [lindex [get_timing_paths {*}$pathopts] 0]
    set f [open [file join $report ${name}.rpt] w];puts $f $text;close $f
    puts $out "$name,$logic,$route,$total,[get_property SLACK $path],[get_property LOGIC_LEVELS $path],[get_property STARTPOINT_PIN $path],[get_property ENDPOINT_PIN $path]"
}
foreach stage {Q0 Q1 A0 A1 A2 A3 C} {measure $stage [set $stage]}
measure FORWARD_CONTROL $A0 $control
measure A3_FEEDBACK $A0 $A3
measure C_FEEDBACK $A0 $C
measure ACC_READ $A0 $memory
measure ACC_WRITE $memory
measure A3_DATA [get_pins -of_objects [select {^core/physical_regions.*add/result_value_reg}] -filter {REF_PIN_NAME == D}]
close $out
puts "COMPACT_ROUTED_REPORT_COMPLETE $report"
