import pcore_pkg::*;
import deqacc_v1_pkg::*;

(* keep_hierarchy="yes" *)
module published_v1_group(
  input logic clk,reset,clear,input v1_key_t input_key,
  input logic signed [1:0][3:0][31:0] psum,
  input logic [1:0][7:0] ea,input logic [3:0][7:0] eb,
  input logic signed [EXP_FOLD_BITS-1:0] fold,
  output logic commit_valid,output logic [1:0][3:0][31:0] commit_data,
  input logic external_rd_fire,input acc_sel_e external_rd_sel,input logic [9:0] external_rd_addr,
  output logic [1:0][3:0][31:0] external_data,
  input logic external_wr_fire,input acc_sel_e external_wr_sel,input logic [9:0] external_wr_addr,
  input logic [1:0] external_wr_rows,input logic [1:0][3:0][31:0] external_wr_data,
  input acc_sel_e dbg_sel,input logic dbg_parity,input logic [9:0] dbg_addr,
  input logic [1:0] dbg_column,output logic [31:0] dbg_data
);
  // Only local keys cross the memory/feedback path; full metadata stays in the spine.
  v1_key_t keys[0:6];
  logic [1:0][3:0][31:0] old_fetch,old_issue,partial_values,a3_values;
  logic [1:0][3:0] partial_valid,a3_valid;
  logic [1:0] use_a3,use_c;
  function automatic bit key_match(input v1_key_t producer,consumer,input int parity);
    return producer.valid&&producer.rows[parity]&&producer.generation==consumer.generation&&
      producer.sel==consumer.sel&&producer.addr==consumer.addr;
  endfunction
  always_comb begin
    for(int p=0;p<2;p++)begin
      use_a3[p]=key_match(keys[5],keys[1],p);
      use_c[p]=!use_a3[p]&&key_match(keys[6],keys[1],p);
      for(int n=0;n<4;n++)old_issue[p][n]=!keys[1].add_old?32'b0:
        use_a3[p]?a3_values[p][n]:use_c[p]?commit_data[p][n]:old_fetch[p][n];
    end
  end
  always_ff @(posedge clk)begin
    keys[0]<=input_key;
    for(int s=1;s<7;s++)keys[s]<=keys[s-1];
    commit_data<=a3_values;
    if(reset||clear)for(int s=0;s<7;s++)keys[s].valid<=0;
  end
  assign commit_valid=keys[6].valid;
  published_v1_acc memory(
    .clk,.reset,.clear,.rd_valid(keys[0].valid&&keys[0].add_old),.rd_sel(keys[0].sel),.rd_addr(keys[0].addr),
    .old_data(old_fetch),.wr_valid(keys[5].valid),.wr_sel(keys[5].sel),.wr_addr(keys[5].addr),
    .wr_rows(keys[5].rows),.wr_data(a3_values),
    .external_rd_fire,.external_rd_sel,.external_rd_addr,.external_data,
    .external_wr_fire,.external_wr_sel,.external_wr_addr,.external_wr_rows,.external_wr_data,
    .dbg_sel,.dbg_parity,.dbg_addr,.dbg_column,.dbg_data);
  for(genvar micro=0;micro<2;micro++)begin: micro_clusters
    for(genvar r=0;r<2;r++)for(genvar c=0;c<2;c++)begin: lanes
      localparam int N=micro*2+c;
      published_v1_dequant quant(.clk,.reset,.clear,.in_valid(input_key.valid),.psum(psum[r][N]),
        .ea(ea[r]),.eb(eb[N]),.fold,.out_valid(partial_valid[r][N]),.partial_value(partial_values[r][N]));
      fp32_add_lane_v1 add(.clk,.reset,.clear,.in_valid(keys[1].valid),.add_old(keys[1].add_old),
        .old_value(old_issue[r][N]),.partial_value(partial_values[r][N]),
        .out_valid(a3_valid[r][N]),.result_value(a3_values[r][N]));
    end
  end
  // synthesis translate_off
  always @(posedge clk)if(!reset&&!clear)begin
    for(int r=0;r<2;r++)for(int n=0;n<4;n++)begin
      if(partial_valid[r][n]!==keys[1].valid)$fatal(1,"V1 partial/key mismatch");
      if(a3_valid[r][n]!==keys[5].valid)$fatal(1,"V1 A3/key mismatch");
    end
    if(input_key.valid&&input_key.add_old)
      for(int p=0;p<2;p++)if(input_key.rows[p])
        for(int s=0;s<3;s++)if(key_match(keys[s],input_key,p))
          $fatal(1,"V1 accumulator RAW: dependent input interval below four cycles");
    if(keys[1].valid&&keys[1].add_old)
      for(int p=0;p<2;p++)if(keys[1].rows[p])
        for(int s=2;s<5;s++)if(key_match(keys[s],keys[1],p))
          $fatal(1,"V1 unresolved writer at A0");
  end
  // synthesis translate_on
endmodule
