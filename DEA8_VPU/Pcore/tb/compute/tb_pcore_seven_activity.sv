`timescale 1ns/1ps

// Passive observer: the original seven-Job TB supplies all stimulus/checks.
// Count at the real official-IP input boundary, including CE and reset.
// No clock-enable, data, ready, or valid signals are driven by this observer.
module tb_pcore_seven_activity;
  import pcore_pkg::*;
  localparam int UNITS=89;
  tb_pcore_seven_native tb();
  wire [UNITS-1:0] launch;
  wire [1:0] quant_launch;
  wire qk_pair_launch=tb.dut.vpu.qk.in_valid&&tb.dut.vpu.qk.in_ready;
  longint unsigned counts[UNITS][7],quant_counts[2][7],qk_counts[7];
  longint unsigned outside_window=0;
  int jobs_seen=0;

`define BINARY_FIRE(IP) ((IP.aresetn)&&(IP.aclken)&&(IP.s_axis_a_tvalid)&&(IP.s_axis_b_tvalid))
`define UNARY_FIRE(IP) ((IP.aresetn)&&(IP.aclken)&&(IP.s_axis_a_tvalid))
  for(genvar r=0;r<2;r++)begin: vpu_rows
    for(genvar j=0;j<16;j++)begin: lanes
      assign launch[16*r+j]=`BINARY_FIRE(tb.dut.vpu.shared_mul.rows[r].lanes[j].native_mul);
      assign launch[32+16*r+j]=`BINARY_FIRE(tb.dut.vpu.p_pipe.rows[r].nodes[j].add.impl.native_add);
    end
    assign launch[64+r]=`BINARY_FIRE(tb.dut.vpu.qk.subtract_rows[r].subtractor.native_add);
    assign quant_launch[r]=tb.dut.vpu.shared_quant[r].q.in_valid&&tb.dut.vpu.shared_quant[r].q.in_ready;
  end
  for(genvar j=0;j<4;j++)begin: exp_lanes
    assign launch[66+j]=`BINARY_FIRE(tb.dut.sfu.arithmetic.exp_lanes[j].sub);
    assign launch[70+j]=`UNARY_FIRE(tb.dut.sfu.arithmetic.exp_lanes[j].exponential);
  end
  for(genvar j=0;j<2;j++)begin: gelu_lanes
    assign launch[74+5*j]=`BINARY_FIRE(tb.dut.sfu.arithmetic.gelu_lanes[j].m0);
    assign launch[75+5*j]=`BINARY_FIRE(tb.dut.sfu.arithmetic.gelu_lanes[j].m1);
    assign launch[76+5*j]=`BINARY_FIRE(tb.dut.sfu.arithmetic.gelu_lanes[j].m2);
    assign launch[77+5*j]=`BINARY_FIRE(tb.dut.sfu.arithmetic.gelu_lanes[j].m3);
    assign launch[78+5*j]=`BINARY_FIRE(tb.dut.sfu.arithmetic.gelu_lanes[j].m4);
    assign launch[84+2*j]=`BINARY_FIRE(tb.dut.sfu.arithmetic.gelu_lanes[j].add_x);
    assign launch[85+2*j]=`BINARY_FIRE(tb.dut.sfu.arithmetic.gelu_lanes[j].add_one);
  end
  assign launch[88]=`UNARY_FIRE(tb.dut.sfu.arithmetic.reciprocal);
`undef BINARY_FIRE
`undef UNARY_FIRE

  function automatic string unit_name(input int n);
    if(n<32)return $sformatf("VPU_MUL_r%0d_l%0d",n/16,n%16);
    if(n<64)return $sformatf("VPU_ADD_r%0d_n%0d",(n-32)/16,(n-32)%16);
    if(n<66)return $sformatf("VPU_QK_SUB_r%0d",n-64);
    if(n<70)return $sformatf("SFU_P_SUB_l%0d",n-66);
    if(n<74)return $sformatf("SFU_EXP_l%0d",n-70);
    if(n<84)return $sformatf("SFU_GELU_MUL_l%0d_m%0d",(n-74)/5,(n-74)%5);
    if(n<88)return $sformatf("SFU_GELU_ADD_l%0d_a%0d",(n-84)/2,(n-84)%2);
    return "SFU_RECIP";
  endfunction

  initial begin
    for(int n=0;n<UNITS;n++)for(int op=0;op<7;op++)counts[n][op]=0;
    for(int r=0;r<2;r++)for(int op=0;op<7;op++)quant_counts[r][op]=0;
    for(int op=0;op<7;op++)qk_counts[op]=0;
  end
  always @(posedge tb.clk)if(!tb.reset&&!tb.clear)begin
    if(tb.job_valid&&tb.job_ready)jobs_seen++;
    for(int n=0;n<UNITS;n++)if(launch[n])begin
      if(!tb.busy||tb.done_valid)outside_window++;
      counts[n][tb.job.header.op]++;
    end
    for(int r=0;r<2;r++)if(quant_launch[r])quant_counts[r][tb.job.header.op]++;
    if(qk_pair_launch)qk_counts[tb.job.header.op]++;
  end

  // $finish in the original TB executes these final blocks. The runner also
  // requires the original numeric PASS and checks the activity completion tag.
  final begin
    longint unsigned total,all_issues;
    all_issues=0;
    $display("ACTIVITY_SCOPE units=%0d jobs=%0d total_cycles=%0d outside_window=%0d physical_IP_valid_CE=1",UNITS,jobs_seen,tb.total_cycles,outside_window);
    for(int op=0;op<7;op++)
      $display("ACTIVITY_JOB op=%0d cycles=%0d",op,tb.job_cycles[op]);
    for(int n=0;n<UNITS;n++)begin
      total=0;
      for(int op=0;op<7;op++)total+=counts[n][op];
      all_issues+=total;
      $display("ACTIVITY_UNIT name=%s issues=%0d Q=%0d K=%0d V=%0d Attention=%0d O=%0d GU=%0d Down=%0d",
        unit_name(n),total,counts[n][0],counts[n][1],counts[n][2],counts[n][3],counts[n][4],counts[n][5],counts[n][6]);
    end
    for(int r=0;r<2;r++)begin
      total=0;for(int op=0;op<7;op++)total+=quant_counts[r][op];
      $display("ACTIVITY_BLOCK name=VPU_QUANT_r%0d issues=%0d Q=%0d K=%0d V=%0d Attention=%0d O=%0d GU=%0d Down=%0d",
        r,total,quant_counts[r][0],quant_counts[r][1],quant_counts[r][2],quant_counts[r][3],quant_counts[r][4],quant_counts[r][5],quant_counts[r][6]);
    end
    total=0;for(int op=0;op<7;op++)total+=qk_counts[op];
    $display("ACTIVITY_BLOCK name=VPU_QK_PAIR_MAX issues=%0d",total);
    $display("ACTIVITY_TOTAL arithmetic_issues=%0d units=%0d cycles=%0d avg_issue_pct=%0.6f",
      all_issues,UNITS,tb.total_cycles,100.0*all_issues/(UNITS*real'(tb.total_cycles)));
    if(tb.completed==7&&jobs_seen==7&&outside_window==0&&tb.total_cycles>0)
      $display("tb_pcore_seven_activity PASS jobs=7 physical_units=89 outside_window=0");
  end
endmodule
