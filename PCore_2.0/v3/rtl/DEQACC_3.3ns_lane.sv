import dea8_fp32_v3_pkg::*;

// Six arithmetic boundaries: order, align, add/coarse detect, shift control,
// normalize shift, round/pack. Bypass follows exactly the same latency.
(* keep_hierarchy="yes" *)
module DEQACC_3_3ns_lane(
  input logic clk,reset,clear,in_valid,add_old,
  input logic [31:0] old_value,partial_value,
  output logic out_valid,output logic [31:0] result_value
);
  typedef struct packed {
    logic valid,bypass;
    logic [31:0] partial;
    fp_add_pre_t pre;
    logic [7:0] distance;
  } order_t;
  typedef struct packed {
    logic valid,bypass;
    logic [31:0] partial;
    fp_add_pre_t pre;
  } align_t;
  typedef struct packed {
    logic valid,bypass;
    logic [31:0] partial;
    fp_add_raw_t raw;
    logic [3:0] nonzero_group;
  } raw_t;
  typedef struct packed {
    logic valid,bypass;
    logic [31:0] partial;
    fp_add_raw_t raw;
    logic [4:0] shift;
    logic [8:0] exponent;
  } control_t;
  typedef struct packed {
    logic valid,bypass;
    logic [31:0] partial;
    fp_norm_mid_t norm;
  } norm_t;
  order_t order_q,order_d;
  align_t align_q;
  raw_t raw_q,raw_d;
  control_t control_q,control_d;
  norm_t norm_q,norm_d;
  logic [7:0] ea,eb;
  logic [23:0] ma,mb;
  logic a_big,an,bn,ai,bi;
  logic [1:0] group_sel;
  logic [6:0] group_value;
  logic [4:0] leading,wanted;
  always_comb begin
    ea=(old_value[30:23]==0)?8'd1:old_value[30:23];
    eb=(partial_value[30:23]==0)?8'd1:partial_value[30:23];
    ma={|old_value[30:23],old_value[22:0]};
    mb={|partial_value[30:23],partial_value[22:0]};
    a_big=(ea>eb)||((ea==eb)&&(ma>=mb));
    an=(&old_value[30:23])&&(|old_value[22:0]);
    bn=(&partial_value[30:23])&&(|partial_value[22:0]);
    ai=old_value[30:0]==FP_INF[30:0];bi=partial_value[30:0]==FP_INF[30:0];
    order_d='0;order_d.valid=in_valid;order_d.bypass=!add_old;order_d.partial=partial_value;
    order_d.distance=a_big?ea-eb:eb-ea;
    order_d.pre.special=an||bn||ai||bi;
    order_d.pre.special_value=(an||bn||(ai&&bi&&(old_value[31]!=partial_value[31])))?
      FP_QNAN:(ai?old_value:partial_value);
    order_d.pre.sign_result=a_big?old_value[31]:partial_value[31];
    order_d.pre.zero_sign=old_value[31]&&partial_value[31];
    order_d.pre.subtract=old_value[31]^partial_value[31];
    order_d.pre.exponent={1'b0,a_big?ea:eb};
    order_d.pre.big_x={1'b0,a_big?ma:mb,3'b0};
    order_d.pre.small_x={1'b0,a_big?mb:ma,3'b0};
    raw_d='0;raw_d.valid=align_q.valid;raw_d.bypass=align_q.bypass;raw_d.partial=align_q.partial;
    raw_d.raw=fp32_add_raw(align_q.pre);
    for(int g=0;g<4;g++) raw_d.nonzero_group[g]=|raw_d.raw.sum_raw[g*7+:7];
    group_sel=raw_q.nonzero_group[3]?2'd3:raw_q.nonzero_group[2]?2'd2:
      raw_q.nonzero_group[1]?2'd1:2'd0;
    group_value=raw_q.raw.sum_raw[7*group_sel+:7];
    leading=5'(group_sel)*5'd7+lead32({25'b0,group_value});
    wanted=5'd26-leading;
    control_d='0;control_d.valid=raw_q.valid;control_d.bypass=raw_q.bypass;
    control_d.partial=raw_q.partial;control_d.raw=raw_q.raw;
    control_d.shift=({4'b0,wanted}>raw_q.raw.exponent-9'd1)?5'(raw_q.raw.exponent-9'd1):wanted;
    control_d.exponent=raw_q.raw.sum_raw[27]?raw_q.raw.exponent+9'd1:
      raw_q.raw.exponent-{4'b0,control_d.shift};
    norm_d='0;norm_d.valid=control_q.valid;norm_d.bypass=control_q.bypass;norm_d.partial=control_q.partial;
    norm_d.norm.special=control_q.raw.special;norm_d.norm.special_value=control_q.raw.special_value;
    norm_d.norm.sign_result=control_q.raw.sign_result;norm_d.norm.zero_sign=control_q.raw.zero_sign;
    norm_d.norm.is_zero=control_q.raw.sum_raw==0;norm_d.norm.exponent_norm=control_q.exponent;
    norm_d.norm.sum_norm=control_q.raw.sum_raw[27]?
      {1'b0,control_q.raw.sum_raw[27:2],|control_q.raw.sum_raw[1:0]}:
      control_q.raw.sum_raw<<control_q.shift;
  end
  always_ff @(posedge clk) begin
    order_q<=order_d;
    align_q.bypass<=order_q.bypass;align_q.partial<=order_q.partial;
    align_q.pre<=order_q.pre;
    align_q.pre.small_x<=shift_right_jam28(order_q.pre.small_x,order_q.distance);
    raw_q<=raw_d;control_q<=control_d;norm_q<=norm_d;
    result_value<=norm_q.bypass?norm_q.partial:fp32_pack_mid(norm_q.norm);
    if(reset||clear) begin
      order_q.valid<=0;align_q.valid<=0;raw_q.valid<=0;control_q.valid<=0;norm_q.valid<=0;out_valid<=0;
    end else begin
      align_q.valid<=order_q.valid;
      out_valid<=norm_q.valid;
    end
  end
endmodule
