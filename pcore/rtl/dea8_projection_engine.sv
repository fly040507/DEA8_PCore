import dea8_pcore_pkg::*;
import dea8_job_pkg::*;

// Correctness-first Q linear projection: [51,1024] x [1024,256].
// nt -> kt -> row order, one FACC bank, external VPU requantization to QOZ.
// This is an execution top, not the final W/KV-shared PCore top.
module dea8_projection_engine (
  input logic clk,rst_n,clear,
  input logic job_valid,
  output logic job_ready,job_busy,job_done_valid,
  input logic job_done_ready,
  input logic [HEAD_BITS-1:0] job_head,
  input logic [EPOCH_BITS-1:0] job_epoch,
  input logic hbm_valid,
  output logic hbm_ready,
  input logic [HBM_BITS-1:0] hbm_data,
  input logic xbc_valid,
  output logic xbc_ready,
  input logic [2*DW_ACT-1:0] xbc_q,
  input logic [2*SCALE_BITS-1:0] xbc_e,
  input logic [ROW_BITS-1:0] xbc_row,
  input logic [PROJ_K_BITS-1:0] xbc_blk,
  input logic [2*TILE-1:0] xbc_lane_mask,
  input logic xbc_last,
  input logic [EPOCH_BITS-1:0] xbc_epoch,
  output logic post_cmd_valid,
  input logic post_cmd_ready,
  output projection_post_job_t post_cmd,
  input logic post_rd_valid,
  output logic post_rd_ready,
  input logic [ROW_BITS-1:0] post_rd_row,
  output logic post_rsp_valid,
  output logic [DW_VEC-1:0] post_rsp_data,
  input logic post_result_valid,
  output logic post_result_ready,
  input projection_q_result_t post_result,
  input logic post_done_valid,
  output logic post_done_ready,
  input projection_post_job_t post_done,
  output logic qoz_valid,protocol_error,
  input logic qoz_rd_en,
  output logic qoz_rd_ready,qoz_rsp_valid,
  input logic [QOZ_ADDR_BITS-1:0] qoz_rd_addr,
  output logic [DW_ACT-1:0] qoz_rd_data,
  output logic [SCALE_BITS-1:0] qoz_rd_scale,
  output logic commit_valid,
  output pipe_tag_t commit_tag,
  output deq_dest_t commit_dest
);
  localparam int TOTAL_TILES=PROJ_N_TILES*PROJ_K_TILES;
  localparam int TOTAL_WORDS=TOTAL_TILES*SUFFIX_LEN;
  localparam int TOTAL_BEATS=TOTAL_TILES*HBM_BEATS_PER_TILE;
  localparam int ABORT_DRAIN=PIPE_DRAIN+2;
  typedef enum logic [2:0] {IDLE,PAIR_RX,RUN_PAIR,POST_CMD,POST_WAIT,DONE,ABORTING} state_e;
  state_e state_q;
  logic [HEAD_BITS-1:0] head_q;
  logic [EPOCH_BITS-1:0] epoch_q;
  logic [TILE_IDX_BITS-1:0] nt_q;
  logic [PROJ_K_BITS-1:0] kt_q;
  logic [ROW_BITS-1:0] row_q;
  logic [$clog2(TOTAL_TILES+1)-1:0] loaded_q,activated_q;
  logic [$clog2(TOTAL_WORDS+1)-1:0] committed_q;
  logic [$clog2(TOTAL_BEATS+1)-1:0] hbm_count_q;
  logic [$clog2(ABORT_DRAIN+1)-1:0] abort_q;
  logic [ROW_BITS:0] results_q;
  logic accept_job,path_clear,pair_full,pair_release,pair_error,pair_issue_done;
  logic a_rd_en,tile_available,req_valid,req_ready,rsp_valid;
  logic [DW_ACT-1:0] activation;
  logic [SCALE_BITS-1:0] e_stream,rsp_e_stream;
  pipe_tag_t read_tag,req_tag,rsp_tag;
  deq_dest_t read_dest,req_dest,rsp_dest;
  logic loader_hbm_ready,loader_hbm_valid;
  logic bank_load_enable,bank_activate,new_active_bank,active_bank,active_valid;
  logic load_bank,load_valid,scale_load_valid,load_tile_complete,tile_last_mul_fire,mul_valid;
  logic [TILE_IDX_BITS-1:0] load_weight_idx;
  logic signed [TILE-1:0][WEIGHT_BITS-1:0] load_weight_beat;
  logic [SCALE_WORD_BITS-1:0] load_scale_word;
  bank_state_e bank_state_a,bank_state_b;
  logic signed [TILE-1:0][PSUM_BITS-1:0] psum;
  logic [TILE-1:0][SCALE_BITS-1:0] e_stat;
  mxu_rsp_t deq_req;
  logic mem_rd_en,mem_wr_en,raw_commit_valid;
  pipe_tag_t raw_commit_tag;
  deq_dest_t raw_commit_dest;
  acc_sel_e mem_rd_sel,mem_wr_sel;
  logic [ACC_ADDR_BITS-1:0] mem_rd_addr,mem_wr_addr;
  logic [DW_VEC-1:0] mem_rd_data,mem_wr_data;
  logic [TILE-1:0] mem_wr_lane_en;
  logic [2:0] deq_reserved;
  logic fabric_post_ready,fabric_post_valid,post_bad,result_fire,qoz_write;
  logic [DW_VEC-1:0] fabric_post_data;

  assign job_ready=rst_n && !clear && state_q==IDLE;
  assign accept_job=job_valid && job_ready;
  assign path_clear=clear || accept_job;
  assign job_busy=state_q!=IDLE;
  assign job_done_valid=rst_n && !clear && state_q==DONE;
  assign bank_load_enable=job_busy && state_q!=DONE && state_q!=ABORTING && loaded_q<TOTAL_TILES;
  assign loader_hbm_valid=hbm_valid && bank_load_enable && hbm_count_q<TOTAL_BEATS;
  assign hbm_ready=loader_hbm_ready && bank_load_enable && hbm_count_q<TOTAL_BEATS;
  dea8_w_loader loader (
    .clear(path_clear),.hbm_valid(loader_hbm_valid),.hbm_ready(loader_hbm_ready),.*
  );

  assign tile_available=activated_q>nt_q*PROJ_K_TILES+kt_q ||
    bank_state_a==BANK_READY || bank_state_b==BANK_READY ||
    (load_valid && load_weight_idx==TILE-2);
  assign a_rd_en=rst_n && !clear && state_q==RUN_PAIR && !pair_issue_done &&
    (row_q!=0 || tile_available);
  assign pair_release=commit_valid && commit_tag.row==SUFFIX_LEN-1 && commit_tag.kt[0];
  dea8_projection_xpair input_pair (
    .clk,.rst_n,.clear(path_clear),.enable(state_q==PAIR_RX),.release_pair(pair_release),
    .expected_pair(PROJ_K_BITS'(kt_q & ~1)),.expected_epoch(epoch_q),
    .xbc_valid,.xbc_ready,.xbc_q,.xbc_e,.xbc_row,.xbc_blk,.xbc_lane_mask,.xbc_last,.xbc_epoch,
    .full(pair_full),.protocol_error(pair_error),.rd_en(a_rd_en),.rd_half(kt_q[0]),
    .rd_row(row_q),.rd_data(activation),.rd_scale(e_stream)
  );
  always_comb begin
    read_tag='0;read_dest='0;
    read_tag.row=row_q;read_tag.kt=TOKEN_BITS'(kt_q);read_tag.nt=TOKEN_BITS'(nt_q);
    read_tag.head=head_q;read_tag.epoch=epoch_q;read_tag.lane_mask='1;
    read_tag.final_k=kt_q==PROJ_K_TILES-1;
    read_tag.last=read_tag.final_k && nt_q==PROJ_N_TILES-1 && row_q==SUFFIX_LEN-1;
    read_dest.acc_sel=ACC_FACC_A;read_dest.acc_addr=ACC_ADDR_BITS'(row_q);
    read_dest.acc_clear=kt_q==0;
  end
  dea8_mxu #(.COLUMN_LOAD(1)) mxu (.clear(path_clear),.req_valid(req_valid && !clear),.rsp_ready(1'b1),.*);
  assign deq_req='{psum:psum,e_stat:e_stat,e_stream:rsp_e_stream,tag:rsp_tag};
  dea8_deqacc deq (
    .clk,.rst_n,.req_valid(rsp_valid && !clear && state_q!=ABORTING),
    .req(deq_req),.req_dest(rsp_dest),
    .mem_rd_en,.mem_rd_sel,.mem_rd_addr,.mem_rd_data,
    .mem_wr_en,.mem_wr_sel,.mem_wr_addr,.mem_wr_lane_en,.mem_wr_data,
    .commit_valid(raw_commit_valid),.commit_tag(raw_commit_tag),.commit_dest(raw_commit_dest)
  );
  assign commit_valid=raw_commit_valid && !clear && state_q!=ABORTING;
  assign commit_tag=raw_commit_tag;
  assign commit_dest=raw_commit_dest;
  assign deq_reserved=(state_q==PAIR_RX || state_q==RUN_PAIR || state_q==ABORTING) ? 3'b001 : 3'b000;
  dea8_accumulator_fabric accum (
    .clk,.rst_n,.deq_reserved,
    .deq_rd_en(mem_rd_en && !clear && state_q!=ABORTING),.deq_rd_sel(mem_rd_sel),
    .deq_rd_addr(mem_rd_addr),.deq_rd_data(mem_rd_data),
    .deq_wr_en(mem_wr_en && !clear && state_q!=ABORTING),.deq_wr_sel(mem_wr_sel),
    .deq_wr_addr(mem_wr_addr),.deq_wr_lane_en(mem_wr_lane_en),.deq_wr_data(mem_wr_data),
    .vpu_rd_valid(post_rd_valid && state_q==POST_WAIT && !clear),.vpu_rd_ready(fabric_post_ready),
    .vpu_rd_sel(ACC_FACC_A),.vpu_rd_addr(ACC_ADDR_BITS'(post_rd_row)),
    .vpu_rsp_valid(fabric_post_valid),.vpu_rsp_data(fabric_post_data),
    .vpu_wr_valid(1'b0),.vpu_wr_ready(),.vpu_wr_sel(ACC_FACC_A),
    .vpu_wr_addr('0),.vpu_wr_lane_en('0),.vpu_wr_data('0)
  );

  assign post_cmd='{head:head_q,epoch:epoch_q,nt:nt_q};
  assign post_cmd_valid=rst_n && !clear && state_q==POST_CMD;
  assign post_rd_ready=fabric_post_ready && !clear && state_q==POST_WAIT;
  assign post_rsp_valid=fabric_post_valid && !clear && state_q==POST_WAIT;
  assign post_rsp_data=fabric_post_data;
  assign post_bad=post_result_valid && state_q==POST_WAIT &&
    (post_result.job!=post_cmd || post_result.row!=results_q ||
     post_result.last!=(results_q==SUFFIX_LEN-1) || results_q>=SUFFIX_LEN);
  assign post_result_ready=rst_n && !clear && state_q==POST_WAIT &&
    results_q<SUFFIX_LEN && !protocol_error && !post_bad;
  assign result_fire=post_result_valid && post_result_ready;
  assign post_done_ready=rst_n && !clear && state_q==POST_WAIT && results_q==SUFFIX_LEN &&
    post_done==post_cmd && !protocol_error;
  assign qoz_write=result_fire;
  assign qoz_rd_ready=rst_n && !clear && !accept_job && qoz_valid;
  dea8_qoz_buffer qoz (
    .clk,.wr_en(qoz_write),.wr_addr(QOZ_ADDR_BITS'(post_result.row*QOZ_TILES+nt_q)),
    .wr_data(post_result.data),.wr_scale(post_result.scale),
    .rd_en(qoz_rd_en && qoz_rd_ready),.rd_addr(qoz_rd_addr),
    .rd_data(qoz_rd_data),.rd_scale(qoz_rd_scale)
  );

  always_ff @(posedge clk or negedge rst_n) begin
    if(!rst_n) begin
      state_q<=IDLE;head_q<='0;epoch_q<='0;nt_q<='0;kt_q<='0;row_q<='0;
      loaded_q<='0;activated_q<='0;committed_q<='0;hbm_count_q<='0;abort_q<='0;
      results_q<='0;pair_issue_done<=0;req_valid<=0;req_tag<='0;req_dest<='0;
      qoz_valid<=0;qoz_rsp_valid<=0;protocol_error<=0;
    end else if(clear) begin
      // Suppress storage side effects and clear MXU valid immediately; drain
      // old DEQACC transactions before permitting another job. No reset gating.
      state_q<=ABORTING;abort_q<=ABORT_DRAIN;
      req_valid<=0;qoz_valid<=0;qoz_rsp_valid<=0;protocol_error<=0;
      loaded_q<='0;activated_q<='0;committed_q<='0;hbm_count_q<='0;
      results_q<='0;pair_issue_done<=0;
    end else begin
      req_valid<=a_rd_en;
      qoz_rsp_valid<=qoz_rd_en && qoz_rd_ready;
      if(pair_error || post_bad || (post_done_valid && state_q==POST_WAIT &&
        (post_done!=post_cmd || results_q!=SUFFIX_LEN))) protocol_error<=1;
      if(a_rd_en) begin
        req_tag<=read_tag;req_dest<=read_dest;
        if(row_q==SUFFIX_LEN-1) begin
          row_q<='0;
          if(kt_q[0]) pair_issue_done<=1;
          else kt_q<=kt_q+1'b1;
        end else row_q<=row_q+1'b1;
      end
      if(hbm_valid && hbm_ready) hbm_count_q<=hbm_count_q+1'b1;
      if(load_valid && load_weight_idx==0) loaded_q<=loaded_q+1'b1;
      if(bank_activate) activated_q<=activated_q+1'b1;
      if(commit_valid) committed_q<=committed_q+1'b1;
      if(result_fire) results_q<=results_q+1'b1;
      case(state_q)
        IDLE: if(accept_job) begin
          state_q<=PAIR_RX;head_q<=job_head;epoch_q<=job_epoch;nt_q<='0;kt_q<='0;row_q<='0;
          loaded_q<='0;activated_q<='0;committed_q<='0;hbm_count_q<='0;
          results_q<='0;pair_issue_done<=0;qoz_valid<=0;protocol_error<=0;
        end
        PAIR_RX: if(pair_full) state_q<=RUN_PAIR;
        RUN_PAIR: if(pair_release) begin
          pair_issue_done<=0;
          if(kt_q==PROJ_K_TILES-1) begin state_q<=POST_CMD;results_q<='0;end
          else begin kt_q<=kt_q+1'b1;state_q<=PAIR_RX;end
        end
        POST_CMD: if(post_cmd_ready) state_q<=POST_WAIT;
        POST_WAIT: if(post_done_valid && post_done_ready) begin
          if(nt_q==PROJ_N_TILES-1) begin state_q<=DONE;qoz_valid<=1;end
          else begin nt_q<=nt_q+1'b1;kt_q<='0;state_q<=PAIR_RX;end
        end
        DONE: if(job_done_ready) state_q<=IDLE;
        ABORTING: if(abort_q==1) state_q<=IDLE;
                  else abort_q<=abort_q-1'b1;
        default: state_q<=IDLE;
      endcase
    end
  end
  // synthesis translate_off
  always @(posedge clk) if(rst_n && !clear && state_q!=ABORTING) begin
    if(req_valid && !req_ready) $fatal(1,"Projection A response not accepted");
    if(commit_valid) begin
      if(state_q!=RUN_PAIR || commit_tag.row!=committed_q%SUFFIX_LEN ||
         commit_tag.kt!=(committed_q/SUFFIX_LEN)%PROJ_K_TILES ||
         commit_tag.nt!=committed_q/(SUFFIX_LEN*PROJ_K_TILES) ||
         commit_tag.head!=head_q || commit_tag.epoch!=epoch_q || commit_tag.exp_fold!=0 ||
         commit_tag.final_k!=(commit_tag.kt==PROJ_K_TILES-1) ||
         commit_tag.last!=(committed_q==TOTAL_WORDS-1) ||
         commit_dest.acc_sel!=ACC_FACC_A || commit_dest.acc_addr!=commit_tag.row ||
         commit_dest.acc_clear!=(commit_tag.kt==0)) $fatal(1,"Projection commit context/order mismatch");
    end
    if(post_bad) $fatal(1,"Projection VPU result context/order mismatch");
    if(post_done_valid && state_q==POST_WAIT && (post_done!=post_cmd || results_q!=SUFFIX_LEN))
      $fatal(1,"Projection VPU done before all QOZ writes or wrong context");
    if(job_done_valid && (committed_q!=TOTAL_WORDS || hbm_count_q!=TOTAL_BEATS || !qoz_valid))
      $fatal(1,"Projection completed before all arithmetic and QOZ writes");
  end
  initial if(PROJ_K_TILES%2!=0 || PROJ_N_TILES>QOZ_TILES || PROJ_N_TILES>TILE ||
             PROJ_K_TILES>(1<<TOKEN_BITS)) $fatal(1,"Unsupported projection geometry");
  // synthesis translate_on
endmodule
