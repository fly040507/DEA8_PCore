# Complete GCore OOC resource check; no placement/routing or timing signoff.
set here [file dirname [file normalize [info script]]]
cd $here
file mkdir .sim
create_project -in_memory -part xcu50-fsvh2104-2-e
set_property XPM_LIBRARIES {XPM_MEMORY} [current_project]
read_ip ip/generated/gcore_rsqrt_ip/gcore_rsqrt_ip.xci
set f [open gcore_rtl.f r]
set files [split [read $f] "\n"]
close $f
foreach line $files {
    set line [string trim $line]
    if {$line eq "" || [string match "tb/*" $line] || [string match "ip/*" $line]} {continue}
    read_verilog -sv $line
}
synth_design -top dea8_gcore -mode out_of_context -part xcu50-fsvh2104-2-e
set blocks [get_cells -hier -filter {REF_NAME == gcore_rsqrt_ip && IS_BLACKBOX == 1}]
foreach block $blocks {
    read_checkpoint -cell $block ip/generated/gcore_rsqrt_ip/gcore_rsqrt_ip.dcp
}
set unresolved [get_cells -hier -filter {IS_BLACKBOX == 1}]
if {[llength $unresolved] != 0} {error "Unresolved GCore blackboxes: $unresolved"}
report_utilization -hierarchical -file reports/gcore_utilization.rpt
report_utilization -file reports/gcore_utilization_summary.rpt
set dsps [llength [get_cells -hier -filter {REF_NAME == DSP48E2}]]
set f [open reports/gcore_synth_summary.txt w]
puts $f "Complete GCore OOC synthesis, INTERNAL_RSQRT=1, no blackboxes."
puts $f "DSP48E2=$dsps BUDGET=109, internal four-lane reduce and single rsqrt."
puts $f "No placement/routing; no 250MHz signoff. X/prefix are preloaded by contract."
close $f
if {$dsps>109} {error "GCore exceeds DSP budget: $dsps"}
write_checkpoint -force .sim/gcore_synth.dcp
puts "GCORE_SYNTH_PASS DSP48E2=$dsps"
