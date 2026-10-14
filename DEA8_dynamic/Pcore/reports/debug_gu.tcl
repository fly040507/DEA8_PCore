run 150000 ns
foreach path {
  /tb_dynamic_gu_chain/scenario/cycles
  /tb_dynamic_gu_chain/scenario/work_count
  /tb_dynamic_gu_chain/scenario/issue_count
  /tb_dynamic_gu_chain/scenario/command_count
  /tb_dynamic_gu_chain/scenario/function_commands
  /tb_dynamic_gu_chain/scenario/dut/matrix/core/tile_q
  /tb_dynamic_gu_chain/scenario/dut/matrix/core/state
  /tb_dynamic_gu_chain/scenario/dut/post/finished_pairs
  /tb_dynamic_gu_chain/scenario/dut/post/unit_running
  /tb_dynamic_gu_chain/scenario/dut/post/f_running
  /tb_dynamic_gu_chain/scenario/dut/post/gu_started
  /tb_dynamic_gu_chain/scenario/dut/post/gu_join/requested
  /tb_dynamic_gu_chain/scenario/dut/post/gu_join/returned
  /tb_dynamic_gu_chain/scenario/dut/post/gu_join/consumed
  /tb_dynamic_gu_chain/scenario/dut/post/gu_join/up_count
  /tb_dynamic_gu_chain/scenario/dut/post/gu_join/join_held
  /tb_dynamic_gu_chain/scenario/dut/gu_scheduler/retired
  /tb_dynamic_gu_chain/scenario/dut/gu_scheduler/active
  /tb_dynamic_gu_chain/scenario/dut/gu_scheduler/done
  /tb_dynamic_gu_chain/scenario/dut/post/done
  /tb_dynamic_gu_chain/scenario/completion_valid
} {
  puts "GU_DEBUG $path [get_value $path]"
}
quit
