`timescale 1ns/1ps
import dea8_pcore_pkg::*;
import dea8_job_pkg::*;

// SIMULATION ONLY. Equal-score fixture, not a general arithmetic engine.
// Port directions match the current PCore client contract. Power-on reset only.
// Replace this model with the owner's RTL for algorithm/numerical signoff.
module dea8_sfu_stub (
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
          if(!sbuf_rsp_valid || sbuf_rd_data!=={TILE{32'h41800000}}) $fatal(1,"SBUF generation mismatch");
          if(!sfu_m_rsp_valid || sfu_m_rsp_data!=32'h41800000) $fatal(1,"SFU m read mismatch");
          @(negedge clk); sbuf_rd_en=0;sfu_m_rd_en=0;
          for(int pair=0;pair<PAIRS_PER_ROW;pair++) begin
            sfu_p_data='0;sfu_p_data.ctx=sfu_done.ctx;sfu_p_data.row=ROW_BITS'(r);
            sfu_p_data.pair_index=PAIR_BITS'(pair);sfu_p_data.lane_mask='1;
            sfu_p_data.data={SFU_LANES{32'h3f800000}};
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
            if(sfu_done.op==SFU_ALPHA_EXP && (!sfu_aa_rsp_valid ||
               sfu_aa_rsp_data[n*FP_BITS+:FP_BITS]!=(sfu_done.ctx.block_id==0 ? 32'hff800000 : 32'h0)))
              $fatal(1,"SFU aa pair mismatch");
            if(sfu_done.op==SFU_RECIP && (!sfu_l_rsp_valid || sfu_l_rsp_data[n*FP_BITS+:FP_BITS]!=32'h445c0000))
              $fatal(1,"SFU l pair mismatch");
          end
          @(negedge clk);sfu_aa_rd_en=0;sfu_l_rd_en=0;
          if(sfu_done.op==SFU_ALPHA_EXP) begin
            alpha_wr_en=1;alpha_wr_base=ROW_BITS'(r);alpha_wr_mask=r==SUFFIX_LEN-1 ? 2'b01 : 2'b11;
            alpha_wr_data=sfu_done.ctx.block_id==0 ? '0 : {SFU_LANES{32'h3f800000}};
          end else begin
            recip_wr_en=1;recip_wr_base=ROW_BITS'(r);recip_wr_mask=r==SUFFIX_LEN-1 ? 2'b01 : 2'b11;
            recip_wr_data={SFU_LANES{32'h3a94f209}};
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
