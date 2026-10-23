`include "../tb/tb_vpu_p_history.sv"
module tb_p_history_shared;
  tb_vpu_p_history tb();
  final if(tb.writes==4&&tb.results==26)$display("tb_p_history_shared PASS old_l_preserved=1");
endmodule
