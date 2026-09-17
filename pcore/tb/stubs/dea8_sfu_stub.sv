`timescale 1ns/1ps
import dea8_pcore_pkg::*;
import dea8_job_pkg::*;
import dea8_behavioral_fp_pkg::*;

// SIMULATION ONLY. Default: historical equal-score fixture.
// SOFTMAX_MODEL: EXP and reciprocal from actual PCore memory responses using
// real-number arithmetic. This does not specify the final SFU microarchitecture.
// Port directions match the current PCore client contract. Power-on reset only.
// Replace this model with the owner's RTL for algorithm/numerical signoff.
module dea8_sfu_stub #(
  parameter bit SOFTMAX_MODEL = 0
) (
  input logic clk,rst_n,
  input logic sfu_valid,
  output logic sfu_ready,
  input sfu_job_t sfu_cmd,
  output logic sfu_done_valid,
  input logic sfu_done_ready,
  output sfu_job_t sfu_done,
  output logic sbuf_rd_en,sbuf_rd_bank,
  output logic [ROW_BITS-1:0] sbuf_rd_row,
  input logic sbuf_rsp_valid,
  input logic [DW_VEC-1:0] sbuf_rd_data,
  output logic sfu_m_rd_en,
  output logic [ROW_BITS-1:0] sfu_m_rd_row,
  input logic sfu_m_rsp_valid,
  input fp_t sfu_m_rsp_data,
  output logic sfu_aa_rd_en,sfu_l_rd_en,
  output logic [ROW_BITS-1:0] sfu_aa_rd_base,sfu_l_rd_base,
  output logic [SFU_LANES-1:0] sfu_aa_rd_mask,sfu_l_rd_mask,
  input logic sfu_aa_rsp_valid,sfu_l_rsp_valid,
  input logic [SFU_LANES*FP_BITS-1:0] sfu_aa_rsp_data,sfu_l_rsp_data,
  output logic alpha_wr_en,
  output logic [ROW_BITS-1:0] alpha_wr_base,
  output logic [SFU_LANES-1:0] alpha_wr_mask,
  output logic [SFU_LANES*FP_BITS-1:0] alpha_wr_data,
  output logic recip_wr_en,
  output logic [ROW_BITS-1:0] recip_wr_base,
  output logic [SFU_LANES-1:0] recip_wr_mask,
  output logic [SFU_LANES*FP_BITS-1:0] recip_wr_data,
  output logic sfu_p_valid,
  input logic sfu_p_ready,
  output p_result_t sfu_p_data,
  output integer jobs
);
  always @(negedge rst_n) if(jobs>0) $fatal(1,"SFU fixture supports power-on reset only");
  initial begin
    jobs=0;
    sfu_ready='0;
    sfu_done_valid='0;
    sfu_done='0;
    sbuf_rd_en='0;
    sbuf_rd_bank='0;
    sbuf_rd_row='0;
    sfu_m_rd_en='0;
    sfu_m_rd_row='0;
    sfu_aa_rd_en='0;
    sfu_l_rd_en='0;
    sfu_aa_rd_base='0;
    sfu_l_rd_base='0;
    sfu_aa_rd_mask='0;
    sfu_l_rd_mask='0;
    alpha_wr_en='0;
    alpha_wr_base='0;
    alpha_wr_mask='0;
    alpha_wr_data='0;
    recip_wr_en='0;
    recip_wr_base='0;
    recip_wr_mask='0;
    recip_wr_data='0;
    sfu_p_valid='0;
    sfu_p_data='0;
  end
  initial begin : sfu_model
    logic [DW_VEC-1:0] score_row;
    fp_t row_max;
    logic [SFU_LANES*FP_BITS-1:0] pair_result;
    wait(rst_n);
    forever begin
      @(negedge clk); sfu_ready=1;
      do @(posedge clk); while(!sfu_valid);
      sfu_done=sfu_cmd; jobs++;
      @(negedge clk); sfu_ready=0;
      if(sfu_done.op==SFU_P_EXP) begin
        for(int r=0;r<SUFFIX_LEN;r++) begin
          sbuf_rd_en=1; sbuf_rd_bank=sfu_done.sbuf_bank; sbuf_rd_row=ROW_BITS'(r);
          sfu_m_rd_en=1;sfu_m_rd_row=ROW_BITS'(r);
          @(posedge clk); #1;
          if(!sbuf_rsp_valid || (!SOFTMAX_MODEL && sbuf_rd_data!=={TILE{32'h41800000}})) $fatal(1,"SBUF generation mismatch");
          if(!sfu_m_rsp_valid || (!SOFTMAX_MODEL && sfu_m_rsp_data!=32'h41800000)) $fatal(1,"SFU m read mismatch");
          score_row=sbuf_rd_data;row_max=sfu_m_rsp_data;
          @(negedge clk); sbuf_rd_en=0;sfu_m_rd_en=0;
          for(int pair=0;pair<PAIRS_PER_ROW;pair++) begin
            sfu_p_data='0;sfu_p_data.ctx=sfu_done.ctx;sfu_p_data.row=ROW_BITS'(r);
            sfu_p_data.pair_index=PAIR_BITS'(pair);sfu_p_data.lane_mask='1;
            sfu_p_data.data={SFU_LANES{32'h3f800000}};
            if(SOFTMAX_MODEL) for(int n=0;n<SFU_LANES;n++) begin
              sfu_p_data.data[n*FP_BITS+:FP_BITS]=
                score_row[(pair*SFU_LANES+n)*FP_BITS+:FP_BITS]==32'hff800000 ? 0 :
                sim_exp(real_fp(fp_real(score_row[(pair*SFU_LANES+n)*FP_BITS+:FP_BITS])-fp_real(row_max)));
            end
            sfu_p_data.last=r==SUFFIX_LEN-1 && pair==PAIRS_PER_ROW-1;
            sfu_p_valid=1;
            do @(posedge clk);while(!sfu_p_ready);
            @(negedge clk);sfu_p_valid=0;
          end
        end
      end else begin
        for(int r=0;r<SUFFIX_LEN;r+=SFU_LANES) begin
          if(sfu_done.op==SFU_ALPHA_EXP) begin
            sfu_aa_rd_en=1;sfu_aa_rd_base=ROW_BITS'(r);sfu_aa_rd_mask=r==SUFFIX_LEN-1 ? 2'b01 : 2'b11;
          end else begin sfu_l_rd_en=1;sfu_l_rd_base=ROW_BITS'(r);sfu_l_rd_mask=r==SUFFIX_LEN-1 ? 2'b01 : 2'b11;end
          @(posedge clk);#1;
          for(int n=0;n<SFU_LANES;n++) if(r+n<SUFFIX_LEN) begin
            if(!SOFTMAX_MODEL && sfu_done.op==SFU_ALPHA_EXP && (!sfu_aa_rsp_valid ||
               sfu_aa_rsp_data[n*FP_BITS+:FP_BITS]!=(sfu_done.ctx.block_id==0 ? 32'hff800000 : 32'h0)))
              $fatal(1,"SFU aa pair mismatch");
            if(!SOFTMAX_MODEL && sfu_done.op==SFU_RECIP && (!sfu_l_rsp_valid || sfu_l_rsp_data[n*FP_BITS+:FP_BITS]!=32'h445c0000))
              $fatal(1,"SFU l pair mismatch");
            if(SOFTMAX_MODEL) begin
              if(sfu_done.op==SFU_ALPHA_EXP) begin
                if(!sfu_aa_rsp_valid) $fatal(1,"Missing aa response");
                pair_result[n*FP_BITS+:FP_BITS]=sim_exp(sfu_aa_rsp_data[n*FP_BITS+:FP_BITS]);
              end else begin
                if(!sfu_l_rsp_valid || fp_real(sfu_l_rsp_data[n*FP_BITS+:FP_BITS])<=0.0)
                  $fatal(1,"Invalid l response");
                pair_result[n*FP_BITS+:FP_BITS]=real_fp(1.0/fp_real(sfu_l_rsp_data[n*FP_BITS+:FP_BITS]));
              end
            end
          end
          @(negedge clk);sfu_aa_rd_en=0;sfu_l_rd_en=0;
          if(sfu_done.op==SFU_ALPHA_EXP) begin
            alpha_wr_en=1;alpha_wr_base=ROW_BITS'(r);alpha_wr_mask=r==SUFFIX_LEN-1 ? 2'b01 : 2'b11;
            alpha_wr_data=sfu_done.ctx.block_id==0 ? '0 : {SFU_LANES{32'h3f800000}};
            if(SOFTMAX_MODEL) alpha_wr_data=pair_result;
          end else begin
            recip_wr_en=1;recip_wr_base=ROW_BITS'(r);recip_wr_mask=r==SUFFIX_LEN-1 ? 2'b01 : 2'b11;
            recip_wr_data={SFU_LANES{32'h3a94f209}};
            if(SOFTMAX_MODEL) recip_wr_data=pair_result;
          end
          @(negedge clk);alpha_wr_en=0;recip_wr_en=0;
        end
      end
      sfu_done_valid=1;
      do @(posedge clk); while(!sfu_done_ready);
      @(negedge clk); sfu_done_valid=0;
    end
  end
endmodule
