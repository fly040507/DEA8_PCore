module tb_compute_sfu_shared;
  tb_compute_sfu #(.SHARED(1)) tb();
  final if(tb.commands==4)$display("tb_compute_sfu_shared PASS commands=4 shared_MUL16_ADD16=1");
endmodule
