`timescale 1ns/1ps
import pcore_pkg::*;
module tb_dynamic_frontend #(parameter bit LOCAL_TEST=0);
  logic clk=0;always #2 clk=~clk;
  logic reset=1,clear=0,job_valid=0,job_ready,busy,done_valid,done_ready=0,protocol_error;
  compute_job_t job='0,current;
  b_source_e job_b_source=B_HBM;
  a_source_e job_a_source=A_XBC;
  logic local_cmd_valid=0,local_cmd_ready,local_rd_valid,local_rd_ready;
  local_load_cmd_t local_cmd='0;local_read_t local_rd;
  logic local_out_valid,local_out_ready,source_read_closed;
  local_response_t local_out_response;
  logic a_desc_valid=0,a_desc_ready,a_in_valid=0,a_in_ready;
  a_slot_desc_t a_desc='0;a3_beat_t a_in='0;
  logic b_desc_valid=0,b_desc_ready;b_packet_desc_t b_desc='0;
  logic [1:0] hbm_valid=0,hbm_ready;
  logic [1:0][B_BEAT_BITS/2-1:0] hbm_data='0;b_beat_tag_t hbm_tag[0:1];
  logic kv_valid=0,kv_ready;logic [B_BEAT_BITS-1:0] kv_data='0;b_beat_tag_t kv_tag='0;
  logic result_rd_valid=0,result_rd_ready,result_rd_data_valid;
  acc_sel_e result_rd_sel=ACC_FACC_A;logic [9:0] result_rd_addr=0;
  logic [15:0][31:0] result_even_data,result_odd_data;
  logic vpu_wr_valid=0,vpu_wr_ready;acc_write_t vpu_wr='0,commit_write;
  logic issue_valid,psum_valid,commit_valid,commit_write_valid;
  pair_meta_t issue_meta,commit_meta;mxu_rsp_t psum_rsp;
  dea8_matrix_frontend dut(.*);

  logic mem_acquire_valid=0,mem_acquire_ready,mem_acquire_set=0;
  local_object_t mem_object='0;
  job_token_t mem_writer=0,mem_reader=0;
  logic mem_bind_valid=0,mem_bind_ready,mem_release_valid=0,mem_release_ready;
  local_release_t mem_release='0;
  logic mem_wr_valid=0,mem_wr_ready,mem_error,mem_empty;
  local_write_t mem_wr='0;
  logic qoz_active,qoz_complete,qoz_bound;
  logic [1:0] pbuf_active,pbuf_complete,pbuf_bound;
  dea8_local_memory memory(.clk,.reset,.clear,
    .acquire_valid(mem_acquire_valid),.acquire_ready(mem_acquire_ready),.acquire_set(mem_acquire_set),
    .acquire_object(mem_object),.producer_token(mem_writer),
    .bind_valid(mem_bind_valid),.bind_ready(mem_bind_ready),.bind_set(mem_acquire_set),
    .bind_object(mem_object),.consumer_token(mem_reader),
    .release_valid(mem_release_valid),.release_ready(mem_release_ready),.release_request(mem_release),
    .wr_valid(mem_wr_valid),.wr_ready(mem_wr_ready),.wr(mem_wr),
    .rd_valid(local_rd_valid),.rd_ready(local_rd_ready),.rd(local_rd),
    .out_valid(local_out_valid),.out_ready(local_out_ready),.out_response(local_out_response),
    .qoz_active,.qoz_complete,.qoz_bound,.pbuf_active,.pbuf_complete,.pbuf_bound,
    .protocol_error(mem_error),.empty(mem_empty));

  localparam int DELAY=MXU_PIPE_STAGES+DEQACC_PIPE_STAGES-1;
  logic [DELAY:0] ev=0;
  mxu_rsp_t ep[0:DELAY];acc_write_t ew[0:DELAY];
  logic [31:0] model[0:2][0:PAIRS*TILE-1][0:1][0:TILE-1];
  int cycle=0,cases=0,issued=0,committed=0,total_psums=0,total_commits=0,reads=0;
  int a_peak=0,b_peak=0,pc_stalls=0,a_stalls=0,last_issue=-1;
  int seed=0,negative_checks=0,cancel_checks=0;
  bit stress=0,allow_error=0;
  int local_requests=0,local_replies=0,local_flushed_reads=0,loader_peak=0,source_closed_early=0;

  function automatic int a_slice(input int tile);
    return current.mode==MAT_GU?tile/2:(current.nt_per_tile?0:tile);
  endfunction
  function automatic int avalue(input int tile,row,k);
    return int'($signed(8'(a_slice(tile)*31+row*17+k*11+seed*23)));
  endfunction
  function automatic int bvalue(input int tile,k,n);
    return int'($signed(8'(tile*13+k*29+n*19+seed*7)));
  endfunction
  function automatic int ascale(input int tile,row);
    return 126+(a_slice(tile)+row+seed)%8;
  endfunction
  function automatic int bscale(input int tile,n);
    return 127+(tile*3+n+seed)%8;
  endfunction
  function automatic logic [31:0] dequant_ref(input int signed x,input int ea,eb,fold);
    logic [31:0] mag;int lead;
    mag=x<0?(~32'(x)+32'd1):32'(x);lead=0;
    for(int i=0;i<32;i++)if(mag[i])lead=i;
    return fp32_legacy_ref_pkg::pack_scaled32(x<0,mag<<(31-lead),ea+eb+fold-266+lead,
      mag==0,ea==255||eb==255);
  endfunction
  function automatic pair_meta_t expected_meta(input int tile,pair_idx);
    pair_meta_t m;
    m='0;m.token=current.token;m.work_seq=current.work_seq;m.block_id=current.block_id;
    m.role=current.mode==MAT_GU?(tile[0]?ROLE_UP:ROLE_GATE):current.role;
    m.epoch=current.epoch;m.head=current.head;m.tile_idx=SEQ_BITS'(tile);
    m.pair_idx=PAIR_BITS'(pair_idx);m.m_rows=current.m_rows;m.nt=current.nt;
    m.exp_fold=current.exp_fold;m.mode=current.mode;m.gu_n=current.gu_n;
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
  function automatic a3_beat_t a_word(input a_slot_desc_t d,input int group_idx);
    a3_beat_t entry;
    entry='0;entry.token=d.token;entry.work_seq=d.work_seq;entry.occurrence_seq=d.occurrence_seq;
    entry.group_idx=A_GROUP_BITS'(group_idx);entry.row_valid=a_group_mask(d.m_rows,group_idx);
    for(int r=0;r<A_INPUT_ROWS;r++)begin
      entry.row[r].scale=8'(ascale(d.first_tile,group_idx*A_INPUT_ROWS+r));
      for(int k=0;k<TILE;k++)entry.row[r].data[k*INT_BITS+:INT_BITS]=
        8'(avalue(d.first_tile,group_idx*A_INPUT_ROWS+r,k));
    end
    return entry;
  endfunction
  function automatic logic [B_BEAT_BITS-1:0] b_word(input b_packet_desc_t d,input int beat_idx);
    logic [B_BEAT_BITS-1:0] word_data;int tile,group_idx;
    word_data=0;
    if(beat_idx==0)begin
      for(int t=0;t<B_PACKET_MAX_TILES;t++)if(t<b_packet_tiles(d.source))
        for(int n=0;n<TILE;n++)word_data[(t*TILE+n)*SCALE_BITS+:SCALE_BITS]=8'(bscale(d.first_tile+t,n));
      if(d.source==B_KVB)word_data[B_BEAT_BITS-1-:B_PACKET_BITS]=B_PACKET_BITS'(d);
    end else begin
      tile=int'(d.first_tile)+(beat_idx-1)/B_LOAD_GROUPS;group_idx=(beat_idx-1)%B_LOAD_GROUPS;
      for(int c=0;c<B_LOAD_COLS;c++)for(int k=0;k<TILE;k++)
        word_data[c*DATA_BITS+k*INT_BITS+:INT_BITS]=8'(bvalue(tile,k,group_idx*B_LOAD_COLS+c));
    end
    return word_data;
  endfunction
  function automatic logic [$bits(b_beat_tag_t)-1:0] beat_tag(input b_packet_desc_t d,input int idx);
    return {d.token,d.work_seq,d.packet_seq,B_BEAT_INDEX_BITS'(idx),
      (idx==b_packet_tiles(d.source)*B_LOAD_GROUPS)};
  endfunction

  task automatic produce_a;
    a_slot_desc_t d;int uses;
    uses=current.mode==MAT_GU?2:(current.nt_per_tile?int'(current.tiles):1);
    for(int tile=0;tile<int'(current.tiles);tile+=uses)begin
      d='0;d.token=current.token;d.work_seq=current.work_seq;d.first_tile=SEQ_BITS'(tile);
      d.occurrence_seq=SEQ_BITS'(tile/uses);d.m_rows=current.m_rows;d.uses=5'(uses);
      a_desc=d;a_desc_valid=1;
      do @(posedge clk);while(!a_desc_ready);
      @(negedge clk);a_desc_valid=0;
      for(int g=0;g<(int'(current.m_rows)+A_INPUT_ROWS-1)/A_INPUT_ROWS;g++)begin
        if(stress&&g%5==2)begin a_in_valid=0;@(negedge clk);end
        a_in=a_word(d,g);a_in_valid=1;
        do @(posedge clk);while(!a_in_ready);
        @(negedge clk);
      end
      a_in_valid=0;
    end
  endtask
  task automatic prepare_local(input local_kind_e kind);
    local_write_t w;int count;
    count=kind==LOCAL_P?1:(kind==LOCAL_Z?QOZ_Z_TILES:QOZ_Q_TILES);
    @(negedge clk);mem_object='0;mem_object.kind=kind;mem_object.content_version=16'(cases+1);
    mem_object.profile_id=8;mem_object.profile_version=16'(cases+2);mem_object.data_context=16'(cases+3);
    mem_object.head=current.head;mem_object.m_rows=current.m_rows;
    mem_object.block_id=6'(cases%KV_BLOCKS);mem_acquire_set=kind==LOCAL_P?mem_object.block_id[0]:0;
    mem_writer=32'h98760000+32'(cases);mem_reader=current.token;mem_acquire_valid=1;
    @(posedge clk);if(!mem_acquire_ready)$fatal(1,"Local fixture acquire refused");
    @(negedge clk);mem_acquire_valid=0;
    for(int t=0;t<count;t++)for(int g=0;g<(int'(current.m_rows)+A_INPUT_ROWS-1)/A_INPUT_ROWS;g++)begin
      w='0;w.kind=kind;w.set_id=mem_acquire_set;w.token=mem_writer;w.content_version=mem_object.content_version;
      w.tile=TILE_BITS'(t);w.mask=a_group_mask(current.m_rows,g);
      for(int r=0;r<A_INPUT_ROWS;r++)begin
        w.row[r]=ROW_COUNT_BITS'(g*A_INPUT_ROWS+r);w.entry[r].scale=8'(ascale(t,g*A_INPUT_ROWS+r));
        for(int k=0;k<TILE;k++)w.entry[r].data[k*INT_BITS+:INT_BITS]=8'(avalue(t,g*A_INPUT_ROWS+r,k));
      end
      mem_wr=w;mem_wr_valid=1;
      @(posedge clk);if(!mem_wr_ready)$fatal(1,"Local fixture write refused");
      @(negedge clk);
    end
    mem_wr_valid=0;mem_bind_valid=1;
    @(posedge clk);if(!mem_bind_ready)$fatal(1,"Local fixture region not complete");
    @(negedge clk);mem_bind_valid=0;
  endtask
  task automatic produce_local;
    local_load_cmd_t command;int uses;
    uses=current.nt_per_tile?int'(current.tiles):1;
    for(int tile=0;tile<int'(current.tiles);tile+=uses)begin
      command='0;command.destination.token=current.token;command.destination.work_seq=current.work_seq;
      command.destination.m_rows=current.m_rows;command.destination.uses=5'(uses);
      command.destination.first_tile=SEQ_BITS'(tile);command.destination.occurrence_seq=SEQ_BITS'(tile/uses);
      command.kind=mem_object.kind;command.set_id=mem_acquire_set;command.content_version=mem_object.content_version;
      command.tile=TILE_BITS'(current.nt_per_tile?0:tile);
      @(negedge clk);local_cmd=command;local_cmd_valid=1;
      do @(posedge clk);while(!local_cmd_ready);
      @(negedge clk);local_cmd_valid=0;
      if(stress&&tile%5==1)repeat(3)@(negedge clk);
    end
  endtask
  task automatic release_local;
    @(negedge clk);mem_release='0;mem_release.token=current.token;mem_release.kind=mem_object.kind;
    mem_release.set_id=mem_acquire_set;mem_release.content_version=mem_object.content_version;mem_release_valid=1;
    @(posedge clk);if(!mem_release_ready)$fatal(1,"Local source retained replies after real matrix retire");
    @(negedge clk);mem_release_valid=0;
    if(!mem_empty)$fatal(1,"Local source release failed");
  endtask
  task automatic produce_pc(input int pc,input b_packet_desc_t d);
    logic [B_BEAT_BITS-1:0] word_data;
    @(negedge clk);
    for(int i=0;i<=b_packet_tiles(d.source)*B_LOAD_GROUPS;i++)begin
      if(stress&&(pc+i)%4==1)begin hbm_valid[pc]=0;repeat(pc+1)@(negedge clk);end
      word_data=b_word(d,i);hbm_data[pc]=word_data[pc*(B_BEAT_BITS/2)+:B_BEAT_BITS/2];
      hbm_tag[pc]=beat_tag(d,i);hbm_valid[pc]=1;
      do @(posedge clk);while(!hbm_ready[pc]);
      @(negedge clk);
    end
    hbm_valid[pc]=0;
  endtask
  task automatic produce_b;
    b_packet_desc_t d;int count;
    count=b_packet_tiles(job_b_source);
    for(int tile=0;tile<int'(current.tiles);tile+=count)begin
      d='0;d.token=current.token;d.work_seq=current.work_seq;d.source=job_b_source;
      d.mode=current.mode;d.role=current.role;d.block_id=current.block_id;
      d.first_tile=SEQ_BITS'(tile);d.packet_seq=SEQ_BITS'(tile/count);
      b_desc=d;b_desc_valid=1;
      do @(posedge clk);while(!b_desc_ready);
      @(negedge clk);b_desc_valid=0;
      if(job_b_source==B_HBM)begin
        fork produce_pc(0,d);produce_pc(1,d);join
      end else begin
        for(int i=0;i<=count*B_LOAD_GROUPS;i++)begin
          if(stress&&i%3==1)begin kv_valid=0;@(negedge clk);end
          kv_data=b_word(d,i);kv_tag=beat_tag(d,i);kv_valid=1;
          do @(posedge clk);while(!kv_ready);
          @(negedge clk);
        end
        kv_valid=0;
      end
    end
  endtask

  always @(posedge clk)begin
    mxu_rsp_t expected;acc_write_t write_expected;pair_meta_t m;
    int tile,pair_idx,address,dot;
    cycle++;
    if(reset||clear)begin
      ev=0;
      for(int s=0;s<3;s++)for(int addr=0;addr<PAIRS*TILE;addr++)
        for(int r=0;r<ROW_LANES;r++)for(int n=0;n<TILE;n++)model[s][addr][r][n]=0;
    end else begin
      for(int i=DELAY;i>0;i--)begin ev[i]=ev[i-1];ep[i]=ep[i-1];ew[i]=ew[i-1];end
      ev[0]=issue_valid;
      if(dut.aq.used_slots>a_peak)a_peak=dut.aq.used_slots;
      if(dut.bq.used_slots>b_peak)b_peak=dut.bq.used_slots;
      if(|(hbm_valid&~hbm_ready))pc_stalls++;
      if(a_desc_valid&&!a_desc_ready)a_stalls++;
      if(local_rd_valid&&local_rd_ready)local_requests++;
      if(local_out_valid&&local_out_ready)local_replies++;
      if(dut.loader.count>loader_peak)loader_peak=dut.loader.count;
      if(issue_valid)begin
        tile=issued/pairs_for_rows(current.m_rows);pair_idx=issued%pairs_for_rows(current.m_rows);
        m=expected_meta(tile,pair_idx);
        if(issue_meta!==m)$fatal(1,"Frontend issue identity/sequence");
        if(pair_idx!=0&&cycle!=last_issue+1)$fatal(1,"Launched A tile paused");
        last_issue=cycle;
        expected='0;write_expected='0;expected.meta=m;
        expected.row_valid=row_mask_for_rows(current.m_rows,pair_idx);
        address=m.acc_sel==ACC_OACC?pair_idx*TILE+int'(m.nt):pair_idx;
        write_expected.sel=m.acc_sel;write_expected.addr=10'(address);write_expected.row_valid=expected.row_valid;
        for(int n=0;n<TILE;n++)expected.e_stat[n]=8'(bscale(tile,n));
        for(int r=0;r<ROW_LANES;r++)begin
          expected.e_stream[r]=8'(ascale(tile,pair_idx*ROW_LANES+r));
          // An invalid A lane is zero before multiply, independent of old RAM.
          if(!expected.row_valid[r])expected.e_stream[r]=0;
          for(int n=0;n<TILE;n++)begin
            dot=0;if(expected.row_valid[r])for(int k=0;k<TILE;k++)
              dot+=avalue(tile,pair_idx*ROW_LANES+r,k)*bvalue(tile,k,n);
            expected.psum[r][n]=dot;
            if(expected.row_valid[r])begin
              write_expected.data[r][n]=dequant_ref(dot,ascale(tile,pair_idx*ROW_LANES+r),bscale(tile,n),
                int'($signed(current.exp_fold)));
              if(m.add_old)write_expected.data[r][n]=fp32_legacy_ref_pkg::fp32_add(model[m.acc_sel][address][r][n],write_expected.data[r][n]);
              model[m.acc_sel][address][r][n]=write_expected.data[r][n];
            end
          end
        end
        ep[0]=expected;ew[0]=write_expected;issued++;
      end
    end
    #1;
    if(mem_error&&!allow_error)$fatal(1,"Frontend local memory protocol error");
    if(!reset&&!clear&&protocol_error&&!allow_error)
      $fatal(1,"Frontend protocol case=%0d control=%b A=%b row3=%b B=%b PC=%b core=%b Alegal=%b Blegal=%b Avalid=%b tile=%0d pair=%0d Atoken=%h ctx=%h",
        cases,dut.error_q,dut.aq_error,dut.aq.store_error,dut.bq_error,dut.pair_error,dut.core_error,
        dut.core.a_legal,dut.core.b_legal,dut.aq_valid,dut.aq_entry.tile_idx,dut.aq_entry.pair_idx,
        dut.aq_entry.token,dut.core.ctx.token);
    if(psum_valid!==ev[MXU_PIPE_STAGES-1])$fatal(1,"Frontend MXU latency");
    if(psum_valid)begin
      if(psum_rsp!==ep[MXU_PIPE_STAGES-1])$fatal(1,"Loaded INT8 psum/scale/tag mismatch case=%0d tile=%0d pair=%0d",cases,psum_rsp.meta.tile_idx,psum_rsp.meta.pair_idx);
      total_psums++;
    end
    if(commit_valid!==ev[DELAY]||commit_write_valid!==commit_valid)$fatal(1,"Frontend C latency");
    if(commit_valid)begin
      if(commit_meta!==ep[DELAY].meta||commit_write.sel!==ew[DELAY].sel||
        commit_write.addr!==ew[DELAY].addr||commit_write.row_valid!==ew[DELAY].row_valid)
        $fatal(1,"Frontend C identity");
      for(int r=0;r<ROW_LANES;r++)if(commit_write.row_valid[r])for(int n=0;n<TILE;n++)
        if(commit_write.data[r][n]!==ew[DELAY].data[r][n])
          $fatal(1,"Loaded FP32 accumulate mismatch case=%0d t=%0d pair=%0d lane=%0d got=%h expected=%h",
            cases,commit_meta.tile_idx,commit_meta.pair_idx,n,commit_write.data[r][n],ew[DELAY].data[r][n]);
      committed++;total_commits++;
    end
  end
  task automatic read_check(input acc_sel_e sel,input int addr,rows);
    logic [1:0] mask;int pair_idx;
    pair_idx=sel==ACC_OACC?addr/TILE:addr;mask=row_mask_for_rows(rows,pair_idx);
    @(negedge clk);result_rd_sel=sel;result_rd_addr=10'(addr);result_rd_valid=1;
    @(posedge clk);if(!result_rd_ready)$fatal(1,"Frontend result read refused");
    #1;if(!result_rd_data_valid)$fatal(1,"Frontend read response missing");
    for(int n=0;n<TILE;n++)begin
      if(result_even_data[n]!==model[sel][addr][0][n])$fatal(1,"Frontend even result");
      if(result_odd_data[n]!==(mask[1]?model[sel][addr][1][n]:0))$fatal(1,"Frontend odd result");
    end
    reads++;@(negedge clk);result_rd_valid=0;
  endtask
  task automatic begin_job(input int rows,tiles,input matrix_mode_e mode,input bit pv,old_value);
    compute_job_t d;
    d='0;d.token=32'habcd0000+32'(cases);d.work_seq=SEQ_BITS'(cases+256);
    d.m_rows=ROW_COUNT_BITS'(rows);d.tiles=MATRIX_TILE_COUNT_BITS'(tiles);d.mode=mode;
    d.nt_per_tile=pv;d.add_old=old_value;d.acc_sel=pv?ACC_OACC:ACC_FACC_A;
    d.role=mode==MAT_ATTENTION?(pv?ROLE_V:ROLE_K):ROLE_WEIGHT;
    d.epoch=EPOCH_BITS'(cases);d.head=3'(cases);d.block_id=6'(cases%KV_BLOCKS);d.exp_fold=EXP_FOLD_BITS'(cases%8-4);
    @(negedge clk);job=d;current=d;seed=cases;issued=0;committed=0;last_issue=-1;job_valid=1;
    @(posedge clk);if(!job_ready)$fatal(1,"Frontend job rejected case=%0d",cases);
    @(negedge clk);job_valid=0;
  endtask
  task automatic run_case(input int rows,tiles,input matrix_mode_e mode,input bit pv,
    input b_source_e source,input bit old_value,stressed);
    int start_cycle,pairs;
    job_b_source=source;stress=stressed;begin_job(rows,tiles,mode,pv,old_value);start_cycle=cycle;
    if(rows!=0)begin fork produce_a();produce_b();join end
    while(!done_valid)@(negedge clk);
    pairs=pairs_for_rows(rows);
    if(issued!=tiles*pairs||committed!=issued||!dut.all_empty)$fatal(1,"Frontend retirement counts");
    repeat(3)begin @(negedge clk);if(!done_valid||job_ready)$fatal(1,"Frontend done hold");end
    for(int p=0;p<pairs;p++)begin
      if(mode==MAT_GU)begin read_check(ACC_FACC_A,p,rows);read_check(ACC_FACC_B,p,rows);end
      else if(pv)for(int nt=0;nt<tiles;nt++)read_check(ACC_OACC,p*TILE+nt,rows);
      else read_check(ACC_FACC_A,p,rows);
    end
    $display("CASE FRONTEND M=%0d tiles=%0d mode=%0d PV=%0d source=%0d stress=%0d issues=%0d total_with_reads=%0d",
      rows,tiles,mode,pv,source,stressed,issued,cycle-start_cycle);
    @(negedge clk);done_ready=1;@(negedge clk);done_ready=0;cases++;
  endtask
  task automatic run_local_case(input int rows,input local_kind_e kind,input bit stressed,old_value);
    int tiles,start_cycle,pairs,start_requests;
    tiles=kind==LOCAL_Z?QOZ_Z_TILES:QOZ_Q_TILES;
    job_a_source=A_LOCAL;job_b_source=kind==LOCAL_Q||kind==LOCAL_P?B_KVB:B_HBM;stress=stressed;
    begin_job(rows,tiles,kind==LOCAL_Q||kind==LOCAL_P?MAT_ATTENTION:MAT_PROJECTION,kind==LOCAL_P,old_value);
    start_cycle=cycle;start_requests=local_requests;
    if(rows!=0)begin
      prepare_local(kind);
      fork produce_local();produce_b();join
    end
    while(!done_valid)begin
      if(source_read_closed&&busy)source_closed_early++;
      @(negedge clk);
    end
    pairs=pairs_for_rows(rows);
    if(issued!=tiles*pairs||committed!=issued||!dut.all_empty||!source_read_closed)
      $fatal(1,"Local frontend retirement counts");
    if(local_requests-start_requests!=(rows==0?0:(kind==LOCAL_P?1:tiles)*((rows+A_INPUT_ROWS-1)/A_INPUT_ROWS)))
      $fatal(1,"Local source fetch/replay count");
    for(int p=0;p<pairs;p++)begin
      if(kind==LOCAL_P)for(int nt=0;nt<tiles;nt++)read_check(ACC_OACC,p*TILE+nt,rows);
      else read_check(ACC_FACC_A,p,rows);
    end
    if(rows!=0)release_local();
    $display("CASE LOCAL M=%0d kind=%0d tiles=%0d stress=%0d issues=%0d total_with_fixture_reads=%0d",rows,kind,tiles,stressed,issued,cycle-start_cycle);
    @(negedge clk);done_ready=1;@(negedge clk);done_ready=0;cases++;
  endtask
  task automatic flush;
    @(negedge clk);clear=1;job_valid=0;a_desc_valid=0;a_in_valid=0;b_desc_valid=0;hbm_valid=0;kv_valid=0;
    if(local_requests-local_replies-local_flushed_reads!=memory.outstanding)$fatal(1,"Local clear reference accounting");
    local_flushed_reads+=int'(memory.outstanding);
    local_cmd_valid=0;mem_acquire_valid=0;mem_bind_valid=0;mem_wr_valid=0;mem_release_valid=0;
    @(negedge clk);clear=0;
    repeat(DELAY+2)@(negedge clk);
    if(busy||done_valid||protocol_error||mem_error||psum_valid||commit_valid||!dut.all_empty||!mem_empty)
      $fatal(1,"Frontend flush");
  endtask
  task automatic descriptor_rejection;
    allow_error=1;job_b_source=B_HBM;begin_job(3,16,MAT_PROJECTION,0,0);
    a_desc='0;a_desc.token=current.token;a_desc.work_seq=current.work_seq;
    a_desc.m_rows=3;a_desc.uses=1;a_desc.occurrence_seq=1;a_desc_valid=1;
    @(posedge clk);#1;if(a_desc_ready||!protocol_error||issue_valid)$fatal(1,"Wrong A occurrence accepted");
    negative_checks++;flush();
    begin_job(3,16,MAT_PROJECTION,0,0);
    b_desc='0;b_desc.token=current.token;b_desc.work_seq=current.work_seq;b_desc.source=B_HBM;
    b_desc.mode=MAT_PROJECTION;b_desc.role=ROLE_V;b_desc.block_id=current.block_id;b_desc_valid=1;
    @(posedge clk);#1;if(b_desc_ready||!protocol_error||issue_valid)$fatal(1,"Wrong B role accepted");
    negative_checks++;flush();allow_error=0;
  endtask
  task automatic packet_rejection(input bit header_error);
    b_packet_desc_t d;
    allow_error=1;job_b_source=header_error?B_KVB:B_HBM;
    begin_job(3,16,header_error?MAT_ATTENTION:MAT_PROJECTION,0,0);
    d='0;d.token=current.token;d.work_seq=current.work_seq;d.source=job_b_source;
    d.mode=current.mode;d.role=current.role;d.block_id=current.block_id;
    b_desc=d;b_desc_valid=1;do @(posedge clk);while(!b_desc_ready);
    @(negedge clk);b_desc_valid=0;
    if(header_error)begin
      kv_tag=beat_tag(d,0);kv_data=b_word(d,0);kv_data[B_BEAT_BITS-1]=1;kv_valid=1;
    end else begin
      hbm_tag[0]=beat_tag(d,0);hbm_tag[1]=beat_tag(d,0);hbm_tag[1].packet_seq=1;
      hbm_valid=2'b11;hbm_data=0;
    end
    repeat(5)@(negedge clk);
    if(!protocol_error||dut.bq.used_slots==0||issue_valid)$fatal(1,"Bad packet accepted");
    negative_checks++;flush();allow_error=0;
  endtask
  task automatic cancel_inflight;
    a_slot_desc_t ad;b_packet_desc_t bd;
    job_b_source=B_HBM;stress=0;begin_job(51,16,MAT_PROJECTION,0,0);
    ad='0;ad.token=current.token;ad.work_seq=current.work_seq;ad.m_rows=51;ad.uses=1;
    bd='0;bd.token=current.token;bd.work_seq=current.work_seq;bd.source=B_HBM;
    bd.mode=current.mode;bd.role=current.role;bd.block_id=current.block_id;
    fork
      begin
        a_desc=ad;a_desc_valid=1;do @(posedge clk);while(!a_desc_ready);
        @(negedge clk);a_desc_valid=0;
        for(int g=0;g<A_ROW_GROUPS;g++)begin
          a_in=a_word(ad,g);a_in_valid=1;do @(posedge clk);while(!a_in_ready);@(negedge clk);
        end
        a_in_valid=0;
      end
      begin
        b_desc=bd;b_desc_valid=1;do @(posedge clk);while(!b_desc_ready);
        @(negedge clk);b_desc_valid=0;fork produce_pc(0,bd);produce_pc(1,bd);join
      end
    join
    while(issued<2)@(negedge clk);
    if(!busy||done_valid)$fatal(1,"Cancel did not reach active matrix");
    flush();cancel_checks++;cases++;
  endtask
  task automatic cancel_local(input bit after_issue);
    local_load_cmd_t c;b_packet_desc_t bd;int start_requests;
    job_a_source=A_LOCAL;job_b_source=B_KVB;stress=0;
    begin_job(51,16,MAT_ATTENTION,0,0);prepare_local(LOCAL_Q);start_requests=local_requests;
    c='0;c.destination.token=current.token;c.destination.work_seq=current.work_seq;
    c.destination.m_rows=current.m_rows;c.destination.uses=1;c.kind=LOCAL_Q;
    c.content_version=mem_object.content_version;
    @(negedge clk);local_cmd=c;local_cmd_valid=1;
    do @(posedge clk);while(!local_cmd_ready);
    @(negedge clk);local_cmd_valid=0;
    if(after_issue)begin
      bd='0;bd.token=current.token;bd.work_seq=current.work_seq;bd.source=B_KVB;
      bd.mode=current.mode;bd.role=current.role;bd.block_id=current.block_id;
      b_desc=bd;b_desc_valid=1;do @(posedge clk);while(!b_desc_ready);
      @(negedge clk);b_desc_valid=0;
      for(int i=0;i<=b_packet_tiles(B_KVB)*B_LOAD_GROUPS;i++)begin
        kv_data=b_word(bd,i);kv_tag=beat_tag(bd,i);kv_valid=1;
        do @(posedge clk);while(!kv_ready);@(negedge clk);
      end
      kv_valid=0;while(issued<2)@(negedge clk);
    end else begin
      while(local_requests==start_requests)@(negedge clk);
      if(issued!=0||dut.ld_empty)$fatal(1,"Local cancel did not reach in-flight source read");
    end
    if(!busy||done_valid)$fatal(1,"Local cancel missed active work");
    flush();cancel_checks++;cases++;
  endtask
  initial begin
    repeat(32)@(negedge clk);reset=0;
    if(LOCAL_TEST)begin
      for(int m=0;m<=ROWS;m++)run_local_case(m,LOCAL_Q,0,0);
      run_local_case(1,LOCAL_P,0,0);run_local_case(11,LOCAL_P,0,0);run_local_case(11,LOCAL_P,1,1);
      run_local_case(51,LOCAL_P,1,0);
      run_local_case(1,LOCAL_O,0,0);run_local_case(11,LOCAL_O,1,0);run_local_case(51,LOCAL_O,0,0);
      run_local_case(1,LOCAL_Z,0,0);run_local_case(11,LOCAL_Z,1,0);run_local_case(51,LOCAL_Z,0,0);
      cancel_local(0);run_local_case(5,LOCAL_Q,0,0);
      cancel_local(1);run_local_case(51,LOCAL_P,0,0);
      if(loader_peak!=2||local_requests-local_replies!=local_flushed_reads||source_closed_early==0||
        cancel_checks!=2||local_flushed_reads==0)
        $fatal(1,"Local loader prefetch/replay coverage missing");
      $display("tb_dynamic_local_compute PASS normal_cases=%0d all_M=0..51 psums=%0d commits=%0d acc_reads=%0d source_reads=%0d source_replies=%0d cancelled_reads=%0d commands_peak=%0d replay_PV=16 source_closed_before_retire=%0d cancel=%0d",
        cases-cancel_checks,total_psums,total_commits,reads,local_requests,local_replies,local_flushed_reads,loader_peak,source_closed_early,cancel_checks);
      $finish;
    end
    for(int m=0;m<=ROWS;m++)run_case(m,16,MAT_PROJECTION,0,B_HBM,0,0);
    run_case(11,64,MAT_PROJECTION,0,B_HBM,0,1);
    run_case(51,64,MAT_PROJECTION,0,B_HBM,0,0);
    run_case(1,128,MAT_GU,0,B_HBM,0,0);
    run_case(51,128,MAT_GU,0,B_HBM,0,1);
    run_case(1,16,MAT_ATTENTION,0,B_KVB,0,0);
    run_case(51,16,MAT_ATTENTION,0,B_KVB,0,1);
    run_case(11,16,MAT_ATTENTION,1,B_KVB,0,0);
    run_case(11,16,MAT_ATTENTION,1,B_KVB,1,1);
    run_case(51,16,MAT_ATTENTION,1,B_KVB,0,0);
    run_case(2,16,MAT_PROJECTION,0,B_HBM,0,0);
    descriptor_rejection();packet_rejection(1);packet_rejection(0);
    cancel_inflight();run_case(5,16,MAT_PROJECTION,0,B_HBM,0,0);
    if(a_peak!=A_SLOTS||b_peak!=B_SLOTS||pc_stalls==0||a_stalls==0)
      $fatal(1,"Queue/PC-skew coverage missing A=%0d B=%0d pc=%0d astall=%0d",a_peak,b_peak,pc_stalls,a_stalls);
    $display("tb_dynamic_frontend PASS cases=%0d all_M=0..51 psums=%0d commits=%0d reads=%0d A_slots_peak=%0d B_slots_peak=%0d pc_stalls=%0d replay_GU=2 replay_PV=16 negative_checks=%0d cancel=%0d",
      cases,total_psums,total_commits,reads,a_peak,b_peak,pc_stalls,negative_checks,cancel_checks);
    $finish;
  end
  initial begin #5000000;$fatal(1,"Frontend watchdog");end
endmodule

module tb_dynamic_local_compute;
  tb_dynamic_frontend #(.LOCAL_TEST(1)) test();
endmodule
