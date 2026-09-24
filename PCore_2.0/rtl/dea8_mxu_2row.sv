import pcore2_pkg::*;
module dea8_mxu_2row (
  input logic clk,reset,clear,
  input logic req_valid,req_bank,
  input a2_t req,
  input tag_t req_tag[0:1],
  input dest_t req_dest[0:1],
  input logic load_valid,load_bank,
  input logic [$clog2(TILE)-1:0] load_column,
  input b_t load_entry,
  output logic rsp_valid,
  output logic [1:0] rsp_row_valid,
  output logic signed [1:0][TILE-1:0][PSUM_BITS-1:0] psum,
  output logic [1:0][SCALE_BITS-1:0] rsp_scale,
  output logic [TILE-1:0][SCALE_BITS-1:0] rsp_e_stat,
  output tag_t rsp_tag[0:1],
  output dest_t rsp_dest[0:1]
);
  logic signed [1:0][TILE-1:0][7:0] Q_ACT_REG;
  logic bank_q;
  logic [TILE-1:0][SCALE_BITS-1:0] E_STAT_BANK[0:1];
  logic valid_q[0:STAGES-1];
  logic [1:0] mask_q[0:STAGES-1];
  logic [1:0][SCALE_BITS-1:0] scale_q[0:STAGES-1];
  logic [TILE-1:0][SCALE_BITS-1:0] stat_q[0:STAGES-1];
  tag_t tag_q[0:STAGES-1][0:1];
  dest_t dest_q[0:STAGES-1][0:1];
  wire signed [15:0] product[0:1][0:TILE-1][0:TILE-1];
  logic signed [16:0] l1[0:1][0:TILE-1][0:7];
  logic signed [17:0] l2[0:1][0:TILE-1][0:3];
  logic signed [18:0] l3[0:1][0:TILE-1][0:1];
  for(genvar k=0;k<TILE;k++) begin : g_k
    for(genvar n=0;n<TILE;n++) begin : g_n
      dea8_pe_2row pe (
        .clk,.reset,.clear,.mul_en(valid_q[0]),.active_bank(bank_q),
        .load_we(load_valid && load_column==n),.load_bank,
        .load_weight(load_entry.data[k*8+:8]),.a0(Q_ACT_REG[0][k]),.a1(Q_ACT_REG[1][k]),
        .product0(product[0][k][n]),.product1(product[1][k][n])
      );
    end
  end
  assign rsp_valid=valid_q[STAGES-1] && !clear && !reset;
  assign rsp_row_valid=mask_q[STAGES-1];
  assign rsp_scale=scale_q[STAGES-1];
  assign rsp_e_stat=stat_q[STAGES-1];
  for(genvar r=0;r<2;r++) begin : g_rsp
    assign rsp_tag[r]=tag_q[STAGES-1][r];
    assign rsp_dest[r]=dest_q[STAGES-1][r];
  end
  always_ff @(posedge clk) begin
    if(load_valid && !reset && !clear) E_STAT_BANK[load_bank][load_column]<=load_entry.scale;
    if(reset || clear) begin
      for(int s=0;s<STAGES;s++) valid_q[s]<=0;
    end else begin
      valid_q[0]<=req_valid;
      if(req_valid) begin
        bank_q<=req_bank;
        for(int r=0;r<2;r++) begin
          Q_ACT_REG[r]<=req.row_valid[r] ? req.data[r] : '0;
          tag_q[0][r]<=req_tag[r]; dest_q[0][r]<=req_dest[r];
        end
        mask_q[0]<=req.row_valid; scale_q[0]<=req.scale;
        stat_q[0]<=E_STAT_BANK[req_bank];
      end
      for(int s=1;s<STAGES;s++) begin
        valid_q[s]<=valid_q[s-1];
        if(valid_q[s-1]) begin
          mask_q[s]<=mask_q[s-1];scale_q[s]<=scale_q[s-1];stat_q[s]<=stat_q[s-1];
          for(int r=0;r<2;r++) begin tag_q[s][r]<=tag_q[s-1][r];dest_q[s][r]<=dest_q[s-1][r];end
        end
      end
      for(int r=0;r<2;r++) for(int n=0;n<TILE;n++) begin
        if(valid_q[2]) for(int k=0;k<8;k++)
          l1[r][n][k]<=$signed({product[r][2*k][n][15],product[r][2*k][n]})+
                        $signed({product[r][2*k+1][n][15],product[r][2*k+1][n]});
        if(valid_q[3]) for(int k=0;k<4;k++)
          l2[r][n][k]<=$signed({l1[r][n][2*k][16],l1[r][n][2*k]})+
                        $signed({l1[r][n][2*k+1][16],l1[r][n][2*k+1]});
        if(valid_q[4]) for(int k=0;k<2;k++)
          l3[r][n][k]<=$signed({l2[r][n][2*k][17],l2[r][n][2*k]})+
                        $signed({l2[r][n][2*k+1][17],l2[r][n][2*k+1]});
        if(valid_q[5]) psum[r][n]<=PSUM_BITS'($signed(l3[r][n][0]))+PSUM_BITS'($signed(l3[r][n][1]));
      end
    end
  end
  // synthesis translate_off
  initial if(TILE!=16 || STAGES!=7 || INT_BITS!=8) $fatal(1,"Unsupported DSP/tree geometry");
  always @(posedge clk) if(!reset && !clear) begin
    if(load_valid && valid_q[0] && load_bank==bank_q) $fatal(1,"Writing multiplying B bank");
    if(req_valid && load_valid && req_bank==load_bank) $fatal(1,"B bank not fully resident at issue");
  end
  // synthesis translate_on
endmodule
