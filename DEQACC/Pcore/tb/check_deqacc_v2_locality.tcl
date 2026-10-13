# Read-only device/Tcl check using an OLD checkpoint, not current RTL proof.
# No synth/opt/place/route/write_checkpoint command is allowed here.
set root [file normalize [file join [file dirname [info script]] ..]]
source [file join $root deqacc_v2_locality.tcl]
if {[llength $argv] != 1} {error "Pass an existing U50 checkpoint for device geometry only"}
open_checkpoint [file normalize [lindex $argv 0]]
set part [get_property PART [current_design]]
if {$part ne "xcu50-fsvh2104-2-e"} {error "Unexpected device: $part"}
set regions [deqacc_v2_locality::choose_clock_regions]
if {[deqacc_v2_locality::choose_clock_regions $regions] ne $regions} {error "Explicit region selection mismatch"}
foreach sample {{core[3].foo/bar} {a+b(c)/d} {DEQACC_V1}} {
    set pattern ^[deqacc_v2_locality::quote $sample]$
    if {![regexp $pattern $sample]} {error "Hierarchy regexp quoting failed: $sample"}
}
if {![catch {deqacc_v2_locality::choose_clock_regions {X999Y999 X998Y999 X999Y998 X998Y998}}]} {
    error "Missing clock regions were not rejected"
}
if {![catch {deqacc_v2_locality::apply absent_v2_instance $regions} failure] ||
    ![string match {*V2 locality missing*} $failure]} {
    error "Missing current V2 lane hierarchy was not rejected: $failure"
}
# Exercise the real Pblock API on 32 OLD arbitrary registers. They are
# proxies only; this does not validate current V2 hierarchy or capacity.
set proxies [get_cells -hierarchical -filter {IS_PRIMITIVE && REF_NAME == FDRE}]
if {[llength $proxies] < 32} {error "Old checkpoint lacks enough register proxies"}
for {set g 0} {$g < 4} {incr g} {
    set name v2_api_probe_${g}
    set cr [lindex $regions $g]
    create_pblock $name
    add_cells_to_pblock [get_pblocks $name] [lrange $proxies [expr {$g*8}] [expr {$g*8+7}]]
    resize_pblock [get_pblocks $name] -add CLOCKREGION_${cr}:CLOCKREGION_${cr}
    set_property EXCLUDE_PLACEMENT FALSE [get_pblocks $name]
    set_property CONTAIN_ROUTING FALSE [get_pblocks $name]
    set_property IS_SOFT FALSE [get_pblocks $name]
    set soft [get_property IS_SOFT [get_pblocks $name]]
    set members [get_cells -of_objects [get_pblocks $name]]
    if {$soft || [llength $members] != 8} {
        error "Hard Pblock API/membership verification failed: $name soft=$soft members=[llength $members] names=[lrange $members 0 8]"
    }
    delete_pblocks [get_pblocks $name]
}
puts "deqacc_v2_locality Tcl/device PASS part=$part regions=$regions pblock_API=1 old_proxy_registers=32 missing_hierarchy=rejected current_netlist=NOT_CHECKED placement=NOT_RUN"
close_design
