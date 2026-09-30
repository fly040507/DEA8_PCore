import pcore3_pkg::*;
import dea8_fp32_v3_pkg::*;

// D0 abs/lead, D1 normalize/exponent, D2 pack preparation/ACC read,
// D3 pack finish/RAM response, D4..D9 lane arithmetic, D10 commit. II=1.
module DEQACC_3_3ns(
  input logic clk,reset,clear,rsp_valid,input mxu_rsp_t rsp,
  input acc_read_owner_e result_rd_owner,
  input logic result_rd_valid,output logic result_rd_ready,
  input logic vpu_wr_valid,output logic vpu_wr_ready,input acc_write_t vpu_wr,
  input acc_sel_e result_rd_sel,input logic [9:0] result_rd_addr,
  output logic result_rd_data_valid,output logic [15:0][31:0] result_even_data,result_odd_data,
  output logic commit_valid,done,output pair_meta_t commit_meta,
  input logic dbg_valid,input acc_sel_e dbg_sel,input logic dbg_parity,
  input logic [9:0] dbg_addr,input logic [3:0] dbg_lane,output logic [31:0] dbg_data
);
  typedef struct packed {logic valid;pair_meta_t meta;logic [1:0] rows;} context_t;
  typedef struct packed {
    logic sign_bit,is_zero,bad;
    logic [31:0] mag;
    logic [4:0] lead;
    logic [7:0] a,b;
    logic signed [EXP_FOLD_BITS-1:0] fold;
  } magnitude_t;
  typedef struct packed {
    logic sign_bit,is_zero,bad;
    logic [31:0] norm;
    logic signed [10:0] exponent;
  } normalized_t;
  typedef struct packed {
    logic sign_bit,is_zero,bad,subnormal;
    logic signed [10:0] exponent;
    logic [23:0] kept;
    logic increment;
  } pack_t;
  typedef struct packed {logic [31:0] partial,old_value;} operands_t;
  magnitude_t magnitude_q[0:1][0:15];
  normalized_t s0[0:1][0:15];
  pack_t s1[0:1][0:15];
  operands_t s2[0:1][0:15];
  pack_t pack_next[0:1][0:15];
  logic [31:0] partial_next[0:1][0:15];
  context_t context_q[0:9];
  logic [1:0] word_valid;
  logic rd_valid,rd_data_valid;
  logic [9:0] rd_addr,wr_addr;
  logic [15:0][31:0] rd_even,rd_odd,wr_even,wr_odd;
  logic lane_valid[0:1][0:15];
  logic [31:0] lane_value[0:1][0:15];
  function automatic magnitude_t magnitude(input logic signed [31:0] value,
    input logic [7:0] a,b,input logic signed [EXP_FOLD_BITS-1:0] fold);
    magnitude_t t;
    t.mag=value[31]?(~value+32'd1):value;t.lead=lead32(t.mag);
    t.sign_bit=value[31];t.is_zero=t.mag==0;t.bad=(&a)||(&b);
    t.a=a;t.b=b;t.fold=fold;return t;
  endfunction
  function automatic logic [31:0] finish_pack(input pack_t p);
    logic [24:0] rounded;logic [23:0] mant;logic signed [11:0] exponent;
    rounded={1'b0,p.kept}+25'(p.increment);
    mant=rounded[24]?rounded[24:1]:rounded[23:0];
    exponent=$signed({p.exponent[10],p.exponent})+$signed({11'b0,rounded[24]});
    if(p.bad) return FP_QNAN;
    if(p.is_zero) return 0;
    if(p.subnormal) return {p.sign_bit,7'b0,rounded[23:0]};
    if(exponent>127) return {p.sign_bit,FP_INF[30:0]};
    return {p.sign_bit,8'(exponent+127),mant[22:0]};
  endfunction
  assign rd_valid=context_q[1].valid&&context_q[1].meta.add_old;
  assign rd_addr=context_q[1].meta.acc_sel==ACC_OACC?
    {1'b0,context_q[1].meta.pair_idx,context_q[1].meta.nt}:10'(context_q[1].meta.pair_idx);
  assign wr_addr=context_q[9].meta.acc_sel==ACC_OACC?
    {1'b0,context_q[9].meta.pair_idx,context_q[9].meta.nt}:10'(context_q[9].meta.pair_idx);
  dea8_acc_store_v3 acc_store(
    .clk,.reset,.clear,.rd_valid,.rd_sel(context_q[1].meta.acc_sel),.rd_addr,
    .rd_data_valid,.rd_even_data(),.rd_odd_data(),
    .rd_even_raw(rd_even),.rd_odd_raw(rd_odd),.rd_word_valid(word_valid),
    .result_rd_owner,.result_rd_valid,.result_rd_ready,.result_rd_sel,.result_rd_addr,
    .result_rd_data_valid,.result_even_data,.result_odd_data,.vpu_wr_valid,.vpu_wr_ready,.vpu_wr,
    .wr_valid(context_q[9].valid),.wr_sel(context_q[9].meta.acc_sel),
    .wr_even_valid(context_q[9].rows[0]),.wr_odd_valid(context_q[9].rows[1]),
    .wr_addr,.wr_even_data(wr_even),.wr_odd_data(wr_odd),
    .dbg_valid,.dbg_sel,.dbg_parity,.dbg_addr,.dbg_lane,.dbg_data);
  for(genvar r=0;r<2;r++)for(genvar n=0;n<16;n++) begin: lanes
    logic signed [11:0] distance;
    logic [31:0] shifted,mask;
    logic guard_bit;
    assign distance=($signed(s0[r][n].exponent)<-126)?(-$signed(s0[r][n].exponent)-12'sd118):12'sd8;
    assign shifted=(distance>=32)?32'b0:(s0[r][n].norm>>distance[4:0]);
    assign mask=(distance>32)?32'hffffffff:(32'hffffffff>>(12'd33-distance));
    assign guard_bit=(distance<=32)?s0[r][n].norm[$unsigned(5'(distance-1))]:1'b0;
    assign pack_next[r][n]={s0[r][n].sign_bit,s0[r][n].is_zero,s0[r][n].bad,
      ($signed(s0[r][n].exponent)<-126),s0[r][n].exponent,shifted[23:0],
      (guard_bit&&((|(s0[r][n].norm&mask))||shifted[0]))};
    assign partial_next[r][n]=finish_pack(s1[r][n]);
    DEQACC_3_3ns_lane lane(.clk,.reset,.clear,.in_valid(context_q[3].valid),
      .add_old(context_q[3].meta.add_old),.old_value(s2[r][n].old_value),.partial_value(s2[r][n].partial),
      .out_valid(lane_valid[r][n]),.result_value(lane_value[r][n]));
    if(r==0) assign wr_even[n]=lane_value[r][n];
    else assign wr_odd[n]=lane_value[r][n];
  end
  always_ff @(posedge clk) begin
    context_q[0].meta<=rsp.meta;context_q[0].rows<=rsp.row_valid;
    for(int i=1;i<10;i++)context_q[i]<=context_q[i-1];
    commit_meta<=context_q[9].meta;
    for(int r=0;r<2;r++)for(int n=0;n<16;n++)begin
      magnitude_q[r][n]<=magnitude(rsp.psum[r][n],rsp.e_stream[r],rsp.e_stat[n],rsp.meta.exp_fold);
      s0[r][n].norm<=magnitude_q[r][n].mag<<(5'd31-magnitude_q[r][n].lead);
      s0[r][n].exponent<=$signed({3'b0,magnitude_q[r][n].a})+$signed({3'b0,magnitude_q[r][n].b})-11'sd266+
        $signed(magnitude_q[r][n].fold)+$signed({6'b0,magnitude_q[r][n].lead});
      s0[r][n].sign_bit<=magnitude_q[r][n].sign_bit;
      s0[r][n].is_zero<=magnitude_q[r][n].is_zero;s0[r][n].bad<=magnitude_q[r][n].bad;
      s1[r][n]<=pack_next[r][n];s2[r][n].partial<=partial_next[r][n];
      s2[r][n].old_value<=context_q[2].meta.add_old&&word_valid[r]?(r==0?rd_even[n]:rd_odd[n]):32'b0;
    end
    if(reset||clear) begin
      for(int i=0;i<10;i++)context_q[i].valid<=0;
      commit_valid<=0;done<=0;
    end else begin
      context_q[0].valid<=rsp_valid;
      commit_valid<=context_q[9].valid;done<=context_q[9].valid&&context_q[9].meta.last;
    end
  end
  // synthesis translate_off
  always @(posedge clk) if(!reset&&!clear) begin
    if(rd_data_valid!==(context_q[2].valid&&context_q[2].meta.add_old)) $fatal(1,"DEQACC ACC response context mismatch");
    for(int r=0;r<2;r++)for(int n=0;n<16;n++)
      if(lane_valid[r][n]!==context_q[9].valid) $fatal(1,"DEQACC lane/context latency mismatch");
    for(int i=2;i<10;i++) if(rd_valid&&context_q[i].valid&&
      context_q[i].meta.acc_sel==context_q[1].meta.acc_sel&&
      context_q[i].meta.pair_idx==context_q[1].meta.pair_idx&&
      (context_q[1].meta.acc_sel!=ACC_OACC||context_q[i].meta.nt==context_q[1].meta.nt))
      $fatal(1,"DEQACC accumulator RAW hazard");
  end
  // synthesis translate_on
endmodule
