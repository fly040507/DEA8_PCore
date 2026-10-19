# Deferred until the user reviews single-GCore/single-PCore resource results.
error "Eight-core synthesis is deferred; use run_dea8.py synth --target gcore|pcore --server-heavy"
# Historical whole-layer recipe below is not executed in this phase.
set root [file normalize [file join [file dirname [info script]] ..]]
cd $root
create_project -in_memory -part xcu50-fsvh2104-2-e
set_property XPM_LIBRARIES XPM_MEMORY [current_project]
set ip_files {}
foreach name {pcore_fpadd_ip dea8_fpadd_ip dea8_fpmul_ip dea8_fpexp_ip dea8_fprecip_ip} {
    lappend ip_files [file join $root Pcore ip generated $name $name.xci]
}
lappend ip_files [file join $root Gcore ip generated gcore_rsqrt_ip gcore_rsqrt_ip.xci]
foreach file $ip_files {
    read_ip $file
    # Global synthesis includes the generated IP RTL, rather than depending on
    # an absent OOC checkpoint or counting its black box as zero resources.
    set_property GENERATE_SYNTH_CHECKPOINT false [get_files $file]
    generate_target synthesis [get_files $file]
}
set f [open output/dea8_synth_sources.f r]
while {[gets $f line]>=0} {if {$line ne ""} {read_verilog -sv $line}}
close $f
read_xdc tools/dea8_4ns.xdc
synth_design -top dea8_layer_top -part xcu50-fsvh2104-2-e -mode out_of_context
file mkdir reports/layer_native/synth
report_utilization -hierarchical -file reports/layer_native/synth/utilization_hier.rpt
report_timing_summary -max_paths 50 -file reports/layer_native/synth/timing_4ns.rpt
report_drc -file reports/layer_native/synth/drc.rpt
set unresolved [get_cells -hier -quiet -filter {IS_BLACKBOX == 1}]
if {[llength $unresolved]!=0} {error "Unresolved black boxes: $unresolved"}
write_checkpoint -force reports/layer_native/synth/dea8_layer_synth.dcp
puts "DEA8_LAYER_SYNTH_DONE NOT_ROUTED=1"
