# Small synthesis check for the actual RoPE ROM, including initialized storage.
set root [file normalize [file join [file dirname [info script]] ..]]
if {[llength $argv] != 1} {error "Expected: report_directory"}
set report [file normalize [lindex $argv 0]]
file mkdir $report
cd [file join $root Pcore]
create_project -in_memory -part xcu50-fsvh2104-2-e
set_param synth.maxThreads 1
foreach source {
    rtl/pcore_ip_config_pkg.sv rtl/pcore_pkg.sv rtl/dea8_tile_link_pkg.sv
    rtl/pcore_control_pkg.sv units/sfu/dea8_sfu_rope_rom.sv
} {read_verilog -sv $source}
read_xdc [file join $root tools dea8_4ns.xdc]
synth_design -top dea8_sfu_rope_rom -part xcu50-fsvh2104-2-e -mode out_of_context
report_utilization -file [file join $report utilization.rpt]
report_ram_utilization -file [file join $report ram.rpt]
write_verilog -force -mode funcsim [file join $report rope_post_synth.v]
set blocks [get_cells -hier -quiet -filter {REF_NAME == RAMB36E2 || REF_NAME == RAMB18E2}]
if {![llength $blocks]} {error "ROPE_ROM_SYNTH_FAIL: coefficient ROM was not retained as block RAM"}
puts "ROPE_ROM_SYNTH_PASS initialized_block_ram_primitives=[llength $blocks]"
