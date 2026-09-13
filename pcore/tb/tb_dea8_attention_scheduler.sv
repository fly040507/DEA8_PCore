`timescale 1ns/1ps
import dea8_pcore_pkg::*;
import dea8_job_pkg::*;
module tb_dea8_attention_scheduler;
  logic clk=0; always #5 clk=~clk;
  logic rst_n=0, start_valid=0, start_ready, busy, done_valid, done_ready=0;
  logic [HEAD_BITS-1:0] start_head=3;
  logic [EPOCH_BITS-1:0] start_epoch=7;
  logic matrix_valid, matrix_ready, matrix_done_valid=0, matrix_done_ready;
  logic vpu_valid, vpu_ready, vpu_done_valid=0, vpu_done_ready;
  logic sfu_valid, sfu_ready, sfu_done_valid=0, sfu_done_ready;
  matrix_job_t matrix_cmd, matrix_done;
  vpu_job_t vpu_cmd, vpu_done;
  sfu_job_t sfu_cmd, sfu_done;
  int cycle=0, mt=0, vt=0, st=0, qk_count=0, pv_count=0;
  int post_count=0, alpha_count=0, p_count=0, scale_count=0, final_count=0, recip_count=0;
  bit qk_done_bits[0:N_KV_BLOCK-1], p_done_bits[0:N_KV_BLOCK-1];
  bit pv_done_bits[0:N_KV_BLOCK-1], scale_done_bits[0:N_KV_BLOCK-1];
  bit alpha_done_bits[0:N_KV_BLOCK-1];
  bit wrong_context;
  matrix_job_t held_matrix;
  vpu_job_t held_vpu;
  sfu_job_t held_sfu;
  bit mstall=0, vstall=0, sstall=0;
  bit m_consumed=0, v_consumed=0, s_consumed=0;
  dea8_attention_scheduler dut (.*);
  assign matrix_ready = mt==0 && !matrix_done_valid && cycle%13 != 0;
  assign vpu_ready = vt==0 && !vpu_done_valid && cycle%7 != 0;
  assign sfu_ready = st==0 && !sfu_done_valid && cycle%5 != 0;

  // Models deliberately complete on different cycles. They model control only,
  // not VPU/SFU arithmetic or the RAM side effects of those engines.
  always @(posedge clk) if (rst_n) begin
    m_consumed=matrix_done_valid && matrix_done_ready;
    v_consumed=vpu_done_valid && vpu_done_ready;
    s_consumed=sfu_done_valid && sfu_done_ready;
    if (m_consumed) begin
      if (matrix_done.op==MATRIX_QK) qk_done_bits[matrix_done.ctx.block_id]=1;
      else pv_done_bits[matrix_done.ctx.block_id]=1;
    end
    if (v_consumed) begin
      if (vpu_done.op==VPU_P_POST) p_done_bits[vpu_done.ctx.block_id]=1;
      if (vpu_done.op==VPU_OACC_SCALE) scale_done_bits[vpu_done.ctx.block_id]=1;
    end
    if (s_consumed && sfu_done.op==SFU_ALPHA_EXP) alpha_done_bits[sfu_done.ctx.block_id]=1;
    if (mstall && (!matrix_valid || matrix_cmd !== held_matrix)) $fatal(1,"Matrix command unstable");
    if (vstall && (!vpu_valid || vpu_cmd !== held_vpu)) $fatal(1,"VPU command unstable");
    if (sstall && (!sfu_valid || sfu_cmd !== held_sfu)) $fatal(1,"SFU command unstable");
    mstall=matrix_valid && !matrix_ready; held_matrix=matrix_cmd;
    vstall=vpu_valid && !vpu_ready; held_vpu=vpu_cmd;
    sstall=sfu_valid && !sfu_ready; held_sfu=sfu_cmd;
  end
  always @(negedge clk) if (rst_n) begin
    cycle++;
    if (m_consumed) matrix_done_valid=0;
    if (v_consumed) vpu_done_valid=0;
    if (s_consumed) sfu_done_valid=0;
    if (mt>0) begin mt--; if(mt==0) matrix_done_valid=1; end
    if (vt>0) begin vt--; if(vt==0) vpu_done_valid=1; end
    if (st>0) begin st--; if(st==0) sfu_done_valid=1; end
  end
  always @(posedge clk) if (rst_n) begin
    if(matrix_valid && matrix_ready) begin
      if(matrix_cmd.ctx.head!=start_head || matrix_cmd.ctx.epoch!=start_epoch)
        $fatal(1,"Matrix job context lost");
      if(matrix_cmd.op==MATRIX_QK) begin
        if(matrix_cmd.ctx.block_id!=qk_count) $fatal(1,"QK order");
        if(qk_count>1 && !pv_done_bits[qk_count-2]) $fatal(1,"QK before previous PV commit");
        qk_count++;
      end else begin
        if(matrix_cmd.ctx.block_id!=pv_count || !p_done_bits[pv_count]) $fatal(1,"PV before P ready");
        if(pv_count>0 && !scale_done_bits[pv_count]) $fatal(1,"PV before scale writeback");
        if(matrix_cmd.init_oacc!=(pv_count==0)) $fatal(1,"PV clear policy");
        pv_count++;
      end
      matrix_done=matrix_cmd; mt=MATRIX_BLOCK_CYCLES+PIPE_DRAIN;
      if(wrong_context) matrix_done.ctx.epoch=0;
    end
    if(vpu_valid && vpu_ready) begin
      vpu_done=vpu_cmd; vt=13;
      case(vpu_cmd.op)
        VPU_QK_POST: begin
          if(!qk_done_bits[vpu_cmd.ctx.block_id]) $fatal(1,"FACC consumed before commit");
          post_count++; vt=SUFFIX_LEN+7;
        end
        VPU_P_POST: begin
          if(!alpha_done_bits[vpu_cmd.ctx.block_id]) $fatal(1,"P post before alpha");
          vt=SUFFIX_LEN*TILE/2+80; p_count++;
        end
        VPU_OACC_SCALE: begin
          if(vpu_cmd.ctx.block_id==0 || !pv_done_bits[vpu_cmd.ctx.block_id-1] ||
             !alpha_done_bits[vpu_cmd.ctx.block_id]) $fatal(1,"Scale dependency");
          vt=OACC_WORDS+7; scale_count++;
        end
        VPU_AFIN: begin
          if(!pv_done_bits[N_KV_BLOCK-1] || recip_count!=1) $fatal(1,"AFIN before tail");
          final_count++; vt=OACC_WORDS+7;
        end
        default: $fatal(1,"Unexpected VPU operation");
      endcase
    end
    if(sfu_valid && sfu_ready) begin
      sfu_done=sfu_cmd;
      case(sfu_cmd.op)
        SFU_ALPHA_EXP: begin st=(SUFFIX_LEN+1)/2+9; alpha_count++; end
        SFU_P_EXP: begin
          if(vpu_done.op!=VPU_P_POST || vpu_done.ctx!=sfu_cmd.ctx || vt==0)
            $fatal(1,"SFU producer started without consumer");
          st=SUFFIX_LEN*TILE/2+9;
        end
        SFU_RECIP: begin
          if(!pv_done_bits[N_KV_BLOCK-1]) $fatal(1,"Reciprocal before PV54 commit");
          st=(SUFFIX_LEN+1)/2+9; recip_count++;
        end
      endcase
    end
  end
  initial begin
    wrong_context=$test$plusargs("BAD_CONTEXT");
    repeat(3) @(negedge clk); rst_n=1;
    @(negedge clk); start_valid=1;
    @(negedge clk); start_valid=0;
    wait(done_valid);
    if(qk_count!=N_KV_BLOCK || pv_count!=N_KV_BLOCK || post_count!=N_KV_BLOCK ||
       p_count!=N_KV_BLOCK || alpha_count!=N_KV_BLOCK || scale_count!=N_KV_BLOCK-1 ||
       final_count!=1 || recip_count!=1) $fatal(1,"Job counts incorrect");
    repeat(5) begin @(negedge clk); if(!done_valid || start_ready) $fatal(1,"Completion not held"); end
    done_ready=1; @(negedge clk); done_ready=0;
    if(!start_ready) $fatal(1,"Scheduler did not return idle");
    $display("tb_dea8_attention_scheduler PASS: 55 QK, 55 PV, 54 scale; delayed completions and backpressure");
    $finish;
  end
  initial begin #2000000; $fatal(1,"Scheduler timeout"); end
endmodule
