import pcore_pkg::*;
import dea8_fp32_pkg::*;

// Physical ownership: two columns x two rows. The arithmetic equations and
// D0..D9 register boundaries are identical to the ungrouped implementation.
(* keep_hierarchy="yes" *)
module DEQACC_3_3ns_group2(
  input logic clk,reset,clear,in_valid,add_old,
  input logic signed [EXP_FOLD_BITS-1:0] fold,
  input logic [1:0][1:0][31:0] psum,
  input logic [1:0][7:0] e_stream,e_stat,
  input logic [1:0][1:0][31:0] old_data,
  input logic [1:0] word_valid,
  output logic [1:0][1:0] out_valid,
  output logic [1:0][1:0][31:0] result_value
);
  typedef struct packed {
    logic sign_bit,is_zero,bad;
    logic [31:0] mag;
    logic [4:0] lead;
    logic [7:0] a,b;
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
  magnitude_t magnitude_q[0:1][0:1];
  (* shreg_extract="no" *) normalized_t s0[0:1][0:1];
  pack_t s1[0:1][0:1],pack_next[0:1][0:1];
  operands_t s2[0:1][0:1];
  (* dont_touch="yes", shreg_extract="no" *) logic signed [EXP_FOLD_BITS-1:0] fold_q;
  (* dont_touch="yes", shreg_extract="no" *) logic [1:0][7:0] stream_exp_q;
  (* dont_touch="yes", shreg_extract="no" *) logic [3:0] valid_q,add_old_q;
  function automatic magnitude_t magnitude(input logic signed [31:0] value,input logic [7:0] a,b);
    magnitude_t t;
    t.mag=value[31]?(~value+32'd1):value;t.lead=lead32(t.mag);
    t.sign_bit=value[31];t.is_zero=t.mag==0;t.bad=(&a)||(&b);
    t.a=a;t.b=b;return t;
  endfunction
  function automatic logic [31:0] finish_pack(input pack_t p);
    logic [24:0] rounded;logic [23:0] mant;logic signed [11:0] exponent;
    rounded={1'b0,p.kept}+25'(p.increment);
    mant=rounded[24]?rounded[24:1]:rounded[23:0];
    exponent=$signed({p.exponent[10],p.exponent})+$signed({11'b0,rounded[24]});
    if(p.bad)return FP_QNAN;
    if(p.is_zero)return 0;
    if(p.subnormal)return {p.sign_bit,7'b0,rounded[23:0]};
    if(exponent>127)return {p.sign_bit,FP_INF[30:0]};
    return {p.sign_bit,8'(exponent+127),mant[22:0]};
  endfunction
  always_ff @(posedge clk)begin
    fold_q<=fold;stream_exp_q<=e_stream;add_old_q<={add_old_q[2:0],add_old};
    if(reset||clear)valid_q<=0;
    else valid_q<={valid_q[2:0],in_valid};
  end
  for(genvar r=0;r<2;r++)for(genvar n=0;n<2;n++)begin: lanes
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
    always_ff @(posedge clk)begin
      magnitude_q[r][n]<=magnitude($signed(psum[r][n]),e_stream[r],e_stat[n]);
      s0[r][n].norm<=magnitude_q[r][n].mag<<(5'd31-magnitude_q[r][n].lead);
      s0[r][n].exponent<=$signed({3'b0,stream_exp_q[r]})+$signed({3'b0,magnitude_q[r][n].b})-11'sd266+
        $signed(fold_q)+$signed({6'b0,magnitude_q[r][n].lead});
      s0[r][n].sign_bit<=magnitude_q[r][n].sign_bit;
      s0[r][n].is_zero<=magnitude_q[r][n].is_zero;s0[r][n].bad<=magnitude_q[r][n].bad;
      s1[r][n]<=pack_next[r][n];s2[r][n].partial<=finish_pack(s1[r][n]);
      // ACC already applies local initialized one-hot masking at its existing
      // response boundary; no global valid zero-select reaches these data FFs.
      s2[r][n].old_value<=add_old_q[2]?old_data[r][n]:32'b0;
    end
    DEQACC_3_3ns_lane lane(.clk,.reset,.clear,.in_valid(valid_q[3]),.add_old(add_old_q[3]),
      .old_value(s2[r][n].old_value),.partial_value(s2[r][n].partial),
      .out_valid(out_valid[r][n]),.result_value(result_value[r][n]));
  end
endmodule
