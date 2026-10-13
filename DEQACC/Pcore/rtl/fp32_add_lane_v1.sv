import dea8_fp32_pkg::*;

// Full dual path: A0 order/classify; A1 FAR align/arithmetic || CLOSE
// subtract/LZA; A2 normalize + parallel rounding; A3 candidate select/pack.
module fp32_add_lane_v1 #(parameter bit USE_LZA=1)(
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
    logic special,sign_result,zero_sign;
    logic [31:0] special_value;
    logic [8:0] exponent;
    logic [27:0] far_raw,close_raw;
    logic [4:0] close_shift;
  } arithmetic_t;
  typedef struct packed {
    logic [8:0] exp0,exp1;
    logic [23:0] mant0,mant1;
    logic round_up,is_zero;
  } round_t;
  typedef struct packed {
    logic valid,bypass,close_path;
    logic [31:0] partial;
    logic special,sign_result,zero_sign;
    logic [31:0] special_value;
    round_t far_round,close_round;
  } candidates_t;

  order_t order_q,order_d;
  arithmetic_t arithmetic_q,arithmetic_d;
  candidates_t candidates_q,candidates_d;
  round_t selected_round;
  logic [7:0] ea,eb;
  logic [23:0] ma,mb;
  logic big_a,an,bn,ai,bi;
  logic [27:0] far_aligned,close_aligned,lza_t,lza_z,lza_indicator;
  logic [27:0] far_norm,close_pre_norm,close_norm;
  logic [8:0] far_exp,close_exp,close_limit;
  logic [4:0] close_amount;
  logic close_correction;
  logic [31:0] packed_result;

  function automatic logic [27:0] left_barrel(input logic [27:0] value,input logic [4:0] amount);
    logic [27:0] s1,s2,s4,s8;
    s1=amount[0]?(value<<1):value;
    s2=amount[1]?(s1<<2):s1;
    s4=amount[2]?(s2<<4):s2;
    s8=amount[3]?(s4<<8):s4;
    return amount[4]?(s8<<16):s8;
  endfunction

  // Compute mantissa+0 and mantissa+1 independently of the RNE predicate.
  // The carry and both exponents cross A2; no late incrementer follows A3.
  function automatic logic [$bits(round_t)-1:0] rounding_candidates(
    input logic [27:0] normalized,input logic [8:0] exponent,input logic is_zero);
    logic [24:0] incremented;
    logic [23:0] m0,m1;
    logic [8:0] e1;
    logic up;
    m0=normalized[26:3];
    incremented={1'b0,m0}+25'd1;
    m1=incremented[24]?incremented[24:1]:incremented[23:0];
    e1=exponent+9'(incremented[24]);
    up=normalized[2]&&(normalized[1]||normalized[0]||normalized[3]);
    return {exponent,e1,m0,m1,up,is_zero};
  endfunction

  // A0: shared decode and ordered, unaligned significands.
  always_comb begin
    ea=old_value[30:23]==0?8'd1:old_value[30:23];
    eb=partial_value[30:23]==0?8'd1:partial_value[30:23];
    ma={|old_value[30:23],old_value[22:0]};
    mb={|partial_value[30:23],partial_value[22:0]};
    big_a=(ea>eb)||((ea==eb)&&(ma>=mb));
    an=(&old_value[30:23])&&(|old_value[22:0]);
    bn=(&partial_value[30:23])&&(|partial_value[22:0]);
    ai=old_value[30:0]==FP_INF[30:0];
    bi=partial_value[30:0]==FP_INF[30:0];
    order_d='0;
    order_d.valid=in_valid;order_d.bypass=!add_old;order_d.partial=partial_value;
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
  end

  // A1: independent datapaths. Positive ordered X-Y has its leading one
  // at the predicted position or one below (Schmookler/Nowka, ARITH15).
  // This anticipator uses operands only, never the subtractor result.
  always_comb begin
    far_aligned=shift_right_jam28(order_q.pre.small_x,order_q.distance);
    close_aligned=order_q.distance[0]?(order_q.pre.small_x>>1):order_q.pre.small_x;
    lza_t=order_q.pre.big_x^~close_aligned;
    lza_z=~(order_q.pre.big_x|~close_aligned);
    lza_indicator={1'b1,lza_t[27:1]}^~lza_z;
    arithmetic_d='0;
    arithmetic_d.valid=order_q.valid;arithmetic_d.bypass=order_q.bypass;
    arithmetic_d.close_path=order_q.close_path;arithmetic_d.partial=order_q.partial;
    arithmetic_d.special=order_q.pre.special;
    arithmetic_d.special_value=order_q.pre.special_value;
    arithmetic_d.sign_result=order_q.pre.sign_result;arithmetic_d.zero_sign=order_q.pre.zero_sign;
    arithmetic_d.exponent=order_q.pre.exponent;
    arithmetic_d.far_raw=order_q.pre.subtract?order_q.pre.big_x-far_aligned:
      order_q.pre.big_x+far_aligned;
    arithmetic_d.close_raw=order_q.pre.big_x-close_aligned;
    arithmetic_d.close_shift=USE_LZA?(5'd25-lead32({4'b0,lza_indicator})):
      (5'd26-lead32({4'b0,arithmetic_d.close_raw}));
    if(order_q.pre.big_x==close_aligned)arithmetic_d.close_shift=0;
  end

  // A2 FAR: limited carry/one-bit normalization. CLOSE: anticipated coarse
  // shift + exact one-bit correction. Clamp to exponent-1 for subnormals.
  always_comb begin
    if(arithmetic_q.far_raw[27])begin
      far_norm={1'b0,arithmetic_q.far_raw[27:2],|arithmetic_q.far_raw[1:0]};
      far_exp=arithmetic_q.exponent+9'd1;
    end else if(!arithmetic_q.far_raw[26]&&arithmetic_q.exponent>1)begin
      far_norm=arithmetic_q.far_raw<<1;
      far_exp=arithmetic_q.exponent-9'd1;
    end else begin
      far_norm=arithmetic_q.far_raw;
      far_exp=arithmetic_q.exponent;
    end
    close_limit=arithmetic_q.exponent-9'd1;
    close_amount={4'b0,arithmetic_q.close_shift}>close_limit?
      5'(close_limit):arithmetic_q.close_shift;
    close_pre_norm=left_barrel(arithmetic_q.close_raw,close_amount);
    close_correction=USE_LZA&&!close_pre_norm[26]&&arithmetic_q.close_raw!=0&&
      ({4'b0,close_amount}<close_limit);
    close_norm=close_correction?(close_pre_norm<<1):close_pre_norm;
    close_exp=arithmetic_q.exponent-{4'b0,close_amount}-9'(close_correction);
    candidates_d='0;
    candidates_d.valid=arithmetic_q.valid;candidates_d.bypass=arithmetic_q.bypass;
    candidates_d.close_path=arithmetic_q.close_path;candidates_d.partial=arithmetic_q.partial;
    candidates_d.special=arithmetic_q.special;candidates_d.special_value=arithmetic_q.special_value;
    candidates_d.sign_result=arithmetic_q.sign_result;candidates_d.zero_sign=arithmetic_q.zero_sign;
    candidates_d.far_round=rounding_candidates(far_norm,far_exp,arithmetic_q.far_raw==0);
    candidates_d.close_round=rounding_candidates(close_norm,close_exp,arithmetic_q.close_raw==0);
  end

  // A3: select registered candidates, then special/overflow/packing only.
  always_comb begin
    logic [8:0] exponent;
    logic [23:0] mantissa;
    logic [7:0] exp_field;
    selected_round=candidates_q.close_path?candidates_q.close_round:candidates_q.far_round;
    exponent=selected_round.round_up?selected_round.exp1:selected_round.exp0;
    mantissa=selected_round.round_up?selected_round.mant1:selected_round.mant0;
    exp_field=(exponent==1&&!mantissa[23])?8'b0:exponent[7:0];
    packed_result={candidates_q.sign_result,exp_field,mantissa[22:0]};
    if(exponent>=255)packed_result={candidates_q.sign_result,FP_INF[30:0]};
    if(selected_round.is_zero)packed_result={candidates_q.zero_sign,31'b0};
    if(candidates_q.special)packed_result=candidates_q.special_value;
    if(candidates_q.bypass)packed_result=candidates_q.partial;
  end
  always_ff @(posedge clk)begin
    order_q<=order_d;
    arithmetic_q<=arithmetic_d;
    candidates_q<=candidates_d;
    result_value<=packed_result;
    if(reset||clear)begin
      order_q.valid<=0;arithmetic_q.valid<=0;candidates_q.valid<=0;out_valid<=0;
    end else out_valid<=candidates_q.valid;
  end

  // synthesis translate_off
  always @(posedge clk)if(!reset&&!clear&&arithmetic_q.valid&&arithmetic_q.close_path&&
      !arithmetic_q.special&&!arithmetic_q.bypass&&arithmetic_q.close_raw!=0)begin
    if(USE_LZA&&(arithmetic_q.close_shift>5'd26-lead32({4'b0,arithmetic_q.close_raw})||
       5'd26-lead32({4'b0,arithmetic_q.close_raw})-arithmetic_q.close_shift>1))
      $fatal(1,"V2 CLOSE LZA prediction outside one-bit correction");
    if(close_exp>1&&!close_norm[26])$fatal(1,"V2 CLOSE normalization correction failed");
  end
  // synthesis translate_on
endmodule
