module dea8_gcore_vector (
  input logic clk,reset,clear,clear_sq,
  input logic in_valid,
  output logic in_ready,
  input gcore_pkg::vector_request_t request,
  output logic out_valid,
  input logic out_ready,
  output gcore_pkg::vector_result_t result,
  input logic [5:0] sq_row0,sq_row1,
  input logic stats_read,stats_advance,
  output logic [31:0] sq_value0,sq_value1,
  output logic empty
);
  import gcore_pkg::*;
  import gcore_fp_pkg::*;
  localparam int ADD_LAT=ADD_LATENCY, BF_STAGE=ADD_LAT+1, MUL_LAT=MUL_LATENCY;
  localparam int MUL_STAGE=BF_STAGE+MUL_LAT, SUM_LEVELS=$clog2(TILE);
  localparam int SUM_STAGE=MUL_STAGE+SUM_LEVELS*ADD_LAT, OUT_STAGE=SUM_STAGE+ADD_LAT;
  localparam int QUANT_LAT=3, QUANT_STAGE=MUL_STAGE+QUANT_LAT+1;
  logic advance;
  logic [OUT_STAGE:0] valid_q,bad_q;
  vector_meta_t meta_q [OUT_STAGE+1];
  logic [255:0] input_residual;
  logic [511:0] input_delta;
  logic [31:0] inverse_q [BF_STAGE+1];
  logic [15:0][31:0] add_result,mul_result;
  logic [255:0] rounded_bf;
  logic rounded_bad,multiply_bad;
  logic [255:0] bf_delay [OUT_STAGE-BF_STAGE+1];
  logic [136:0] quant_value;
  logic [135:0] quant_delay [OUT_STAGE-QUANT_STAGE+1];
  logic [31:0] sum_result [SUM_LEVELS][TILE/2];
  logic [ROWS-1:0] sq_valid;
  logic [31:0] sq_read0_q,sq_read1_q;
  logic sq_mask0_q,sq_mask1_q;
  logic sq_write;
  logic [31:0] sq_old,sq_result;

  assign out_valid=valid_q[OUT_STAGE]&&!reset&&!clear;
  assign advance=(!out_valid||out_ready)&&!reset&&!clear;
  assign in_ready=advance;
  assign empty=!(|valid_q);
  assign sq_value0=sq_mask0_q?sq_read0_q:32'b0;
  assign sq_value1=sq_mask1_q?sq_read1_q:32'b0;
  assign sq_old=(meta_q[SUM_STAGE].nt==0||!sq_mask1_q)?32'b0:sq_read1_q;
  // TDP port A: commit writes, or the first rsqrt row read. Port B:
  // prefetch the feedback one stage early, or the second rsqrt row read.
  assign sq_write=out_valid&&out_ready&&!result.numeric_fault&&result.meta.mode!=VECTOR_APPLY;
  dea8_gcore_stat_ram square_sum_ram (
    .clk,.enable_a(sq_write||(stats_read&&stats_advance&&sq_row0<ROWS)),
    .enable_b(stats_read?(stats_advance&&sq_row1<ROWS):(advance&&valid_q[SUM_STAGE-1])),
    .write_a(sq_write),.write_b(1'b0),
    .address_a(sq_write?result.meta.row:sq_row0),
    .address_b(stats_read?sq_row1:meta_q[SUM_STAGE-1].row),
    .data_a(sq_result),.data_b(32'b0),.result_a(sq_read0_q),.result_b(sq_read1_q)
  );
  always_ff @(posedge clk) begin
    if(reset||clear||clear_sq)begin sq_valid<=0;sq_mask0_q<=0;sq_mask1_q<=0;end
    else begin
      if(out_valid&&out_ready&&!result.numeric_fault&&result.meta.mode!=VECTOR_APPLY)
        sq_valid[result.meta.row]<=1;
      if(stats_read&&stats_advance)begin
        sq_mask0_q<=sq_row0<ROWS?sq_valid[sq_row0]:1'b0;
        sq_mask1_q<=sq_row1<ROWS?sq_valid[sq_row1]:1'b0;
      end else if(!stats_read&&advance&&valid_q[SUM_STAGE-1])
        sq_mask1_q<=sq_valid[meta_q[SUM_STAGE-1].row];
    end
  end
  always_comb begin
    result='0; result.meta=meta_q[OUT_STAGE];
    result.residual=bf_delay[OUT_STAGE-BF_STAGE];
    result.quantized=quant_delay[OUT_STAGE-QUANT_STAGE];
    result.square_sum=sq_result;
    result.numeric_fault=bad_q[OUT_STAGE] ||
      (meta_q[OUT_STAGE].mode!=VECTOR_APPLY&&!finite32(sq_result));
    rounded_bad=0; multiply_bad=0;
    for(int lane=0;lane<TILE;lane++) begin
      rounded_bf[16*lane+:16]=round_bf16(add_result[lane]);
      if(!finite32(add_result[lane])||rounded_bf[16*lane+7+:8]==8'hff) rounded_bad=1;
      if(!finite32(mul_result[lane])) multiply_bad=1;
    end
  end
  dea8_gcore_quant quantizer(.clk,.advance,.values(mul_result),.result(quant_value));
  for(genvar lane=0;lane<TILE;lane++) begin: lanes
    logic [31:0] a,b,mult_b;
    assign a={input_residual[16*lane+:16],16'b0};
    assign b=meta_q[0].mode==VECTOR_RESIDUAL?input_delta[32*lane+:32]:32'b0;
    assign mult_b=meta_q[BF_STAGE].mode==VECTOR_APPLY?inverse_q[BF_STAGE]:
      {bf_delay[0][16*lane+:16],16'b0};
    dea8_gcore_fp_add add_lane(.clk,.reset,.clear,.advance,.a,.b,.result(add_result[lane]));
    dea8_gcore_fp_mul multiply_lane(.clk,.reset,.clear,.advance,
      .a({bf_delay[0][16*lane+:16],16'b0}),.b(mult_b),.result(mul_result[lane]));
  end
  for(genvar level=0;level<SUM_LEVELS;level++) begin: tree_levels
    for(genvar node=0;node<(TILE>>(level+1));node++) begin: nodes
      if(level==0) begin: first
        dea8_gcore_fp_add add_node(.clk,.reset,.clear,.advance,.a(mul_result[2*node]),
          .b(mul_result[2*node+1]),.result(sum_result[level][node]));
      end else begin: later
        dea8_gcore_fp_add add_node(.clk,.reset,.clear,.advance,.a(sum_result[level-1][2*node]),
          .b(sum_result[level-1][2*node+1]),.result(sum_result[level][node]));
      end
    end
  end
  dea8_gcore_fp_add row_accumulator(.clk,.reset,.clear,.advance,.a(sq_old),
    .b(sum_result[SUM_LEVELS-1][0]),.result(sq_result));

  always_ff @(posedge clk) begin
    if(reset||clear) begin
      valid_q<=0; bad_q<=0; input_residual<=0; input_delta<=0;
      for(int s=0;s<=OUT_STAGE;s++) meta_q[s]<='0;
      for(int s=0;s<=BF_STAGE;s++) inverse_q[s]<=0;
    end else if(advance) begin
      valid_q[0]<=in_valid; bad_q[0]<=0;
      if(in_valid) begin
        meta_q[0]<=request.meta; input_residual<=request.residual;
        input_delta<=request.delta; inverse_q[0]<=request.inverse;
        for(int lane=0;lane<TILE;lane++)
          if(request.residual[16*lane+7+:8]==8'hff ||
              (request.meta.mode==VECTOR_RESIDUAL&&!finite32(request.delta[32*lane+:32])) ||
              (request.meta.mode==VECTOR_APPLY&&!finite32(request.inverse))) bad_q[0]<=1;
      end
      for(int s=1;s<=OUT_STAGE;s++) begin
        valid_q[s]<=valid_q[s-1]; meta_q[s]<=meta_q[s-1]; bad_q[s]<=bad_q[s-1];
      end
      for(int s=1;s<=BF_STAGE;s++) inverse_q[s]<=inverse_q[s-1];
      bad_q[BF_STAGE]<=bad_q[BF_STAGE-1]||rounded_bad;
      bad_q[MUL_STAGE+1]<=bad_q[MUL_STAGE]||multiply_bad;
      bad_q[QUANT_STAGE]<=bad_q[QUANT_STAGE-1]||
        (meta_q[QUANT_STAGE-1].mode==VECTOR_APPLY&&quant_value[136]);
      bad_q[SUM_STAGE+1]<=bad_q[SUM_STAGE] ||
        (meta_q[SUM_STAGE].mode!=VECTOR_APPLY&&!finite32(sum_result[SUM_LEVELS-1][0]));
      bf_delay[0]<=rounded_bf;
      for(int s=1;s<=OUT_STAGE-BF_STAGE;s++) bf_delay[s]<=bf_delay[s-1];
      quant_delay[0]<=quant_value[135:0];
      for(int s=1;s<=OUT_STAGE-QUANT_STAGE;s++) quant_delay[s]<=quant_delay[s-1];
    end
  end
`ifndef SYNTHESIS
  always @(posedge clk) if(!reset&&!clear) begin
    if(clear_sq&&!empty) $fatal(1,"GCore statistics reset with work in flight");
    if(in_valid&&in_ready && (request.meta.row>=ROWS||request.meta.nt>=HIDDEN_TILES||
        request.meta.index!=request.meta.nt*ROWS+request.meta.row)) $fatal(1,"GCore vector address mismatch");
  end
`endif
endmodule
