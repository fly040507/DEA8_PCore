import pcore_pkg::*;

// Matrix compute boundary. A/B queues and the seven-job PCore controller
// remain outside this block; one accepted job owns both stationary B banks.
module dea8_compute_core (
  input logic clk,reset,clear,
  input logic job_valid,output logic job_ready,input compute_job_t job,
  output logic busy,done_valid,input logic done_ready,output logic protocol_error,
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
  compute_job_t ctx;
  logic [MATRIX_TILE_COUNT_BITS-1:0] tile_q,b_tile_q;
  logic [PAIR_BITS-1:0] pair_q;
  logic [$clog2(ACC_RAW_INTERVAL+1)-1:0] cooldown;
  logic [1:0] bank_ready,bank_busy;
  logic [TILE_BITS-1:0] bank_tile[0:1];
  logic active_bank,release_pending,release_bank;
  logic fill_open,fill_bank;
  logic [B_GROUP_BITS-1:0] fill_group;
  logic b_fire,a_legal,b_legal,bank_available,job_legal,deq_done;
  int unsigned pair_count;

  assign job_ready=!reset&&!clear&&!protocol_error&&state==IDLE&&!done_valid;
  assign busy=state!=IDLE||done_valid;
  assign b_fire=b_valid&&b_ready;
  assign issue_valid=a_valid&&a_ready;
  assign a_tile_reserve=issue_valid&&pair_q==0;

  always_comb begin
    pair_count=pairs_for_rows(ctx.m_rows);
    job_legal=job.m_rows<=ROWS&&job.mode<=MAT_GU&&job.acc_sel<=ACC_OACC&&
      (job.m_rows==0||job.tiles!=0)&&
      (!job.nt_per_tile||(job.acc_sel==ACC_OACC&&int'(job.nt)+int'(job.tiles)<=TILE))&&
      (job.acc_sel!=ACC_OACC||job.nt<TILE)&&
      (job.mode!=MAT_GU||(!job.nt_per_tile&&!job.tiles[0]));
    b_legal=b.tile_idx==TILE_BITS'(b_tile_q)&&
      (fill_open?(b.bank==fill_bank&&b.group_idx==fill_group):b.group_idx==0);
    b_ready=!reset&&!clear&&!protocol_error&&state==RUN&&b_tile_q<ctx.tiles&&b_legal&&
      (fill_open||(!bank_ready[b.bank]&&!bank_busy[b.bank]));
    // Final group can share the first S0 edge: DSP uses the bank at S1,
    // one edge later. The complete scale vector was installed at group 0.
    bank_available=bank_ready[a_bank]&&bank_tile[a_bank]==TILE_BITS'(tile_q);
    if(b_fire&&b.group_idx==B_LOAD_GROUPS-1&&b.bank==a_bank&&
       b.tile_idx==TILE_BITS'(tile_q))bank_available=1;
    a_legal=a.pair_idx==pair_q&&a.tile_idx==TILE_BITS'(tile_q)&&
      a.row_valid==row_mask_for_rows(ctx.m_rows,pair_q)&&a.reserved==0&&
      (pair_q==0||a_bank==active_bank);
    a_ready=!reset&&!clear&&!protocol_error&&state==RUN&&cooldown==0&&a_legal&&
      (pair_q==0?(bank_available&&a_tile_available):bank_busy[active_bank]);

    issue_meta='0;
    issue_meta.epoch=ctx.epoch;issue_meta.head=ctx.head;
    issue_meta.tile_idx=TILE_BITS'(tile_q);issue_meta.pair_idx=pair_q;
    issue_meta.m_rows=ctx.m_rows;issue_meta.nt=ctx.nt;
    issue_meta.exp_fold=ctx.exp_fold;issue_meta.mode=ctx.mode;issue_meta.gu_n=ctx.gu_n;
    issue_meta.acc_sel=ctx.acc_sel;
    issue_meta.add_old=ctx.add_old||tile_q!=0;
    issue_meta.final_k=ctx.m_rows!=0&&int'(tile_q)+1==int'(ctx.tiles);
    if(ctx.mode==MAT_GU)begin
      issue_meta.acc_sel=tile_q[0]?ACC_FACC_B:ACC_FACC_A;
      issue_meta.add_old=ctx.add_old||tile_q>=2;
      issue_meta.final_k=ctx.m_rows!=0&&int'(tile_q)+2>=int'(ctx.tiles);
    end else if(ctx.nt_per_tile)begin
      issue_meta.nt=ctx.nt+TILE_BITS'(tile_q);
      issue_meta.add_old=ctx.add_old;
      issue_meta.final_k=1;
    end
    issue_meta.last=ctx.m_rows!=0&&int'(tile_q)+1==int'(ctx.tiles)&&int'(pair_q)+1==pair_count;
  end

  always_ff @(posedge clk)begin
    if(reset||clear)begin
      state<=IDLE;done_valid<=0;protocol_error<=0;ctx<='0;
      tile_q<=0;pair_q<=0;b_tile_q<=0;cooldown<=0;
      bank_ready<=0;bank_busy<=0;release_pending<=0;
      fill_open<=0;fill_group<=0;active_bank<=0;
    end else begin
      if(done_valid&&done_ready)done_valid<=0;
      if(cooldown!=0)cooldown<=cooldown-1'b1;
      release_pending<=0;
      if(release_pending)bank_busy[release_bank]<=0;
      if(job_valid&&job_ready)begin
        ctx<=job;tile_q<=0;pair_q<=0;b_tile_q<=0;cooldown<=0;
        bank_ready<=0;bank_busy<=0;fill_open<=0;
        if(!job_legal)begin protocol_error<=1;done_valid<=1;end
        else if(job.m_rows==0)done_valid<=1;
        else state<=RUN;
      end
      if(state==RUN)begin
        if(a_valid&&!a_legal)protocol_error<=1;
        if(b_valid&&!b_legal)protocol_error<=1;
        if(b_fire)begin
          if(b.group_idx==0)begin
            bank_tile[b.bank]<=b.tile_idx;fill_bank<=b.bank;fill_open<=1;
          end
          fill_group<=b.group_idx+1'b1;
          if(b.group_idx==B_LOAD_GROUPS-1)begin
            fill_open<=0;bank_ready[b.bank]<=1;b_tile_q<=b_tile_q+1'b1;
          end
        end
        if(issue_valid)begin
          if(pair_q==0)begin
            active_bank<=a_bank;bank_ready[a_bank]<=0;bank_busy[a_bank]<=1;
          end
          if(int'(pair_q)+1==pair_count)begin
            pair_q<=0;tile_q<=tile_q+1'b1;
            release_pending<=1;release_bank<=a_bank;
            // A3 forward needs Delta>=4. This guard is also compatible with
            // the four-cycle B loader; it never pauses a launched A tile.
            cooldown<=pair_count<ACC_RAW_INTERVAL?ACC_RAW_INTERVAL-pair_count:0;
            if(int'(tile_q)+1==int'(ctx.tiles))state<=DRAIN;
          end else pair_q<=pair_q+1'b1;
        end
      end
      if(state==DRAIN&&deq_done)begin state<=IDLE;done_valid<=1;end
    end
  end

  dea8_mxu_2row mxu(.clk,.reset,.clear,.req_valid(issue_valid),.req_bank(a_bank),
    .req(a),.req_meta(issue_meta),.load_valid(b_fire),.load_entry(b),
    .rsp_valid(psum_valid),.rsp(psum_rsp));
  DEQACC_V1 deqacc(.clk,.reset,.clear,.rsp_valid(psum_valid),.rsp(psum_rsp),
    .result_rd_owner(ACC_READ_RESULT),.result_rd_valid,.result_rd_ready,
    .vpu_wr_valid,.vpu_wr_ready,.vpu_wr,.result_rd_sel,.result_rd_addr,
    .result_rd_data_valid,.result_even_data,.result_odd_data,
    .commit_valid,.done(deq_done),.commit_meta,.commit_write_valid,.commit_write,
    .dbg_valid(1'b0),.dbg_sel(ACC_FACC_A),.dbg_parity(1'b0),.dbg_addr(10'b0),
    .dbg_lane(4'b0),.dbg_data());

  // synthesis translate_off
  always @(posedge clk)if(!reset&&!clear)begin
    if(b_fire&&bank_busy[b.bank])$fatal(1,"B load before last S1 release");
    if(issue_valid&&pair_q==0&&bank_busy[a_bank])$fatal(1,"B bank reused by two tiles");
    if(deq_done&&state!=DRAIN)$fatal(1,"Unexpected dynamic job completion");
  end
  // synthesis translate_on
endmodule
