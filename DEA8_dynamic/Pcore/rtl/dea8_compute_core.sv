import pcore_pkg::*;

// One arithmetic chain, one active and one prepared work descriptor. A B bank
// outlives its queue slot, but only until the last S1 use, not the last C.
module dea8_compute_core (
  input logic clk,reset,clear,gu_capture_ready,launch_allow,
  input logic job_valid,output logic job_ready,input compute_job_t job,
  output logic busy,done_valid,input logic done_ready,output compute_job_t done_work,output logic protocol_error,
  input logic a_valid,a_bank,a_tile_available,input a2_t a,
  output logic a_ready,a_tile_reserve,
  input logic b_valid,input b4_t b,output logic b_ready,
  input logic result_rd_valid,output logic result_rd_ready,
  input acc_sel_e result_rd_sel,input logic [9:0] result_rd_addr,
  output logic result_rd_data_valid,output logic [15:0][31:0] result_even_data,result_odd_data,
  input logic vpu_wr_valid,output logic vpu_wr_ready,input acc_write_t vpu_wr,
  output logic issue_valid,output pair_meta_t issue_meta,
  output logic psum_valid,output mxu_rsp_t psum_rsp,
  output logic commit_valid,output pair_meta_t commit_meta,
  output logic commit_write_valid,output acc_write_t commit_write
);
  typedef enum logic [1:0] {IDLE,RUN,DRAIN} state_e;
  state_e state;
  compute_job_t ctx,prepared,issue_ctx,load_ctx;
  logic prepared_valid,use_prepared,promote,load_prepared,cold_start;
  logic [MATRIX_TILE_COUNT_BITS-1:0] tile_q,b_tile_q,prepared_b_tiles,issue_tile,load_tile;
  logic [PAIR_BITS-1:0] pair_q,issue_pair;
  logic [$clog2(ACC_RAW_INTERVAL+1)-1:0] cooldown;
  logic [1:0] bank_ready,bank_busy;
  logic [SEQ_BITS-1:0] bank_tile[0:1],bank_work[0:1];
  job_token_t bank_token[0:1];
  logic active_bank,release_pending,release_bank;
  logic fill_open,fill_bank;
  logic [B_GROUP_BITS-1:0] fill_group;
  logic b_fire,a_legal,b_legal,bank_available,job_legal,deq_done,retire_now,last_retire;
  int unsigned pair_count;
  assign job_ready=!reset&&!clear&&!protocol_error&&!prepared_valid&&!done_valid&&(state==IDLE||job.m_rows!=0);
  assign cold_start=job_valid&&job_ready&&state==IDLE;
  assign busy=state!=IDLE||done_valid||prepared_valid;
  assign b_fire=b_valid&&b_ready;
  assign issue_valid=a_valid&&a_ready;
  assign a_tile_reserve=issue_valid&&issue_pair==0;
  assign use_prepared=prepared_valid&&(state==IDLE||(state==DRAIN&&retire_now));
  assign promote=use_prepared&&issue_valid;
  always_comb begin
    issue_ctx=use_prepared?prepared:ctx;issue_tile=use_prepared?'0:tile_q;issue_pair=use_prepared?'0:pair_q;
    pair_count=pairs_for_rows(issue_ctx.m_rows);
    load_prepared=prepared_valid&&b.token==prepared.token&&b.work_seq==prepared.work_seq&&b_tile_q==ctx.tiles;
    load_ctx=load_prepared?prepared:ctx;load_tile=load_prepared?prepared_b_tiles:b_tile_q;
    job_legal=job.m_rows<=ROWS&&job.mode<=MAT_GU&&job.acc_sel<=ACC_OACC&&
      (job.m_rows==0||job.tiles!=0)&&
      (!job.nt_per_tile||(job.acc_sel==ACC_OACC&&int'(job.nt)+int'(job.tiles)<=TILE))&&
      (job.acc_sel!=ACC_OACC||job.nt<TILE)&&
      (job.mode!=MAT_GU||(!job.nt_per_tile&&!job.tiles[0]));
    b_legal=b.token==load_ctx.token&&b.work_seq==load_ctx.work_seq&&b.tile_idx==SEQ_BITS'(load_tile)&&
      b.role==(load_ctx.mode==MAT_GU?(load_tile[0]?ROLE_UP:ROLE_GATE):load_ctx.role)&&
      (fill_open?(b.bank==fill_bank&&b.group_idx==fill_group):b.group_idx==0);
    b_ready=!reset&&!clear&&!protocol_error&&(state==RUN||load_prepared)&&load_tile<load_ctx.tiles&&b_legal&&
      (fill_open||(!bank_ready[b.bank]&&!bank_busy[b.bank]));
    bank_available=bank_ready[a_bank]&&bank_tile[a_bank]==SEQ_BITS'(issue_tile)&&
      bank_work[a_bank]==issue_ctx.work_seq&&bank_token[a_bank]==issue_ctx.token;
    if(b_fire&&b.group_idx==B_LOAD_GROUPS-1&&b.bank==a_bank&&b.tile_idx==SEQ_BITS'(issue_tile)&&
      b.token==issue_ctx.token&&b.work_seq==issue_ctx.work_seq)bank_available=1;
    a_legal=a.token==issue_ctx.token&&a.work_seq==issue_ctx.work_seq&&a.pair_idx==issue_pair&&
      a.tile_idx==SEQ_BITS'(issue_tile)&&a.row_valid==row_mask_for_rows(issue_ctx.m_rows,issue_pair)&&
      (issue_pair==0||a_bank==active_bank);
    a_ready=!reset&&!clear&&!protocol_error&&(state==RUN||use_prepared)&&cooldown==0&&a_legal&&
      (issue_pair==0?(bank_available&&a_tile_available):bank_busy[active_bank]);
    if(issue_tile==0&&issue_pair==0&&!launch_allow)a_ready=0;
    if(issue_ctx.mode==MAT_GU&&int'(issue_tile)+2>=int'(issue_ctx.tiles)&&issue_pair==0&&!gu_capture_ready)a_ready=0;
    issue_meta='0;issue_meta.token=issue_ctx.token;issue_meta.work_seq=issue_ctx.work_seq;issue_meta.block_id=issue_ctx.block_id;
    issue_meta.role=issue_ctx.mode==MAT_GU?(issue_tile[0]?ROLE_UP:ROLE_GATE):issue_ctx.role;
    issue_meta.epoch=issue_ctx.epoch;issue_meta.head=issue_ctx.head;issue_meta.tile_idx=SEQ_BITS'(issue_tile);
    issue_meta.pair_idx=issue_pair;issue_meta.m_rows=issue_ctx.m_rows;issue_meta.nt=issue_ctx.nt;
    issue_meta.exp_fold=issue_ctx.exp_fold;issue_meta.mode=issue_ctx.mode;issue_meta.gu_n=issue_ctx.gu_n;
    issue_meta.acc_sel=issue_ctx.acc_sel;issue_meta.add_old=issue_ctx.add_old||issue_tile!=0;
    issue_meta.final_k=issue_ctx.m_rows!=0&&int'(issue_tile)+1==int'(issue_ctx.tiles);
    if(issue_ctx.mode==MAT_GU)begin
      issue_meta.acc_sel=issue_tile[0]?ACC_FACC_B:ACC_FACC_A;
      issue_meta.add_old=issue_ctx.add_old||issue_tile>=2;
      issue_meta.final_k=issue_ctx.m_rows!=0&&int'(issue_tile)+2>=int'(issue_ctx.tiles);
    end else if(issue_ctx.nt_per_tile)begin
      issue_meta.nt=issue_ctx.nt+TILE_BITS'(issue_tile);issue_meta.add_old=issue_ctx.add_old;issue_meta.final_k=1;
    end
    issue_meta.last=issue_ctx.m_rows!=0&&int'(issue_tile)+1==int'(issue_ctx.tiles)&&int'(issue_pair)+1==pair_count;
  end
  always_ff @(posedge clk)begin
    if(reset||clear)begin
      state<=IDLE;done_valid<=0;done_work<='0;protocol_error<=0;ctx<='0;prepared<='0;prepared_valid<=0;
      tile_q<=0;pair_q<=0;b_tile_q<=0;prepared_b_tiles<=0;cooldown<=0;bank_ready<=0;bank_busy<=0;release_pending<=0;
      fill_open<=0;fill_group<=0;active_bank<=0;last_retire<=0;
    end else begin
      if(done_valid&&done_ready)done_valid<=0;
      if(cooldown!=0)cooldown<=cooldown-1'b1;
      release_pending<=0;last_retire<=retire_now;
      if(release_pending)bank_busy[release_bank]<=0;
      if(job_valid&&job_ready)begin
        if(!job_legal)begin protocol_error<=1;done_valid<=1;done_work<=job;end
        else if(state==IDLE)begin
          ctx<=job;tile_q<=0;pair_q<=0;b_tile_q<=0;cooldown<=0;fill_open<=0;
          if(job.m_rows==0)begin done_valid<=1;done_work<=job;end else state<=RUN;
        end else begin prepared<=job;prepared_valid<=1;prepared_b_tiles<=0;end
      end
      if(state==RUN&&a_valid&&!a_legal)protocol_error<=1;
      if(b_valid&&(state==RUN||prepared_valid)&&!b_legal)protocol_error<=1;
      if(b_fire)begin
        if(b.group_idx==0)begin
          bank_tile[b.bank]<=b.tile_idx;bank_work[b.bank]<=b.work_seq;bank_token[b.bank]<=b.token;
          fill_bank<=b.bank;fill_open<=1;
        end
        fill_group<=b.group_idx+1'b1;
        if(b.group_idx==B_LOAD_GROUPS-1)begin
          fill_open<=0;bank_ready[b.bank]<=1;
          if(load_prepared)prepared_b_tiles<=prepared_b_tiles+1'b1;else b_tile_q<=b_tile_q+1'b1;
        end
      end
      if(retire_now)begin state<=IDLE;done_valid<=1;done_work<=ctx;end
      if(promote)begin
        ctx<=prepared;prepared_valid<=0;state<=RUN;
        b_tile_q<=prepared_b_tiles+MATRIX_TILE_COUNT_BITS'(b_fire&&load_prepared&&b.group_idx==B_LOAD_GROUPS-1);
      end
      if(issue_valid)begin
        if(issue_pair==0)begin active_bank<=a_bank;bank_ready[a_bank]<=0;bank_busy[a_bank]<=1;end
        if(int'(issue_pair)+1==pair_count)begin
          pair_q<=0;tile_q<=issue_tile+1'b1;release_pending<=1;release_bank<=a_bank;
          cooldown<=pair_count<ACC_RAW_INTERVAL?ACC_RAW_INTERVAL-pair_count:0;
          if(int'(issue_tile)+1==int'(issue_ctx.tiles))state<=DRAIN;
        end else begin pair_q<=issue_pair+1'b1;tile_q<=issue_tile;end
      end
    end
  end
  dea8_mxu_2row mxu(.clk,.reset,.clear,.req_valid(issue_valid),.req_bank(a_bank),.req(a),.req_meta(issue_meta),
    .load_valid(b_fire),.load_entry(b),.rsp_valid(psum_valid),.rsp(psum_rsp));
  DEQACC_V1 deqacc(.clk,.reset,.clear,.rsp_valid(psum_valid),.rsp(psum_rsp),.result_rd_owner(ACC_READ_RESULT),
    .result_rd_valid,.result_rd_ready,.vpu_wr_valid,.vpu_wr_ready,.vpu_wr,.result_rd_sel,.result_rd_addr,
    .result_rd_data_valid,.result_even_data,.result_odd_data,.commit_valid,.done(deq_done),.retire_valid(retire_now),
    .commit_meta,.commit_write_valid,.commit_write,.dbg_valid(1'b0),.dbg_sel(ACC_FACC_A),.dbg_parity(1'b0),
    .dbg_addr(10'b0),.dbg_lane(4'b0),.dbg_data());
  // synthesis translate_off
  always @(posedge clk)if(!reset&&!clear)begin
    if(b_fire&&bank_busy[b.bank])$fatal(1,"B load before last S1 release");
    if(issue_valid&&issue_pair==0&&bank_busy[a_bank])$fatal(1,"B bank reused by two tiles");
    if(deq_done&&!last_retire)$fatal(1,"Unexpected dynamic job completion");
    if(promote&&!bank_available)$fatal(1,"Prepared work issued without its B bank");
  end
  // synthesis translate_on
endmodule
