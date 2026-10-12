`timescale 1ns/1ps
import pcore_pkg::*;
import deqacc_v1_pkg::*;
module tb_deqacc_v1_stream;
  logic clk=0;always #2 clk=~clk;
  logic reset=1,clear=0,rsp_valid=0,commit_valid,done,commit_write_valid;
  mxu_rsp_t rsp;
  pair_meta_t commit_meta;
  acc_write_t commit_write;
  logic result_rd_valid=0,result_rd_ready,result_rd_data_valid,vpu_wr_valid=0,vpu_wr_ready;
  acc_sel_e result_rd_sel=ACC_OACC,dbg_sel=ACC_OACC;
  logic [9:0] result_rd_addr=0,dbg_addr=0;
  logic [15:0][31:0] result_even_data,result_odd_data;
  acc_write_t vpu_wr;
  logic dbg_valid=0,dbg_parity=0;logic [3:0] dbg_lane=0;logic [31:0] dbg_data;
  logic [31:0] model[0:2][0:415][0:1][0:15];
  logic [1:0][15:0][31:0] expected[0:6];
  pair_meta_t expected_meta[0:6];logic [1:0] expected_rows[0:6];logic [6:0] valids=0;
  int last_issue[0:2][0:415][0:1];
  int cycle=0,accepted=0,checked=0,flushed=0,a3_hits=0,c_hits=0,external_reads=0,external_writes=0;
  logic [31:0] rng=32'h3597a4c1;
  logic compare_old=0,old_commit,old_done;
  pair_meta_t old_meta;acc_write_t old_write;
  logic [10:0] old_valids=0;logic [1:0][15:0][31:0] old_expected[0:10];
  pair_meta_t old_expected_meta[0:10];logic [1:0] old_expected_rows[0:10];int old_checked=0;
  DEQACC_V1 dut(.*,.result_rd_owner(ACC_READ_RESULT));
  DEQACC_3_3ns old_dut(.clk,.reset,.clear,.rsp_valid(rsp_valid&&compare_old),.rsp,
    .result_rd_owner(ACC_READ_RESULT),.result_rd_valid(1'b0),.result_rd_ready(),
    .result_rd_sel(ACC_OACC),.result_rd_addr(10'b0),.result_rd_data_valid(),.result_even_data(),.result_odd_data(),
    .vpu_wr_valid(1'b0),.vpu_wr_ready(),.vpu_wr('0),.commit_valid(old_commit),.done(old_done),.commit_meta(old_meta),
    .commit_write_valid(),.commit_write(old_write),.dbg_valid(1'b0),.dbg_sel(ACC_OACC),
    .dbg_parity(1'b0),.dbg_addr(10'b0),.dbg_lane(4'b0),.dbg_data());
  function automatic logic [31:0] random_bits;
    rng=rng^(rng<<13);rng=rng^(rng>>17);rng=rng^(rng<<5);return rng;
  endfunction
  function automatic logic [31:0] partial(input logic signed [31:0] x,input int ea,eb,fold);
    logic [31:0] mag;int lead;
    mag=x[31]?(~x+32'd1):x;lead=0;
    for(int i=0;i<32;i++)if(mag[i])lead=i;
    return fp32_legacy_ref_pkg::pack_scaled32(x[31],mag<<(31-lead),ea+eb+fold-266+lead,
      mag==0,ea==255||eb==255);
  endfunction
  always @(posedge clk)begin
    int addr;
    logic read_fire;logic [1:0][15:0][31:0] read_expected;
    cycle++;read_fire=0;
    if(reset||clear)begin
      for(int s=0;s<6;s++)if(valids[s])flushed++;
      valids=0;old_valids=0;
      for(int bank=0;bank<3;bank++)for(int a=0;a<416;a++)for(int r=0;r<2;r++)begin
        last_issue[bank][a][r]=-1000;
        for(int n=0;n<16;n++)model[bank][a][r][n]=0;
      end
    end else begin
      if(dut.groups[0].compute.keys[1].valid)
        for(int r=0;r<2;r++)if(dut.groups[0].compute.keys[1].rows[r])begin
          if(dut.groups[0].compute.use_a3[r])a3_hits++;
          if(dut.groups[0].compute.use_c[r])c_hits++;
        end
      read_fire=result_rd_valid&&result_rd_ready;
      if(read_fire)begin
        read_expected='0;
        for(int r=0;r<2;r++)if(result_rd_addr<(r==0?(ROWS+1)/2:ROWS/2)*(result_rd_sel==ACC_OACC?TILE:1))
          for(int n=0;n<16;n++)read_expected[r][n]=model[result_rd_sel][result_rd_addr][r][n];
        external_reads++;
      end
      if(vpu_wr_valid&&vpu_wr_ready)begin
        for(int r=0;r<2;r++)if(vpu_wr.row_valid[r]&&vpu_wr.addr<(r==0?(ROWS+1)/2:ROWS/2)*(vpu_wr.sel==ACC_OACC?TILE:1))
          for(int n=0;n<16;n++)model[vpu_wr.sel][vpu_wr.addr][r][n]=vpu_wr.data[r][n];
        external_writes++;
      end
      for(int s=6;s>0;s--)begin
        expected[s]=expected[s-1];expected_meta[s]=expected_meta[s-1];expected_rows[s]=expected_rows[s-1];
      end
      valids={valids[5:0],rsp_valid};expected_meta[0]=rsp.meta;expected_rows[0]=rsp.row_valid;
      if(rsp_valid)begin
        addr=v1_address(rsp.meta);accepted++;
        for(int r=0;r<2;r++)begin
          if(rsp.row_valid[r])last_issue[rsp.meta.acc_sel][addr][r]=cycle;
          for(int n=0;n<16;n++)begin
            logic [31:0] p;
            p=partial(rsp.psum[r][n],int'(rsp.e_stream[r]),int'(rsp.e_stat[n]),int'($signed(rsp.meta.exp_fold)));
            expected[0][r][n]=rsp.meta.add_old?fp32_legacy_ref_pkg::fp32_add(model[rsp.meta.acc_sel][addr][r][n],p):p;
            if(rsp.row_valid[r])model[rsp.meta.acc_sel][addr][r][n]=expected[0][r][n];
          end
        end
      end
      for(int s=10;s>0;s--)begin
        old_expected[s]=old_expected[s-1];old_expected_meta[s]=old_expected_meta[s-1];
        old_expected_rows[s]=old_expected_rows[s-1];
      end
      old_valids={old_valids[9:0],rsp_valid&&compare_old};
      old_expected[0]=expected[0];old_expected_meta[0]=rsp.meta;old_expected_rows[0]=rsp.row_valid;
    end
    #1;
    if(commit_valid!==valids[6]||commit_write_valid!==valids[6])$fatal(1,"V1 seven-stage latency mismatch");
    if(done!==(valids[6]&&expected_meta[6].last))$fatal(1,"V1 done mismatch");
    if(commit_valid)begin
      if(commit_meta!==expected_meta[6]||commit_write.sel!==expected_meta[6].acc_sel||
         commit_write.addr!==v1_address(expected_meta[6])||commit_write.row_valid!==expected_rows[6])
        $fatal(1,"V1 commit identity/address/mask mismatch");
      for(int r=0;r<2;r++)if(expected_rows[6][r])for(int n=0;n<16;n++)
        if(commit_write.data[r][n]!==expected[6][r][n])
          $fatal(1,"V1 stream numeric mismatch checked=%0d row=%0d col=%0d got=%h expected=%h",checked,r,n,commit_write.data[r][n],expected[6][r][n]);
      checked++;
    end
    if(result_rd_data_valid!==read_fire)$fatal(1,"V1 external read latency mismatch");
    if(read_fire&&{result_odd_data,result_even_data}!==read_expected)$fatal(1,"V1 external read data mismatch");
    if(old_commit!==old_valids[10])$fatal(1,"A11 comparison latency mismatch");
    if(old_commit)begin
      if(old_meta!==old_expected_meta[10])$fatal(1,"A11 identity comparison mismatch");
      for(int r=0;r<2;r++)if(old_expected_rows[10][r])for(int n=0;n<16;n++)
        if(old_write.data[r][n]!==old_expected[10][r][n])$fatal(1,"A11/V1 numerical comparison mismatch");
      old_checked++;
    end
  end
  task automatic make_issue(input int bank,pair_index,tile,input bit accumulate,input logic [1:0] rows);
    rsp='0;rsp_valid=1;rsp.meta.acc_sel=acc_sel_e'(bank);rsp.meta.pair_idx=PAIR_BITS'(pair_index);
    rsp.meta.nt=TILE_BITS'(tile);rsp.meta.add_old=accumulate;rsp.row_valid=rows&row_mask(pair_index);
    rng=random_bits();rsp.meta.exp_fold=EXP_FOLD_BITS'(rng[5:0]);rsp.meta.epoch=EPOCH_BITS'(accepted);
    rsp.meta.head=3'(accepted/19);rsp.meta.mode=matrix_mode_e'(accepted%3);
    rsp.meta.tile_idx=TILE_BITS'(accepted/7);rsp.meta.gu_n=6'(accepted/23);
    rsp.meta.final_k=rng[6];rsp.meta.last=rng[7];
    rsp.e_stream[0]=rng[15:8];rsp.e_stream[1]=rng[23:16];
    for(int n=0;n<16;n++)begin
      rsp.e_stat[n]=8'(random_bits());rsp.psum[0][n]=random_bits();rsp.psum[1][n]=random_bits();
    end
  endtask
  task automatic idle(input int clocks);
    rsp_valid=0;repeat(clocks)@(negedge clk);
  endtask
  task automatic check_acc;
    dbg_valid=1;
    for(int bank=0;bank<3;bank++)for(int addr=0;addr<(bank==2?416:26);addr++)
      for(int r=0;r<2;r++)if(addr<(r==0?(ROWS+1)/2:ROWS/2)*(bank==2?16:1))
        for(int n=0;n<16;n++)begin
          dbg_sel=acc_sel_e'(bank);dbg_addr=10'(addr);dbg_parity=1'(r);dbg_lane=4'(n);#0.01;
          if(dbg_data!==model[bank][addr][r][n])
            $fatal(1,"V1 complete ACC model mismatch bank=%0d addr=%0d parity=%0d col=%0d",bank,addr,r,n);
        end
    dbg_valid=0;
    @(negedge clk);
  endtask
  initial begin
    rsp='0;vpu_wr='0;
    repeat(4)@(negedge clk);reset=0;
    if($test$plusargs("BAD_RAW")||$test$plusargs("BAD_RAW_2")||$test$plusargs("BAD_RAW_3"))begin
      make_issue(0,0,0,0,3);@(negedge clk);
      if($test$plusargs("BAD_RAW_2"))idle(1);
      if($test$plusargs("BAD_RAW_3"))idle(2);
      make_issue(0,0,0,1,3);
      repeat(10)@(negedge clk);$fatal(1,"Expected RAW rejection missing");
    end
    compare_old=1;
    for(int i=0;i<5000;i++)begin
      make_issue(i%3,(i/3)%PAIRS,(i/(3*PAIRS))%16,i[0],3);@(negedge clk);
    end
    idle(12);compare_old=0;
    for(int delta=4;delta<=7;delta++)begin
      for(int i=0;i<120;i++)begin
        make_issue(0,0,0,i!=0,3);@(negedge clk);idle(delta-1);
      end
      idle(8);
    end
    // Two parity planes independently bypass different producers: even at
    // t0, odd at t1, both at t5 -> C for even and A3 for odd at A0.
    make_issue(1,2,0,0,1);@(negedge clk);
    make_issue(1,2,0,0,2);@(negedge clk);idle(3);
    make_issue(1,2,0,1,3);@(negedge clk);idle(8);
    for(int i=0;i<5000;i++)begin
      int bank,pair_index,tile,addr;bit accumulate;logic [1:0] rows;
      bank=int'(random_bits()%3);pair_index=int'(random_bits()%PAIRS);tile=int'(random_bits()%16);
      rows=2'(random_bits()%3+1)&row_mask(pair_index);
      if(rows==0)rows=1;
      accumulate=1'(random_bits());
      addr=bank==2?oacc_addr(pair_index,tile):pair_index;
      for(int r=0;r<2;r++)if(rows[r]&&cycle+1-last_issue[bank][addr][r]<4)accumulate=0;
      make_issue(bank,pair_index,tile,accumulate,rows);@(negedge clk);
    end
    idle(8);
    check_acc();
    // External write and a read of another bank continue while matrix owns A.
    make_issue(0,0,0,0,3);result_rd_sel=ACC_FACC_A;result_rd_valid=1;
    vpu_wr_valid=1;vpu_wr.sel=ACC_FACC_B;vpu_wr.addr=3;vpu_wr.row_valid=3;
    for(int r=0;r<2;r++)for(int n=0;n<16;n++)vpu_wr.data[r][n]=32'h3f800000+32'(r*16+n);
    #1;if(result_rd_ready!==0||vpu_wr_ready!==1)$fatal(1,"V1 bank reservation mismatch");
    @(negedge clk);rsp_valid=0;vpu_wr_valid=0;
    repeat(5)begin
      #1;if(result_rd_ready!==0)$fatal(1,"V1 pending bank ownership released before commit");
      @(negedge clk);
    end
    result_rd_sel=ACC_FACC_B;result_rd_addr=3;
    @(negedge clk);result_rd_valid=0;idle(8);
    make_issue(1,3,0,1,3);@(negedge clk);idle(8);
    // Read/write of one idle bank: response must be the pre-write contents.
    result_rd_sel=ACC_FACC_B;result_rd_addr=3;result_rd_valid=1;
    vpu_wr_valid=1;vpu_wr.data='0;
    @(negedge clk);vpu_wr_valid=0;
    @(negedge clk);result_rd_valid=0;
    check_acc();
    make_issue(0,5,0,0,3);@(negedge clk);rsp_valid=0;clear=1;
    @(negedge clk);clear=0;idle(10);
    result_rd_valid=1;result_rd_sel=ACC_OACC;result_rd_addr=0;
    @(negedge clk);result_rd_addr=1023;
    @(negedge clk);result_rd_valid=0;
    make_issue(2,PAIRS-1,15,1,1);@(negedge clk);idle(8);
    // Inspect the complete final model, every bank/parity/column, via debug.
    check_acc();
    if(checked!=accepted-flushed||old_checked!=5000||a3_hits==0||c_hits==0||external_reads<4||external_writes<2)
      $fatal(1,"V1 stream coverage/count mismatch accepted=%0d checked=%0d flushed=%0d",accepted,checked,flushed);
    $display("tb_deqacc_v1_stream PASS checked=%0d A11_compared=%0d latency=7 II=1 delta=4,5,6,7 A3_hits=%0d C_hits=%0d external_reads=%0d external_writes=%0d clear=1 final_ACC=1",
      checked,old_checked,a3_hits,c_hits,external_reads,external_writes);$finish;
  end
  initial begin #1000000;$fatal(1,"V1 stream watchdog");end
endmodule
