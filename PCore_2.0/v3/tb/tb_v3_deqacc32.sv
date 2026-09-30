`timescale 1ns/1ps
import pcore3_pkg::*;
import fp32_legacy_ref_pkg::*;

module tb_v3_deqacc32;
  logic clk=0; always #2 clk=~clk;
  logic reset=1,clear=0,rsp_valid;
  mxu_rsp_t rsp;
  logic commit_valid,done; pair_meta_t commit_meta;
  logic result_rd_data_valid; logic [15:0][31:0] result_even_data,result_odd_data;
  logic dbg_valid,dbg_parity; acc_sel_e dbg_sel; logic [9:0] dbg_addr; logic [3:0] dbg_lane; logic [31:0] dbg_data;
  int commits,cycle_no,first_rsp_cycle,first_commit_cycle;
  function automatic logic [31:0] even_one(input int lane,input int exponent);
    return pack_scaled32(0,(16+lane)<<27,exponent,0,0);
  endfunction
  function automatic logic [31:0] odd_one(input int lane,input int exponent);
    return pack_scaled32(0,(32+lane)<<26,exponent,0,0);
  endfunction
  DEQACC_3_3ns dut(.clk,.reset,.clear,.rsp_valid,.rsp,.commit_valid,.done,.commit_meta,
    .vpu_wr_valid(1'b0),.vpu_wr('0),.vpu_wr_ready(),.result_rd_ready(),
    .result_rd_owner(ACC_READ_DEQACC),.result_rd_valid(1'b0),.result_rd_sel(ACC_FACC_A),
    .result_rd_addr(10'b0),.result_rd_data_valid,.result_even_data,.result_odd_data,
    .dbg_valid,.dbg_sel,.dbg_parity,.dbg_addr,.dbg_lane,.dbg_data);

  task automatic drive_one(input acc_sel_e sel,input int pair,input int nt,
                           input logic clear_acc,input logic last_flag);
    begin
      @(negedge clk); rsp_valid=1; rsp='0; rsp.row_valid=row_mask(pair);
      rsp.e_stream[0]=128; rsp.e_stream[1]=128;
      for(int n=0;n<16;n++) begin
        rsp.e_stat[n]=128;
        rsp.psum[0][n]=32'sd16+n; rsp.psum[1][n]=32'sd32+n;
      end
      rsp.meta.epoch=1; rsp.meta.head=0; rsp.meta.tile_idx=0;
      rsp.meta.pair_idx=pair; rsp.meta.nt=nt; rsp.meta.final_k=1;
      rsp.meta.last=last_flag; rsp.meta.exp_fold=0;
      rsp.meta.acc_sel=sel; rsp.meta.add_old=!clear_acc;
      @(posedge clk); @(negedge clk); rsp_valid=0;
    end
  endtask

  // Sample after NBA updates; commit_valid is the registered commit output.
  always @(posedge clk) begin
    #1;
    if(rsp_valid&&first_rsp_cycle<0) first_rsp_cycle=cycle_no;
    if(commit_valid) begin
      commits++;
      if(first_commit_cycle<0) first_commit_cycle=cycle_no;
    end
    cycle_no++;
  end
  initial begin
    rsp_valid=0;commits=0;cycle_no=0;first_rsp_cycle=-1;first_commit_cycle=-1;
    dbg_valid=0;dbg_sel=ACC_FACC_A;dbg_parity=0;dbg_addr=0;dbg_lane=0;
    repeat(20) @(negedge clk);reset=0;
    for(int p=0;p<PAIRS;p++) begin
      @(negedge clk);rsp_valid=1;rsp='0;rsp.row_valid=row_mask(p);
      rsp.e_stream[0]=128;rsp.e_stream[1]=128;
      for(int n=0;n<16;n++) rsp.e_stat[n]=128;
      rsp.meta.epoch=1;rsp.meta.head=0;rsp.meta.tile_idx=0;rsp.meta.pair_idx=p;rsp.meta.nt=0;
      rsp.meta.final_k=1;rsp.meta.last=p==PAIRS-1;rsp.meta.exp_fold=0;rsp.meta.acc_sel=ACC_FACC_A;rsp.meta.add_old=p!=0;
      for(int n=0;n<16;n++) begin
        rsp.psum[0][n]=32'sd16+n;
        rsp.psum[1][n]=32'sd32+n;
      end
      @(posedge clk);
    end
    @(negedge clk);rsp_valid=0;
    wait(done);#1;
    if(commits!=PAIRS) $fatal(1,"DEQACC commit count=%0d",commits);
    if(first_commit_cycle-first_rsp_cycle!=DEQACC_PIPE_STAGES-1)
      $fatal(1,"DEQACC edge latency=%0d, expected D0..D7 edge delta 7",
        first_commit_cycle-first_rsp_cycle);
    dbg_valid=1;dbg_sel=ACC_FACC_A;dbg_parity=0;dbg_addr=0;dbg_lane=0;#1;
    if(dbg_data!==pack_scaled32(0,32'h80000000,-6,0,0)) $fatal(1,"FACC even value mismatch %h",dbg_data);
    dbg_lane=1;#1;
    if(dbg_data!==even_one(1,-6)) $fatal(1,"FACC even lane1 mismatch %h",dbg_data);
    dbg_lane=15;#1;
    if(dbg_data!==even_one(15,-6)) $fatal(1,"FACC even lane15 mismatch %h",dbg_data);
    dbg_lane=0;
    dbg_parity=1;#1;
    if(dbg_data!==odd_one(0,-5)) $fatal(1,"FACC odd value mismatch %h",dbg_data);
    dbg_lane=1;#1;
    if(dbg_data!==odd_one(1,-5)) $fatal(1,"FACC odd lane1 mismatch %h",dbg_data);
    dbg_lane=15;#1;
    if(dbg_data!==odd_one(15,-5)) $fatal(1,"FACC odd lane15 mismatch %h",dbg_data);

    // Wait for the registered done pulse to leave before starting the next
    // independent transaction stream.
    @(posedge clk); #1;
    // OACC/PV mode: the second transaction must see the first transaction's
    // committed value at the same pair/nt address.
    drive_one(ACC_OACC,0,3,1,0);
    wait(commit_valid); @(posedge clk); #1;
    drive_one(ACC_OACC,0,3,0,1);
    wait(done); #1;
    dbg_valid=1; dbg_sel=ACC_OACC; dbg_parity=0; dbg_addr=oacc_addr(0,3); dbg_lane=0; #1;
    if(dbg_data!==even_one(0,-5))
      $fatal(1,"OACC even read/add mismatch %h",dbg_data);
    dbg_lane=1; #1;
    if(dbg_data!==even_one(1,-5)) $fatal(1,"OACC even lane1 mismatch %h",dbg_data);
    dbg_lane=15; #1;
    if(dbg_data!==even_one(15,-5)) $fatal(1,"OACC even lane15 mismatch %h",dbg_data);
    dbg_lane=0;
    dbg_parity=1; #1;
    if(dbg_data!==odd_one(0,-4))
      $fatal(1,"OACC odd read/add mismatch %h",dbg_data);
    dbg_lane=1; #1;
    if(dbg_data!==odd_one(1,-4)) $fatal(1,"OACC odd lane1 mismatch %h",dbg_data);
    dbg_lane=15; #1;
    if(dbg_data!==odd_one(15,-4)) $fatal(1,"OACC odd lane15 mismatch %h",dbg_data);
    dbg_lane=0;

    @(posedge clk); #1;
    // FACC B uses an independent physical bank and must not alias FACC A.
    drive_one(ACC_FACC_B,0,0,1,1);
    wait(done); #1;
    dbg_valid=1; dbg_sel=ACC_FACC_B; dbg_parity=0; dbg_addr=0; dbg_lane=0; #1;
    if(dbg_data!==even_one(0,-6))
      $fatal(1,"FACC B even value mismatch %h",dbg_data);
    dbg_lane=1; #1;
    if(dbg_data!==even_one(1,-6)) $fatal(1,"FACC B lane1 mismatch %h",dbg_data);
    dbg_lane=15; #1;
    if(dbg_data!==even_one(15,-6)) $fatal(1,"FACC B lane15 mismatch %h",dbg_data);
    $display("tb_v3_deqacc32 PASS commits=%0d stages=11 edge_delta=%0d FACC_A/FACC_B/OACC=1",
      commits,first_commit_cycle-first_rsp_cycle);
    $finish;
  end
  initial begin #100000;$fatal(1,"v3 DEQACC watchdog"); end
endmodule
