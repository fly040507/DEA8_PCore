run 728ns
foreach p {rows cycle works dut/matrix_error dut/memory_error dut/attn_error dut/attention/scheduler_error dut/attention/memory_error dut/attention/units/error_q dut/attention/units/v_error dut/attention/units/f_error dut/attention/units/workspace_error dut/attention/units/v_current dut/attention/units/v_auth dut/attention/units/f_auth unit_ws unit_ws_valid dut/attention/units/workspace/legal dut/attention/units/read_pending dut/result_rd_data_valid} {
  puts "PROBE $p=[get_value /tb_dynamic_attention/$p]"
}
quit
