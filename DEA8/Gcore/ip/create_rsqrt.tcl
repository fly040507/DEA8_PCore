set here [file dirname [file normalize [info script]]]
create_project -in_memory -part xcu50-fsvh2104-2-e
file mkdir [file join $here generated]
if {[file exists [file join $here generated gcore_rsqrt_ip gcore_rsqrt_ip.xci]]} {
    read_ip [file join $here generated gcore_rsqrt_ip gcore_rsqrt_ip.xci]
} else {
    create_ip -name floating_point -vendor xilinx.com -library ip -version 7.1 \
        -module_name gcore_rsqrt_ip -dir [file join $here generated]
}
set_property -dict [list CONFIG.Operation_Type {Rec_Square_Root} \
    CONFIG.A_Precision_Type {Single} CONFIG.Result_Precision_Type {Single} \
    CONFIG.C_Mult_Usage {Full_Usage} CONFIG.Flow_Control {NonBlocking} \
    CONFIG.Has_ACLKEN {true} CONFIG.Has_ARESETn {true} \
    CONFIG.Maximum_Latency {true} CONFIG.C_Rate {1}] [get_ips gcore_rsqrt_ip]
generate_target all [get_ips gcore_rsqrt_ip]
if {[get_property CONFIG.C_Latency [get_ips gcore_rsqrt_ip]] != 32} {
    error "rsqrt wrapper expects the frozen 32-cycle IP configuration"
}
set f [open [file join $here rsqrt_config.txt] w]
foreach p {CONFIG.Operation_Type CONFIG.C_Latency CONFIG.C_Rate CONFIG.C_Mult_Usage CONFIG.Has_ACLKEN CONFIG.Has_ARESETn} {
    puts $f "$p=[get_property $p [get_ips gcore_rsqrt_ip]]"
}
close $f
puts "GCORE_RSQRT_IP_READY [get_property CONFIG.C_Latency [get_ips gcore_rsqrt_ip]]"
