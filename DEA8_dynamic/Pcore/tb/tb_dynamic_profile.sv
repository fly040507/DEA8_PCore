`timescale 1ns/1ps
import pcore_pkg::*;
module tb_dynamic_profile;
  logic clk=0;always #2 clk=~clk;
  logic reset=1,clear=0,in_use=0;
  logic begin_valid=0,begin_ready,wr_valid=0,wr_ready,commit_valid=0,commit_ready;
  logic [ROW_COUNT_BITS-1:0] begin_rows=0,wr_index=0,wr_original=0,m_rows;
  logic [15:0] begin_id=0,begin_version=0,profile_id,profile_version;
  logic profile_valid,protocol_error,rd_valid=0,rd_ready,out_valid,out_ready=0;
  logic [ROW_COUNT_BITS-1:0] rd_index=0,out_index,out_original;
  int profiles=0,reads=0,negative_checks=0;
  dea8_profile dut(.*);
  task automatic flush;
    @(negedge clk);clear=1;begin_valid=0;wr_valid=0;commit_valid=0;rd_valid=0;out_ready=0;in_use=0;
    @(negedge clk);clear=0;
    if(protocol_error||profile_valid||out_valid)$fatal(1,"Profile clear");
  endtask
  task automatic start_map(input int m);
    @(negedge clk);begin_rows=ROW_COUNT_BITS'(m);begin_id=16'(profiles);begin_version=16'(profiles+100);begin_valid=1;
    @(posedge clk);if(!begin_ready)$fatal(1,"Profile begin rejected");
    @(negedge clk);begin_valid=0;
  endtask
  task automatic write_row(input int i,original);
    wr_index=ROW_COUNT_BITS'(i);wr_original=ROW_COUNT_BITS'(original);wr_valid=1;
    @(posedge clk);if(!wr_ready)$fatal(1,"Profile legal row rejected");
    @(negedge clk);wr_valid=0;
  endtask
  initial begin
    operation_profile_t op;
    repeat(4)@(negedge clk);reset=0;
    for(int code=0;code<7;code++)begin
      op=operation_profile(pcore_op_e'(code));
      if(op.mode>MAT_GU||op.b_source>B_KVB)$fatal(1,"Seven-job mapping");
      if(effective_rows(pcore_op_e'(code),0)!==((code==OP_K_PROJ||code==OP_V_PROJ)?ROWS:0))
        $fatal(1,"K/V row contract");
      if(code==OP_GU&&(op.matrix_a!=A_XBC||op.k_tiles!=64||op.n_tiles!=32))$fatal(1,"GU mapping");
    end
    for(int m=0;m<=ROWS;m++)begin
      start_map(m);
      for(int i=0;i<m;i++)write_row(i,ROWS-1-i);
      commit_valid=1;@(posedge clk);if(!commit_ready)$fatal(1,"Profile commit unavailable");
      #1;if(!profile_valid||protocol_error||m_rows!=m)$fatal(1,"Profile completion");
      @(negedge clk);commit_valid=0;in_use=1;begin_valid=1;
      @(posedge clk);if(begin_ready)$fatal(1,"Live profile overwritten");
      @(negedge clk);begin_valid=0;
      for(int i=0;i<m;i++)begin
        rd_valid=1;rd_index=ROW_COUNT_BITS'(i);
        @(posedge clk);if(!rd_ready)$fatal(1,"Profile read");
        #1;if(!out_valid||out_original!=ROWS-1-i||out_index!=i)$fatal(1,"Noncontinuous profile lookup");
        @(negedge clk);rd_valid=0;
        repeat(3)begin @(posedge clk);#1;if(!out_valid||out_original!=ROWS-1-i)$fatal(1,"Profile response hold");end
        @(negedge clk);out_ready=1;@(negedge clk);out_ready=0;reads++;
      end
      in_use=0;profiles++;
    end
    start_map(2);write_row(0,4);wr_index=1;wr_original=4;wr_valid=1;
    @(posedge clk);#1;if(wr_ready||!protocol_error||profile_valid)$fatal(1,"Duplicate original accepted");
    negative_checks++;flush();
    start_map(3);write_row(0,1);commit_valid=1;
    @(posedge clk);#1;if(!protocol_error||profile_valid)$fatal(1,"Partial profile committed");
    negative_checks++;flush();
    start_map(ROWS+1);@(posedge clk);#1;if(!protocol_error)$fatal(1,"Illegal M accepted");
    negative_checks++;flush();
    $display("tb_dynamic_profile PASS profiles=%0d reads=%0d seven_jobs=7 negative_checks=%0d",profiles,reads,negative_checks);
    $finish;
  end
  initial begin #1000000;$fatal(1,"Profile watchdog");end
endmodule
