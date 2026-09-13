`timescale 1ns/1ps
import dea8_pcore_pkg::*;
module tb_dea8_attention_buffers;
  logic clk=0; always #5 clk=~clk;
  logic rst_n=0;
  logic sbuf_wr_en=0,sbuf_wr_bank=0,sbuf_rd_en=0,sbuf_rd_bank=0,sbuf_rsp_valid;
  logic pbuf_wr_en=0,pbuf_wr_bank=0,pbuf_rd_en=0,pbuf_rd_bank=0,pbuf_rsp_valid;
  logic [ROW_BITS-1:0] sbuf_wr_row=0,sbuf_rd_row=0,pbuf_wr_row=0,pbuf_rd_row=0;
  logic [DW_VEC-1:0] sbuf_wr_data=0,sbuf_rd_data;
  logic [DW_ACT-1:0] pbuf_wr_data=0,pbuf_rd_data;
  logic [SCALE_BITS-1:0] pbuf_wr_scale=0,pbuf_rd_scale;
  dea8_attention_buffers dut (.*);
  task automatic tick; @(posedge clk); #1; endtask
  initial begin
    repeat(3) @(negedge clk); rst_n=1;
    for(int r=0;r<SUFFIX_LEN;r++) begin
      sbuf_wr_en=1; pbuf_wr_en=1;
      sbuf_wr_row=ROW_BITS'(r); pbuf_wr_row=ROW_BITS'(r);
      sbuf_wr_data=DW_VEC'(r+11); pbuf_wr_data=DW_ACT'(r+22); pbuf_wr_scale=SCALE_BITS'(r+100);
      tick(); @(negedge clk);
    end
    sbuf_wr_bank=1; pbuf_wr_bank=1;
    sbuf_rd_en=1; pbuf_rd_en=1;
    if($test$plusargs("BANK_CONFLICT")) pbuf_rd_bank=1;
    for(int r=0;r<SUFFIX_LEN;r++) begin
      sbuf_rd_row=ROW_BITS'(r); pbuf_rd_row=ROW_BITS'(r);
      sbuf_wr_row=ROW_BITS'(SUFFIX_LEN-1-r); pbuf_wr_row=ROW_BITS'(SUFFIX_LEN-1-r);
      sbuf_wr_data=DW_VEC'(r+33); pbuf_wr_data=DW_ACT'(r+44); pbuf_wr_scale=SCALE_BITS'(r+150);
      tick();
      if(!sbuf_rsp_valid || !pbuf_rsp_valid || sbuf_rd_data!==DW_VEC'(r+11) ||
         pbuf_rd_data!==DW_ACT'(r+22) || pbuf_rd_scale!==SCALE_BITS'(r+100))
        $fatal(1,"Concurrent ping-pong read/write mismatch");
      @(negedge clk);
    end
    sbuf_wr_en=0; pbuf_wr_en=0; sbuf_rd_bank=1; pbuf_rd_bank=1;
    for(int r=0;r<SUFFIX_LEN;r++) begin
      sbuf_rd_row=ROW_BITS'(SUFFIX_LEN-1-r); pbuf_rd_row=ROW_BITS'(SUFFIX_LEN-1-r);
      tick();
      if(sbuf_rd_data!==DW_VEC'(r+33) || pbuf_rd_data!==DW_ACT'(r+44) ||
         pbuf_rd_scale!==SCALE_BITS'(r+150)) $fatal(1,"PBUF data/scale pairing mismatch");
      @(negedge clk);
    end
    rst_n=0; tick(); if(sbuf_rsp_valid || pbuf_rsp_valid) $fatal(1,"Reset valid");
    $display("tb_dea8_attention_buffers PASS: independent addresses and paired P scales");
    $finish;
  end
endmodule
