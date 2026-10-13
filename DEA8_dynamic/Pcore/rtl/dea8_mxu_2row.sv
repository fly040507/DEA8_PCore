import pcore_pkg::*;

module dea8_mxu_2row (
  input logic clk,reset,clear,
  input logic req_valid,req_bank,input a2_t req,input pair_meta_t req_meta,
  input logic load_valid,input b4_t load_entry,
  output logic rsp_valid,output mxu_rsp_t rsp
);
  localparam int PRODUCT_BITS=2*INT_BITS;
  localparam int STAGES=MXU_PIPE_STAGES;
  logic signed [ROW_LANES-1:0][TILE-1:0][INT_BITS-1:0] q_act_reg;
  logic bank_q;
  logic [TILE-1:0][SCALE_BITS-1:0] e_stat_bank[0:1];
  logic valid_q[0:STAGES-1];
  logic [ROW_LANES-1:0] mask_q[0:STAGES-1];
  logic [ROW_LANES-1:0][SCALE_BITS-1:0] stream_q[0:STAGES-1];
  logic [TILE-1:0][SCALE_BITS-1:0] stat_q[0:STAGES-1];
  pair_meta_t meta_q[0:STAGES-1];
  wire signed [PRODUCT_BITS-1:0] product[0:ROW_LANES-1][0:TILE-1][0:TILE-1];
  logic signed [PRODUCT_BITS:0] l1[0:ROW_LANES-1][0:TILE-1][0:TILE/2-1];
  logic signed [PRODUCT_BITS+1:0] l2[0:ROW_LANES-1][0:TILE-1][0:TILE/4-1];
  logic signed [PRODUCT_BITS+2:0] l3[0:ROW_LANES-1][0:TILE-1][0:TILE/8-1];
  logic signed [PSUM_BITS-1:0] psum_out_reg[0:ROW_LANES-1][0:TILE-1];

  for(genvar k=0;k<TILE;k++) for(genvar n=0;n<TILE;n++) begin: g_pe
    dea8_pe_2row pe(
      .clk,.reset,.clear,.mul_en(valid_q[0]),.active_bank(bank_q),
      .load_we(load_valid&&load_entry.group_idx==n/B_LOAD_COLS),
      .load_bank(load_entry.bank),
      .load_weight(load_entry.data[n%B_LOAD_COLS][k*INT_BITS+:INT_BITS]),
      .a0(q_act_reg[0][k]),.a1(q_act_reg[1][k]),
      .product0(product[0][k][n]),.product1(product[1][k][n]));
  end
  assign rsp_valid=valid_q[STAGES-1]&&!reset&&!clear;
  assign rsp.row_valid=mask_q[STAGES-1];
  assign rsp.e_stream=stream_q[STAGES-1];
  assign rsp.e_stat=stat_q[STAGES-1];
  assign rsp.meta=meta_q[STAGES-1];
  always_comb begin
    for(int r=0;r<ROW_LANES;r++)for(int n=0;n<TILE;n++)
      rsp.psum[r][n]=psum_out_reg[r][n];
  end

  always_ff @(posedge clk) begin
    if(load_valid&&!reset&&!clear&&load_entry.group_idx==0)
      e_stat_bank[load_entry.bank]<=load_entry.scales;
    if(reset||clear)begin
      for(int s=0;s<STAGES;s++)valid_q[s]<=0;
    end else begin
      valid_q[0]<=req_valid;
      if(req_valid)begin
        bank_q<=req_bank;
        mask_q[0]<=req.row_valid;
        for(int r=0;r<ROW_LANES;r++)begin
          q_act_reg[r]<=req.row_valid[r]?req.row[r].data:'0;
          stream_q[0][r]<=req.row[r].scale;
        end
        stat_q[0]<=e_stat_bank[req_bank];
        meta_q[0]<=req_meta;
      end
      for(int s=1;s<STAGES;s++)begin
        valid_q[s]<=valid_q[s-1];
        if(valid_q[s-1])begin
          mask_q[s]<=mask_q[s-1];stream_q[s]<=stream_q[s-1];
          stat_q[s]<=stat_q[s-1];meta_q[s]<=meta_q[s-1];
        end
      end
      // S3/S4/S5/S6. The fourth tree result is the output register itself.
      for(int r=0;r<ROW_LANES;r++)for(int n=0;n<TILE;n++)begin
        if(valid_q[2])for(int k=0;k<TILE/2;k++)
          l1[r][n][k]<=$signed({product[r][2*k][n][PRODUCT_BITS-1],product[r][2*k][n]})+
                       $signed({product[r][2*k+1][n][PRODUCT_BITS-1],product[r][2*k+1][n]});
        if(valid_q[3])for(int k=0;k<TILE/4;k++)
          l2[r][n][k]<=$signed({l1[r][n][2*k][PRODUCT_BITS],l1[r][n][2*k]})+
                       $signed({l1[r][n][2*k+1][PRODUCT_BITS],l1[r][n][2*k+1]});
        if(valid_q[4])for(int k=0;k<TILE/8;k++)
          l3[r][n][k]<=$signed({l2[r][n][2*k][PRODUCT_BITS+1],l2[r][n][2*k]})+
                       $signed({l2[r][n][2*k+1][PRODUCT_BITS+1],l2[r][n][2*k+1]});
        if(valid_q[5])psum_out_reg[r][n]<=
          PSUM_BITS'($signed(l3[r][n][0]))+PSUM_BITS'($signed(l3[r][n][1]));
      end
    end
  end
  // synthesis translate_off
  always @(posedge clk)if(!reset&&!clear)begin
    if(load_valid&&valid_q[0]&&load_entry.bank==bank_q)
      $fatal(1,"MXU weight write overlaps S1 use");
    if(req_valid&&(req_meta.m_rows==0||req_meta.m_rows>ROWS||
      req.pair_idx>=pairs_for_rows(req_meta.m_rows)||
      req.row_valid!==row_mask_for_rows(req_meta.m_rows,req.pair_idx)))
      $fatal(1,"MXU illegal dynamic row mask");
    if(req_valid&&load_valid&&req_bank==load_entry.bank&&load_entry.group_idx!=B_LOAD_GROUPS-1)
      $fatal(1,"MXU request before final weight group");
  end
  initial if(TILE!=16||ROW_LANES!=2||INT_BITS!=8||STAGES!=7)
    $fatal(1,"MXU requires 16x16 shared-B dual INT8 and seven stages");
  // synthesis translate_on
endmodule
