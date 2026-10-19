# Place/route is outside the current simulation/resource-measurement phase.
error "Place/route is deferred; this phase measures single-module synthesis resources only"
# Historical implementation recipe below is not executed in this phase.
set root [file normalize [file join [file dirname [info script]] ..]]
cd $root
open_checkpoint reports/layer_native/synth/dea8_layer_synth.dcp
opt_design
place_design
phys_opt_design
route_design
file mkdir reports/layer_native/implementation
report_utilization -hierarchical -file reports/layer_native/implementation/utilization.rpt
report_timing_summary -max_paths 50 -file reports/layer_native/implementation/timing_4ns.rpt
report_drc -file reports/layer_native/implementation/drc.rpt
write_checkpoint -force reports/layer_native/implementation/dea8_layer_routed.dcp
puts "DEA8_LAYER_IMPLEMENTATION_DONE SHELL_INTEGRATION=0"
