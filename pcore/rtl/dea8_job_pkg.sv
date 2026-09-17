package dea8_job_pkg;
  import dea8_pcore_pkg::*;

  // PCore-side job contracts. These are NOT replacements for the GCore VOP,
  // CNET or CCU wire encodings; adapters must preserve those external contracts.
  typedef enum logic {MATRIX_QK, MATRIX_PV} matrix_op_e;
  typedef enum logic [2:0] {
    VPU_QK_POST, VPU_P_POST, VPU_OACC_SCALE, VPU_AFIN,
    VPU_ROPE_Q, VPU_ROPE_K, VPU_GELU_MUL
  } vpu_op_e;
  typedef enum logic [1:0] {SFU_ALPHA_EXP, SFU_P_EXP, SFU_RECIP} sfu_op_e;

  typedef struct packed {
    logic [BLOCK_BITS-1:0] block_id;
    logic [HEAD_BITS-1:0] head;
    logic [EPOCH_BITS-1:0] epoch;
  } job_context_t;

  // Transport/queue descriptor: physical banks are derived at execution.
  typedef struct packed {
    matrix_op_e op;
    job_context_t ctx;
  } matrix_block_job_t;

  localparam int MATRIX_JOB_COUNT = 2*N_KV_BLOCK;
  localparam int MATRIX_JOB_INDEX_BITS = $clog2(MATRIX_JOB_COUNT+1);

  function automatic matrix_block_job_t attention_block_job(
      input int index, input logic [HEAD_BITS-1:0] head,
      input logic [EPOCH_BITS-1:0] epoch);
    matrix_block_job_t value;
    value='0;
    value.ctx.head=head;
    value.ctx.epoch=epoch;
    if(index==0) begin value.op=MATRIX_QK; value.ctx.block_id=0; end
    else if(index==MATRIX_JOB_COUNT-1) begin
      value.op=MATRIX_PV; value.ctx.block_id=BLOCK_BITS'(N_KV_BLOCK-1);
    end else if(index%2==1) begin
      value.op=MATRIX_QK; value.ctx.block_id=BLOCK_BITS'((index+1)/2);
    end else begin
      value.op=MATRIX_PV; value.ctx.block_id=BLOCK_BITS'(index/2-1);
    end
    return value;
  endfunction

  typedef struct packed {
    matrix_op_e op;
    job_context_t ctx;
    logic facc_bank;
    logic pbuf_bank;
    logic init_oacc;
  } matrix_job_t;

  function automatic matrix_job_t expand_matrix_job(input matrix_block_job_t block_job);
    return {block_job.op, block_job.ctx, block_job.ctx.block_id[0],
            block_job.ctx.block_id[0],
            (block_job.op==MATRIX_PV && block_job.ctx.block_id==0)};
  endfunction

  typedef struct packed {
    vpu_op_e op;
    job_context_t ctx;
    logic facc_bank;
    logic sbuf_bank;
    logic pbuf_bank;
    logic alpha_bank;
  } vpu_job_t;

  typedef struct packed {
    sfu_op_e op;
    job_context_t ctx;
    logic sbuf_bank;
    logic alpha_bank;
  } sfu_job_t;

  // Separate result streams retain row identity through arbitrary SFU latency.
  localparam int SFU_LANES = 2;
  localparam int PAIRS_PER_ROW = TILE / SFU_LANES;
  localparam int PAIR_BITS = (PAIRS_PER_ROW <= 1) ? 1 : $clog2(PAIRS_PER_ROW);
  typedef struct packed {
    job_context_t ctx;
    logic [ROW_BITS-1:0] row;
    logic [PAIR_BITS-1:0] pair_index;
    logic [SFU_LANES-1:0] lane_mask;
    logic [SFU_LANES*FP_BITS-1:0] data;
    logic last;
  } p_result_t;

  // Q linear-projection post-processing contract, separate from RoPE commands.
  localparam int PROJ_K_TILES = D_MODEL/TILE;
  localparam int PROJ_N_TILES = D_HEAD/TILE;
  localparam int PROJ_K_BITS = $clog2(PROJ_K_TILES);
  typedef struct packed {
    logic [HEAD_BITS-1:0] head;
    logic [EPOCH_BITS-1:0] epoch;
    logic [TILE_IDX_BITS-1:0] nt;
  } projection_post_job_t;
  typedef struct packed {
    projection_post_job_t job;
    logic [ROW_BITS-1:0] row;
    logic [DW_ACT-1:0] data;
    logic [SCALE_BITS-1:0] scale;
    logic last;
  } projection_q_result_t;
endpackage
