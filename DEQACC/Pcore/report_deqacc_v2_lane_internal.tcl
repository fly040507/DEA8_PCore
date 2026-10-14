# Compare lane-owned sequential source -> own stage endpoints separately from
# worst incoming paths, which may originate in central ACC/control.
set root [file normalize [lindex $argv 0]]
set target [lindex $argv 1]
set report [file join $root reports $target]
set f [open [file join $report lane_internal_timing.csv] w]
puts $f "variant,row,col,stage,logic_ns,route_ns,total_ns,slack_ns,logic_levels,startpoint,endpoint"
foreach tag [list v2_nopblock_20261014 $target] {
    open_checkpoint [file join $root reports $tag routed.dcp]
    set cells [get_cells -hier -filter {IS_PRIMITIVE == 1}]
    set names [get_property NAME $cells];set refs [get_property REF_NAME $cells]
    set lanes [dict create]
    foreach c $cells n $names ref $refs {
        if {![regexp {^(FD|SRL)} $ref]} {continue}
        if {[regexp {^core/physical_regions\[([0-3])\]\.lanes\[([0-7])\][./]} $n unused g lane]} {
            dict lappend lanes $g,$lane $c
        }
    }
    for {set g 0} {$g<4} {incr g} {for {set lane 0} {$lane<8} {incr lane} {
        set local [dict get $lanes $g,$lane]
        foreach {stage pattern} {
            Q1 {quant/(partial_value|out_valid)_reg}
            A0 {add/order_q_reg} A1 {add/arithmetic_q_reg} A2 {add/candidates_q_reg}
        } {
            set endpoints {}
            foreach c $local {if {[regexp $pattern [get_property NAME $c]]} {lappend endpoints $c}}
            set options [list -from $local -to $endpoints -max_paths 1 -delay_type max]
            set paths [get_timing_paths {*}$options]
            if {![llength $paths]} {error "Missing own-lane path: $g,$lane,$stage"}
            set text [report_timing {*}$options -return_string]
            if {![regexp {Data Path Delay:\s+([0-9.]+)ns\s+\(logic ([0-9.]+)ns[^\n]*route ([0-9.]+)ns} $text unused total logic route]} {error "Parse failed"}
            set p [lindex $paths 0]
            puts $f "$tag,[expr {$g/2}],[expr {($g%2)*8+$lane}],$stage,$logic,$route,$total,[get_property SLACK $p],[get_property LOGIC_LEVELS $p],[get_property STARTPOINT_PIN $p],[get_property ENDPOINT_PIN $p]"
        }
    }}
    close_design
}
close $f
puts "LANE_INTERNAL_TIMING_COMPLETE $report"
