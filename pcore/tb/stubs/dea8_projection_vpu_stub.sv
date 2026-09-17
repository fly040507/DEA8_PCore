import dea8_pcore_pkg::*;
import dea8_job_pkg::*;
import dea8_behavioral_fp_pkg::*;

// Simulation-only VPU contract model. Quantizes ACTUAL FACC reads, no oracle
// input, no RoPE, no SFU invocation. Not part of the synthesizable file list.
module dea8_projection_vpu_stub (
  input logic clk,rst_n,clear,
  input logic post_cmd_valid,
  output logic post_cmd_ready,
  input projection_post_job_t post_cmd,
  output logic post_rd_valid,
  input logic post_rd_ready,
  output logic [ROW_BITS-1:0] post_rd_row,
  input logic post_rsp_valid,
  input logic [DW_VEC-1:0] post_rsp_data,
  output logic post_result_valid,
  input logic post_result_ready,
  output projection_q_result_t post_result,
  output logic post_done_valid,
  input logic post_done_ready,
  output projection_post_job_t post_done
);
  typedef enum {IDLE,READ_ROW,WAIT_ROW,SEND_ROW,FINISH} phase_e;
  phase_e phase_q;
  projection_post_job_t job_q;
  logic [ROW_BITS-1:0] row_q;
  logic [B_ENTRY_BITS-1:0] quant_q;
  int cycle=0;
  bit slow_mode;
  function automatic logic [B_ENTRY_BITS-1:0] quantize(input logic [DW_VEC-1:0] word);
    real maximum,magnitude,step,value;
    int exponent_value,code_value;
    logic [B_ENTRY_BITS-1:0] result;
    maximum=0;
    for(int n=0;n<TILE;n++) begin
      if(word[n*FP_BITS+23+:8]==255) $fatal(1,"Nonfinite Projection VPU input");
      value=fp_real(word[n*FP_BITS+:FP_BITS]);
      magnitude=value<0 ? -value : value;
      if(magnitude>maximum) maximum=magnitude;
    end
    exponent_value=0;step=2.0**(-133);
    while(maximum>127.0*step && exponent_value<254) begin exponent_value++;step*=2.0;end
    result='0;result[0+:SCALE_BITS]=SCALE_BITS'(exponent_value);
    for(int n=0;n<TILE;n++) begin
      value=fp_real(word[n*FP_BITS+:FP_BITS])/step;
      if(value>127) code_value=127;
      else if(value< -128) code_value=-128;
      else code_value=round_even(value);
      result[SCALE_BITS+n*ACT_BITS+:ACT_BITS]=ACT_BITS'(code_value);
    end
    return result;
  endfunction
  initial slow_mode=$test$plusargs("STALL");
  assign post_cmd_ready=rst_n && !clear && phase_q==IDLE && (!slow_mode || cycle%7==0);
  assign post_rd_valid=rst_n && !clear && phase_q==READ_ROW && (!slow_mode || cycle%3!=0);
  assign post_rd_row=row_q;
  assign post_result_valid=rst_n && !clear && phase_q==SEND_ROW && (!slow_mode || cycle%5==0);
  always_comb begin
    post_result='0;post_result.job=job_q;post_result.row=row_q;
    post_result.data=quant_q[B_ENTRY_BITS-1:SCALE_BITS];post_result.scale=quant_q[0+:SCALE_BITS];
    post_result.last=row_q==SUFFIX_LEN-1;
    if($test$plusargs("BAD_RESULT")) post_result.job.epoch=job_q.epoch+1'b1;
    if($test$plusargs("BAD_QUANT")) post_result.data[0]=!post_result.data[0];
  end
  assign post_done_valid=rst_n && !clear && (phase_q==FINISH ||
    ($test$plusargs("EARLY_DONE") && phase_q==READ_ROW));
  assign post_done=job_q;
  always @(posedge clk) cycle<=cycle+1;
  always_ff @(posedge clk or negedge rst_n) begin
    if(!rst_n) begin phase_q<=IDLE;row_q<='0;job_q<='0;quant_q<='0;end
    else if(clear) begin phase_q<=IDLE;row_q<='0;job_q<='0;quant_q<='0;end
    else case(phase_q)
      IDLE: if(post_cmd_valid && post_cmd_ready) begin job_q<=post_cmd;row_q<='0;phase_q<=READ_ROW;end
      READ_ROW: if(post_rd_valid && post_rd_ready) phase_q<=WAIT_ROW;
      WAIT_ROW: if(post_rsp_valid) begin quant_q<=quantize(post_rsp_data);phase_q<=SEND_ROW;end
      SEND_ROW: if(post_result_valid && post_result_ready) begin
        if(row_q==SUFFIX_LEN-1) phase_q<=FINISH;
        else begin row_q<=row_q+1'b1;phase_q<=READ_ROW;end
      end
      FINISH: if(post_done_valid && post_done_ready) phase_q<=IDLE;
      default: phase_q<=IDLE;
    endcase
  end
endmodule
