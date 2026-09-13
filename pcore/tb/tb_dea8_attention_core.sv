`timescale 1ns/1ps
import dea8_pcore_pkg::*;
import dea8_job_pkg::*;
module tb_dea8_attention_core;
  logic clk=0; always #5 clk=~clk;
  logic rst_n=0,start_valid=0,resources_ready=1,start_ready,busy,done_valid,done_ready=0,matrix_busy;
  logic [HEAD_BITS-1:0] start_head=1;
  logic [EPOCH_BITS-1:0] start_epoch=2;
  matrix_job_t current_job;
  logic b_valid=1,b_ready;
  logic [DW_ACT-1:0] b_data={TILE{8'd1}};
  logic [SCALE_BITS-1:0] b_scale=133;
  logic qoz_wr_en=0;
  logic [QOZ_ADDR_BITS-1:0] qoz_wr_addr=0;
  logic [DW_ACT-1:0] qoz_wr_data={TILE{8'd1}};
  logic [SCALE_BITS-1:0] qoz_wr_scale=133;
  logic vpu_valid,vpu_ready,vpu_done_valid,vpu_done_ready;
  vpu_job_t vpu_cmd,vpu_done;
  logic sfu_valid,sfu_ready,sfu_done_valid,sfu_done_ready;
  sfu_job_t sfu_cmd,sfu_done;
  logic vpu_rd_valid,vpu_rd_ready,vpu_rsp_valid,vpu_wr_valid,vpu_wr_ready;
  acc_sel_e vpu_rd_sel,vpu_wr_sel;
  logic [ACC_ADDR_BITS-1:0] vpu_rd_addr,vpu_wr_addr;
  logic [DW_VEC-1:0] vpu_rsp_data,vpu_wr_data;
  logic [TILE-1:0] vpu_wr_lane_en;
  logic sbuf_wr_en,sbuf_wr_bank,sbuf_rd_en,sbuf_rd_bank,sbuf_rsp_valid;
  logic [ROW_BITS-1:0] sbuf_wr_row,sbuf_rd_row;
  logic [DW_VEC-1:0] sbuf_wr_data,sbuf_rd_data;
  logic pbuf_wr_en,pbuf_wr_bank;
  logic [ROW_BITS-1:0] pbuf_wr_row;
  logic [DW_ACT-1:0] pbuf_wr_data;
  logic [SCALE_BITS-1:0] pbuf_wr_scale;
  logic vpu_m_rd_en,vpu_m_rsp_valid,vpu_m_aa_wr_en,vpu_l_rd_en,vpu_l_rsp_valid,vpu_l_wr_en;
  logic [ROW_BITS-1:0] vpu_m_rd_row,vpu_m_aa_wr_row,vpu_l_rd_row,vpu_l_wr_row;
  fp_t vpu_m_rsp_data,vpu_m_wr_data,vpu_aa_wr_data,vpu_l_rsp_data,vpu_l_wr_data;
  logic sfu_m_rd_en,sfu_m_rsp_valid,sfu_aa_rd_en,sfu_l_rd_en,sfu_aa_rsp_valid,sfu_l_rsp_valid;
  logic [ROW_BITS-1:0] sfu_m_rd_row,sfu_aa_rd_base,sfu_l_rd_base;
  logic [SFU_LANES-1:0] sfu_aa_rd_mask,sfu_l_rd_mask;
  fp_t sfu_m_rsp_data;
  logic [SFU_LANES*FP_BITS-1:0] sfu_aa_rsp_data,sfu_l_rsp_data;
  logic alpha_wr_en,vpu_alpha_rd_en,vpu_alpha_rd_bank,vpu_alpha_rsp_valid;
  logic [ROW_BITS-1:0] alpha_wr_base,vpu_alpha_rd_row;
  logic [SFU_LANES-1:0] alpha_wr_mask;
  logic [SFU_LANES*FP_BITS-1:0] alpha_wr_data;
  fp_t vpu_alpha_rsp_data;
  logic recip_wr_en,vpu_recip_rd_en,vpu_recip_rsp_valid;
  logic [ROW_BITS-1:0] recip_wr_base,vpu_recip_rd_row;
  logic [SFU_LANES-1:0] recip_wr_mask;
  logic [SFU_LANES*FP_BITS-1:0] recip_wr_data;
  fp_t vpu_recip_rsp_data;
  logic sfu_p_valid,sfu_p_ready,vpu_p_valid,vpu_p_ready;
  p_result_t sfu_p_data,vpu_p_data;
  logic commit_valid;
  pipe_tag_t commit_tag;
  deq_dest_t commit_dest;
  int qk_commits=0,pv_commits=0,vpu_jobs,sfu_jobs;
  dea8_attention_core dut (.*);
  // Controlled fixture: all Q/K/V/P codes are one with scale=133.
  // VPU/SFU models move real RAM data, but do NOT implement the operators.
  // SCALE is identity and no general mask/quantization occurs. Scalar and P
  // fixtures are exact for these equal-score inputs, not implementations of EXP.
  dea8_vpu_stub vpu_model (.jobs(vpu_jobs),.*);
  dea8_sfu_stub sfu_model (.jobs(sfu_jobs),.*);
  always @(posedge clk) if(rst_n && dut.mem_wr_en) begin
    if(current_job.op==MATRIX_QK) qk_commits++;
    else pv_commits++;
  end
  initial begin
    repeat(3) @(negedge clk); rst_n=1;
    for(int r=0;r<SUFFIX_LEN;r++) for(int t=0;t<HEAD_TILES;t++) begin
      qoz_wr_en=1; qoz_wr_addr=QOZ_ADDR_BITS'(r*QOZ_TILES+t);
      @(negedge clk);
    end
    qoz_wr_en=0; start_valid=1;
    do @(posedge clk); while(!start_ready);
    @(negedge clk); start_valid=0;
    wait(done_valid);
    if(qk_commits!=N_KV_BLOCK*SUFFIX_LEN*HEAD_TILES || pv_commits!=qk_commits ||
       vpu_jobs!=N_KV_BLOCK*3 || sfu_jobs!=N_KV_BLOCK*2+1) $fatal(1,"Integrated job counts");
    $display("tb_dea8_attention_core PASS: 55 QK/PV real matrix jobs; RAM clients use non-arithmetic fixtures");
    $finish;
  end
  initial begin #5000000; $fatal(1,"Attention core timeout"); end
endmodule
