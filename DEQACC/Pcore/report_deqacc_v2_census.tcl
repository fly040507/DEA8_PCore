set root [file normalize [lindex $argv 0]]
set report [file join $root reports [lindex $argv 1]]
set routed [expr {[llength $argv]>2&&[lindex $argv 2] eq "routed"}]
open_checkpoint [file join $report [expr {$routed?"routed.dcp":"synthesized_with_locality.dcp"}]]
set cells [get_cells -hierarchical -filter {IS_PRIMITIVE == 1}]
set names [get_property NAME $cells];set refs [get_property REF_NAME $cells]
proc primitives {pattern} {
    global cells names
    set result {}
    foreach cell $cells name $names {if {[regexp $pattern $name]} {lappend result $cell}}
    return $result
}
source [file join $root deqacc_v2_locality.tcl]
proc deqacc_v2_locality::primitives {pattern} {return [::primitives $pattern]}
set f [open [file join $report pblocks.csv] w]
puts $f "pblock,hard,grid_ranges,selected_primitive_members"
for {set g 0} {$g<4} {incr g} {
    set p [get_pblocks deqacc_v2_core_region$g]
    set members [deqacc_v2_locality::regional_cells core $g]
    puts $f "$p,[expr {![get_property IS_SOFT $p]}],[get_property GRID_RANGES $p],[llength $members]"
}
close $f
set f [open [file join $report register_mapping.csv] w]
puts $f "stage,flip_flops,SRL_primitives,other_primitives"
foreach {stage pattern} {
    Q0 {^core/physical_regions.*quant/(mag_q|lead_q|base_q|sign_q|zero_q|bad_q|valid_q)_reg}
    Q1 {^core/physical_regions.*quant/(partial_value|out_valid)_reg}
    A0 {^core/physical_regions.*add/order_q_reg}
    A1 {^core/physical_regions.*add/arithmetic_q_reg}
    A2 {^core/physical_regions.*add/candidates_q_reg}
    A3 {^core/physical_regions.*add/(result_value|out_valid)_reg}
    C {^core/physical_regions\[[0-3]\]\.lanes\[[0-7]\]\.c_q_reg}
} {
    set ff 0;set srl 0;set other 0
    foreach name $names ref $refs {
        if {![regexp $pattern $name]} {continue}
        if {[string match FD* $ref]} {incr ff} elseif {[string match SRL* $ref]} {incr srl} else {incr other}
    }
    puts $f "$stage,$ff,$srl,$other"
}
close $f
set f [open [file join $report buffer_tree_counts.csv] w]
puts $f "network,protected_LUT1"
foreach {group pattern} {
    scale {^core/scale_ingress/.*(branch_buffer|bad_buffer)$}
    forward {^core/row_forward.*(branch_buffer|leaf_buffer)$}
    common {^core/control_fanout/.*(branch_buffer|leaf_buffer)$}
    ACC_masks {^core/memory/output_rows.*(branch_buffer|leaf_buffer)$}
} {
    set count 0
    foreach name $names ref $refs {if {$ref eq "LUT1"&&[regexp $pattern $name]} {incr count}}
    puts $f "$group,$count"
}
close $f
foreach p [get_pblocks] {
    report_utilization -pblocks $p -file [file join $report ${p}_utilization.rpt]
}
set f [open [file join $report report_script_sha256.txt] w]
foreach file {synth_deqacc_v2.tcl report_deqacc_v2_census.tcl} {
    puts $f "$file\n[exec certutil -hashfile [file join $root $file] SHA256]"
}
close $f
puts "V2_CENSUS_PASS $report"
