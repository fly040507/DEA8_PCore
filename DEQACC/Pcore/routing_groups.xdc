# Coarse locality only: no cell LOC, no routing containment, no new cycles.
create_pblock deqacc_slr0
resize_pblock [get_pblocks deqacc_slr0] -add {CLOCKREGION_X0Y0:CLOCKREGION_X7Y3}
add_cells_to_pblock [get_pblocks deqacc_slr0] [get_cells core]
for {set g 0} {$g < 8} {incr g} {
    set x [expr {1+($g%4)}]
    set y [expr {1+($g/4)}]
    set name deqacc_group_$g
    create_pblock $name
    resize_pblock [get_pblocks $name] -add "CLOCKREGION_X${x}Y${y}:CLOCKREGION_X${x}Y${y}"
    set arithmetic [get_cells -hier -filter [format {NAME == core/groups[%d].arithmetic} $g]]
    set memory [get_cells -hier -regexp [format {core/acc_store/banks\[[0-2]\]\.parity\[[0-1]\]\.groups\[%d\]\.ram} $g]]
    set control [get_cells -hier -filter [format {NAME =~ core/local_control[%d].* || NAME =~ core/acc_store/group_read_select[%d].*} $g $g]]
    if {[llength $arithmetic]!=1 || [llength $memory]!=6} {error "Incomplete physical group $g"}
    add_cells_to_pblock [get_pblocks $name] [concat $arithmetic $memory $control]
    set_property IS_SOFT false [get_pblocks $name]
    set_property CONTAIN_ROUTING false [get_pblocks $name]
}
