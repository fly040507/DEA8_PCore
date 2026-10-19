# Legacy entry would overwrite the only historical GCore reports/checkpoint.
error "Use DEA8/run_dea8.py synth --target gcore --server-heavy after simulations; legacy output is protected"
# Retained historical implementation below is not executed.
set here [file dirname [file normalize [info script]]]
cd $here
file mkdir .sim
create_project -in_memory -part xcu50-fsvh2104-2-e
set_property XPM_LIBRARIES {XPM_MEMORY} [current_project]
foreach file {ip/generated/gcore_rsqrt_ip/gcore_rsqrt_ip.xci ../Pcore/ip/generated/dea8_fpadd_ip/dea8_fpadd_ip.xci ../Pcore/ip/generated/dea8_fpmul_ip/dea8_fpmul_ip.xci} {
    read_ip $file
    set_property GENERATE_SYNTH_CHECKPOINT false [get_files $file]
    generate_target synthesis [get_files $file]
}
set f [open gcore_rtl.f r]
set files [split [read $f] "\n"]
close $f
foreach line $files {
    set line [string trim $line]
    if {$line eq "" || [string match "tb/*" $line] || [string match "ip/*" $line] || [string match "*/ip/generated/*" $line]} {continue}
    read_verilog -sv $line
}
synth_design -top dea8_gcore -mode out_of_context -part xcu50-fsvh2104-2-e
create_clock -name core_clk -period 4.000 [get_ports clk]
set unresolved [get_cells -hier -filter {IS_BLACKBOX == 1}]
if {[llength $unresolved] != 0} {error "Unresolved GCore blackboxes: $unresolved"}
report_utilization -hierarchical -file reports/gcore_utilization.rpt
report_utilization -file reports/gcore_utilization_summary.rpt
report_timing_summary -max_paths 50 -file reports/gcore_timing_4ns.rpt
report_drc -file reports/gcore_drc.rpt
set dsps [llength [get_cells -hier -filter {REF_NAME == DSP48E2}]]
set f [open reports/gcore_synth_summary.txt w]
puts $f "Complete GCore OOC synthesis, INTERNAL_RSQRT=1, no blackboxes."
puts $f "DSP48E2=$dsps BUDGET=109, internal four-lane reduce and single rsqrt."
puts $f "No placement/routing; no 250MHz signoff. X/prefix are preloaded by contract."
close $f
if {$dsps>109} {error "GCore exceeds DSP budget: $dsps"}
write_checkpoint -force .sim/gcore_synth.dcp
puts "GCORE_SYNTH_PASS DSP48E2=$dsps"
