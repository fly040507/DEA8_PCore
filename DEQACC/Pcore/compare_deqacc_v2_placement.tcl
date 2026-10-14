set root [file normalize [lindex $argv 0]]
set baseline [lindex $argv 1]
set candidate [lindex $argv 2]
set report [file join $root reports $candidate]
set f [open [file join $root reports $baseline path_delays.csv] r]
set records [split [string trim [read $f]] "\n"];close $f
set selected {}
foreach row [lrange $records 1 end] {
    set fields [split $row ,]
    if {[string match lane* [lindex $fields 0]]} {continue}
    lappend selected $fields
}
proc resolve_pin {name} {
    global cell_by_name
    set cut [string last / $name]
    set cell_name [string range $name 0 [expr {$cut-1}]]
    if {![dict exists $cell_by_name $cell_name]} {return {}}
    set cell [dict get $cell_by_name $cell_name]
    set leaf [string range $name [expr {$cut+1}] end]
    foreach p [get_pins -of_objects $cell] {
        if {[get_property REF_PIN_NAME $p] eq $leaf} {return $p}
    }
    return {}
}
set csv [open [file join $report matched_paths.csv] w]
puts $csv "variant,group,mode,status,logic_ns,route_ns,total_ns,slack_ns,logic_levels,clock_skew_ns,startpoint,endpoint"
foreach tag [list $baseline $candidate] {
    open_checkpoint [file join $root reports $tag routed.dcp]
    set cells [get_cells -hier -filter {IS_PRIMITIVE == 1}]
    set names [get_property NAME $cells]
    set cell_by_name [dict create]
    foreach c $cells name $names {dict set cell_by_name $name $c}
    foreach fields $selected {
        set group [lindex $fields 0]
        set original_start [lindex $fields 7];set original_end [lindex $fields 8]
        set to [resolve_pin $original_end];set from [resolve_pin $original_start]
        foreach mode {endpoint exact_pair} {
            if {![llength $to] || ($mode eq "exact_pair" && ![llength $from])} {
                puts $csv "$tag,$group,$mode,MISSING_PIN,NA,NA,NA,NA,NA,NA,$original_start,$original_end"
                continue
            }
            set options [list -to $to -max_paths 1 -delay_type max]
            if {$mode eq "exact_pair"} {lappend options -from $from}
            set paths [get_timing_paths {*}$options]
            if {![llength $paths]} {
                puts $csv "$tag,$group,$mode,NO_PATH,NA,NA,NA,NA,NA,NA,$original_start,$original_end"
                continue
            }
            set text [report_timing {*}$options -path_type full -input_pins -return_string]
            regexp {Data Path Delay:\s+([0-9.]+)ns\s+\(logic ([0-9.]+)ns[^\n]*route ([0-9.]+)ns} $text unused total logic route
            regexp {Clock Path Skew:\s+([-0-9.]+)ns} $text unused skew
            set path [lindex $paths 0]
            puts $csv "$tag,$group,$mode,OK,$logic,$route,$total,[get_property SLACK $path],[get_property LOGIC_LEVELS $path],$skew,[get_property STARTPOINT_PIN $path],[get_property ENDPOINT_PIN $path]"
            set out [open [file join $report matched_${tag}_${group}_${mode}.rpt] w]
            puts $out $text;close $out
        }
    }
    # Unique occupied SLICE sites are CLB usage; LUT and primitive counts are
    # intentionally separate because multiple cells share each CLB.
    set locs [lsort -unique [get_property LOC $cells]]
    set site_region [dict create];set region_sites [dict create]
    set sites [get_sites -quiet $locs]
    foreach site $sites region [get_property CLOCK_REGION $sites] type [get_property SITE_TYPE $sites] {
        dict set site_region [get_property NAME $site] $region
        if {[string match SLICE* $type]} {dict lappend region_sites $region $site}
    }
    set density [open [file join $report ${tag}_clock_region_density.csv] w]
    puts $density "region,occupied_CLB,total_CLB,CLB_percent"
    foreach region [lsort [dict keys $region_sites]] {
        set used [llength [lsort -unique [dict get $region_sites $region]]]
        set available [llength [get_sites -of_objects [get_clock_regions $region] -filter {SITE_TYPE =~ SLICE*}]]
        puts $density "$region,$used,$available,[format %.2f [expr {100.0*$used/$available}]]"
    }
    close $density
    set distribution [open [file join $report ${tag}_lane_regions.csv] w]
    puts $distribution "logical_group,lane,region,primitive_count"
    for {set g 0} {$g<4} {incr g} {
        for {set n 0} {$n<8} {incr n} {
            set counts [dict create]
            set pattern [format {^core/physical_regions\[%d\]\.lanes\[%d\][./]} $g $n]
            foreach c $cells name $names {
                if {![regexp $pattern $name]} {continue}
                set loc [get_property LOC $c]
                if {[dict exists $site_region $loc]} {dict incr counts [dict get $site_region $loc]}
            }
            dict for {region count} $counts {puts $distribution "$g,$n,$region,$count"}
        }
    }
    close $distribution
    # Categorize every violating endpoint, one worst path per endpoint.
    set counts [dict create];set slacks [dict create]
    set failed [get_timing_paths -max_paths 10000 -nworst 1 -slack_lesser_than 0 -delay_type max]
    foreach path $failed {
        set endpoint [get_property ENDPOINT_PIN $path]
        set category OTHER
        foreach {name pattern} {
            Q0 {quant/(mag_q|lead_q|base_q|sign_q|zero_q|bad_q|valid_q)_reg}
            Q1 {quant/(partial_value|out_valid)_reg}
            A0 {add/order_q_reg} A1 {add/arithmetic_q_reg}
            A2 {add/candidates_q_reg} A3 {add/(result_value|out_valid)_reg}
            C {\.c_q_reg} ACC {^core/memory/}
            CONTROL {^core/control/} OUTPUT {^(result_|commit_|done|vpu_wr_ready)}
        } {if {[regexp $pattern $endpoint]} {set category $name;break}}
        dict incr counts $category
        if {![dict exists $slacks $category] || [get_property SLACK $path]<[dict get $slacks $category]} {
            dict set slacks $category [get_property SLACK $path]
        }
    }
    set out [open [file join $report ${tag}_violating_endpoints.csv] w]
    puts $out "category,violating_endpoints,worst_slack_ns"
    dict for {name count} $counts {puts $out "$name,$count,[dict get $slacks $name]"}
    close $out
    close_design
}
close $csv
puts "V2_PLACEMENT_COMPARISON_COMPLETE $report"
