# Experimental eight same-row 4-lane groups; no RTL/clock/algorithm changes.
namespace eval deqacc_v2_locality4lane {
    proc regions {} {
        foreach slr [get_slrs] {
            set points [dict create];set xs {};set ys {}
            foreach cr [get_clock_regions -of_objects $slr] {
                if {[regexp {^X([0-9]+)Y([0-9]+)$} $cr unused x y]} {
                    dict set points $x,$y $cr;lappend xs $x;lappend ys $y
                }
            }
            set xs [lsort -integer -unique $xs];set ys [lsort -integer -unique $ys]
            if {![llength $xs]} {continue}
            set cx [expr {([lindex $xs 0]+[lindex $xs end])/2.0}]
            set cy [expr {([lindex $ys 0]+[lindex $ys end])/2.0}]
            set best {};set score 1e30
            foreach x $xs {foreach y $ys {
                set candidate {};set complete 1
                for {set row 0} {$row<2} {incr row} {
                    for {set col 0} {$col<4} {incr col} {
                        set key [expr {$x+$col}],[expr {$y+$row}]
                        if {![dict exists $points $key]} {set complete 0;break}
                        lappend candidate [dict get $points $key]
                    }
                }
                if {!$complete} {continue}
                set distance [expr {abs($x+1.5-$cx)+abs($y+0.5-$cy)}]
                if {$distance<$score} {set best $candidate;set score $distance}
            }}
            if {[llength $best]==8} {return $best}
        }
        error "No contiguous 4x2 region rectangle within a single SLR"
    }
    proc select {pattern} {
        global cells names
        set result {}
        foreach cell $cells name $names {if {[regexp $pattern $name]} {lappend result $cell}}
        return $result
    }
    proc apply {report} {
        set regions [regions]
        set assigned [dict create]
        set manifest [open [file join $report locality_members.csv] w]
        puts $manifest "pblock,row,column_first,column_last,clock_region,primitive_count"
        for {set g 0} {$g<8} {incr g} {
            set row [expr {$g/4}];set chunk [expr {$g%4}]
            set oldgroup [expr {$row*2+$chunk/2}]
            set first [expr {($chunk%2)*4}]
            set members {}
            for {set n $first} {$n<$first+4} {incr n} {
                set lane [select [format {^core/physical_regions\[%d\]\.lanes\[%d\][./].*} $oldgroup $n]]
                if {![llength $lane]} {error "Missing lane group=$g n=$n"}
                set members [concat $members $lane]
            }
            # Common root branches are shared by eight lanes. Keep these 16
            # LUT1s free; only the four-lane leaf endpoints enter each Pblock.
            for {set n $first} {$n<$first+4} {incr n} {
                set leaf [select [format {^core/control_fanout/branches\[%d\]\.leaves\[%d\][./].*} $oldgroup $n]]
                if {![llength $leaf]} {error "Missing common control leaf group=$g n=$n"}
                set members [concat $members $leaf]
            }
            foreach pattern [list \
                [format {^core/scale_ingress/rows\[%d\]\.branches\[%d\][./].*} $row $chunk] \
                [format {^core/row_forward\[%d\]\.fanout/branches\[%d\][./].*} $row $chunk] \
                [format {^core/memory/output_rows\[%d\]\.old_controls/branches\[%d\][./].*} $row $chunk] \
                [format {^core/memory/output_rows\[%d\]\.external_controls/branches\[%d\][./].*} $row $chunk]] {
                set local [select $pattern]
                if {![llength $local]} {error "Missing locality endpoint $pattern"}
                set members [concat $members $local]
            }
            set members [lsort -unique $members]
            foreach cell $members {
                if {[dict exists $assigned $cell]} {error "Overlapping four-lane membership $cell"}
                if {[string match *memory/banks* $cell]} {error "ACC RAM must stay outside lane regions"}
                dict set assigned $cell $g
            }
            set name deqacc_v2_fourlane_region$g
            create_pblock $name
            add_cells_to_pblock [get_pblocks $name] $members
            set cr [lindex $regions $g]
            resize_pblock [get_pblocks $name] -add CLOCKREGION_${cr}:CLOCKREGION_${cr}
            set_property EXCLUDE_PLACEMENT false [get_pblocks $name]
            set_property CONTAIN_ROUTING false [get_pblocks $name]
            set_property IS_SOFT false [get_pblocks $name]
            if {[get_property IS_SOFT [get_pblocks $name]]} {error "Soft region $g"}
            puts $manifest "$name,$row,[expr {$chunk*4}],[expr {$chunk*4+3}],$cr,[llength $members]"
            puts "V2_FOURLANE region=$g row=$row columns=[expr {$chunk*4}]:[expr {$chunk*4+3}] clock_region=$cr cells=[llength $members] hard=1"
        }
        close $manifest
        return $regions
    }
}
