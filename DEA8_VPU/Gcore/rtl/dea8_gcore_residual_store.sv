module dea8_gcore_residual_store (
  input logic clk,reset,clear,
  input logic wr_valid,
  output logic wr_ready,
  input logic [gcore_pkg::VECTOR_ADDR_BITS-1:0] wr_addr,
  input logic [255:0] wr_data,
  input logic rd_valid,
  output logic rd_ready,
  input logic [gcore_pkg::VECTOR_ADDR_BITS-1:0] rd_addr,
  output logic rsp_valid,
  input logic rsp_ready,
  output logic [255:0] rsp_data,
  output logic [gcore_pkg::VECTOR_ADDR_BITS-1:0] rsp_addr,
  output logic protocol_error
);
  import gcore_pkg::*;
  (* ram_style="ultra" *) logic [255:0] memory [VECTOR_WORDS];
  logic rd_fire,wr_fire;
  assign wr_ready=!reset&&!clear&&!protocol_error;
  assign rd_ready=!reset&&!clear&&!protocol_error&&(!rsp_valid||rsp_ready);
  assign wr_fire=wr_valid&&wr_ready;
  assign rd_fire=rd_valid&&rd_ready;

  // No RAM reset. Object validity is owned by gcore_control.
  always_ff @(posedge clk) begin
    if(wr_fire && wr_addr<VECTOR_WORDS) memory[wr_addr]<=wr_data;
    if(rd_fire && rd_addr<VECTOR_WORDS && !(wr_fire&&wr_addr==rd_addr))
      rsp_data<=memory[rd_addr];
    if(reset||clear) begin rsp_valid<=0; rsp_addr<=0; protocol_error<=0; end
    else begin
      if(rsp_valid&&rsp_ready) rsp_valid<=0;
      if(rd_fire) begin
        if(rd_addr>=VECTOR_WORDS || (wr_fire&&wr_addr==rd_addr)) protocol_error<=1;
        else begin rsp_addr<=rd_addr; rsp_valid<=1; end
      end
      if(wr_fire&&wr_addr>=VECTOR_WORDS) protocol_error<=1;
    end
  end
endmodule
