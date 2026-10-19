// Two MAX boundaries plus the generated native FP32 SUB latency. II=1.
module dea8_vpu_qk_post_pair_v3 (
  input logic clk, reset, clear,
  input logic in_valid,
  output logic in_ready,
  input pcore_pkg::vpu_cmd_t in_cmd,
  input logic [pcore_pkg::PAIR_BITS-1:0] in_pair_idx,
  input logic [1:0] in_row_valid,
  input logic [1:0][15:0][31:0] in_score,
  input logic [1:0][15:0] in_effective_mask,
  input logic [1:0][31:0] in_m_old,
  output logic out_valid,
  input logic out_ready,
  output pcore_pkg::vpu_cmd_t out_cmd,
  output logic [pcore_pkg::PAIR_BITS-1:0] out_pair_idx,
  output logic [1:0] out_row_valid,
  // Accepted masked payload goes straight to the VPU's existing stream RAM;
  // it is not replicated across the SUB metadata pipeline.
  output logic [1:0][15:0][31:0] capture_masked_score,
  output logic [1:0][31:0] out_row_max, out_m_new, out_aa,
  output logic [1:0] out_empty_row, out_initial_row, out_numeric_error
);

  localparam int STAGES=2+dea8_compute_config_pkg::FP_ADD_LATENCY;
  localparam logic [31:0] NEG_INF=32'hff800000,POS_INF=32'h7f800000,POS_ZERO=0;
  typedef struct packed {
    pcore_pkg::vpu_cmd_t cmd;
    logic [pcore_pkg::PAIR_BITS-1:0] pair_idx;
    logic [1:0] rv,empty_row,initial_row,error,bypass;
    logic [1:0][31:0] old_m,row_max,new_m,bypass_aa;
  } context_t;
  context_t s0_d,s1_d,c[STAGES];
  logic [1:0][3:0][31:0] group_d,group_q;
  logic [1:0][15:0][31:0] masked_score_d;
  logic [1:0][15:0][31:0] leaf;logic [1:0] has_finite;
  logic [STAGES-1:0] v;
  wire advance=!v[STAGES-1]||out_ready;
  wire ce=advance&&!reset&&!clear;
  logic [1:0][31:0] difference;
  assign in_ready=ce;
  assign out_valid=!reset&&!clear&&v[STAGES-1];
  function automatic logic is_nan(input logic [31:0] x);
    return (&x[30:23]) && (|x[22:0]);
  endfunction

  // FP32 comparison by sign and magnitude, after rejecting NaN.
  // Raw unsigned/integer comparison alone would order negative floats wrongly.
  function automatic logic [31:0] max_fp(input logic [31:0] a,b);
    if ((a[30:0]==0) && (b[30:0]==0)) return POS_ZERO;
    if (a[31]!=b[31]) return a[31]?b:a;
    // One magnitude comparator shared by both signs. Equal magnitudes have
    // identical encodings here; signed-zero canonicalization stays above.
    return ((a[30:0]>=b[30:0]) ^ a[31])?a:b;
  endfunction


  // First register boundary: sanitize/mask and two comparator levels.
  always_comb begin
    s0_d='0;group_d='0;leaf='0;has_finite='0;masked_score_d='0;
    s0_d.cmd=in_cmd;s0_d.pair_idx=in_pair_idx;s0_d.rv=in_row_valid;
    s0_d.old_m=in_m_old;
    for(int r=0;r<2;r++)begin
      if(in_row_valid[r])begin
        s0_d.empty_row[r]=!(|in_effective_mask[r]);
        s0_d.error[r]=is_nan(in_m_old[r])||in_m_old[r]==POS_INF;
        for(int j=0;j<16;j++)begin
          masked_score_d[r][j]=in_effective_mask[r][j]?in_score[r][j]:NEG_INF;
          leaf[r][j]=masked_score_d[r][j];
          has_finite[r]|=in_effective_mask[r][j]&&!(&in_score[r][j][30:23]);
          if(in_effective_mask[r][j]&&(is_nan(in_score[r][j])||in_score[r][j]==POS_INF))begin
            leaf[r][j]=NEG_INF;s0_d.error[r]=1;
          end
        end
        if(!s0_d.empty_row[r]&&in_m_old[r]==NEG_INF&&!has_finite[r])s0_d.error[r]=1;
        s0_d.initial_row[r]=!s0_d.empty_row[r]&&!s0_d.error[r]&&in_m_old[r]==NEG_INF;
        s0_d.bypass_aa[r]=s0_d.initial_row[r]?NEG_INF:0;
        s0_d.bypass[r]=s0_d.empty_row[r]||s0_d.error[r]||s0_d.initial_row[r];
        for(int g=0;g<4;g++)group_d[r][g]=max_fp(
          max_fp(leaf[r][4*g],leaf[r][4*g+1]),max_fp(leaf[r][4*g+2],leaf[r][4*g+3]));
      end
    end
  end
  // Second boundary: final MAX levels, history merge and special-row policy.
  always_comb begin
    s1_d=c[0];
    for(int r=0;r<2;r++)begin
      if(c[0].rv[r])begin
        s1_d.row_max[r]=max_fp(max_fp(group_q[r][0],group_q[r][1]),max_fp(group_q[r][2],group_q[r][3]));
        s1_d.new_m[r]=(c[0].empty_row[r]||c[0].error[r])?c[0].old_m[r]:max_fp(c[0].old_m[r],s1_d.row_max[r]);
      end else s1_d.bypass[r]=1;

    end
  end
  always_ff @(posedge clk)begin
    if(reset||clear)begin v<=0;group_q<=0;for(int i=0;i<STAGES;i++)c[i]<='0;end
    else if(advance)begin
      v<={v[STAGES-2:0],in_valid};
      if(in_valid)begin c[0]<=s0_d;group_q<=group_d;end
      if(v[0])c[1]<=s1_d;
      for(int i=2;i<STAGES;i++)if(v[i-1])c[i]<=c[i-1];
    end
  end
  for(genvar r=0;r<2;r++)begin: subtract_rows
    dea8_vpu_add_stall subtractor(.clk,.reset,.clear,.advance,
      .in_valid(v[1]),.a(c[1].old_m[r]),.b({~c[1].new_m[r][31],c[1].new_m[r][30:0]}),
      .out_valid(),.y(difference[r]));
    assign out_aa[r]=c[STAGES-1].bypass[r]?c[STAGES-1].bypass_aa[r]:difference[r];
  end
  assign out_cmd=c[STAGES-1].cmd;
  assign out_pair_idx=c[STAGES-1].pair_idx;
  assign out_row_valid=c[STAGES-1].rv;
  assign capture_masked_score=masked_score_d;
  assign out_row_max=c[STAGES-1].row_max;
  assign out_m_new=c[STAGES-1].new_m;
  assign out_empty_row=c[STAGES-1].empty_row;
  assign out_initial_row=c[STAGES-1].initial_row;
  assign out_numeric_error=c[STAGES-1].error;
  // Simulation checks only; no hardware exception policy implied.
  // synthesis translate_off
  always @(posedge clk) if (!reset && !clear && in_valid && in_ready) begin
    assert (in_cmd.op==pcore_pkg::VPU_QK_POST) else $fatal(1,"wrong QK_POST op");
    assert (int'(in_pair_idx)<pcore_pkg::PAIRS) else $fatal(1,"invalid pair index");
    assert (in_row_valid==pcore_pkg::row_mask(int'(in_pair_idx)))
      else $fatal(1,"invalid row mask for pair index");
  end
  // synthesis translate_on
endmodule
