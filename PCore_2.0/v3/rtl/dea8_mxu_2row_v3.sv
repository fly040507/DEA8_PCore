import pcore3_pkg::*;

module dea8_mxu_2row_v3 (
  input logic clk,reset,clear,
  input logic req_valid,req_bank,input a2_t req,input pair_meta_t req_meta,
  input logic load_valid,load_bank,input logic [3:0] load_column,input b1_t load_entry,
  output logic rsp_valid,output mxu_rsp_t rsp
);
  localparam int STAGES=7;
  logic signed [1:0][TILE-1:0][7:0] q_act_reg;
  logic bank_q;
  logic [TILE-1:0][7:0] e_stat_bank[0:1];
  logic valid_q[0:STAGES-1]; logic [1:0] mask_q[0:STAGES-1];
  logic [1:0][7:0] stream_q[0:STAGES-1]; logic [TILE-1:0][7:0] stat_q[0:STAGES-1];
  pair_meta_t meta_q[0:STAGES-1];
  logic signed [PSUM_BITS-1:0] psum_reg[0:1][0:TILE-1];
  wire signed [15:0] product[0:1][0:TILE-1][0:TILE-1];
  logic signed [16:0] l1[0:1][0:TILE-1][0:7];
  logic signed [17:0] l2[0:1][0:TILE-1][0:3];
  logic signed [18:0] l3[0:1][0:TILE-1][0:1];
  for(genvar k=0;k<TILE;k++) for(genvar n=0;n<TILE;n++) begin: g_pe
    dea8_pe_2row_v3 pe(.clk,.reset,.clear,.mul_en(valid_q[0]),.active_bank(bank_q),
      .load_we(load_valid&&load_column==n),.load_bank,
      .load_weight(load_entry.col.data[k*8+:8]),.a0(q_act_reg[0][k]),.a1(q_act_reg[1][k]),
      .product0(product[0][k][n]),.product1(product[1][k][n]));
  end
  assign rsp_valid=valid_q[6]&&!reset&&!clear;
  assign rsp.row_valid=mask_q[6];
  assign rsp.e_stream=stream_q[6];
  assign rsp.e_stat=stat_q[6];
  assign rsp.meta=meta_q[6];
  always_comb begin
    rsp.psum='0;
    for(int r=0;r<2;r++) for(int n=0;n<TILE;n++) rsp.psum[r][n]=psum_reg[r][n];
  end
  always_ff @(posedge clk) begin
    if(load_valid&&!reset&&!clear) e_stat_bank[load_bank][load_column]<=load_entry.col.scale;
    if(reset||clear) begin
      for(int s=0;s<STAGES;s++) valid_q[s]<=0;
    end else begin
      valid_q[0]<=req_valid;
      if(req_valid) begin
        bank_q<=req_bank;mask_q[0]<=req.row_valid;stream_q[0]<={req.row[1].scale,req.row[0].scale};
        stat_q[0]<=e_stat_bank[req_bank];meta_q[0]<=req_meta;
        for(int r=0;r<2;r++) q_act_reg[r]<=req.row_valid[r]?req.row[r].data:'0;
      end
      for(int s=1;s<STAGES;s++) begin
        valid_q[s]<=valid_q[s-1];
        if(valid_q[s-1]) begin mask_q[s]<=mask_q[s-1];stream_q[s]<=stream_q[s-1];stat_q[s]<=stat_q[s-1];meta_q[s]<=meta_q[s-1];end
      end
      for(int r=0;r<2;r++) for(int n=0;n<TILE;n++) begin
        if(valid_q[2]) for(int k=0;k<8;k++) l1[r][n][k]<=$signed({product[r][2*k][n][15],product[r][2*k][n]})+$signed({product[r][2*k+1][n][15],product[r][2*k+1][n]});
        if(valid_q[3]) for(int k=0;k<4;k++) l2[r][n][k]<=$signed({l1[r][n][2*k][16],l1[r][n][2*k]})+$signed({l1[r][n][2*k+1][16],l1[r][n][2*k+1]});
        if(valid_q[4]) for(int k=0;k<2;k++) l3[r][n][k]<=$signed({l2[r][n][2*k][17],l2[r][n][2*k]})+$signed({l2[r][n][2*k+1][17],l2[r][n][2*k+1]});
        if(valid_q[5]) psum_reg[r][n]<=PSUM_BITS'($signed(l3[r][n][0]))+PSUM_BITS'($signed(l3[r][n][1]));
      end
    end
  end
  initial if(TILE!=16) $fatal(1,"v3 MXU is fixed at 16x16");
endmodule
