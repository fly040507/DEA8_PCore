# Source after synth_design, before opt_design/place_design. This file does
# not launch synthesis or implementation. Four hard Pblocks contain the
# same-row lanes and their local scale/control endpoints, never ACC RAM.
namespace eval deqacc_v2_locality {
    proc quote {text} {
        return [regsub -all {[][\\.^$*+?()|]} $text {\\&}]
    }

    proc choose_clock_regions {{requested {}}} {
        if {[llength $requested]} {
            if {[llength $requested] != 4 || [llength [lsort -unique $requested]] != 4} {
                error "Specify four distinct clock regions in row0-left/right, row1-left/right order"
            }
            set owners {}
            foreach name $requested {
                set cr [get_clock_regions -quiet $name]
                if {[llength $cr] != 1} {error "Unknown clock region: $name"}
                lappend owners [get_property NAME [get_slrs -of_objects $cr]]
            }
            if {[llength [lsort -unique $owners]] != 1} {error "V2 locality regions must share one SLR"}
            return $requested
        }

        # Choose an adjacent 2x2 square near the middle of one actual SLR.
        # No U50 SLICE coordinate or clock-region count is hard-coded.
        foreach slr [get_slrs] {
            set regions [get_clock_regions -of_objects $slr]
            set points [dict create]
            set xs {}; set ys {}
            foreach cr $regions {
                set name [get_property NAME $cr]
                if {![regexp {^X([0-9]+)Y([0-9]+)$} $name unused x y]} {continue}
                dict set points $x,$y $name
                lappend xs $x; lappend ys $y
            }
            if {![llength $xs]} {continue}
            set xs [lsort -integer -unique $xs]; set ys [lsort -integer -unique $ys]
            set cx [expr {([lindex $xs 0]+[lindex $xs end])/2.0}]
            set cy [expr {([lindex $ys 0]+[lindex $ys end])/2.0}]
            set best {}; set score 1e30
            foreach x $xs {
                foreach y $ys {
                    set x1 [expr {$x+1}]; set y1 [expr {$y+1}]
                    if {![dict exists $points $x,$y] || ![dict exists $points $x1,$y] || ![dict exists $points $x,$y1] ||
                        ![dict exists $points $x1,$y1]} {continue}
                    set candidate [list [dict get $points $x,$y] [dict get $points $x1,$y] \
                        [dict get $points $x,$y1] [dict get $points $x1,$y1]]
                    set distance [expr {abs($x+0.5-$cx)+abs($y+0.5-$cy)}]
                    if {$distance < $score} {set score $distance; set best $candidate}
                }
            }
            if {[llength $best]} {return $best}
        }
        error "No adjacent 2x2 clock-region square in one SLR; provide four explicit regions"
    }

    proc primitives {pattern} {
        return [get_cells -quiet -hierarchical -regexp -filter {IS_PRIMITIVE} $pattern]
    }

    proc regional_cells {core region} {
        set scope [expr {$core eq "" ? "" : "[quote $core]/"}]
        set row [expr {$region/2}]
        set first_branch [expr {($region%2)*2}]
        set cells {}
        for {set n 0} {$n < 8} {incr n} {
            set pattern [format {^%sphysical_regions\[%d\]\.lanes\[%d\][./].*} $scope $region $n]
            set lane [primitives $pattern]
            if {![llength $lane]} {error "V2 locality missing row=$row region=$region lane=$n under '$core'"}
            set cells [concat $cells $lane]
        }
        set controls [primitives [format {^%scontrol_fanout/branches\[%d\][./].*} $scope $region]]
        if {![llength $controls]} {error "V2 locality missing region=$region common control buffers"}
        set cells [concat $cells $controls]
        for {set g $first_branch} {$g < $first_branch+2} {incr g} {
            foreach pattern [list \
                [format {^%sscale_ingress/rows\[%d\]\.branches\[%d\][./].*} $scope $row $g] \
                [format {^%srow_forward\[%d\]\.fanout/branches\[%d\][./].*} $scope $row $g] \
                [format {^%smemory/output_rows\[%d\]\.old_controls/branches\[%d\][./].*} $scope $row $g] \
                [format {^%smemory/output_rows\[%d\]\.external_controls/branches\[%d\][./].*} $scope $row $g]] {
                set local [primitives $pattern]
                if {![llength $local]} {error "V2 locality missing local endpoints: $pattern"}
                set cells [concat $cells $local]
            }
        }
        return [lsort -unique $cells]
    }

    proc apply {{core ""} {clock_regions {}}} {
        set regions [choose_clock_regions $clock_regions]
        set grouped {}; set assigned [dict create]
        # Validate every selector before creating any Pblock. Wrong/old
        # netlists fail instead of silently constraining an empty collection.
        for {set g 0} {$g < 4} {incr g} {
            set cells [regional_cells $core $g]
            foreach cell $cells {
                if {[dict exists $assigned $cell]} {error "V2 locality overlapping region membership: $cell"}
                if {[string match *memory/banks* $cell]} {error "ACC RAM must not enter lane Pblocks"}
                dict set assigned $cell $g
            }
            lappend grouped $cells
        }
        set tag [regsub -all {[^A-Za-z0-9_]} $core _]
        if {$tag ne ""} {append tag _}
        for {set g 0} {$g < 4} {incr g} {
            set name deqacc_v2_${tag}region${g}
            if {[llength [get_pblocks -quiet $name]]} {error "Pblock already exists: $name"}
        }
        for {set g 0} {$g < 4} {incr g} {
            set name deqacc_v2_${tag}region${g}
            set cr [lindex $regions $g]
            create_pblock $name
            add_cells_to_pblock [get_pblocks $name] [lindex $grouped $g]
            resize_pblock [get_pblocks $name] -add CLOCKREGION_${cr}:CLOCKREGION_${cr}
            set_property EXCLUDE_PLACEMENT FALSE [get_pblocks $name]
            set_property CONTAIN_ROUTING FALSE [get_pblocks $name]
            # Set hardness last: containment setters can restore softness.
            set_property IS_SOFT FALSE [get_pblocks $name]
            if {[get_property IS_SOFT [get_pblocks $name]]} {error "Pblock is unexpectedly soft: $name"}
            puts "V2_LOCALITY region=$g clock_region=$cr lanes=8 cells=[llength [lindex $grouped $g]] hard=1 ACC_RAM=excluded"
        }
        return $regions
    }
}
