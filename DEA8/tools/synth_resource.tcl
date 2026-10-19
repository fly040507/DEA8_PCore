# Resource measurement of one complete, official-IP module.
set root [file normalize [file join [file dirname [info script]] ..]]
if {[llength $argv] != 3} {error "Expected: gcore|pcore source_list report_directory; use run_dea8.py"}
lassign $argv component listing report
set listing [file normalize $listing]
set report [file normalize $report]
switch -- $component {
    gcore {
        set top dea8_gcore
        set base [file join $root Gcore]
        set names {dea8_fpadd_ip dea8_fpmul_ip gcore_rsqrt_ip}
    }
    pcore {
        set top dea8_pcore_top
        set base [file join $root Pcore]
        set names {pcore_fpadd_ip dea8_fpadd_ip dea8_fpmul_ip dea8_fpexp_ip dea8_fprecip_ip}
    }
    default {error "Only GCore or a single PCore is allowed in this resource phase"}
}
# PCore default Mask/RoPE image paths are relative to Pcore, not to DEA8.
cd $base
file mkdir $report
create_project -in_memory -part xcu50-fsvh2104-2-e
set_property target_language Verilog [current_project]
set_property XPM_LIBRARIES XPM_MEMORY [current_project]
foreach name $names {
    set owner [expr {$name eq "gcore_rsqrt_ip" ? "Gcore" : "Pcore"}]
    set original [file join $root $owner ip generated $name ${name}.xci]
    if {![file exists $original]} {error "Missing official IP: $original; run the ip stage first"}
    # Keep validated simulation products and the historical GCore DCP untouched.
    set work [file join $report ip_work $name]
    file mkdir $work
    set xci [file join $work ${name}.xci]
    file copy -force $original $xci
    read_ip $xci
    set_property GENERATE_SYNTH_CHECKPOINT false [get_files $xci]
    generate_target synthesis [get_files $xci]
}
set f [open $listing r]
while {[gets $f line] >= 0} {
    set line [string trim $line]
    if {$line ne ""} {read_verilog -sv $line}
}
close $f
read_xdc [file join $root tools dea8_4ns.xdc]
synth_design -top $top -part xcu50-fsvh2104-2-e -mode out_of_context
set unresolved [get_cells -hier -quiet -filter {IS_BLACKBOX == 1}]
if {[llength $unresolved]} {error "Unresolved official IP/modules: $unresolved"}
report_utilization -file [file join $report utilization.rpt]
report_utilization -hierarchical -file [file join $report utilization_hier.rpt]
report_ram_utilization -file [file join $report ram.rpt]
set f [open [file join $report primitives.tsv] w]
puts $f "primitive\tcount"
foreach primitive {DSP48E2 RAMB36E2 RAMB18E2 URAM288 URAM288_BASE} {
    puts $f "$primitive\t[llength [get_cells -hier -quiet -filter "REF_NAME == $primitive"]]"
}
close $f
write_checkpoint -force [file join $report ${top}_synth.dcp]
set f [open [file join $report scope.txt] w]
puts $f "target=$component top=$top part=xcu50-fsvh2104-2-e"
puts $f "official_fp_ip=1 blackboxes=0 synthesis_only=1 placement_routing=0 eight_core_synthesis=0"
puts $f "Constraint=4.000ns; resource measurement only, no frequency/board signoff."
puts $f "No U50 platform shell, physical HBM/PCIe controller, or DEA8 global policy included."
close $f
puts "DEA8_RESOURCE_SYNTH_DONE target=$component top=$top synthesis_only=1 routed=0 blackboxes=0"
