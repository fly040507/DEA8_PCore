`timescale 1ns/1ps
module tb_mask_profile;
  logic clk=0;always #2 clk=~clk;
  logic reset=1,flush=0;
  logic [2:0] cv=0,cr,configured,config_error,qv=0,qr,ov,oready=0,protocol_error;
  logic [2:0][15:0] position,context_id,version,position_base,sm,am;
  logic [5:0] block_id=0;
  int checked=0;
  for(genvar c=0;c<3;c++)begin: cases
    localparam FILE=c==0?"Pcore/tb/data/compute/mask_empty.mem":c==1?
      "Pcore/tb/data/compute/mask_full.mem":"Pcore/tb/data/compute/mask_holes.mem";
    dea8_mask_context #(.MASK_FILE(FILE)) dut(.clk,.reset,.flush,
      .config_valid(cv[c]),.config_ready(cr[c]),.config_context(16'd9),.config_version(16'd1),.config_position(position[c]),
      .configured(configured[c]),.config_error(config_error[c]),.context_id(context_id[c]),.version(version[c]),.position_base(position_base[c]),
      .query_valid(qv[c]),.query_ready(qr[c]),.block_id,.result_valid(ov[c]),.result_ready(oready[c]),
      .state_mask(sm[c]),.action_mask(am[c]),.protocol_error(protocol_error[c]));
  end
  initial begin
    position={16'd408,16'd816,16'd0};repeat(4)@(negedge clk);reset=0;
    cv='1;@(negedge clk);cv=0;wait(&configured);
    for(int b=0;b<55;b++)begin
      @(negedge clk);block_id=6'(b);qv='1;wait(&qr);@(negedge clk);qv=0;
      wait(&ov);
      for(int c=0;c<3;c++)begin
        logic [15:0] es,ea;
        es=b<51?(c==0?16'h0000:c==1?16'hffff:16'h55aa):(b==51?16'h1:16'h0);
        ea=b<51?es:(b==54?16'h7:16'hffff);
        repeat(3)begin
          @(negedge clk);if(!ov[c]||sm[c]!==es||am[c]!==ea)$fatal(1,"Official pi0 Mask c=%0d block=%0d got=%h/%h expected=%h/%h",c,b,sm[c],am[c],es,ea);
        end
        checked++;
      end
      oready='1;@(negedge clk);oready=0;
    end
    @(negedge clk);position[2]=409;cv=3'b100;@(negedge clk);cv=0;
    wait(config_error[2]);if(configured[2])$fatal(1,"Bad Mask popcount accepted");
    @(negedge clk);position[2]=408;cv=3'b100;@(negedge clk);cv=0;wait(configured[2]);
    @(negedge clk);block_id=55;qv='1;@(negedge clk);qv=0;wait(&protocol_error);
    @(negedge clk);flush=1;@(negedge clk);flush=0;
    if(protocol_error!=0||configured!='1)$fatal(1,"Mask flush/context contract");
    $display("tb_mask_profile PASS block_queries=%0d empty_full_holes=3 suffix_state_action=1 popcount_reject=1 flush=1",checked);$finish;
  end
  initial begin #20000;$fatal(1,"Mask profile watchdog");end
endmodule
