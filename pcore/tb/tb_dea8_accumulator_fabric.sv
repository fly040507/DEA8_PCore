`timescale 1ns/1ps
import dea8_pcore_pkg::*;
module tb_dea8_accumulator_fabric;
  logic clk=0; always #5 clk=~clk;
  logic rst_n=0;
  logic [2:0] deq_reserved=0;
  logic deq_rd_en=0, deq_wr_en=0, vpu_rd_valid=0, vpu_wr_valid=0;
  logic vpu_rd_ready,vpu_wr_ready,vpu_rsp_valid;
  acc_sel_e deq_rd_sel=ACC_OACC, deq_wr_sel=ACC_OACC;
  acc_sel_e vpu_rd_sel=ACC_FACC_A, vpu_wr_sel=ACC_FACC_A;
  logic [ACC_ADDR_BITS-1:0] deq_rd_addr=0,deq_wr_addr=0,vpu_rd_addr=0,vpu_wr_addr=0;
  logic [DW_VEC-1:0] deq_rd_data,deq_wr_data=0,vpu_rsp_data,vpu_wr_data=0;
  logic [TILE-1:0] deq_wr_lane_en='1,vpu_wr_lane_en='1;
  dea8_accumulator_fabric dut (.*);
  task automatic tick; @(posedge clk); #1; endtask
  initial begin
    repeat(3) @(negedge clk); rst_n=1;
    if($test$plusargs("NO_RESERVATION")) begin
      deq_wr_en=1; tick(); $fatal(1,"Missing reservation assertion");
    end
    deq_reserved=3'b100;
    for(int a=0;a<SUFFIX_LEN;a++) begin
      deq_wr_en=1; deq_wr_addr=ACC_ADDR_BITS'(a); deq_wr_data=DW_VEC'(a+100);
      vpu_wr_valid=1; vpu_wr_addr=ACC_ADDR_BITS'(a); vpu_wr_data=DW_VEC'(a+200);
      tick(); if(!vpu_wr_ready) $fatal(1,"Independent FACC write blocked");
      @(negedge clk);
    end
    deq_wr_en=0; vpu_wr_valid=0;
    for(int a=0;a<SUFFIX_LEN;a++) begin
      deq_rd_en=1; deq_rd_addr=ACC_ADDR_BITS'(a);
      vpu_rd_valid=1; vpu_rd_addr=ACC_ADDR_BITS'(SUFFIX_LEN-1-a);
      tick();
      if(deq_rd_data!==DW_VEC'(a+100) || !vpu_rsp_valid ||
         vpu_rsp_data!==DW_VEC'(SUFFIX_LEN-1-a+200)) $fatal(1,"Parallel read mismatch");
      @(negedge clk);
    end
    deq_rd_en=0; vpu_rd_sel=ACC_OACC; tick();
    if(vpu_rd_ready || vpu_rsp_valid) $fatal(1,"Reserved OACC access not blocked");
    @(negedge clk); deq_reserved=0; tick();
    if(!vpu_rsp_valid || vpu_rsp_data!==DW_VEC'(100)) $fatal(1,"OACC handoff failed");
    @(negedge clk); vpu_rd_valid=0;
    deq_reserved=3'b010; deq_wr_sel=ACC_FACC_B; deq_wr_en=1; deq_wr_addr=0; deq_wr_data=777;
    vpu_rd_valid=1; vpu_rd_sel=ACC_FACC_A; vpu_rd_addr=3; tick();
    if(!vpu_rsp_valid || vpu_rsp_data!==DW_VEC'(203)) $fatal(1,"FACC bank parallelism failed");
    @(negedge clk); deq_wr_en=0; vpu_rd_valid=0;
    deq_reserved=0; vpu_wr_valid=1; vpu_wr_sel=ACC_FACC_A; vpu_wr_addr=3;
    vpu_wr_lane_en='0; vpu_wr_lane_en[1]=1; vpu_wr_data='1; tick();
    @(negedge clk); vpu_wr_valid=0; vpu_rd_valid=1; tick();
    if(vpu_rsp_data[31:0]!==32'd203 || vpu_rsp_data[63:32]!==32'hffffffff ||
       vpu_rsp_data[DW_VEC-1:64]!=='0) $fatal(1,"Lane write mask failed");
    @(negedge clk); rst_n=0; tick();
    if(vpu_rsp_valid || vpu_rd_ready) $fatal(1,"Reset response failed");
    $display("tb_dea8_accumulator_fabric PASS: independent banks, reservation, handoff, lane masks");
    $finish;
  end
endmodule
