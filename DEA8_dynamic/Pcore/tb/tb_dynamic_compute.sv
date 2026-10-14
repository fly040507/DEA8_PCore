`timescale 1ns/1ps
import pcore_pkg::*;
module tb_dynamic_compute;
  logic clk=0;always #2 clk=~clk;
  logic reset=1,clear=0,job_valid=0,job_ready,busy,done_valid,done_ready=0,protocol_error;
  compute_job_t job='0,current;
  logic gu_capture_ready=1;
  logic launch_allow=1;compute_job_t done_work;
  logic a_valid=0,a_bank=0,a_tile_available=1,a_ready,a_tile_reserve;
  a2_t a='0;
  logic b_valid=0,b_ready;b4_t b='0;
  logic result_rd_valid=0,result_rd_ready,result_rd_data_valid,vpu_wr_valid=0,vpu_wr_ready;
  acc_sel_e result_rd_sel=ACC_FACC_A;logic [9:0] result_rd_addr=0;
  logic [15:0][31:0] result_even_data,result_odd_data;
  acc_write_t vpu_wr='0,commit_write;
  logic issue_valid,psum_valid,commit_valid,commit_write_valid;
  pair_meta_t issue_meta,commit_meta;mxu_rsp_t psum_rsp;
  dea8_compute_core dut(.*);

  localparam int COMMIT_DELAY=MXU_PIPE_STAGES+DEQACC_PIPE_STAGES-1;
  logic [COMMIT_DELAY:0] expected_valid=0;
  mxu_rsp_t expected_psum[0:COMMIT_DELAY];
  acc_write_t expected_write[0:COMMIT_DELAY];
  logic [31:0] model[0:2][0:PAIRS*TILE-1][0:1][0:TILE-1];
  int seed=0,cycle=0,a_sent=0,b_sent=0,committed=0,psum_checks=0;
  int total_commits=0,cases=0,forward_a3=0,forward_c=0,read_checks=0,protocol_checks=0;
  int first_issue=-1,last_issue=-1,previous_tile=-1,previous_first=-1;
  bit feeding=0,ideal=1,allow_protocol_error=0;

  function automatic int avalue(input int tile,row,k);
    if((seed%7)==0)return -128;
    return int'($signed(8'(tile*31+row*17+k*11+seed*23)));
  endfunction
  function automatic int bvalue(input int tile,k,n);
    if((seed%7)==0)return -128;
    return int'($signed(8'(tile*13+k*29+n*19+seed*7)));
  endfunction
  function automatic int ascale(input int tile,row);
    return 126+(tile+row+seed)%8;
  endfunction
  function automatic int bscale(input int tile,n);
    return 127+(tile*3+n+seed)%8;
  endfunction
  function automatic logic [31:0] dequant_ref(input int signed x,input int ea,eb,fold);
    logic [31:0] mag;int lead;
    mag=x<0?(~32'(x)+32'd1):32'(x);lead=0;
    for(int bit_idx=0;bit_idx<32;bit_idx++)if(mag[bit_idx])lead=bit_idx;
    return fp32_legacy_ref_pkg::pack_scaled32(x<0,mag<<(31-lead),
      ea+eb+fold-266+lead,mag==0,ea==255||eb==255);
  endfunction
  function automatic pair_meta_t meta_ref(input int tile,pair_idx);
    pair_meta_t m;
    m='0;m.epoch=current.epoch;m.head=current.head;
    m.token=current.token;m.work_seq=current.work_seq;m.block_id=current.block_id;
    m.role=current.mode==MAT_GU?(tile[0]?ROLE_UP:ROLE_GATE):current.role;
    m.tile_idx=SEQ_BITS'(tile);m.pair_idx=PAIR_BITS'(pair_idx);m.m_rows=current.m_rows;
    m.nt=current.nt;m.exp_fold=current.exp_fold;m.mode=current.mode;m.gu_n=current.gu_n;
    m.acc_sel=current.acc_sel;m.add_old=current.add_old||tile!=0;
    m.final_k=tile==int'(current.tiles)-1;
    if(current.mode==MAT_GU)begin
      m.acc_sel=tile[0]?ACC_FACC_B:ACC_FACC_A;m.add_old=current.add_old||tile>=2;
      m.final_k=tile>=int'(current.tiles)-2;
    end else if(current.nt_per_tile)begin
      m.nt=TILE_BITS'(int'(current.nt)+tile);m.add_old=current.add_old;m.final_k=1;
    end
    m.last=tile==int'(current.tiles)-1&&pair_idx==pairs_for_rows(current.m_rows)-1;
    return m;
  endfunction

  // Real A/B producers: B is column-major, four groups per stationary tile.
  // No psum or FP32 result is injected into the DUT.
  always @(negedge clk)begin
    a2_t next_a;b4_t next_b;int tile,pair_idx;
    a_valid=0;b_valid=0;
    if(!reset&&!clear&&feeding)begin
      if(a_sent<int'(current.tiles)*pairs_for_rows(current.m_rows))begin
        tile=a_sent/pairs_for_rows(current.m_rows);pair_idx=a_sent%pairs_for_rows(current.m_rows);
        next_a='0;next_a.token=current.token;next_a.work_seq=current.work_seq;
        next_a.tile_idx=SEQ_BITS'(tile);next_a.pair_idx=PAIR_BITS'(pair_idx);
        next_a.row_valid=row_mask_for_rows(current.m_rows,pair_idx);
        for(int r=0;r<ROW_LANES;r++)begin
          next_a.row[r].scale=8'(ascale(tile,2*pair_idx+r));
          for(int k=0;k<TILE;k++)next_a.row[r].data[k*INT_BITS+:INT_BITS]=
            8'(next_a.row_valid[r]?avalue(tile,2*pair_idx+r,k):127);
        end
        a=next_a;a_bank=tile[0];a_valid=1;
      end
      if(b_sent<int'(current.tiles)*B_LOAD_GROUPS)begin
        tile=b_sent/B_LOAD_GROUPS;
        next_b='0;next_b.token=current.token;next_b.work_seq=current.work_seq;
        next_b.role=current.mode==MAT_GU?(tile[0]?ROLE_UP:ROLE_GATE):current.role;
        next_b.bank=tile[0];next_b.tile_idx=SEQ_BITS'(tile);
        next_b.group_idx=B_GROUP_BITS'(b_sent%B_LOAD_GROUPS);
        for(int n=0;n<TILE;n++)next_b.scales[n]=8'(bscale(tile,n));
        for(int c=0;c<B_LOAD_COLS;c++)for(int k=0;k<TILE;k++)
          next_b.data[c][k*INT_BITS+:INT_BITS]=8'(bvalue(tile,k,int'(next_b.group_idx)*B_LOAD_COLS+c));
        b=next_b;b_valid=ideal||cycle%7!=0;
      end
    end
  end

  always @(posedge clk)begin
    mxu_rsp_t expected;acc_write_t write_expected;pair_meta_t metadata;
    int tile,pair_idx,address,dot,pairs,interval;
    cycle++;
    if(reset||clear)begin
      expected_valid=0;
      for(int sel=0;sel<3;sel++)for(int addr=0;addr<PAIRS*TILE;addr++)
        for(int r=0;r<ROW_LANES;r++)for(int n=0;n<TILE;n++)model[sel][addr][r][n]=0;
    end else begin
      for(int s=COMMIT_DELAY;s>0;s--)begin
        expected_valid[s]=expected_valid[s-1];expected_psum[s]=expected_psum[s-1];
        expected_write[s]=expected_write[s-1];
      end
      expected_valid[0]=issue_valid;
      if(b_valid&&b_ready)b_sent++;
      if(issue_valid)begin
        pairs=pairs_for_rows(current.m_rows);tile=a_sent/pairs;pair_idx=a_sent%pairs;
        metadata=meta_ref(tile,pair_idx);
        if(issue_meta!==metadata)$fatal(1,"Issue metadata mismatch tile=%0d pair=%0d",tile,pair_idx);
        if(a_tile_reserve!==(pair_idx==0))$fatal(1,"A reservation boundary mismatch");
        if(first_issue<0)first_issue=cycle;
        if(ideal&&pair_idx!=0&&cycle!=last_issue+1)$fatal(1,"Intra-tile throughput stall");
        if(pair_idx==0)begin
          interval=pairs<ACC_RAW_INTERVAL?ACC_RAW_INTERVAL:pairs;
          if(ideal&&previous_tile>=0&&cycle-previous_first!=interval)
            $fatal(1,"Tile interval got=%0d expected=%0d M=%0d",cycle-previous_first,interval,current.m_rows);
          previous_tile=tile;previous_first=cycle;
        end
        last_issue=cycle;
        expected='0;write_expected='0;expected.meta=metadata;
        expected.row_valid=row_mask_for_rows(current.m_rows,pair_idx);
        write_expected.sel=metadata.acc_sel;
        address=metadata.acc_sel==ACC_OACC?pair_idx*TILE+int'(metadata.nt):pair_idx;
        write_expected.addr=10'(address);write_expected.row_valid=expected.row_valid;
        for(int n=0;n<TILE;n++)expected.e_stat[n]=8'(bscale(tile,n));
        for(int r=0;r<ROW_LANES;r++)begin
          expected.e_stream[r]=8'(ascale(tile,2*pair_idx+r));
          for(int n=0;n<TILE;n++)begin
            dot=0;
            if(expected.row_valid[r])for(int k=0;k<TILE;k++)
              dot+=avalue(tile,2*pair_idx+r,k)*bvalue(tile,k,n);
            expected.psum[r][n]=dot;
            if(expected.row_valid[r])begin
              write_expected.data[r][n]=dequant_ref(dot,ascale(tile,2*pair_idx+r),bscale(tile,n),
                int'($signed(current.exp_fold)));
              if(metadata.add_old)write_expected.data[r][n]=fp32_legacy_ref_pkg::fp32_add(
                model[metadata.acc_sel][address][r][n],write_expected.data[r][n]);
              model[metadata.acc_sel][address][r][n]=write_expected.data[r][n];
            end
          end
        end
        expected_psum[0]=expected;expected_write[0]=write_expected;a_sent++;
      end
      if(dut.deqacc.groups[0].compute.keys[1].valid&&dut.deqacc.groups[0].compute.keys[1].add_old)begin
        if(|dut.deqacc.groups[0].compute.use_a3)forward_a3++;
        if(|dut.deqacc.groups[0].compute.use_c)forward_c++;
      end
    end
    #1;
    if(psum_valid!==expected_valid[MXU_PIPE_STAGES-1])$fatal(1,"MXU latency/valid mismatch");
    if(psum_valid)begin
      if(psum_rsp!==expected_psum[MXU_PIPE_STAGES-1])$fatal(1,"MXU psum/scale/tag mismatch case=%0d pair=%0d",cases,psum_rsp.meta.pair_idx);
      psum_checks++;
    end
    if(commit_valid!==expected_valid[COMMIT_DELAY]||commit_write_valid!==commit_valid)
      $fatal(1,"DEQACC commit latency/valid mismatch");
    if(commit_valid)begin
      if(commit_meta!==expected_psum[COMMIT_DELAY].meta||
        commit_write.sel!==expected_write[COMMIT_DELAY].sel||
        commit_write.addr!==expected_write[COMMIT_DELAY].addr||
        commit_write.row_valid!==expected_write[COMMIT_DELAY].row_valid)
        $fatal(1,"DEQACC commit metadata mismatch");
      for(int r=0;r<ROW_LANES;r++)if(commit_write.row_valid[r])for(int n=0;n<TILE;n++)
        if(commit_write.data[r][n]!==expected_write[COMMIT_DELAY].data[r][n])
          $fatal(1,"FP32 accumulate mismatch M=%0d t=%0d p=%0d r=%0d n=%0d got=%h expected=%h",
            current.m_rows,commit_meta.tile_idx,commit_meta.pair_idx,r,n,
            commit_write.data[r][n],expected_write[COMMIT_DELAY].data[r][n]);
      committed++;total_commits++;
    end
    if(!reset&&!clear&&protocol_error&&!allow_protocol_error)$fatal(1,"Unexpected loader protocol error");
  end

  task automatic read_pair(input acc_sel_e sel,input int addr,rows);
    int pair_idx;logic [1:0] mask;
    pair_idx=sel==ACC_OACC?addr/TILE:addr;mask=row_mask_for_rows(rows,pair_idx);
    @(negedge clk);result_rd_valid=1;result_rd_sel=sel;result_rd_addr=10'(addr);
    @(posedge clk);
    if(!result_rd_ready)$fatal(1,"Result unexpectedly backpressured");
    #1;
    if(!result_rd_data_valid)$fatal(1,"Synchronous result read valid missing");
    for(int n=0;n<TILE;n++)begin
      if(result_even_data[n]!==model[sel][addr][0][n])$fatal(1,"Even ACC read mismatch");
      if(result_odd_data[n]!==(mask[1]?model[sel][addr][1][n]:32'b0))
        $fatal(1,"Odd ACC read mismatch/stale tail row");
    end
    read_checks++;
    @(negedge clk);result_rd_valid=0;
  endtask

  task automatic run_case(input int rows,tiles,input matrix_mode_e mode,
    input bit pv,input acc_sel_e sel,input bit old_value,input bit ideal_feed);
    compute_job_t next_job;int total,pairs;
    pairs=pairs_for_rows(rows);total=pairs*tiles;
    next_job='0;next_job.m_rows=ROW_COUNT_BITS'(rows);next_job.tiles=MATRIX_TILE_COUNT_BITS'(tiles);
    next_job.mode=mode;next_job.nt_per_tile=pv;next_job.acc_sel=sel;next_job.add_old=old_value;
    next_job.token=32'h12340000+32'(cases);next_job.work_seq=SEQ_BITS'(cases);
    next_job.block_id=6'(cases);next_job.role=mode==MAT_ATTENTION?(pv?ROLE_V:ROLE_K):ROLE_WEIGHT;
    next_job.epoch=EPOCH_BITS'(cases);next_job.head=3'(cases);next_job.gu_n=6'(cases);
    next_job.exp_fold=EXP_FOLD_BITS'(cases%10-5);
    @(negedge clk);current=next_job;job=next_job;job_valid=1;
    a_sent=0;b_sent=0;committed=0;first_issue=-1;last_issue=-1;previous_tile=-1;previous_first=-1;
    seed=cases;ideal=ideal_feed;feeding=0;
    @(posedge clk);if(!job_ready)$fatal(1,"Job unexpectedly rejected");
    @(negedge clk);job_valid=0;feeding=rows!=0;
    while(!done_valid)@(negedge clk);
    feeding=0;
    if(a_sent!=total||committed!=total||b_sent!=(rows==0?0:tiles*B_LOAD_GROUPS))
      $fatal(1,"Job transaction count mismatch rows=%0d a=%0d c=%0d b=%0d",rows,a_sent,committed,b_sent);
    // Retirement is the physical C write, not an extra registered notification.
    if(rows!=0&&cycle!=last_issue+COMMIT_DELAY)$fatal(1,"Job completion boundary mismatch");
    if(done_work!==next_job)$fatal(1,"Retired work identity mismatch");
    if(rows==0&&(a_ready||b_ready||psum_valid||commit_valid))$fatal(1,"M0 not an empty job");
    if(rows!=0)begin
      for(int p=0;p<pairs;p++)begin
        if(mode==MAT_GU)begin read_pair(ACC_FACC_A,p,rows);read_pair(ACC_FACC_B,p,rows);end
        else if(pv)for(int nt=0;nt<tiles;nt++)read_pair(ACC_OACC,p*TILE+nt,rows);
        else read_pair(sel,sel==ACC_OACC?p*TILE:p,rows);
      end
      // Addresses outside the current compact region may contain old data,
      // but must not be accepted as result/VPU accesses.
      @(negedge clk);result_rd_sel=mode==MAT_GU?ACC_FACC_A:sel;
      result_rd_addr=10'(result_rd_sel==ACC_OACC?pairs*TILE:pairs);result_rd_valid=1;
      @(posedge clk);if(result_rd_ready)$fatal(1,"Out-of-M read accepted");
      @(negedge clk);result_rd_valid=0;
    end
    $display("CASE M=%0d tiles=%0d mode=%0d PV=%0d ideal=%0d issues=%0d first_to_commit=%0d tile_interval=%0d",
      rows,tiles,mode,pv,ideal_feed,total,rows==0?0:last_issue-first_issue+COMMIT_DELAY,
      pairs<ACC_RAW_INTERVAL?ACC_RAW_INTERVAL:pairs);
    done_ready=1;@(negedge clk);done_ready=0;cases++;
  endtask

  task automatic external_write_check;
    acc_write_t next_write;
    next_write='0;next_write.sel=ACC_FACC_A;next_write.addr=0;next_write.row_valid=2'b01;
    for(int n=0;n<TILE;n++)next_write.data[0][n]=32'h3f800000+32'(n);
    @(negedge clk);vpu_wr=next_write;vpu_wr_valid=1;
    @(posedge clk);if(!vpu_wr_ready)$fatal(1,"VPU write unexpectedly rejected");
    for(int n=0;n<TILE;n++)model[ACC_FACC_A][0][0][n]=next_write.data[0][n];
    @(negedge clk);vpu_wr_valid=0;
    read_pair(ACC_FACC_A,0,1);
    @(negedge clk);vpu_wr.row_valid=2'b11;vpu_wr_valid=1;
    @(posedge clk);if(vpu_wr_ready)$fatal(1,"Out-of-M VPU row write accepted");
    @(negedge clk);vpu_wr_valid=0;
  endtask

  task automatic flush_core;
    @(negedge clk);#0.2;clear=1;feeding=0;a_valid=0;b_valid=0;job_valid=0;
    @(negedge clk);#0.2;clear=0;
    repeat(COMMIT_DELAY+2)@(negedge clk);
    if(busy||done_valid||psum_valid||commit_valid||protocol_error)
      $fatal(1,"Compute clear failed to flush context and all stages");
  endtask

  task automatic cancellation_check;
    compute_job_t next_job;
    next_job='0;next_job.m_rows=5;next_job.tiles=16;next_job.acc_sel=ACC_FACC_A;
    @(negedge clk);current=next_job;job=next_job;job_valid=1;feeding=0;
    a_sent=0;b_sent=0;first_issue=-1;previous_tile=-1;previous_first=-1;
    ideal=1;seed=99;
    @(posedge clk);if(!job_ready)$fatal(1,"Cancel test job rejected");
    @(negedge clk);job_valid=0;feeding=1;
    while(a_sent<3)@(negedge clk);
    flush_core();
  endtask

  task automatic rejection_checks;
    compute_job_t next_job;a2_t bad_a;b4_t bad_b;
    allow_protocol_error=1;
    next_job='0;next_job.m_rows=ROW_COUNT_BITS'(ROWS+1);next_job.tiles=16;
    @(negedge clk);current=next_job;job=next_job;job_valid=1;
    @(posedge clk);if(!job_ready)$fatal(1,"Illegal job must be acknowledged with an error");
    #1;if(!protocol_error||!done_valid||issue_valid||b_ready)$fatal(1,"M>51 not rejected");
    protocol_checks++;flush_core();
    for(int which=0;which<2;which++)begin
      next_job='0;next_job.m_rows=1;next_job.tiles=2;
      @(negedge clk);job=next_job;current=next_job;job_valid=1;
      @(posedge clk);if(!job_ready)$fatal(1,"Protocol test job rejected");
      @(negedge clk);#0.2;job_valid=0;
      bad_a='0;bad_a.row_valid=2'b11;bad_b='0;bad_b.group_idx=2;
      if(which==0)begin a=bad_a;a_bank=0;a_valid=1;end
      else begin b=bad_b;b_valid=1;end
      @(posedge clk);#1;
      if(!protocol_error||issue_valid||b_ready||a_ready)$fatal(1,"Malformed A/B not rejected");
      @(negedge clk);#0.2;a_valid=0;b='0;b_valid=1;
      @(posedge clk);if(b_ready)$fatal(1,"Protocol error must hold transfers until clear");
      protocol_checks++;flush_core();
    end
    allow_protocol_error=0;
  endtask

  initial begin
    repeat(32)@(negedge clk);reset=0;
    for(int m=0;m<=ROWS;m++)run_case(m,16,MAT_PROJECTION,0,ACC_FACC_A,0,1);
    // Real 1024-wide K reduction and 128-tile interleaved Gate/Up.
    run_case(1,64,MAT_PROJECTION,0,ACC_FACC_A,0,1);
    external_write_check();
    run_case(2,64,MAT_PROJECTION,0,ACC_FACC_A,0,1);
    run_case(9,64,MAT_PROJECTION,0,ACC_FACC_A,0,1);
    run_case(11,64,MAT_PROJECTION,0,ACC_FACC_A,0,1);
    run_case(51,64,MAT_PROJECTION,0,ACC_FACC_A,0,1);
    run_case(1,128,MAT_GU,0,ACC_FACC_A,0,1);
    run_case(51,128,MAT_GU,0,ACC_FACC_A,0,1);
    run_case(1,16,MAT_ATTENTION,1,ACC_OACC,0,1);
    run_case(1,16,MAT_ATTENTION,1,ACC_OACC,1,1);
    run_case(51,16,MAT_ATTENTION,1,ACC_OACC,0,1);
    run_case(7,16,MAT_ATTENTION,1,ACC_OACC,0,1);
    run_case(7,16,MAT_ATTENTION,1,ACC_OACC,1,1);
    run_case(3,16,MAT_ATTENTION,0,ACC_FACC_B,0,0);
    run_case(20,32,MAT_PROJECTION,0,ACC_FACC_A,0,0);
    // Shrink/grow without clearing RAM, including an odd stale tail.
    run_case(51,16,MAT_PROJECTION,0,ACC_FACC_A,0,1);
    run_case(1,16,MAT_PROJECTION,0,ACC_FACC_A,0,1);
    run_case(50,16,MAT_PROJECTION,0,ACC_FACC_A,0,1);
    run_case(0,0,MAT_PROJECTION,0,ACC_FACC_A,0,1);
    cancellation_check();
    rejection_checks();
    run_case(3,16,MAT_PROJECTION,0,ACC_FACC_A,0,1);
    if(forward_a3==0||forward_c==0)$fatal(1,"Forward coverage missing A3=%0d C=%0d",forward_a3,forward_c);
    $display("tb_dynamic_compute PASS cases=%0d M0_to_M51=1 psum_checks=%0d commits=%0d reads=%0d A3=%0d C=%0d mxu_delay=%0d commit_delay=%0d II=1 min_tile_interval=4 cancel=1 protocol_rejections=%0d",
      cases,psum_checks,total_commits,read_checks,forward_a3,forward_c,MXU_PIPE_STAGES-1,COMMIT_DELAY,protocol_checks);
    $finish;
  end
  initial begin #3000000;$fatal(1,"Dynamic compute watchdog");end
endmodule
