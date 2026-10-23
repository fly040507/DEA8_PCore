module dea8_gcore_residual_import (
  input logic clk,reset,clear,
  input logic cmd_valid,
  output logic cmd_ready,
  input gcore_pkg::gcore_cmd_t cmd,
  input logic in_valid,
  output logic in_ready,
  input gcore_pkg::residual_import_t in_data,
  output logic wr_valid,
  input logic wr_ready,
  output logic [gcore_pkg::VECTOR_ADDR_BITS-1:0] wr_addr,
  output logic [255:0] wr_data,
  output logic done_valid,
  input logic done_ready,
  output gcore_pkg::gcore_done_t done,
  output logic busy
);
  import gcore_pkg::*;
  gcore_cmd_t command_q;
  logic [VECTOR_ADDR_BITS-1:0] index_q;
  logic legal,numeric_bad;
  always_comb begin
    numeric_bad=0;
    for(int i=0;i<TILE;i++) if(in_data.data[16*i+7+:8]==8'hff) numeric_bad=1;
  end
  assign legal=in_data.token==command_token(command_q) && in_data.index==index_q &&
    in_data.last==(index_q==VECTOR_WORDS-1) && !numeric_bad;
  assign cmd_ready=!busy&&!done_valid&&!reset&&!clear;
  assign in_ready=busy&&!done_valid&&!reset&&!clear&&(legal?wr_ready:1'b1);
  assign wr_valid=in_valid&&busy&&!done_valid&&!reset&&!clear&&legal;
  assign wr_addr=index_q;
  assign wr_data=in_data.data;
  always_ff @(posedge clk) begin
    if(reset||clear) begin busy<=0; done_valid<=0; done<='0; command_q<='0; index_q<=0; end
    else begin
      if(done_valid&&done_ready) done_valid<=0;
      if(cmd_valid&&cmd_ready) begin
        command_q<=cmd; index_q<=0;
        if(cmd.opcode!=GC_IMPORT_RESID) begin
          done<=make_done(cmd,GC_INVALID_CMD,0); done_valid<=1;
        end else busy<=1;
      end
      if(in_valid&&in_ready) begin
        if(!legal) begin
          done<=make_done(command_q,numeric_bad?GC_NUMERIC_FAULT:GC_SOURCE_PROTOCOL,16'(index_q));
          done_valid<=1; busy<=0;
        end else if(index_q==VECTOR_WORDS-1) begin
          done<=make_done(command_q,GC_OK,16'(VECTOR_WORDS)); done_valid<=1; busy<=0;
        end else index_q<=index_q+1'b1;
      end
    end
  end
endmodule
