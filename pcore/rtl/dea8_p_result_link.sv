import dea8_pcore_pkg::*;
import dea8_job_pkg::*;

// One-entry elastic link. FP32 P is forwarded unchanged; no quantization here.
// A consumer job owns the stream until its final pair is accepted.
module dea8_p_result_link (
  input logic clk,rst_n,init,job_start,job_end,
  input job_context_t job_ctx,
  input logic sfu_p_valid,
  output logic sfu_p_ready,
  input p_result_t sfu_p_data,
  output logic vpu_p_valid,
  input logic vpu_p_ready,
  output p_result_t vpu_p_data
);
  logic active_q,full_q,complete_q;
  job_context_t ctx_q;
  p_result_t data_q;
  logic [ROW_BITS-1:0] row_q;
  logic [PAIR_BITS-1:0] pair_q;
  logic pop,push;
  assign vpu_p_valid=rst_n && !init && full_q;
  assign vpu_p_data=data_q;
  assign pop=vpu_p_valid && vpu_p_ready;
  assign sfu_p_ready=rst_n && !init && active_q && (!full_q || pop) && !(pop && data_q.last);
  assign push=sfu_p_valid && sfu_p_ready;
  always_ff @(posedge clk or negedge rst_n) begin
    if(!rst_n) begin
      active_q<=0;full_q<=0;complete_q<=0;row_q<='0;pair_q<='0;ctx_q<='0;data_q<='0;
    end else if(init) begin active_q<=0;full_q<=0;complete_q<=0;row_q<='0;pair_q<='0;end
    else begin
      if(job_start) begin active_q<=1;complete_q<=0;ctx_q<=job_ctx;row_q<='0;pair_q<='0;end
      if(pop) begin
        full_q<=0;
        if(data_q.last) begin active_q<=0;complete_q<=1;end
        if(pair_q==PAIRS_PER_ROW-1) begin pair_q<='0;row_q<=row_q+1'b1;end
        else pair_q<=pair_q+1'b1;
      end
      if(push) begin data_q<=sfu_p_data;full_q<=1;end
      if(job_end) complete_q<=0;
    end
  end
  // synthesis translate_off
  always @(posedge clk) if(rst_n && !init) begin
    if(job_start && (active_q || full_q)) $fatal(1,"P stream job overlap");
    if(pop && (data_q.ctx!==ctx_q || data_q.row!=row_q || data_q.pair_index!=pair_q ||
       data_q.lane_mask!={SFU_LANES{1'b1}} ||
       data_q.last!=(row_q==SUFFIX_LEN-1 && pair_q==PAIRS_PER_ROW-1))) $fatal(1,"P stream context/order mismatch");
    if(job_end && !(complete_q || (pop && data_q.last))) $fatal(1,"VPU P done before final pair accepted");
  end
  // synthesis translate_on
endmodule
