`timescale 1ns/1ps
import pcore_pkg::*;

// Numeric, simultaneous RAM traffic rather than a delay-only VPU model.
module tb_acc_overlap;
  logic clk=0;always #2 clk=~clk;
  logic reset=1,clear=0,rd_valid=0,wr_valid=0;
  acc_sel_e rd_sel=ACC_FACC_B,wr_sel=ACC_FACC_B,result_rd_sel=ACC_OACC;
  logic [9:0] rd_addr=0,wr_addr=0,result_rd_addr=0;
  logic rd_data_valid,result_rd_valid=0,result_rd_ready,result_rd_data_valid;
  logic [15:0][31:0] rd_even_data,rd_odd_data,result_even_data,result_odd_data;
  logic wr_even_valid=1,wr_odd_valid=1;
  logic [15:0][31:0] wr_even_data,wr_odd_data;
  logic vpu_wr_valid=0,vpu_wr_ready;acc_write_t vpu_wr;
  logic [31:0] dbg_data;
  int concurrent_reads=0,concurrent_writes=0;
  dea8_acc_store dut(
    .clk,.reset,.clear,.rd_valid,.rd_sel,.rd_addr,.rd_data_valid,.rd_even_data,.rd_odd_data,
    .result_rd_owner(ACC_READ_RESULT),.result_rd_valid,.result_rd_ready,.result_rd_sel,.result_rd_addr,
    .result_rd_data_valid,.result_even_data,.result_odd_data,.vpu_wr_valid,.vpu_wr_ready,.vpu_wr,
    .wr_valid,.wr_sel,.wr_even_valid,.wr_odd_valid,.wr_addr,.wr_even_data,.wr_odd_data,
    .dbg_valid(1'b0),.dbg_sel(ACC_OACC),.dbg_parity(1'b0),.dbg_addr('0),.dbg_lane('0),.dbg_data);
  task automatic check_read(input int matrix_value,input int vpu_value,input bit odd_present);
    #1;
    if(!rd_data_valid||!result_rd_data_valid) $fatal(1,"concurrent read response lost");
    for(int n=0;n<16;n++) begin
      if(rd_even_data[n]!==32'(matrix_value+n)||rd_odd_data[n]!==32'(matrix_value+100+n))
        $fatal(1,"Matrix RAM data mismatch lane=%0d",n);
      if(result_even_data[n]!==32'(vpu_value+n)||
         result_odd_data[n]!==(odd_present?32'(vpu_value+100+n):32'b0))
        $fatal(1,"VPU RAM data mismatch lane=%0d even=%h odd=%h",n,result_even_data[n],result_odd_data[n]);
    end
  endtask
  initial begin
    vpu_wr='0;wr_even_data='0;wr_odd_data='0;
    repeat(5) @(negedge clk);reset=0;
    // Matrix FACC-B and VPU FACC-A/OACC writes proceed together.
    for(int sel=0;sel<3;sel+=2) begin
      for(int a=0;a<(sel==2?416:26);a++) begin
        @(negedge clk);
        wr_valid=1;wr_addr=0;vpu_wr_valid=1;vpu_wr.sel=acc_sel_e'(sel);
        vpu_wr.addr=10'(a);vpu_wr.row_valid=(a<(sel==2?400:25))?2'b11:2'b01;
        for(int n=0;n<16;n++) begin
          wr_even_data[n]=32'(1000+n);wr_odd_data[n]=32'(1100+n);
          vpu_wr.data[0][n]=32'(2000+a+n);vpu_wr.data[1][n]=32'(2100+a+n);
        end
        #1;if(!vpu_wr_ready) $fatal(1,"different-bank write stalled");
        @(posedge clk);concurrent_writes++;
      end
      @(negedge clk);wr_valid=0;vpu_wr_valid=0;
      rd_valid=1;result_rd_valid=1;result_rd_sel=acc_sel_e'(sel);
      for(int a=0;a<(sel==2?416:26);a++) begin
        result_rd_addr=10'(a);
        #1;if(!result_rd_ready) $fatal(1,"different-bank read stalled");
        @(posedge clk);check_read(1000,2000+a,a<(sel==2?400:25));concurrent_reads++;
        @(negedge clk);
      end
      rd_valid=0;result_rd_valid=0;
    end
    // Same-bank requests remain pending until Matrix relinquishes ownership.
    @(negedge clk);rd_valid=1;result_rd_valid=1;result_rd_sel=ACC_FACC_B;result_rd_addr=0;
    vpu_wr_valid=1;vpu_wr.sel=ACC_FACC_B;
    #1;if(result_rd_ready||vpu_wr_ready) $fatal(1,"same-bank collision accepted");
    @(posedge clk);#1;if(result_rd_data_valid) $fatal(1,"collision produced response");
    @(negedge clk);rd_valid=0;vpu_wr_valid=0;
    #1;if(!result_rd_ready) $fatal(1,"held request not retried");
    @(posedge clk);#1;if(!result_rd_data_valid||result_even_data[0]!==32'd1000) $fatal(1,"retry lost");
    @(negedge clk);result_rd_valid=0;clear=1;
    @(negedge clk);clear=0;result_rd_valid=1;result_rd_sel=ACC_OACC;
    @(posedge clk);#1;if(!result_rd_data_valid||result_even_data!=='0) $fatal(1,"clear leaked stale RAM");
    $display("tb_acc_overlap PASS concurrent_reads=%0d concurrent_writes=%0d collision_retry=1 odd_depth=400",concurrent_reads,concurrent_writes);
    $finish;
  end
  initial begin #30000;$fatal(1,"overlap watchdog");end
endmodule
