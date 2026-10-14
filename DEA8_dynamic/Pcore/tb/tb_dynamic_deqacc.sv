`timescale 1ns/1ps
import pcore_pkg::*;
module tb_dynamic_deqacc;
  logic clk=0;always #2 clk=~clk;
  logic reset=1,clear=0,rsp_valid=0;
  mxu_rsp_t rsp='0;
  acc_read_owner_e result_rd_owner=ACC_READ_RESULT;
  logic result_rd_valid=0,result_rd_ready,vpu_wr_valid=0,vpu_wr_ready;
  acc_write_t vpu_wr='0,commit_write;
  acc_sel_e result_rd_sel=ACC_FACC_A;
  logic [9:0] result_rd_addr=0;
  logic result_rd_data_valid,commit_valid,done,commit_write_valid;
  logic retire_valid;
  logic [15:0][31:0] result_even_data,result_odd_data;
  pair_meta_t commit_meta;
  logic dbg_valid=0,dbg_parity=0;acc_sel_e dbg_sel=ACC_FACC_A;
  logic [9:0] dbg_addr=0;logic [3:0] dbg_lane=0;logic [31:0] dbg_data;
  DEQACC_V1 dut(.*);
  logic [6:0] ev=0;
  pair_meta_t emeta[0:6];acc_write_t ewrite[0:6];
  logic [31:0] model[0:2][0:PAIRS*TILE-1][0:1][0:TILE-1];
  int commits=0,a3_hits=0,c_hits=0,issues=0;
  function automatic logic [31:0] quant_ref(input logic signed [31:0] x,input int ea,eb,fold);
    logic [31:0] mag;int lead;
    mag=x[31]?(~x+32'd1):x;lead=0;
    for(int b=0;b<32;b++)if(mag[b])lead=b;
    return fp32_legacy_ref_pkg::pack_scaled32(x[31],mag<<(31-lead),ea+eb+fold-266+lead,
      mag==0,ea==255||eb==255);
  endfunction
  always @(posedge clk)begin
    acc_write_t expected;int addr;
    if(reset||clear)begin
      ev=0;
      for(int bank=0;bank<3;bank++)for(int index=0;index<PAIRS*TILE;index++)
        for(int r=0;r<ROW_LANES;r++)for(int n=0;n<TILE;n++)model[bank][index][r][n]=0;
    end else begin
      for(int s=6;s>0;s--)begin ev[s]=ev[s-1];emeta[s]=emeta[s-1];ewrite[s]=ewrite[s-1];end
      ev[0]=rsp_valid;
      if(rsp_valid)begin
        expected='0;addr=rsp.meta.acc_sel==ACC_OACC?int'(rsp.meta.pair_idx)*TILE+int'(rsp.meta.nt):int'(rsp.meta.pair_idx);
        expected.sel=rsp.meta.acc_sel;expected.addr=10'(addr);expected.row_valid=rsp.row_valid;
        for(int r=0;r<ROW_LANES;r++)for(int n=0;n<TILE;n++)if(rsp.row_valid[r])begin
          expected.data[r][n]=quant_ref(rsp.psum[r][n],int'(rsp.e_stream[r]),int'(rsp.e_stat[n]),int'($signed(rsp.meta.exp_fold)));
          if(rsp.meta.add_old)expected.data[r][n]=fp32_legacy_ref_pkg::fp32_add(
            model[rsp.meta.acc_sel][addr][r][n],expected.data[r][n]);
          model[rsp.meta.acc_sel][addr][r][n]=expected.data[r][n];
        end
        ewrite[0]=expected;emeta[0]=rsp.meta;issues++;
      end
      if(dut.groups[0].compute.keys[1].valid&&dut.groups[0].compute.keys[1].add_old)begin
        if(|dut.groups[0].compute.use_a3)a3_hits++;
        if(|dut.groups[0].compute.use_c)c_hits++;
      end
    end
    #1;
    if(commit_valid!==ev[6]||commit_write_valid!==ev[6])$fatal(1,"DEQACC seven-stage valid mismatch");
    if(commit_valid)begin
      if(commit_meta!==emeta[6]||commit_write.sel!==ewrite[6].sel||commit_write.addr!==ewrite[6].addr||
        commit_write.row_valid!==ewrite[6].row_valid)$fatal(1,"DEQACC spine metadata mismatch");
      for(int r=0;r<ROW_LANES;r++)if(commit_write.row_valid[r])for(int n=0;n<TILE;n++)
        if(commit_write.data[r][n]!==ewrite[6].data[r][n])$fatal(1,"DEQACC forward/memory numeric mismatch issue=%0d",commits);
      commits++;
    end
  end
  task automatic send(input acc_sel_e bank,input int pair_idx,nt,input bit use_old,
    input logic [1:0] mask,input int value);
    mxu_rsp_t next_rsp;
    next_rsp='0;next_rsp.row_valid=mask;next_rsp.meta.acc_sel=bank;next_rsp.meta.m_rows=ROWS;
    next_rsp.meta.pair_idx=PAIR_BITS'(pair_idx);next_rsp.meta.nt=TILE_BITS'(nt);
    next_rsp.meta.add_old=use_old;next_rsp.meta.exp_fold=EXP_FOLD_BITS'(value%13-6);
    next_rsp.meta.epoch=EPOCH_BITS'(value);next_rsp.meta.head=3'(value);
    for(int r=0;r<ROW_LANES;r++)begin
      next_rsp.e_stream[r]=8'(126+(value+r)%8);
      for(int n=0;n<TILE;n++)next_rsp.psum[r][n]=(value+n+r)%2?(value*123-n*39-r*3):-(value*317+n*19+r*11);
    end
    for(int n=0;n<TILE;n++)next_rsp.e_stat[n]=8'(127+(value+n)%8);
    @(negedge clk);rsp=next_rsp;rsp_valid=1;
  endtask
  task automatic gap(input int delta);
    @(negedge clk);rsp_valid=0;
    repeat(delta-2)@(negedge clk);
  endtask
  task automatic drain;
    @(negedge clk);rsp_valid=0;repeat(8)@(negedge clk);
  endtask
  initial begin
    int bad_gap;
    repeat(4)@(negedge clk);reset=0;
    bad_gap=0;
    if($test$plusargs("BAD_RAW_1"))bad_gap=1;
    if($test$plusargs("BAD_RAW_2"))bad_gap=2;
    if($test$plusargs("BAD_RAW_3"))bad_gap=3;
    if(bad_gap!=0)begin
      send(ACC_FACC_A,0,0,0,2'b11,1);
      if(bad_gap>1)gap(bad_gap);
      send(ACC_FACC_A,0,0,1,2'b11,2);
      drain();$fatal(1,"Expected RAW rejection did not occur");
    end
    // Independent addresses: full 32-lane service on every input cycle.
    for(int repeat_id=0;repeat_id<8;repeat_id++)begin
      for(int p=0;p<PAIRS;p++)send(ACC_FACC_A,p,0,repeat_id!=0,row_mask_for_rows(ROWS,p),1+repeat_id*PAIRS+p);
    end
    drain();
    for(int delta=4;delta<=7;delta++)begin
      send(ACC_FACC_A,0,0,0,2'b11,10);
      for(int iteration=0;iteration<24;iteration++)begin
        gap(delta);send(ACC_FACC_A,0,0,1,2'b11,iteration+11);
      end
      drain();
    end
    // Consecutive transactions may update different parities at one address.
    send(ACC_FACC_B,0,0,0,2'b01,91);
    send(ACC_FACC_B,0,0,0,2'b10,92);
    gap(4);send(ACC_FACC_B,0,0,1,2'b11,93);
    drain();
    for(int nt=0;nt<TILE;nt++)send(ACC_OACC,0,nt,0,2'b11,nt+51);
    for(int nt=0;nt<TILE;nt++)send(ACC_OACC,0,nt,1,2'b11,nt+71);
    drain();
    if(commits!=issues||a3_hits==0||c_hits==0)$fatal(1,"Stream coverage incomplete");
    // Flush both the arithmetic candidates and the RAM-valid generation.
    send(ACC_FACC_A,0,0,0,2'b11,5);
    @(negedge clk);clear=1;rsp_valid=0;
    @(negedge clk);clear=0;
    repeat(8)@(negedge clk);
    send(ACC_FACC_A,0,0,1,2'b11,9);drain();
    if(commits!=issues-1)$fatal(1,"Clear did not cancel exactly one transaction");
    $display("tb_dynamic_deqacc PASS commits=%0d input_II=1 Delta4_5_6_7=1 parity_forward=1 A3=%0d C=%0d clear=1",
      commits,a3_hits,c_hits);
    $finish;
  end
  initial begin #100000;$fatal(1,"DEQACC stream watchdog");end
endmodule
