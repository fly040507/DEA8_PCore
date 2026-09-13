`timescale 1ns/1ps
import dea8_pcore_pkg::*;
import dea8_job_pkg::*;

// SIMULATION ONLY. Equal-score fixture, not a general arithmetic engine.
// Port directions match the current PCore client contract. Power-on reset only.
// Replace this model with the owner's RTL for algorithm/numerical signoff.
module dea8_vpu_stub (
  input logic clk,rst_n,
  input logic vpu_valid,
  output logic vpu_ready,
  input vpu_job_t vpu_cmd,
  output logic vpu_done_valid,
  input logic vpu_done_ready,
  output vpu_job_t vpu_done,
  output logic vpu_rd_valid,
  input logic vpu_rd_ready,
  output acc_sel_e vpu_rd_sel,
  output logic [ACC_ADDR_BITS-1:0] vpu_rd_addr,
  input logic vpu_rsp_valid,
  input logic [DW_VEC-1:0] vpu_rsp_data,
  output logic vpu_wr_valid,
  input logic vpu_wr_ready,
  output acc_sel_e vpu_wr_sel,
  output logic [ACC_ADDR_BITS-1:0] vpu_wr_addr,
  output logic [TILE-1:0] vpu_wr_lane_en,
  output logic [DW_VEC-1:0] vpu_wr_data,
  output logic sbuf_wr_en,sbuf_wr_bank,
  output logic [ROW_BITS-1:0] sbuf_wr_row,
  output logic [DW_VEC-1:0] sbuf_wr_data,
  output logic pbuf_wr_en,pbuf_wr_bank,
  output logic [ROW_BITS-1:0] pbuf_wr_row,
  output logic [DW_ACT-1:0] pbuf_wr_data,
  output logic [SCALE_BITS-1:0] pbuf_wr_scale,
  output logic vpu_m_rd_en,
  output logic [ROW_BITS-1:0] vpu_m_rd_row,
  input logic vpu_m_rsp_valid,
  input fp_t vpu_m_rsp_data,
  output logic vpu_m_aa_wr_en,
  output logic [ROW_BITS-1:0] vpu_m_aa_wr_row,
  output fp_t vpu_m_wr_data,vpu_aa_wr_data,
  output logic vpu_l_rd_en,
  output logic [ROW_BITS-1:0] vpu_l_rd_row,
  input logic vpu_l_rsp_valid,
  input fp_t vpu_l_rsp_data,
  output logic vpu_l_wr_en,
  output logic [ROW_BITS-1:0] vpu_l_wr_row,
  output fp_t vpu_l_wr_data,
  output logic vpu_alpha_rd_en,vpu_alpha_rd_bank,
  output logic [ROW_BITS-1:0] vpu_alpha_rd_row,
  input logic vpu_alpha_rsp_valid,
  input fp_t vpu_alpha_rsp_data,
  output logic vpu_recip_rd_en,
  output logic [ROW_BITS-1:0] vpu_recip_rd_row,
  input logic vpu_recip_rsp_valid,
  input fp_t vpu_recip_rsp_data,
  input logic vpu_p_valid,
  output logic vpu_p_ready,
  input p_result_t vpu_p_data,
  output integer jobs
);
  always @(negedge rst_n) if(jobs>0) $fatal(1,"VPU fixture supports power-on reset only");
  initial begin
    jobs=0;
    vpu_ready='0;
    vpu_done_valid='0;
    vpu_done='0;
    vpu_rd_valid='0;
    vpu_rd_sel=ACC_FACC_A;
    vpu_rd_addr='0;
    vpu_wr_valid='0;
    vpu_wr_sel=ACC_OACC;
    vpu_wr_addr='0;
    vpu_wr_lane_en='0;
    vpu_wr_data='0;
    sbuf_wr_en='0;
    sbuf_wr_bank='0;
    sbuf_wr_row='0;
    sbuf_wr_data='0;
    pbuf_wr_en='0;
    pbuf_wr_bank='0;
    pbuf_wr_row='0;
    pbuf_wr_data='0;
    pbuf_wr_scale='0;
    vpu_m_rd_en='0;
    vpu_m_rd_row='0;
    vpu_m_aa_wr_en='0;
    vpu_m_aa_wr_row='0;
    vpu_m_wr_data='0;
    vpu_aa_wr_data='0;
    vpu_l_rd_en='0;
    vpu_l_rd_row='0;
    vpu_l_wr_en='0;
    vpu_l_wr_row='0;
    vpu_l_wr_data='0;
    vpu_alpha_rd_en='0;
    vpu_alpha_rd_bank='0;
    vpu_alpha_rd_row='0;
    vpu_recip_rd_en='0;
    vpu_recip_rd_row='0;
    vpu_p_ready='0;
    pbuf_wr_data={TILE{8'd1}};pbuf_wr_scale=133;vpu_wr_lane_en='1;
  end
  function automatic fp_t positive_integer_fp(input int value);
    int exponent_value;
    logic [31:0] shifted;
    exponent_value=0;
    for(int i=0;i<31;i++) if(value>>i) exponent_value=i;
    shifted=32'(value) << (23-exponent_value);
    return {1'b0,8'(127+exponent_value),shifted[22:0]};
  endfunction

  initial begin : vpu_model
    wait(rst_n);
    forever begin
      @(negedge clk); vpu_ready=1;
      do @(posedge clk); while(!vpu_valid);
      vpu_done=vpu_cmd; jobs++;
      @(negedge clk); vpu_ready=0;
      case(vpu_done.op)
        VPU_QK_POST: begin
          for(int r=0;r<SUFFIX_LEN;r++) begin
            vpu_rd_valid=1; vpu_rd_sel=vpu_done.facc_bank ? ACC_FACC_B : ACC_FACC_A;
            vpu_rd_addr=ACC_ADDR_BITS'(r);
            do @(posedge clk); while(!vpu_rd_ready);
            #1;
            if(!vpu_rsp_valid || vpu_rsp_data!=={TILE{32'h41800000}}) $fatal(1,"FACC fixture result");
            @(negedge clk); vpu_rd_valid=0;
            sbuf_wr_en=1; sbuf_wr_bank=vpu_done.sbuf_bank; sbuf_wr_row=ROW_BITS'(r); sbuf_wr_data=vpu_rsp_data;
            vpu_m_aa_wr_en=1;vpu_m_aa_wr_row=ROW_BITS'(r);vpu_m_wr_data=32'h41800000;
            vpu_aa_wr_data=vpu_done.ctx.block_id==0 ? 32'hff800000 : 32'h00000000;
            @(negedge clk); sbuf_wr_en=0;vpu_m_aa_wr_en=0;
          end
        end
        VPU_P_POST: begin
          for(int r=0;r<SUFFIX_LEN;r++) begin
            for(int pair=0;pair<PAIRS_PER_ROW;pair++) begin
              vpu_p_ready=1;
              do @(posedge clk); while(!vpu_p_valid);
              if(vpu_p_data.ctx!=vpu_done.ctx || vpu_p_data.row!=r || vpu_p_data.pair_index!=pair ||
                 vpu_p_data.data!={SFU_LANES{32'h3f800000}}) $fatal(1,"P stream fixture mismatch");
              @(negedge clk);vpu_p_ready=0;
            end
            pbuf_wr_en=1; pbuf_wr_bank=vpu_done.pbuf_bank; pbuf_wr_row=ROW_BITS'(r);
            vpu_l_wr_en=1;vpu_l_wr_row=ROW_BITS'(r);
            vpu_l_wr_data=positive_integer_fp((vpu_done.ctx.block_id+1)*TILE);
            vpu_alpha_rd_en=1;vpu_alpha_rd_bank=vpu_done.alpha_bank;vpu_alpha_rd_row=ROW_BITS'(r);
            @(posedge clk);#1;
            if(!vpu_alpha_rsp_valid || vpu_alpha_rsp_data!=(vpu_done.ctx.block_id==0 ? 32'h0 : 32'h3f800000))
              $fatal(1,"Alpha row/generation fixture mismatch");
            @(negedge clk);pbuf_wr_en=0;vpu_l_wr_en=0;vpu_alpha_rd_en=0;
          end
          pbuf_wr_en=0;
        end
        VPU_OACC_SCALE,VPU_AFIN: begin
          for(int a=0;a<OACC_WORDS;a++) begin
            vpu_rd_valid=1; vpu_rd_sel=ACC_OACC; vpu_rd_addr=ACC_ADDR_BITS'(a);
            if(vpu_done.op==VPU_OACC_SCALE) begin
              vpu_alpha_rd_en=1;vpu_alpha_rd_bank=vpu_done.alpha_bank;vpu_alpha_rd_row=ROW_BITS'(a/HEAD_TILES);
            end else begin vpu_recip_rd_en=1;vpu_recip_rd_row=ROW_BITS'(a/HEAD_TILES);end
            do @(posedge clk); while(!vpu_rd_ready);
            #1; if(!vpu_rsp_valid) $fatal(1,"OACC response missing");
            if(vpu_done.op==VPU_OACC_SCALE && (!vpu_alpha_rsp_valid || vpu_alpha_rsp_data!=32'h3f800000))
              $fatal(1,"SCALE alpha generation mismatch");
            if(vpu_done.op==VPU_AFIN && (!vpu_recip_rsp_valid || vpu_recip_rsp_data!=32'h3a94f209))
              $fatal(1,"AFIN reciprocal fixture mismatch");
            if(vpu_done.op==VPU_AFIN && vpu_rsp_data!=={TILE{32'h445c0000}})
              $fatal(1,"Final fixture OACC must be 55 * 16 = 880");
            @(negedge clk); vpu_rd_valid=0;vpu_alpha_rd_en=0;vpu_recip_rd_en=0;
            if(vpu_done.op==VPU_OACC_SCALE) begin
              vpu_wr_valid=1; vpu_wr_addr=ACC_ADDR_BITS'(a); vpu_wr_data=vpu_rsp_data;
              do @(posedge clk); while(!vpu_wr_ready);
              @(negedge clk); vpu_wr_valid=0;
            end
          end
        end
        default: $fatal(1,"Unexpected VPU fixture op");
      endcase
      vpu_done_valid=1;
      do @(posedge clk); while(!vpu_done_ready);
      @(negedge clk); vpu_done_valid=0;
    end
  end
endmodule
