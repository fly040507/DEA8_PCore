`timescale 1ns/1ps
import pcore3_pkg::*;
import fp32_legacy_ref_pkg::*;

// Full 55-KV-block matrix run. VPU/SFU arithmetic and external A/B/P supplies
// are TB models; scheduler, ingress, MXU, DEQACC and accumulators are RTL.
module tb_v3_attention_55;
  localparam int BLOCKS=KV_BLOCKS;
  localparam int JOBS=2*BLOCKS;
  // Model the planned doubled VPU/SFU lanes. Matrix data and final OACC
  // values remain checked through RTL; only arithmetic-side token latency is
  // abstracted for the attention scheduling run.
  bit FAST_VPU_SFU_MODEL;
  initial FAST_VPU_SFU_MODEL=!$test$plusargs("PORT_STRESS");
  logic tail_launch_ready;
  localparam int SFU_P_EXP_CYCLES=204;
  localparam int VPU_OACC_SCALE_CYCLES=208;
  localparam int VPU_AFIN_CYCLES=408;
  logic clk=0; always #2 clk=~clk;
  logic reset=1,clear=0;
  logic start_valid=0,start_ready,busy,done_valid,done_ready=1;
  logic [2:0] start_head=3'd2;
  logic [EPOCH_BITS-1:0] start_epoch=4'h5;
  logic matrix_valid,matrix_ready,matrix_done_valid,matrix_done_ready;
  matrix_cmd_t matrix_cmd,matrix_done;
  logic vpu_valid,vpu_ready=1,vpu_done_valid=0,vpu_done_ready;
  vpu_cmd_t vpu_cmd,vpu_done;
  logic sfu_valid,sfu_ready=1,sfu_done_valid=0,sfu_done_ready;
  sfu_cmd_t sfu_cmd,sfu_done;
  logic qoz_load_valid=0,qoz_load_ready; a2_t qoz_load_entry;
  logic replay_load_valid=0,replay_load_ready; a2_t replay_load_entry;
  logic [5:0] replay_load_block;
  logic hbm_valid=0,hbm_ready; b2_t hbm_entry;
  logic kv_valid=0,kv_ready; b2_t kv_entry;
  logic a_error,b_error;
  logic dbg_valid=0,dbg_parity=0; acc_sel_e dbg_sel=ACC_OACC;
  logic [9:0] dbg_addr=0; logic [3:0] dbg_lane=0; logic [31:0] dbg_data;
  int accepts=0,completions=0,checked=0,loads=0,a_beats=0,b_beats=0;
  int cycle_count=0;
  int accepted_cycle[0:JOBS-1];
  matrix_cmd_t accepted_cmd[0:JOBS-1];
  logic result_rd_valid=0,result_rd_ready,result_rd_data_valid;
  acc_sel_e result_rd_sel=ACC_OACC;
  logic [9:0] result_rd_addr=0;
  logic [15:0][31:0] result_even_data,result_odd_data;
  logic vpu_wr_valid=0,vpu_wr_ready;acc_write_t vpu_wr;
  int vpu_reads=0,vpu_writes=0,overlap_reads=0,overlap_writes=0;
  int request_cycle[0:JOBS-1],commit_cycle[0:JOBS-1],issue_cycle[0:JOBS-1];
  int issue_first_cycle[0:JOBS-1],issue_last_cycle[0:JOBS-1];
  int requests=0,commits=0,issues_in_job=0,issue_jobs=0;
  int min_commit_tail=1<<30,max_commit_tail=0;
  int tail_accept_cycle=-1,tail_prefetch_cycle=-1,tail_guard_release=-1;
  int min_matrix_body=1<<30,max_matrix_body=0;
  int min_issue_interval=1<<30,max_issue_interval_steady=0;
  int min_handoff=1<<30,max_handoff=0;
  int attention_start_cycle=-1,attention_done_cycle=-1;
  bit request_seen=0;

  dea8_attention_scheduler_v4 #(.BLOCKS(BLOCKS)) scheduler(
    .tail_launch_ready,
    .clk,.reset,.clear,.start_valid,.start_ready,.busy,.start_head,.start_epoch,
    .done_valid,.done_ready,.matrix_valid,.matrix_ready,.matrix_cmd,
    .matrix_done_valid,.matrix_done_ready,.matrix_done,
    .vpu_valid,.vpu_ready,.vpu_cmd,.vpu_done_valid,.vpu_done_ready,.vpu_done,
    .sfu_valid,.sfu_ready,.sfu_cmd,.sfu_done_valid,.sfu_done_ready,.sfu_done);

  dea8_attention_matrix_v3 matrix(
    .tail_launch_ready,
    .clk,.reset,.clear,.cmd_valid(matrix_valid),.cmd_ready(matrix_ready),.cmd(matrix_cmd),
    .done_valid(matrix_done_valid),.done_ready(matrix_done_ready),.done_cmd(matrix_done),
    .qoz_load_valid,.qoz_load_ready,.qoz_load_entry,.qoz_load_epoch(start_epoch),.qoz_load_head(start_head),
    .replay_load_valid,.replay_load_ready,.replay_load_entry,
    .replay_load_epoch(start_epoch),.replay_load_head(start_head),.replay_load_block,
    .hbm_valid,.hbm_ready,.hbm_entry,.kv_valid,.kv_ready,.kv_entry,.b_source(B_KVB),
    .vpu_wr_valid,.vpu_wr,.vpu_wr_ready,.result_rd_ready,
    .a_protocol_error(a_error),.b_protocol_error(b_error),
    .result_rd_owner(ACC_READ_RESULT),.result_rd_valid,.result_rd_sel,
    .result_rd_addr,.result_rd_data_valid,.result_even_data,.result_odd_data,
    .dbg_valid,.dbg_sel,.dbg_parity,.dbg_addr,.dbg_lane,.dbg_data);

  function automatic int q_value(input int row);
    return 1+(row%3);
  endfunction
  function automatic int p_value(input int block,input int row);
    return 1+(block%2)+((row%3)==1);
  endfunction
  function automatic int b_value(input int block,input int column);
    return 1+(block%3)+(column%2);
  endfunction
  function automatic qvec16_t qvec(input int value);
    qvec16_t v;
    v='0;v.scale=8'd128;
    for(int k=0;k<TILE;k++) v.data[k*8+:8]=8'(value);
    return v;
  endfunction
  function automatic logic [31:0] scaled_psum(input int psum,input int fold);
    int lead;
    logic [31:0] normalized;
    if(psum==0) return 32'b0;
    lead=0;
    for(int bit_idx=0;bit_idx<32;bit_idx++) if(psum[bit_idx]) lead=bit_idx;
    normalized=32'(psum) << (31-lead);
    return pack_scaled32(1'b0,normalized,128+128-DOT_EXP_OFFSET+fold+lead,1'b0,1'b0);
  endfunction
  function automatic logic [31:0] qk_expected(input int block,input int row,input int col);
    logic [31:0] partial,result;
    partial=scaled_psum(TILE*q_value(row)*b_value(block,col),-4);
    result=partial;
    for(int t=1;t<ATTN_K_TILES;t++) result=fp32_add(result,partial);
    return result;
  endfunction
  function automatic logic [31:0] pv_expected(input int block,input int row,input int col);
    logic [31:0] result,partial;
    result=0;
    for(int b=0;b<=block;b++) begin
      partial=scaled_psum(TILE*p_value(b,row)*b_value(b,col),0);
      result=(b==0)?partial:fp32_add(result,partial);
    end
    return result;
  endfunction

  task automatic send_a(input int tile,input int pair);
    a2_t e;
    e='0;e.tile_idx=TILE_BITS'(tile);e.pair_idx=PAIR_BITS'(pair);e.row_valid=row_mask(pair);
    for(int r=0;r<2;r++) e.row[r]=qvec(q_value(2*pair+r));
    qoz_load_entry=e;qoz_load_valid=1;
    do begin @(posedge clk); end while(qoz_load_ready!==1'b1);
    @(negedge clk);qoz_load_valid=0;
  endtask
  task automatic send_b(input int tile,input int group,input int block);
    b2_t e;
    e='0;e.tile_idx=TILE_BITS'(tile);e.group_idx=3'(group);e.epoch=start_epoch;
    e.col[0]=qvec(b_value(block,2*group));
    e.col[1]=qvec(b_value(block,2*group+1));
    kv_entry=e; kv_valid=1;
    do begin @(posedge clk); end while(kv_ready!==1'b1);
    @(negedge clk); kv_valid=0;
  endtask
  task automatic send_replay(input int block,input int group);
    a2_t e; int guard;
    e='0;e.slot=block[0];e.pair_idx=PAIR_BITS'(group);e.row_valid=row_mask(group);
    for(int r=0;r<2;r++) e.row[r]=qvec(p_value(block,2*group+r));
    @(negedge clk);
    guard=0; replay_load_entry=e;replay_load_block=6'(block);replay_load_valid=1;
    do begin
      @(posedge clk); guard++;
      if(guard>100) $fatal(1,"replay load did not become ready block=%0d group=%0d",block,group);
    end while(replay_load_ready!==1'b1);
    @(negedge clk); replay_load_valid=0;
  endtask
  task automatic produce_job(input matrix_cmd_t c,input int stream_base);
        @(negedge clk);
        for(int t=0;t<ATTN_K_TILES;t++)
          for(int g=0;g<TILE/2;g++) send_b(stream_base+t,g,int'(c.block_id));
  endtask

  task automatic read_check(input acc_sel_e sel,input int row,input int col,
                            input logic [31:0] expected,input int block);
    dbg_valid=1;dbg_sel=sel;dbg_parity=row[0];
    dbg_addr=10'(sel==ACC_OACC?oacc_addr(row/2,col/TILE):row/2);
    dbg_lane=4'(col%TILE);
    #1;
    if(dbg_data!==expected)
      $fatal(1,"numeric mismatch block=%0d sel=%0d row=%0d col=%0d got=%h want=%h",
        block,sel,row,col,dbg_data,expected);
  endtask
  task automatic check_block(input matrix_cmd_t c);
    int b;
    b=int'(c.block_id);
    #1;
    if(c.op==MATRIX_QK) begin
      for(int r_sel=0;r_sel<3;r_sel++) begin
        int row;
        row=(r_sel==0)?0:((r_sel==1)?1:50);
        for(int n_sel=0;n_sel<3;n_sel++) begin
          int col;
          col=(n_sel==0)?0:((n_sel==1)?1:15);
          read_check(c.acc_sel,row,col,qk_expected(b,row,col),b);
        end
      end
    end else begin
      for(int r_sel=0;r_sel<3;r_sel++) begin
        int row;
        row=(r_sel==0)?0:((r_sel==1)?1:50);
        for(int n_sel=0;n_sel<4;n_sel++) begin
          int col;
          col=(n_sel==0)?0:((n_sel==1)?15:((n_sel==2)?128:255));
          read_check(ACC_OACC,row,col,pv_expected(b,row,col),b);
        end
      end
    end
    dbg_valid=0;
    checked++;
  endtask

  // Real RAM traffic through the public VPU ports. Arithmetic remains a model:
  // OACC scale is identity so the existing independent block sums still apply.
  task automatic vpu_read_vector(input acc_sel_e sel,input int addr,
                                 input int block,input bit write_back);
    logic [15:0][31:0] even_data,odd_data;
    int pair_idx,nt;
    pair_idx=(sel==ACC_OACC)?addr/16:addr;nt=(sel==ACC_OACC)?addr%16:0;
    @(negedge clk);result_rd_sel=sel;result_rd_addr=10'(addr);result_rd_valid=1;
    do @(posedge clk); while(!result_rd_ready);
    #1;
    if(!result_rd_data_valid) $fatal(1,"VPU accepted read has no response");
    even_data=result_even_data;odd_data=result_odd_data;
    for(int n=0;n<16;n++) begin
      if(even_data[n]!==((sel==ACC_OACC)?pv_expected(block,2*pair_idx,16*nt+n):qk_expected(block,2*pair_idx,n)))
        $fatal(1,"VPU even read mismatch sel=%0d block=%0d addr=%0d lane=%0d",sel,block,addr,n);
      if(odd_data[n]!==((2*pair_idx+1>=ROWS)?32'b0:
          ((sel==ACC_OACC)?pv_expected(block,2*pair_idx+1,16*nt+n):qk_expected(block,2*pair_idx+1,n))))
        $fatal(1,"VPU odd read mismatch sel=%0d block=%0d addr=%0d lane=%0d",sel,block,addr,n);
    end
    @(negedge clk);result_rd_valid=0;
    if(write_back) begin
      vpu_wr='0;vpu_wr.sel=sel;vpu_wr.addr=10'(addr);vpu_wr.row_valid=row_mask(pair_idx);
      vpu_wr.data[0]=even_data;vpu_wr.data[1]=odd_data;vpu_wr_valid=1;
      do @(posedge clk); while(!vpu_wr_ready);
      @(negedge clk);vpu_wr_valid=0;
    end
  endtask

  // One outstanding command per modeled unit. PBUF is populated by the VPU
  task automatic vpu_vectors(input acc_sel_e sel,input int block,input bit write_back);
    int total,issued,received,written,addr,pair_idx,nt;
    logic accepted;
    total=(sel==ACC_OACC)?PAIRS*TILE:PAIRS;issued=0;received=0;written=0;
    @(negedge clk);
    while(received<total||(write_back&&written<total)) begin
      result_rd_valid=issued<total;result_rd_sel=sel;result_rd_addr=10'(issued);
      @(posedge clk);
      accepted=result_rd_valid&&result_rd_ready;
      if(vpu_wr_valid) begin
        if(!vpu_wr_ready) $fatal(1,"VPU scheduled write bank conflict");
        written++;
      end
      #1;
      if(result_rd_data_valid) begin
        addr=received;pair_idx=(sel==ACC_OACC)?addr/16:addr;nt=(sel==ACC_OACC)?addr%16:0;
        for(int n=0;n<16;n++) begin
          if(result_even_data[n]!==((sel==ACC_OACC)?pv_expected(block,2*pair_idx,16*nt+n):qk_expected(block,2*pair_idx,n)))
            $fatal(1,"pipelined VPU even mismatch block=%0d addr=%0d",block,addr);
          if(result_odd_data[n]!==((2*pair_idx+1>=ROWS)?32'b0:
            ((sel==ACC_OACC)?pv_expected(block,2*pair_idx+1,16*nt+n):qk_expected(block,2*pair_idx+1,n))))
            $fatal(1,"pipelined VPU odd mismatch block=%0d addr=%0d",block,addr);
        end
        received++;
      end
      if(accepted) issued++;
      @(negedge clk);
      vpu_wr_valid=write_back&&accepted;
      if(accepted) begin
        vpu_wr='0;vpu_wr.sel=sel;vpu_wr.addr=10'(received-1);
        vpu_wr.row_valid=row_mask((received-1)/16);
        vpu_wr.data[0]=result_even_data;vpu_wr.data[1]=result_odd_data;
      end
    end
    result_rd_valid=0;vpu_wr_valid=0;
  endtask

  // One outstanding command per modeled unit. PBUF is populated by the VPU
  // post-P model; SFU P-exp takes SFU_P_EXP_CYCLES independently.
  initial begin : vpu_model
    vpu_cmd_t c;
    wait(!reset);
    forever begin
      @(posedge clk);
      if(vpu_valid&&vpu_ready) begin
        c=vpu_cmd;
        if(c.op==VPU_P_POST) begin
          for(int g=0;g<PAIRS;g++) send_replay(int'(c.block_id),g);
          loads++;
          repeat(20) @(negedge clk);
        end else if(c.op==VPU_QK_POST) begin
          vpu_vectors(c.facc_bank?ACC_FACC_B:ACC_FACC_A,int'(c.block_id),0);
        end else if(c.op==VPU_OACC_SCALE||c.op==VPU_AFIN) begin
          if(FAST_VPU_SFU_MODEL) begin
            repeat((c.op==VPU_AFIN)?VPU_AFIN_CYCLES:VPU_OACC_SCALE_CYCLES)
              @(negedge clk);
          end else begin
            vpu_vectors(ACC_OACC,(c.op==VPU_AFIN)?BLOCKS-1:int'(c.block_id)-1,1);
          end
        end
        else repeat(20) @(negedge clk);
        @(negedge clk);vpu_done=c;vpu_done_valid=1;
        @(negedge clk);vpu_done_valid=0;
      end
    end
  end
  initial begin : sfu_model
    sfu_cmd_t c;
    wait(!reset);
    forever begin
      @(posedge clk);
      if(sfu_valid&&sfu_ready) begin
        c=sfu_cmd;
        if(c.op==SFU_P_EXP) repeat(SFU_P_EXP_CYCLES) @(negedge clk);
        else repeat(26) @(negedge clk);
        @(negedge clk);sfu_done=c;sfu_done_valid=1;
        @(negedge clk);sfu_done_valid=0;
      end
    end
  end

  always @(posedge clk) if(!reset&&!clear) begin
    int expected_block;
    matrix_op_e expected_op;
    cycle_count++;
    if(start_valid&&start_ready&&attention_start_cycle<0)
      attention_start_cycle=cycle_count;
    if(done_valid&&done_ready)
      attention_done_cycle=cycle_count;
    if(matrix_valid&&!request_seen) begin
      request_cycle[requests]=cycle_count;requests++;request_seen=1;
    end
    if(matrix_valid&&matrix_ready) request_seen=0;
    if(matrix.private_matrix.matrix.req_valid) begin
      if(issues_in_job==0) begin
        issue_cycle[issue_jobs]=cycle_count;
        issue_first_cycle[issue_jobs]=cycle_count;
      end
      issue_last_cycle[issue_jobs]=cycle_count;
      issues_in_job++;
      if(issues_in_job==ATTN_ISSUES) begin issues_in_job=0;issue_jobs++;end
    end
    if(matrix.matrix_done) begin
      commit_cycle[commits]=cycle_count;
      if(commits<6) $display("ATTN_TRACE job=%0d issue_first=%0d issue_last=%0d commit=%0d",
        commits,issue_first_cycle[commits],issue_last_cycle[commits],cycle_count);
      commits++;
    end
    if(matrix_valid&&matrix_ready&&matrix_cmd.job_last) tail_accept_cycle=cycle_count;
    if(matrix.read_start&&matrix.pending_cmd_q.job_last) tail_prefetch_cycle=cycle_count;
    if(tail_launch_ready&&tail_guard_release<0) tail_guard_release=cycle_count;
    if(result_rd_valid&&result_rd_ready) begin
      vpu_reads++;
      if(matrix.private_matrix.matrix.job_busy) overlap_reads++;
    end
    if(vpu_wr_valid&&vpu_wr_ready) begin
      vpu_writes++;
      if(matrix.private_matrix.matrix.job_busy) overlap_writes++;
    end
    if(qoz_load_valid&&qoz_load_ready) a_beats++;
    if(kv_valid&&kv_ready) b_beats++;
    if(matrix.private_matrix.matrix.job_busy&&hbm_ready) $fatal(1,"Attention must select KVB during a job");
    if(matrix_valid&&matrix_ready) begin
      if(accepts>=JOBS) $fatal(1,"extra matrix command");
      if(accepts==0) begin expected_op=MATRIX_QK;expected_block=0;end
      else if(accepts==JOBS-1) begin expected_op=MATRIX_PV;expected_block=BLOCKS-1;end
      else if(accepts%2) begin expected_op=MATRIX_QK;expected_block=(accepts+1)/2;end
      else begin expected_op=MATRIX_PV;expected_block=accepts/2-1;end
      if(matrix_cmd.op!=expected_op||matrix_cmd.block_id!=expected_block||
         matrix_cmd.a_id!=((expected_op==MATRIX_QK)?0:expected_block)||
         matrix_cmd.b_id!=expected_block*ATTN_K_TILES||
         matrix_cmd.add_old!=(expected_op==MATRIX_PV&&expected_block!=0))
        $fatal(1,"matrix command order/context mismatch index=%0d op=%0d block=%0d a=%0d b=%0d",
          accepts,matrix_cmd.op,matrix_cmd.block_id,matrix_cmd.a_id,matrix_cmd.b_id);
      accepted_cmd[accepts]=matrix_cmd;
      accepted_cycle[accepts]=cycle_count;
      accepts++;
    end
    if(matrix_done_valid&&matrix_done_ready) begin
      if(completions>=accepts||matrix_done!==accepted_cmd[completions])
        $fatal(1,"matrix completion context mismatch index=%0d",completions);
      completions++;
      fork check_block(matrix_done); join_none
      if(completions%20==0) $display("attention55 progress jobs=%0d/%0d cycle=%0d",completions,JOBS,cycle_count);
    end
    if(a_error||b_error) $fatal(1,"Attention ingress protocol error a=%0d b=%0d",a_error,b_error);
  end

  initial begin
    repeat(20) @(negedge clk);
    reset=0;
    @(negedge clk);
    for(int t=0;t<ATTN_K_TILES;t++) for(int p=0;p<PAIRS;p++) send_a(t,p);
    @(negedge clk);start_valid=1;
    @(negedge clk);start_valid=0;
    wait(done_valid);
    wait(checked==JOBS);
    if((!FAST_VPU_SFU_MODEL&&
         (vpu_reads!=BLOCKS*(PAIRS+PAIRS*TILE)||vpu_writes!=BLOCKS*PAIRS*TILE||overlap_writes==0))||
       overlap_reads==0)
      $fatal(1,"VPU RAM coverage reads=%0d writes=%0d overlaps=%0d/%0d",vpu_reads,vpu_writes,overlap_reads,overlap_writes);
    if(accepts!=JOBS||completions!=JOBS||commits!=JOBS||issue_jobs!=JOBS||loads!=BLOCKS||
       a_beats!=ATTN_K_TILES*PAIRS||
       b_beats!=JOBS*ATTN_K_TILES*(TILE/2))
      $fatal(1,"coverage count accept=%0d complete=%0d loads=%0d A=%0d B=%0d",
        accepts,completions,loads,a_beats,b_beats);
    // Full final OACC comparison: every valid row and all 256 columns.
    for(int row=0;row<ROWS;row++)
      for(int col=0;col<TILE*TILE;col++)
        read_check(ACC_OACC,row,col,pv_expected(BLOCKS-1,row,col),BLOCKS-1);
    // Row 51 is invalid and must not have acquired an OACC valid bit.
    for(int col=0;col<TILE*TILE;col++) read_check(ACC_OACC,ROWS,col,0,BLOCKS-1);
    dbg_valid=0;
    for(int j=0;j<JOBS;j++) begin
      int body;
      body=issue_last_cycle[j]-issue_first_cycle[j]+1;
      if(body!=ATTN_ISSUES) $fatal(1,"Matrix body has bubbles job=%0d body=%0d",j,body);
      if(commit_cycle[j]-issue_last_cycle[j]<min_commit_tail) min_commit_tail=commit_cycle[j]-issue_last_cycle[j];
      if(commit_cycle[j]-issue_last_cycle[j]>max_commit_tail) max_commit_tail=commit_cycle[j]-issue_last_cycle[j];
      if(body<min_matrix_body) min_matrix_body=body;
      if(body>max_matrix_body) max_matrix_body=body;
      if(j>0&&j<JOBS-1) begin
        int interval;
        interval=issue_first_cycle[j]-issue_first_cycle[j-1];
        if(FAST_VPU_SFU_MODEL&&interval!=ATTN_NOMINAL_SLOT+1)
          $fatal(1,"steady interval mismatch job=%0d interval=%0d",j,interval);
        if(interval<min_issue_interval) min_issue_interval=interval;
        if(interval>max_issue_interval_steady) max_issue_interval_steady=interval;
      end
      if(j<JOBS-2) begin
        int handoff;
        handoff=issue_first_cycle[j+1]-commit_cycle[j];
        if(handoff<min_handoff) min_handoff=handoff;
        if(handoff>max_handoff) max_handoff=handoff;
      end
    end
    if(FAST_VPU_SFU_MODEL) begin
      if(issue_first_cycle[JOBS-1]-issue_first_cycle[JOBS-2]!=2*ATTN_NOMINAL_SLOT+1)
        $fatal(1,"full tail guard interval mismatch");
      if(tail_accept_cycle>=tail_guard_release||tail_prefetch_cycle>=tail_guard_release)
        $fatal(1,"PV54 descriptor/prefetch not hidden inside tail guard");
      if(attention_done_cycle-commit_cycle[JOBS-1]!=VPU_AFIN_CYCLES+31)
        $fatal(1,"final recip/AFIN tail mismatch");
    end
    $display("ATTN_PERF mode=%s cold_start_to_first_issue=%0d cold_request_to_first_issue=%0d commit_tail=%0d..%0d",
      FAST_VPU_SFU_MODEL?"scheduling":"port_stress",issue_first_cycle[0]-attention_start_cycle,
      issue_first_cycle[0]-request_cycle[0],min_commit_tail,max_commit_tail);
    $display("ATTN_DETAIL matrix_body=%0d..%0d steady_issue_interval=%0d..%0d steady_handoff=%0d..%0d",
      min_matrix_body,max_matrix_body,min_issue_interval,max_issue_interval_steady,
      min_handoff,max_handoff);
    $display("ATTN_TAIL penultimate_PV_to_final_PV=%0d final_PV_commit_to_attention_done=%0d descriptor_accept=%0d prefetch=%0d guard_release=%0d",
      issue_first_cycle[JOBS-1]-issue_first_cycle[JOBS-2],attention_done_cycle-commit_cycle[JOBS-1],
      tail_accept_cycle,tail_prefetch_cycle,tail_guard_release);
    $display("ATTN_JOB start_cycle=%0d done_cycle=%0d job_cycles=%0d",
      attention_start_cycle,attention_done_cycle,
      attention_done_cycle-attention_start_cycle);
    $display("ATTN_TB_CHECK_END cycle=%0d",cycle_count);
    $display("VPU_RAM reads=%0d writes=%0d overlap_reads=%0d overlap_writes=%0d identity_scale_model=1",vpu_reads,vpu_writes,overlap_reads,overlap_writes);
    $display("tb_v3_attention_55 PASS mode=%s QK=%0d PV=%0d P_loads=%0d A_beats=%0d B_beats=%0d final_values=%0d job_cycles=%0d",
      FAST_VPU_SFU_MODEL?"scheduling":"port_stress",BLOCKS,BLOCKS,loads,a_beats,b_beats,ROWS*TILE*TILE,attention_done_cycle-attention_start_cycle);
    $finish;
  end
  // KVB producer runs ahead of commands, bounded by real BFIFO/backpressure.
  // The next Tile is fetched while the previous Matrix/VPU stage is active.
  initial begin : kv_prefetch
    int block;
    wait(!reset);@(negedge clk);
    for(int j=0;j<JOBS;j++) begin
      if(j==0) block=0;
      else if(j==JOBS-1) block=BLOCKS-1;
      else if(j%2) block=(j+1)/2;
      else block=j/2-1;
      for(int t=0;t<ATTN_K_TILES;t++)for(int g=0;g<TILE/2;g++)
        send_b(TILE_BITS'(j*ATTN_K_TILES+t),g,block);
    end
  end
  initial begin #2000000;$fatal(1,"attention55 watchdog accept=%0d complete=%0d checked=%0d",accepts,completions,checked);end
endmodule

