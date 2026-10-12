`timescale 1ns/1ps
import pcore_pkg::*;
module tb_deqacc_v1_dynamic_matrix;
  localparam int K_TILES=16;
  logic clk=0;always #2 clk=~clk;
  logic reset=1,clear=0,xbc_valid=0,xbc_ready,hbm_valid=0,hbm_ready;
  xbc4_t xbc_entry;b2_t hbm_entry;
  logic job_start=0,job_ready,job_busy,commit_valid,commit_write_valid,done;
  pair_meta_t commit_meta;acc_write_t commit_write;
  logic [PAIR_BITS:0] m_rows=ROWS;
  logic a_protocol_error,b_protocol_error;
  logic [31:0] golden[0:ROWS-1][0:15];
  int commits=0,issues=0,done_count=0,cycle=0,last_pair_cycle[0:PAIRS-1],min_reuse=1000000;
  dea8_matrix dut(.clk,.reset,.clear,.runtime_local_a(1'b0),.runtime_streaming(1'b0),
    .xbc_valid,.xbc_ready,.xbc_entry,.local_a_valid(1'b0),.local_a_ready(),.local_a_entry('0),
    .hbm_valid,.hbm_ready,.hbm_entry,.kv_valid(1'b0),.kv_ready(),.kv_entry('0),.b_source(B_HBM),
    .job_start,.job_a_tile_idx(6'b0),.job_b_tile_idx(6'b0),.job_a_stream_idx(6'b0),.job_b_stream_idx(6'b0),
    .job_tiles(MATRIX_TILE_COUNT_BITS'(K_TILES)),.job_m_rows(m_rows),.job_epoch(4'd2),.job_head(3'd1),
    .job_nt(6'b0),.job_nt_per_tile(1'b0),.job_clear_each_tile(1'b0),.job_final_k(1'b1),.job_exp_fold(6'sd0),
    .job_mode(MAT_PROJECTION),.job_gu_n(6'b0),.gu_slot_ready(1'b1),.job_acc_sel(ACC_FACC_A),.job_add_old(1'b0),
    .job_ready,.job_busy,.commit_valid,.done,.matrix_issue_done(),.gu_slot_reserve(),.commit_meta,
    .commit_write_valid,.commit_write,.result_rd_owner(ACC_READ_RESULT),.result_rd_valid(1'b0),
    .result_rd_ready(),.vpu_wr_valid(1'b0),.vpu_wr_ready(),.vpu_wr('0),.result_rd_sel(ACC_OACC),
    .result_rd_addr(10'b0),.result_rd_data_valid(),.result_even_data(),.result_odd_data(),
    .dbg_valid(1'b0),.dbg_sel(ACC_FACC_A),.dbg_parity(1'b0),.dbg_addr(10'b0),.dbg_lane(4'b0),.dbg_data(),
    .a_protocol_error,.b_protocol_error);
  function automatic qvec16_t qv(input int value);
    qvec16_t v;v.scale=128;
    for(int k=0;k<16;k++)v.data[8*k+:8]=8'(value);
    return v;
  endfunction
  function automatic logic [31:0] one_partial(input int row,col);
    int dot,lead;logic [31:0] mag;
    dot=16*(row[0]?-(row+1):row+1)*(col+1);mag=dot<0?-dot:dot;lead=0;
    for(int i=0;i<32;i++)if(mag[i])lead=i;
    return fp32_legacy_ref_pkg::pack_scaled32(dot<0,mag<<(31-lead),lead-10,mag==0,0);
  endfunction
  always @(posedge clk)begin
    cycle++;
    if(reset||clear)begin
      commits=0;issues=0;done_count=0;min_reuse=1000000;
      for(int p=0;p<PAIRS;p++)last_pair_cycle[p]=-1;
      for(int r=0;r<ROWS;r++)for(int n=0;n<16;n++)golden[r][n]=0;
    end else begin
      if(dut.req_valid)issues++;
      if(dut.mxu_rsp_valid)begin
        int pair_index,gap;pair_index=dut.mxu_rsp.meta.pair_idx;
        if(last_pair_cycle[pair_index]>=0)begin
          gap=cycle-last_pair_cycle[pair_index];if(gap<min_reuse)min_reuse=gap;
        end
        last_pair_cycle[pair_index]=cycle;
      end
    end
    #1;
    if(commit_valid)begin
      int p;p=commit_meta.pair_idx;
      if(!commit_write_valid||commit_write.addr!=p||commit_write.sel!=ACC_FACC_A||
         commit_write.row_valid!=((p==(int'(m_rows)+1)/2-1&&m_rows[0])?2'b01:2'b11))
        $fatal(1,"V1 dynamic M metadata/mask mismatch M=%0d pair=%0d",m_rows,p);
      for(int r=0;r<2;r++)if(commit_write.row_valid[r])for(int n=0;n<16;n++)begin
        golden[2*p+r][n]=fp32_legacy_ref_pkg::fp32_add(golden[2*p+r][n],one_partial(2*p+r,n));
        if(commit_write.data[r][n]!==golden[2*p+r][n])$fatal(1,"V1 dynamic M numeric mismatch M=%0d row=%0d col=%0d",m_rows,2*p+r,n);
      end
      commits++;
    end
    if(done)done_count++;
  end
  task automatic test_rows(input int rows);
    @(negedge clk);clear=1;xbc_valid=0;hbm_valid=0;
    @(negedge clk);clear=0;m_rows=(PAIR_BITS+1)'(rows);#1;
    if(!job_ready)$fatal(1,"V1 dynamic M job not ready after clear");
    job_start=1;@(negedge clk);job_start=0;
    fork
      begin
        for(int t=0;t<K_TILES;t++)for(int g=0;g<(rows+3)/4;g++)begin
          xbc_entry='0;xbc_entry.tile_idx=TILE_BITS'(t);xbc_entry.group_idx=4'(g);
          for(int r=0;r<4;r++)begin
            xbc_entry.row_valid[r]=(4*g+r<rows);
            xbc_entry.row[r]=qv((4*g+r)%2?-(4*g+r+1):(4*g+r+1));
          end
          xbc_valid=1;do @(posedge clk);while(!xbc_ready);
          @(negedge clk);xbc_valid=0;
        end
      end
      begin
        for(int t=0;t<K_TILES;t++)for(int g=0;g<8;g++)begin
          hbm_entry='0;hbm_entry.tile_idx=TILE_BITS'(t);hbm_entry.group_idx=3'(g);hbm_entry.epoch=2;
          hbm_entry.col[0]=qv(2*g+1);hbm_entry.col[1]=qv(2*g+2);
          hbm_valid=1;do @(posedge clk);while(!hbm_ready);
          @(negedge clk);hbm_valid=0;
        end
      end
    join
    wait(done_count==1);wait(!job_busy);@(negedge clk);
    if(a_protocol_error||b_protocol_error||job_busy||commits!=K_TILES*((rows+1)/2)||
       issues!=commits||min_reuse<4)$fatal(1,"V1 dynamic M counts/protocol/hazard failed M=%0d",rows);
    $display("V1_DYNAMIC_M M=%0d issues=%0d commits=%0d min_same_address_interval=%0d RAW_stalls_in_DEQACC=0",rows,issues,commits,min_reuse);
  endtask
  initial begin
    xbc_entry='0;hbm_entry='0;
    repeat(4)@(negedge clk);reset=0;
    test_rows(1);test_rows(2);test_rows(3);test_rows(7);test_rows(16);test_rows(31);test_rows(51);
    $display("tb_deqacc_v1_dynamic_matrix PASS M=1,2,3,7,16,31,51 real_MXU=1 bit_exact=1");$finish;
  end
  initial begin #1000000;$fatal(1,"V1 dynamic M watchdog rows=%0d issues=%0d commits=%0d",m_rows,issues,commits);end
endmodule
