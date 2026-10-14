# Synthesis only. No opt_design/place_design/phys_opt_design/route_design.
# argv: project root, report tag. Use one fixed RTL snapshot per report run.
set root [file normalize [lindex $argv 0]]
set tag [lindex $argv 1]
if {$tag eq ""} {error "Expected a unique report tag"}
set report [file join $root reports $tag]
set routed_report [expr {[llength $argv]>2 && [lindex $argv 2] eq "report_route"}]
set report_only [expr {$routed_report || ([llength $argv]>2 && [lindex $argv 2] eq "report_only")}]
if {!$report_only && [file exists $report]} {error "Report directory already exists: $report"}
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
foreach name [concat $sources {core_clock.xdc deqacc_v2_locality.tcl synth_deqacc_v2.tcl}] {
    set hash [exec certutil -hashfile [file join $root $name] SHA256]
    if {![regexp {\n([0-9a-fA-F]{64})\r?\n} $hash unused digest]} {error "Hash failed: $name"}
    puts $manifest "$name,$digest"
}
close $manifest
foreach name $sources {read_verilog -sv [file join $root $name]}
read_xdc [file join $root core_clock.xdc]
synth_design -top deqacc_v2_timing_shell -part xcu50-fsvh2104-2-e -mode out_of_context -flatten_hierarchy rebuilt
write_checkpoint -force [file join $report synthesized.dcp]
} else {
    open_checkpoint [file join $report [expr {$routed_report?"routed.dcp":"synthesized.dcp"}]]
}
report_timing_summary -delay_type min_max -max_paths 30 -report_unconstrained -file [file join $report [expr {$routed_report?"timing_summary_postroute.rpt":"timing_summary_synth.rpt"}]]
report_utilization -file [file join $report utilization.rpt]
report_utilization -hierarchical -hierarchical_depth 6 -file [file join $report utilization_hierarchical.rpt]
report_high_fanout_nets -max_nets 100 -timing -load_types -file [file join $report fanout.rpt]
report_drc -file [file join $report drc.rpt]
check_timing -verbose -file [file join $report check_timing.rpt]

set primitive_objects [get_cells -hierarchical -filter {IS_PRIMITIVE == 1}]
set primitive_names [get_property NAME $primitive_objects]
set primitive_refs [get_property REF_NAME $primitive_objects]
proc primitives {pattern} {
    global primitive_objects primitive_names primitive_refs
    set result {}
    # Match full NAME properties in Tcl: Vivado -hierarchical search patterns
    # otherwise interpret hierarchy separators differently across netlists.
    foreach cell $primitive_objects name $primitive_names ref $primitive_refs {
        if {[regexp {_reg(\.|\\|\[|$)} $pattern] && ![string match FD* $ref] && ![string match SRL* $ref]} {continue}
        if {[regexp $pattern $name]} {lappend result $cell}
    }
    return $result
}
set Q0 [primitives {^core/physical_regions\[[0-3]\]\.lanes\[[0-7]\]\.quant/(mag_q|lead_q|base_q|sign_q|zero_q|bad_q|valid_q)_reg.*}]
set Q1 [primitives {^core/physical_regions\[[0-3]\]\.lanes\[[0-7]\]\.quant/(partial_value|out_valid)_reg.*}]
set A0 [primitives {^core/physical_regions\[[0-3]\]\.lanes\[[0-7]\]\.add/order_q_reg.*}]
set A1 [primitives {^core/physical_regions\[[0-3]\]\.lanes\[[0-7]\]\.add/arithmetic_q_reg.*}]
set A2 [primitives {^core/physical_regions\[[0-3]\]\.lanes\[[0-7]\]\.add/candidates_q_reg.*}]
set A3 [primitives {^core/physical_regions\[[0-3]\]\.lanes\[[0-7]\]\.add/(result_value|out_valid)_reg.*}]
set C [primitives {^core/physical_regions\[[0-3]\]\.lanes\[[0-7]\]\.c_q_reg.*}]
set memory [primitives {^core/memory/.*}]
set spine [primitives {^core/control/.*}]
set launch [primitives {^(rsp_q|rsp_valid_q|reset_q|clear_q|owner_q|rd_valid_q|sel_q|addr_q|wr_valid_q|wr_q)_reg.*}]
set capture [primitives {^(result_rd_ready|vpu_wr_ready|result_rd_data_valid|commit_valid|done|commit_write_valid|commit_meta|commit_write|result_even_data|result_odd_data)_reg.*}]
set all [get_cells -hierarchical -filter {IS_PRIMITIVE == 1}]
set names [get_property NAME $all];set refs [get_property REF_NAME $all]
set census [open [file join $report primitive_cells.csv] w]
puts $census "cell,ref_name"
foreach name $names ref $refs {puts $census "$name,$ref"}
close $census
set endpoints [open [file join $report endpoint_coverage.csv] w]
puts $endpoints "stage,primitive_count"
foreach stage {Q0 Q1 A0 A1 A2 A3 C} {
    if {![llength [set $stage]]} {error "No synthesized endpoint cells for $stage; inspect primitive_cells.csv"}
    puts $endpoints "$stage,[llength [set $stage]]"
}
close $endpoints
set csv [open [file join $report path_delays.csv] w]
puts $csv "group,paths,logic_ns,[expr {$routed_report?"routed_net_ns":"estimated_net_ns"}],total_ns,slack_ns,logic_levels,startpoint,endpoint"
proc characterize {name to {from {}}} {
    global report csv
    if {![llength $to]} {error "Missing endpoint group: $name"}
    set options [list -to $to -delay_type max -max_paths 10 -nworst 1]
    if {[llength $from]} {lappend options -from $from}
    set paths [get_timing_paths {*}$options]
    if {![llength $paths]} {
        puts $csv "$name,0,NA,NA,NA,NA,NA,NA,NA"
    return
    }
    set text [report_timing {*}$options -path_type full -input_pins -return_string]
    set f [open [file join $report ${name}_top10.rpt] w];puts $f $text;close $f
    if {![regexp {Data Path Delay:\s+([0-9.]+)ns\s+\(logic ([0-9.]+)ns[^\n]*route ([0-9.]+)ns} $text unused total logic net]} {
        error "Cannot parse timing group $name"
    }
    set p [lindex $paths 0]
    puts $csv "$name,[llength $paths],$logic,$net,$total,[get_property SLACK $p],[get_property LOGIC_LEVELS $p],[get_property STARTPOINT_PIN $p],[get_property ENDPOINT_PIN $p]"
}
# Incoming maxima include reset, control, memory and feedback where relevant.
foreach stage {Q0 Q1 A0 A1 A2 A3 C} {characterize $stage [set $stage]}
# Separate nominal feed-forward arcs from all incoming stage maxima.
characterize INPUT_to_Q0 $Q0 $launch
foreach {name from to} {Q0_to_Q1 Q0 Q1 Q1_to_A0 Q1 A0 A0_to_A1 A0 A1 A1_to_A2 A1 A2 A2_to_A3 A2 A3 A3_to_C A3 C} {
    characterize $name [set $to] [set $from]
}
characterize A3_feedback_to_A0 $A0 $A3
characterize C_feedback_to_A0 $A0 $C
characterize ACC_read_to_A0 $A0 $memory
characterize ACC_incoming $memory
characterize A3_to_ACC_write $memory $A3
characterize CONTROL_incoming $spine
characterize CONTROL_to_A0 $A0 $spine
characterize OUTPUT_capture $capture
characterize RESET_to_core [concat $Q0 $Q1 $A0 $A1 $A2 $A3 $C $memory $spine] [primitives {^(reset_q|clear_q)_reg.*}]
# Break the heavy Q1 and dual-path cones into actual synthesized fields.
foreach {name pattern} {
    Q0_magnitude {^core/physical_regions.*quant/mag_q_reg.*}
    Q0_lead {^core/physical_regions.*quant/lead_q_reg.*}
    Q0_base {^core/physical_regions.*quant/base_q_reg.*}
    A1_FAR {^core/physical_regions.*add/arithmetic_q_reg\[far_raw\].*}
    A1_CLOSE_subtract {^core/physical_regions.*add/arithmetic_q_reg\[close_raw\].*}
    A1_CLOSE_LZA {^core/physical_regions.*add/arithmetic_q_reg\[close_shift\].*}
    A2_FAR {^core/physical_regions.*add/candidates_q_reg\[far_round\].*}
    A2_CLOSE {^core/physical_regions.*add/candidates_q_reg\[close_round\].*}
    A2_FAR_mant0 {^core/physical_regions.*add/candidates_q_reg\[far_round\]\[mant0\].*}
    A2_FAR_mant1 {^core/physical_regions.*add/candidates_q_reg\[far_round\]\[mant1\].*}
    A2_CLOSE_mant0 {^core/physical_regions.*add/candidates_q_reg\[close_round\]\[mant0\].*}
    A2_CLOSE_mant1 {^core/physical_regions.*add/candidates_q_reg\[close_round\]\[mant1\].*}
    A2_round_predicate {^core/physical_regions.*add/candidates_q_reg\[(far|close)_round\]\[round_up\].*}
    Q1_mantissa {^core/physical_regions.*quant/partial_value_reg\[([0-9]|1[0-9]|2[0-2])\].*}
    Q1_exponent {^core/physical_regions.*quant/partial_value_reg\[(2[3-9]|30)\].*}
    A0_order_data {^core/physical_regions.*add/order_q_reg\[pre\]\[(big_x|small_x|exponent|sign_result)\].*}
    A0_distance {^core/physical_regions.*add/order_q_reg\[distance.*}
    A1_SRL_sideband {^core/physical_regions.*add/arithmetic_q_reg.*_srl.*}
} {characterize $name [primitives $pattern]}
set result_registers [primitives {^core/physical_regions.*add/result_value_reg.*}]
characterize A3_data_pin [get_pins -of_objects $result_registers -filter {REF_PIN_NAME == D}]
characterize C_data_pin [get_pins -of_objects $C -filter {REF_PIN_NAME == D}]
# Per-lane incoming maxima let later pipeline tuning inspect spread rather
# than just the single slowest lane. These use the same unplaced netlist.
for {set g 0} {$g<4} {incr g} {
    for {set n 0} {$n<8} {incr n} {
        foreach {stage suffix} {
            Q0 {quant/(mag_q|lead_q|base_q|sign_q|zero_q|bad_q|valid_q)_reg.*}
            Q1 {quant/(partial_value|out_valid)_reg.*}
            A0 {add/order_q_reg.*} A1 {add/arithmetic_q_reg.*}
            A2 {add/candidates_q_reg.*} A3 {add/(result_value|out_valid)_reg.*}
            C {c_q_reg.*}
        } {
            set pattern [format {^core/physical_regions\[%d\]\.lanes\[%d\]\.%s} $g $n $suffix]
            characterize lane${g}_${n}_${stage} [primitives $pattern]
        }
    }
}
close $csv
# Regional endpoint inventories show whether all 32 lanes and control trees
# survive synthesis. Pblocks are recorded but do not yield placed timing.
source [file join $root deqacc_v2_locality.tcl]
proc deqacc_v2_locality::primitives {pattern} {return [::primitives $pattern]}
if {$routed_report} {
    set regions {}
    foreach p [get_pblocks -quiet] {lappend regions [get_property GRID_RANGES $p]}
} else {
    set regions [deqacc_v2_locality::apply core]
}
set f [open [file join $report pblocks.csv] w]
puts $f "pblock,hard,clock_region,selected_primitive_members,grid_ranges"
foreach p [get_pblocks -quiet] {
    puts $f "$p,[expr {![get_property IS_SOFT $p]}],[get_property GRID_RANGES $p],[llength [get_cells -of_objects $p]],[get_property GRID_RANGES $p]"
}
close $f
if {!$routed_report} {
    write_checkpoint -force [file join $report synthesized_with_locality.dcp]
    write_xdc -force [file join $report synthesized_constraints.xdc]
}
set f [open [file join $report run_info.txt] w]
if {$routed_report} {
    puts $f "Vivado: [version -short]\nPart: [get_property PART [current_design]]\nState: routed OOC checkpoint\nClock: 4.000 ns with actual BUFG\nCore: seven stages; launch/capture excluded from latency\nNet delays: routed device timing, NOT synthesis net estimates\nPblocks: $regions\nStatic timing, not silicon measurement."
} else {
    puts $f "Vivado: [version -short]\nPart: [get_property PART [current_design]]\nFlow: synth_design only, out_of_context\nClock: 4.000 ns\nCore: seven stages, II=1, dependent interval >=4\nExternal launch/capture: characterization only, not core latency\nNet delays: unplaced synthesis estimates, NOT post-route measurements\nLocality clock regions: $regions\nNo place/route/phys_opt run."
}
close $f
set f [open [file join $report report_script_sha256.txt] w]
puts $f [exec certutil -hashfile [file join $root synth_deqacc_v2.tcl] SHA256]
close $f
puts "V2_REPORT_COMPLETE routed=$routed_report $report"
