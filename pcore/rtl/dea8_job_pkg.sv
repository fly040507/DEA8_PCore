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

  typedef struct packed {
    matrix_op_e op;
    job_context_t ctx;
    logic facc_bank;
    logic pbuf_bank;
    logic init_oacc;
  } matrix_job_t;

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
endpackage
