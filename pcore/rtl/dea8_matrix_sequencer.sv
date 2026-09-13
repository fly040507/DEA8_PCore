import dea8_pcore_pkg::*;
import dea8_job_pkg::*;

// QK/PV share one issue loop. A memory responds exactly one clock after rd_en.
// All A words and accumulator capacity must be reserved for the complete job.
module dea8_matrix_sequencer (
  input logic clk, rst_n,
  input logic job_valid, resources_ready,
  output logic job_ready, job_busy, job_done_valid,
  input logic job_done_ready,
  input matrix_job_t job,
  output matrix_job_t current_job,
  input logic load_valid, bank_activate,
  input logic [TILE_IDX_BITS-1:0] load_weight_idx,
  input bank_state_e bank_state_a, bank_state_b,
  output logic bank_load_enable, a_rd_en,
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
  localparam int TILE_COUNT_BITS = $clog2(HEAD_TILES+1);
  logic [ROW_BITS-1:0] row_q;
  logic [TOKEN_BITS-1:0] tile_q;
  logic [TILE_COUNT_BITS-1:0] loaded_q, activated_q;
  logic [COUNT_BITS-1:0] committed_q;
  logic issue_done_q, tile_available;
  pipe_tag_t read_tag;
  deq_dest_t read_dest;
  assign job_ready = rst_n && !job_busy && resources_ready;
  assign bank_load_enable = job_busy && !job_done_valid && loaded_q < HEAD_TILES;
  assign tile_available = activated_q > tile_q || bank_state_a == BANK_READY ||
                          bank_state_b == BANK_READY || (load_valid && load_weight_idx == TILE-2);
  assign a_rd_en = rst_n && job_busy && !issue_done_q && (row_q != 0 || tile_available);
  assign a_rd_addr = current_job.op == MATRIX_QK ?
                     QOZ_ADDR_BITS'(row_q*QOZ_TILES+tile_q) : QOZ_ADDR_BITS'(row_q);
  always_comb begin
    read_tag='0; read_dest='0;
    read_tag.row=row_q; read_tag.head=current_job.ctx.head; read_tag.epoch=current_job.ctx.epoch;
    read_tag.lane_mask='1;
    read_tag.last=tile_q==HEAD_TILES-1 && row_q==SUFFIX_LEN-1;
    if(current_job.op==MATRIX_QK) begin
      read_tag.kt=tile_q; read_tag.exp_fold=EXP_FOLD_BITS'(QK_EXP_FOLD);
      read_tag.final_k=tile_q==HEAD_TILES-1;
      read_dest.acc_sel=current_job.facc_bank ? ACC_FACC_B : ACC_FACC_A;
      read_dest.acc_addr=ACC_ADDR_BITS'(row_q); read_dest.acc_clear=tile_q==0;
    end else begin
      read_tag.nt=tile_q; read_tag.final_k=1;
      read_dest.acc_sel=ACC_OACC; read_dest.acc_addr=ACC_ADDR_BITS'(row_q*HEAD_TILES+tile_q);
      read_dest.acc_clear=current_job.init_oacc;
    end
  end
  always_ff @(posedge clk or negedge rst_n) begin
    if(!rst_n) begin
      job_busy<=0; job_done_valid<=0; current_job<='0; row_q<='0; tile_q<='0;
      loaded_q<='0; activated_q<='0; committed_q<='0; issue_done_q<=0;
      req_valid<=0; req_tag<='0; req_dest<='0;
    end else begin
      req_valid<=a_rd_en;
      if(a_rd_en) begin
        req_tag<=read_tag; req_dest<=read_dest;
        if(row_q==SUFFIX_LEN-1) begin
          row_q<='0;
          if(tile_q==HEAD_TILES-1) issue_done_q<=1;
          else tile_q<=tile_q+1'b1;
        end else row_q<=row_q+1'b1;
      end
      if(job_valid && job_ready) begin
        current_job<=job; job_busy<=1; job_done_valid<=0;
        row_q<='0; tile_q<='0; loaded_q<='0; activated_q<='0; committed_q<='0; issue_done_q<=0;
      end else if(job_busy) begin
        if(load_valid && load_weight_idx==0) loaded_q<=loaded_q+1'b1;
        if(bank_activate) activated_q<=activated_q+1'b1;
        if(commit_valid) begin
          committed_q<=committed_q+1'b1;
          if(commit_tag.last) job_done_valid<=1;
        end
        if(job_done_valid && job_done_ready) begin job_done_valid<=0; job_busy<=0; end
      end
    end
  end
  // synthesis translate_off
  always @(posedge clk) if(rst_n) begin
    if(req_valid && !req_ready) $fatal(1,"Matrix A response not accepted");
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
