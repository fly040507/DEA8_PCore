import dea8_fp32_pkg::*;

// A0 order/classify, A1 FAR align+arithmetic / CLOSE 0/1 align+subtract,
// A2 exact normalization, A3 RNE/pack. Every path has four boundaries.
module published_v1_fpadd(
  input logic clk,reset,clear,in_valid,add_old,
  input logic [31:0] old_value,partial_value,
  output logic out_valid,
  output logic [31:0] result_value
);
  typedef struct packed {
    logic valid,bypass,close_path;
    logic [31:0] partial;
    logic [7:0] distance;
    fp_add_pre_t pre;
  } order_t;
  typedef struct packed {
    logic valid,bypass,close_path;
    logic [31:0] partial;
    fp_add_raw_t raw;
  } raw_t;
  typedef struct packed {
    logic valid,bypass;
    logic [31:0] partial;
    fp_norm_mid_t norm;
  } norm_t;
  order_t order_q,order_d;
  raw_t raw_q,raw_d;
  norm_t norm_q,norm_d;
  logic [7:0] ea,eb;
  logic [23:0] ma,mb;
  logic big_a,an,bn,ai,bi;
  logic [27:0] small_aligned;
  integer wanted,amount;
  always_comb begin
    ea=old_value[30:23]==0?8'd1:old_value[30:23];
    eb=partial_value[30:23]==0?8'd1:partial_value[30:23];
    ma={|old_value[30:23],old_value[22:0]};
    mb={|partial_value[30:23],partial_value[22:0]};
    big_a=(ea>eb)||((ea==eb)&&(ma>=mb));
    an=(&old_value[30:23])&&(|old_value[22:0]);
    bn=(&partial_value[30:23])&&(|partial_value[22:0]);
    ai=old_value[30:0]==FP_INF[30:0];bi=partial_value[30:0]==FP_INF[30:0];
    order_d='0;order_d.valid=in_valid;order_d.bypass=!add_old;order_d.partial=partial_value;
    order_d.distance=big_a?ea-eb:eb-ea;
    order_d.close_path=(old_value[31]^partial_value[31])&&(order_d.distance<=1);
    order_d.pre.special=an||bn||ai||bi;
    order_d.pre.special_value=(an||bn||(ai&&bi&&(old_value[31]!=partial_value[31])))?
      FP_QNAN:(ai?old_value:partial_value);
    order_d.pre.sign_result=big_a?old_value[31]:partial_value[31];
    order_d.pre.zero_sign=old_value[31]&&partial_value[31];
    order_d.pre.subtract=old_value[31]^partial_value[31];
    order_d.pre.exponent={1'b0,big_a?ea:eb};
    order_d.pre.big_x={1'b0,big_a?ma:mb,3'b0};
    order_d.pre.small_x={1'b0,big_a?mb:ma,3'b0};

    small_aligned=order_q.close_path?(order_q.pre.small_x>>order_q.distance[0]):
      shift_right_jam28(order_q.pre.small_x,order_q.distance);
    raw_d='0;raw_d.valid=order_q.valid;raw_d.bypass=order_q.bypass;
    raw_d.partial=order_q.partial;raw_d.close_path=order_q.close_path;
    raw_d.raw.special=order_q.pre.special;raw_d.raw.special_value=order_q.pre.special_value;
    raw_d.raw.sign_result=order_q.pre.sign_result;raw_d.raw.zero_sign=order_q.pre.zero_sign;
    raw_d.raw.exponent=order_q.pre.exponent;
    raw_d.raw.sum_raw=order_q.pre.subtract?order_q.pre.big_x-small_aligned:
      order_q.pre.big_x+small_aligned;

    norm_d='0;norm_d.valid=raw_q.valid;norm_d.bypass=raw_q.bypass;norm_d.partial=raw_q.partial;
    norm_d.norm.special=raw_q.raw.special;norm_d.norm.special_value=raw_q.raw.special_value;
    norm_d.norm.sign_result=raw_q.raw.sign_result;norm_d.norm.zero_sign=raw_q.raw.zero_sign;
    norm_d.norm.is_zero=raw_q.raw.sum_raw==0;
    wanted=raw_q.close_path?26-int'(lead32({5'b0,raw_q.raw.sum_raw[26:0]})):
      (raw_q.raw.sum_raw[26]?0:1);
    amount=wanted<int'(raw_q.raw.exponent)-1?wanted:int'(raw_q.raw.exponent)-1;
    if(raw_q.raw.sum_raw==0)amount=0;
    if(raw_q.raw.sum_raw[27])begin
      norm_d.norm.sum_norm={1'b0,raw_q.raw.sum_raw[27:2],|raw_q.raw.sum_raw[1:0]};
      norm_d.norm.exponent_norm=raw_q.raw.exponent+9'd1;
    end else begin
      norm_d.norm.sum_norm=raw_q.raw.sum_raw<<amount;
      norm_d.norm.exponent_norm=raw_q.raw.exponent-9'(amount);
    end
  end
  always_ff @(posedge clk)begin
    order_q<=order_d;raw_q<=raw_d;norm_q<=norm_d;
    result_value<=norm_q.bypass?norm_q.partial:fp32_pack_mid(norm_q.norm);
    if(reset||clear)begin order_q.valid<=0;raw_q.valid<=0;norm_q.valid<=0;out_valid<=0;end
    else out_valid<=norm_q.valid;
  end
endmodule
