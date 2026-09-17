import dea8_pcore_pkg::*;
import dea8_job_pkg::*;

// Single owner of column-loaded PE banks. A reads have one-clock latency.
// A prefetched next-job bank is never activated before the old final commit.
module dea8_matrix_sequencer #(
  parameter bit ENABLE_LOOKAHEAD = 0
) (
  input logic clk, rst_n,
  input logic job_valid, resources_ready,
  output logic job_ready, job_busy, job_done_valid,
  input logic job_done_ready,
  input matrix_job_t job,
  output matrix_job_t current_job,
  input logic next_job_valid,
  input matrix_job_t next_job,
  input logic b_valid,
  output logic b_ready,
  output logic load_valid, load_bank,
  output logic [TILE_IDX_BITS-1:0] load_weight_idx,
  output logic active_bank, active_valid, bank_activate, new_active_bank,
  input logic tile_last_mul_fire,
  output bank_state_e bank_state_a, bank_state_b,
  output logic a_rd_en,
  output matrix_job_t a_read_job,
  output logic [QOZ_ADDR_BITS-1:0] a_rd_addr,
  output logic req_valid,
  input logic req_ready,
  output pipe_tag_t req_tag,
  output deq_dest_t req_dest,
  input logic commit_valid,
  input pipe_tag_t commit_tag,
  input deq_dest_t commit_dest
);
  localparam int JOB_WORDS = SUFFIX_LEN*HEAD_TILES;
  localparam int COUNT_BITS = $clog2(JOB_WORDS+1);
  bank_state_e bank_state[0:BANK_COUNT-1];
  matrix_job_t bank_job[0:BANK_COUNT-1], fetch_job;
  logic [TOKEN_BITS-1:0] bank_tile[0:BANK_COUNT-1];
  logic [TOKEN_BITS-1:0] tile_q, fetch_tile_q, fetch_tile;
  logic [ROW_BITS-1:0] row_q;
  logic [COUNT_BITS-1:0] committed_q;
  logic loading_q, loading_bank_q, free_valid, free_bank;
  logic [TILE_IDX_BITS-1:0] column_q;
  logic prefetch_started_q, fetch_next, fetch_allowed, start_load;
  logic issue_done_q, tile_available, incoming_tile0, accept_job;
  logic [ROW_BITS-1:0] read_row;
  logic [TOKEN_BITS-1:0] read_tile;
  pipe_tag_t read_tag;
  deq_dest_t read_dest;

  assign bank_state_a=bank_state[0];
  assign bank_state_b=bank_state[1];
  assign active_valid=bank_state[active_bank]==BANK_ACTIVE;
  assign job_done_valid=rst_n && job_busy && committed_q==JOB_WORDS;
  assign job_ready=rst_n && resources_ready && (!job_busy || (job_done_valid && job_done_ready));
  assign accept_job=job_valid && job_ready;
  assign free_valid=bank_state[0]==BANK_NULL || bank_state[1]==BANK_NULL;
  assign free_bank=bank_state[0]==BANK_NULL ? 1'b0 : 1'b1;
  assign fetch_next=fetch_tile_q==HEAD_TILES;
  assign fetch_job=fetch_next ? next_job : current_job;
  assign fetch_tile=fetch_next ? '0 : fetch_tile_q;
  assign fetch_allowed=job_busy && !job_done_valid &&
    (!fetch_next || (ENABLE_LOOKAHEAD && next_job_valid && !prefetch_started_q && tile_q==HEAD_TILES-1));
  assign start_load=!loading_q && free_valid && fetch_allowed;
  assign load_bank=loading_q ? loading_bank_q : free_bank;
  assign load_weight_idx=loading_q ? column_q : '0;
  assign b_ready=rst_n && (loading_q || start_load);
  assign load_valid=b_valid && b_ready;

  always_comb begin
    tile_available=0; incoming_tile0=0;
    bank_activate=0; new_active_bank=active_bank;
    for(int b=0;b<BANK_COUNT;b++) begin
      if(bank_state[b]!=BANK_NULL && bank_job[b]==job && bank_tile[b]==0)
        incoming_tile0=1;
      if(bank_job[b]==current_job && bank_tile[b]==tile_q &&
         (bank_state[b]==BANK_READY || bank_state[b]==BANK_LOAD)) tile_available=1;
      if(req_valid && req_tag.row==0 && bank_job[b]==current_job &&
         bank_tile[b]==(current_job.op==MATRIX_QK ? req_tag.kt : req_tag.nt) &&
         (!active_valid || tile_last_mul_fire) && (bank_state[b]==BANK_READY ||
          (load_valid && load_bank==b && load_weight_idx==TILE-1))) begin
        bank_activate=1; new_active_bank=1'(b);
      end
    end
  end
  // Prefetch row0 during loading. The synchronous RAM response is held until
  // the bank is complete; no later read may overwrite it during starvation.
  assign a_rd_en=accept_job || (rst_n && job_busy && !issue_done_q &&
    (!req_valid || req_ready) && (row_q!=0 || tile_available));
  assign a_read_job=accept_job ? job : current_job;
  assign read_row=accept_job ? '0 : row_q;
  assign read_tile=accept_job ? '0 : tile_q;
  assign a_rd_addr=a_read_job.op==MATRIX_QK ?
    QOZ_ADDR_BITS'(read_row*QOZ_TILES+read_tile) : QOZ_ADDR_BITS'(read_row);
  always_comb begin
    read_tag='0; read_dest='0;
    read_tag.row=read_row; read_tag.head=a_read_job.ctx.head; read_tag.epoch=a_read_job.ctx.epoch;
    read_tag.lane_mask='1;
    read_tag.last=read_tile==HEAD_TILES-1 && read_row==SUFFIX_LEN-1;
    if(a_read_job.op==MATRIX_QK) begin
      read_tag.kt=read_tile; read_tag.exp_fold=EXP_FOLD_BITS'(QK_EXP_FOLD);
      read_tag.final_k=read_tile==HEAD_TILES-1;
      read_dest.acc_sel=a_read_job.facc_bank ? ACC_FACC_B : ACC_FACC_A;
      read_dest.acc_addr=ACC_ADDR_BITS'(read_row); read_dest.acc_clear=read_tile==0;
    end else begin
      read_tag.nt=read_tile; read_tag.final_k=1;
      read_dest.acc_sel=ACC_OACC; read_dest.acc_addr=ACC_ADDR_BITS'(read_row*HEAD_TILES+read_tile);
      read_dest.acc_clear=a_read_job.init_oacc;
    end
  end
  always_ff @(posedge clk or negedge rst_n) begin
    if(!rst_n) begin
      job_busy<=0; current_job<='0; row_q<='0; tile_q<='0;
      fetch_tile_q<='0; committed_q<='0; issue_done_q<=0; prefetch_started_q<=0;
      loading_q<=0; loading_bank_q<=0; column_q<='0; active_bank<=0;
      req_valid<=0; req_tag<='0; req_dest<='0;
      for(int b=0;b<BANK_COUNT;b++) begin bank_state[b]<=BANK_NULL; bank_job[b]<='0; bank_tile[b]<='0; end
    end else begin
      if(!req_valid || req_ready) req_valid<=a_rd_en;
      if(a_rd_en) begin
        req_tag<=read_tag; req_dest<=read_dest;
        if(row_q==SUFFIX_LEN-1) begin
          row_q<='0;
          if(tile_q==HEAD_TILES-1) issue_done_q<=1;
          else tile_q<=tile_q+1'b1;
        end else row_q<=row_q+1'b1;
      end
      if(load_valid) begin
        if(!loading_q) begin
          loading_q<=1; loading_bank_q<=load_bank; column_q<=TILE_IDX_BITS'(1);
          bank_state[load_bank]<=BANK_LOAD; bank_job[load_bank]<=fetch_job;
          bank_tile[load_bank]<=fetch_tile;
          if(fetch_next) prefetch_started_q<=1;
          else fetch_tile_q<=fetch_tile_q+1'b1;
        end else if(load_weight_idx==TILE-1) begin
          loading_q<=0; column_q<='0; bank_state[load_bank]<=BANK_READY;
        end else column_q<=column_q+1'b1;
      end
      if(tile_last_mul_fire) bank_state[active_bank]<=BANK_NULL;
      if(bank_activate) begin bank_state[new_active_bank]<=BANK_ACTIVE; active_bank<=new_active_bank; end
      if(commit_valid) committed_q<=committed_q+1'b1;
      if(job_done_valid && job_done_ready) job_busy<=0;
      if(accept_job) begin
        current_job<=job; job_busy<=1; row_q<=ROW_BITS'(1); tile_q<='0;
        fetch_tile_q<=incoming_tile0 ? TOKEN_BITS'(1) : '0;
        committed_q<='0; issue_done_q<=0; prefetch_started_q<=0;
      end
    end
  end
  // synthesis translate_off
  always @(posedge clk) if(rst_n) begin
    if(req_valid && req_tag.row!=0 && !req_ready) $fatal(1,"Matrix A response not accepted");
    if(load_valid && active_valid && load_bank==active_bank) $fatal(1,"Column loader wrote ACTIVE bank");
    if(commit_valid) begin
      if(!job_busy || job_done_valid || commit_tag.head!=current_job.ctx.head ||
         commit_tag.epoch!=current_job.ctx.epoch || commit_tag.row!=committed_q%SUFFIX_LEN ||
         commit_tag.last!=(committed_q==JOB_WORDS-1)) $fatal(1,"Matrix commit context/order");
      if(current_job.op==MATRIX_QK) begin
        if(commit_tag.kt!=committed_q/SUFFIX_LEN || commit_tag.nt!=0 ||
           commit_dest.acc_addr!=commit_tag.row || commit_tag.exp_fold!=QK_EXP_FOLD ||
           commit_dest.acc_sel!=(current_job.facc_bank ? ACC_FACC_B : ACC_FACC_A) ||
           commit_dest.acc_clear!=(commit_tag.kt==0)) $fatal(1,"QK commit destination");
      end else if(commit_tag.kt!=0 || commit_tag.nt!=committed_q/SUFFIX_LEN ||
                  commit_dest.acc_addr!=commit_tag.row*HEAD_TILES+commit_tag.nt ||
                  commit_tag.exp_fold!=0 || !commit_tag.final_k || commit_dest.acc_sel!=ACC_OACC ||
                  commit_dest.acc_clear!=current_job.init_oacc) $fatal(1,"PV commit destination");
    end
  end
  // synthesis translate_on
endmodule
