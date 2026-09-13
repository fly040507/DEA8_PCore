`timescale 1ns/1ps
import dea8_pcore_pkg::*;
import dea8_job_pkg::*;
module tb_dea8_attention_state;
  logic clk,rst_n,init;
  logic vpu_m_rd_en;
  logic [ROW_BITS-1:0] vpu_m_rd_row;
  logic vpu_m_rsp_valid;
  fp_t vpu_m_rsp_data;
  logic vpu_m_aa_wr_en;
  logic [ROW_BITS-1:0] vpu_m_aa_wr_row;
  fp_t vpu_m_wr_data,vpu_aa_wr_data;
  logic vpu_l_rd_en;
  logic [ROW_BITS-1:0] vpu_l_rd_row;
  logic vpu_l_rsp_valid;
  fp_t vpu_l_rsp_data;
  logic vpu_l_wr_en;
  logic [ROW_BITS-1:0] vpu_l_wr_row;
  fp_t vpu_l_wr_data;
  logic sfu_m_rd_en;
  logic [ROW_BITS-1:0] sfu_m_rd_row;
  logic sfu_m_rsp_valid;
  fp_t sfu_m_rsp_data;
  logic sfu_aa_rd_en,sfu_l_rd_en;
  logic [ROW_BITS-1:0] sfu_aa_rd_base,sfu_l_rd_base;
  logic [SFU_LANES-1:0] sfu_aa_rd_mask,sfu_l_rd_mask;
  logic sfu_aa_rsp_valid,sfu_l_rsp_valid;
  logic [SFU_LANES*FP_BITS-1:0] sfu_aa_rsp_data,sfu_l_rsp_data;
  logic alpha_begin,alpha_begin_bank;
  job_context_t alpha_begin_ctx;
  logic alpha_end;
  logic alpha_wr_en;
  logic [ROW_BITS-1:0] alpha_wr_base;
  logic [SFU_LANES-1:0] alpha_wr_mask;
  logic [SFU_LANES*FP_BITS-1:0] alpha_wr_data;
  logic vpu_alpha_rd_en,vpu_alpha_rd_bank;
  logic [ROW_BITS-1:0] vpu_alpha_rd_row;
  job_context_t vpu_alpha_rd_ctx;
  logic vpu_alpha_rsp_valid;
  fp_t vpu_alpha_rsp_data;
  logic alpha_l_done,alpha_scale_done,alpha_done_bank;
  job_context_t alpha_done_ctx;
  logic [BANK_COUNT-1:0] alpha_ready;
  logic recip_begin,recip_end,recip_wr_en;
  logic [ROW_BITS-1:0] recip_wr_base;
  logic [SFU_LANES-1:0] recip_wr_mask;
  logic [SFU_LANES*FP_BITS-1:0] recip_wr_data;
  logic vpu_recip_rd_en;
  logic [ROW_BITS-1:0] vpu_recip_rd_row;
  logic vpu_recip_rsp_valid;
  fp_t vpu_recip_rsp_data;
  always #5 clk=~clk;
  dea8_attention_state dut (.*);
  task automatic tick; @(posedge clk); #1; endtask
  task automatic begin_alpha(input logic bank,input int generation);
    alpha_begin_bank=bank;alpha_begin_ctx='{block_id:BLOCK_BITS'(generation),head:3'd2,epoch:4'd6};
    alpha_begin=1;tick();@(negedge clk);alpha_begin=0;
  endtask
  task automatic fill_alpha(input int salt);
    for(int r=0;r<SUFFIX_LEN;r+=SFU_LANES) begin
      alpha_wr_en=1;alpha_wr_base=ROW_BITS'(r);alpha_wr_mask=r==SUFFIX_LEN-1 ? 2'b01 : 2'b11;
      alpha_wr_data={32'(salt+r+1),32'(salt+r)};
      tick();@(negedge clk);alpha_wr_en=0;
    end
    alpha_end=1;tick();@(negedge clk);alpha_end=0;
  endtask
  initial begin
    clk=0;
    rst_n='0;
    init='0;
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
    sfu_m_rd_en='0;
    sfu_m_rd_row='0;
    sfu_aa_rd_en='0;
    sfu_l_rd_en='0;
    sfu_aa_rd_base='0;
    sfu_l_rd_base='0;
    sfu_aa_rd_mask='0;
    sfu_l_rd_mask='0;
    alpha_begin='0;
    alpha_begin_bank='0;
    alpha_begin_ctx='0;
    alpha_end='0;
    alpha_wr_en='0;
    alpha_wr_base='0;
    alpha_wr_mask='0;
    alpha_wr_data='0;
    vpu_alpha_rd_en='0;
    vpu_alpha_rd_bank='0;
    vpu_alpha_rd_row='0;
    vpu_alpha_rd_ctx='0;
    alpha_l_done='0;
    alpha_scale_done='0;
    alpha_done_bank='0;
    alpha_done_ctx='0;
    recip_begin='0;
    recip_end='0;
    recip_wr_en='0;
    recip_wr_base='0;
    recip_wr_mask='0;
    recip_wr_data='0;
    vpu_recip_rd_en='0;
    vpu_recip_rd_row='0;
    repeat(3) @(negedge clk);rst_n=1;init=1;tick();@(negedge clk);init=0;
    vpu_m_rd_en=1;vpu_l_rd_en=1;tick();
    if(!vpu_m_rsp_valid || vpu_m_rsp_data!==32'hff800000 || !vpu_l_rsp_valid || vpu_l_rsp_data!==0)
      $fatal(1,"Scalar initialization");
    @(negedge clk);vpu_m_rd_en=0;vpu_l_rd_en=0;
    for(int r=0;r<SUFFIX_LEN;r++) begin
      vpu_m_aa_wr_en=1;vpu_m_aa_wr_row=ROW_BITS'(r);
      vpu_m_wr_data=32'h41000000+r;vpu_aa_wr_data=32'hbf000000+r;
      vpu_l_wr_en=1;vpu_l_wr_row=ROW_BITS'(r);vpu_l_wr_data=32'h42000000+r;
      tick();@(negedge clk);
    end
    vpu_m_aa_wr_en=0;vpu_l_wr_en=0;
    for(int r=0;r<SUFFIX_LEN;r+=SFU_LANES) begin
      sfu_aa_rd_en=1;sfu_l_rd_en=1;sfu_aa_rd_base=ROW_BITS'(r);sfu_l_rd_base=ROW_BITS'(r);
      sfu_aa_rd_mask=r==SUFFIX_LEN-1 ? 2'b01 : 2'b11;sfu_l_rd_mask=sfu_aa_rd_mask;
      if($test$plusargs("BAD_MASK") && r==SUFFIX_LEN-1) sfu_aa_rd_mask=2'b11;
      tick();
      for(int n=0;n<SFU_LANES;n++) begin
        if(sfu_aa_rsp_data[n*FP_BITS+:FP_BITS] !== (r+n<SUFFIX_LEN ? 32'hbf000000+r+n : 32'b0) ||
           sfu_l_rsp_data[n*FP_BITS+:FP_BITS] !== (r+n<SUFFIX_LEN ? 32'h42000000+r+n : 32'b0))
          $fatal(1,"Scalar pair response mismatch");
      end
      @(negedge clk);
    end
    sfu_aa_rd_en=0;sfu_l_rd_en=0;
    begin_alpha(0,1);
    if($test$plusargs("EARLY_ALPHA")) begin alpha_end=1;tick();$fatal(1,"Missing early completion assertion");end
    fill_alpha(100);
    begin_alpha(1,2);fill_alpha(200);
    vpu_alpha_rd_ctx='{block_id:6'd1,head:3'd2,epoch:4'd6};vpu_alpha_rd_bank=0;
    for(int r=0;r<SUFFIX_LEN;r++) begin
      vpu_alpha_rd_en=1;vpu_alpha_rd_row=ROW_BITS'(r);tick();
      if(!vpu_alpha_rsp_valid || vpu_alpha_rsp_data!==32'(100+r)) $fatal(1,"Alpha two-bank isolation");
      @(negedge clk);
    end
    vpu_alpha_rd_en=0;alpha_done_bank=0;alpha_done_ctx=vpu_alpha_rd_ctx;
    alpha_l_done=1;tick();@(negedge clk);alpha_l_done=0;
    if(!alpha_ready[0]) $fatal(1,"Alpha released before OACC consumer");
    if($test$plusargs("OVERWRITE")) begin begin_alpha(0,3);$fatal(1,"Missing overwrite assertion");end
    alpha_scale_done=1;tick();@(negedge clk);alpha_scale_done=0;
    if(alpha_ready[0] || !alpha_ready[1]) $fatal(1,"Alpha release affected wrong bank");
    begin_alpha(0,3);fill_alpha(300);
    recip_begin=1;tick();@(negedge clk);recip_begin=0;
    for(int r=0;r<SUFFIX_LEN;r+=SFU_LANES) begin
      recip_wr_en=1;recip_wr_base=ROW_BITS'(r);recip_wr_mask=r==SUFFIX_LEN-1 ? 2'b01 : 2'b11;
      recip_wr_data={32'(401+r),32'(400+r)};
      tick();@(negedge clk);recip_wr_en=0;
    end
    recip_end=1;tick();@(negedge clk);recip_end=0;
    vpu_recip_rd_en=1;vpu_recip_rd_row=ROW_BITS'(SUFFIX_LEN-1);tick();
    if(!vpu_recip_rsp_valid || vpu_recip_rsp_data!==32'(400+SUFFIX_LEN-1)) $fatal(1,"Reciprocal RF mismatch");
    @(negedge clk);rst_n=0;tick();
    if(alpha_ready || vpu_recip_rsp_valid || vpu_alpha_rsp_valid) $fatal(1,"Scalar reset valid");
    $display("tb_dea8_attention_state PASS: scalar pairs, two consumers, generation reuse, reciprocal and reset");
    $finish;
  end
endmodule
