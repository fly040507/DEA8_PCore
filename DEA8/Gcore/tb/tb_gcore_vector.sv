`timescale 1ns/1ps
module tb_gcore_vector;
  import gcore_pkg::*;
  logic clk=0; always #2 clk=~clk;
  logic reset=1,clear=0,clear_sq=0,in_valid=0,in_ready,out_valid,out_ready=0,empty;
  vector_request_t request;
  vector_result_t result;
  logic [5:0] sq_row0=0,sq_row1=1;
  logic stats_read=0,stats_advance=0;
  logic [31:0] sq_value0,sq_value1;
  logic [255:0] initial_res[VECTOR_WORDS],mid_res[VECTOR_WORDS],next_res[VECTOR_WORDS];
  logic [511:0] delta_o[VECTOR_WORDS],delta_down[VECTOR_WORDS];
  logic [135:0] q_initial[VECTOR_WORDS],q_mid[VECTOR_WORDS],q_next[VECTOR_WORDS];
  logic [31:0] sq_initial[ROWS],sq_mid[ROWS],sq_next[ROWS];
  logic [31:0] inv_initial[ROWS],inv_mid[ROWS],inv_next[ROWS];
  int cycle=0,received=0,total=0,phase=0;
  bit checking=0;
  vector_result_t held;
  bit stalled=0;
  dea8_gcore_vector dut(.*);
  always @(negedge clk) out_ready=(cycle%13!=4&&cycle%13!=5&&cycle%13!=6);
  always @(posedge clk) begin
    cycle++;
    if(reset||clear) stalled=0;
    else begin
      if(stalled&&(!out_valid||result!==held)) $fatal(1,"vector output changed under backpressure");
      stalled=out_valid&&!out_ready; held=result;
      if(checking&&out_valid&&out_ready) begin
        logic [135:0] qgold;
        logic [255:0] rgold;
        logic [31:0] sgold;
        int row;
        row=received%ROWS;
        if(result.meta.index!=received||result.meta.token!=phase||result.numeric_fault)
          $fatal(1,"vector metadata/numeric failure phase=%0d index=%0d got=%0d fault=%0d",phase,received,result.meta.index,result.numeric_fault);
        case(phase)
          1:sgold=sq_initial[row];
          2:qgold=q_initial[received];
          3:begin rgold=mid_res[received]; sgold=sq_mid[row]; end
          4:qgold=q_mid[received];
          5:begin rgold=next_res[received]; sgold=sq_next[row]; end
          6:qgold=q_next[received];
          default:$fatal(1,"unexpected vector phase");
        endcase
        if(phase%2==0 && result.quantized!==qgold)
          $fatal(1,"vector quant mismatch phase=%0d index=%0d got=%h expected=%h",phase,received,result.quantized,qgold);
        if((phase==3||phase==5)&&result.residual!==rgold)
          $fatal(1,"vector residual mismatch phase=%0d index=%0d",phase,received);
        if(phase%2==1&&received>=VECTOR_WORDS-ROWS&&result.square_sum!==sgold)
          $fatal(1,"vector row-square mismatch phase=%0d row=%0d got=%h expected=%h",phase,row,result.square_sum,sgold);
        received++; total++;
      end
    end
  end
  initial begin
    request='0;
    $readmemh("tb/data/initial_residual.mem",initial_res);
    $readmemh("tb/data/mid_residual.mem",mid_res);
    $readmemh("tb/data/next_residual.mem",next_res);
    $readmemh("tb/data/reduce_o.mem",delta_o); $readmemh("tb/data/reduce_down.mem",delta_down);
    $readmemh("tb/data/initial_sq.mem",sq_initial); $readmemh("tb/data/mid_sq.mem",sq_mid); $readmemh("tb/data/next_sq.mem",sq_next);
    $readmemh("tb/data/initial_inv.mem",inv_initial); $readmemh("tb/data/mid_inv.mem",inv_mid); $readmemh("tb/data/next_inv.mem",inv_next);
    $readmemh("tb/data/initial_xhat.mem",q_initial); $readmemh("tb/data/mid_xhat.mem",q_mid); $readmemh("tb/data/next_xhat.mem",q_next);
    repeat(30) @(negedge clk); reset=0;
    for(int p=1;p<=6;p++) begin
      @(negedge clk); phase=p; received=0; checking=1;
      if(p%2==1) begin clear_sq=1; @(negedge clk); clear_sq=0; end
      for(int index=0;index<VECTOR_WORDS;index++) begin
        @(negedge clk);
        request='0; request.meta.token=p; request.meta.index=VECTOR_ADDR_BITS'(index);
        request.meta.row=6'(index%ROWS); request.meta.nt=6'(index/ROWS);
        request.meta.mode=p==1?VECTOR_SCAN:(p%2==0?VECTOR_APPLY:VECTOR_RESIDUAL);
        request.residual=p<=3?initial_res[index]:(p<=5?mid_res[index]:next_res[index]);
        if(p==2) request.inverse=inv_initial[index%ROWS];
        if(p==4) request.inverse=inv_mid[index%ROWS];
        if(p==6) request.inverse=inv_next[index%ROWS];
        if(p==3) request.delta=delta_o[index];
        if(p==5) request.delta=delta_down[index];
        in_valid=1;
        do @(posedge clk); while(!in_ready);
      end
      @(negedge clk); in_valid=0;
      wait(received==VECTOR_WORDS); @(negedge clk); checking=0;
      if(!empty) $fatal(1,"vector pipeline failed to drain");
    end
    $display("tb_gcore_vector PASS vectors=%0d scans=1 residual_jobs=2 normalization_passes=3 fp32_tree_rne=1 stalled=1",total);
    $finish;
  end
  initial begin #1000000; $fatal(1,"vector watchdog"); end
endmodule
