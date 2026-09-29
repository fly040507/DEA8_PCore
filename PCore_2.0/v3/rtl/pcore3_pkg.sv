package pcore3_pkg;
  parameter int TILE=16, ROWS=51, ROW_LANES=2;
  parameter int PAIRS=(ROWS+ROW_LANES-1)/ROW_LANES;
  parameter int INT_BITS=8, SCALE_BITS=8, PSUM_BITS=32, FP_BITS=32;
  parameter int DATA_BITS=TILE*INT_BITS;
  parameter int TILE_BITS=6, PAIR_BITS=5, EPOCH_BITS=4;
  parameter int LOGICAL_ID_BITS=10;
  parameter int AFIFO_DEPTH=64, BFIFO_DEPTH=64;
  parameter int KV_BLOCKS=55;
  parameter int ATTN_K_TILES=16;
  parameter int ATTN_ISSUES=PAIRS*ATTN_K_TILES;
  parameter int MXU_PIPE_STAGES=7;
  // D0..D4 are architectural stages.  The external completion point is
  // therefore MXU(7) + DEQACC(5), not the four drain intervals between them.
  parameter int DEQACC_PIPE_STAGES=5;
  parameter int MATRIX_PIPE_DRAIN=MXU_PIPE_STAGES+DEQACC_PIPE_STAGES;
  parameter int MATRIX_SWITCH_CYCLES=1;
  parameter int MATRIX_STEADY_BUDGET=ATTN_ISSUES+MATRIX_PIPE_DRAIN+MATRIX_SWITCH_CYCLES;
  parameter int MATRIX_COLD_BUDGET=MATRIX_STEADY_BUDGET+16;
  parameter int DOT_EXP_OFFSET=266, EXP_FOLD_BITS=6;
  parameter int XBC_GROUPS=(ROWS+3)/4;

  typedef enum logic [1:0] {B_HBM=0,B_KVB=1} b_source_e;
  typedef enum logic [1:0] {ACC_FACC_A=0,ACC_FACC_B=1,ACC_OACC=2} acc_sel_e;
  typedef enum logic {ACC_READ_DEQACC=0,ACC_READ_RESULT=1} acc_read_owner_e;
  typedef enum logic [1:0] {MAT_PROJECTION=0,MAT_ATTENTION=1,MAT_GU=2} matrix_mode_e;
  typedef enum logic {MATRIX_QK=0,MATRIX_PV=1} matrix_op_e;

  typedef struct packed {
    logic [DATA_BITS-1:0] data;
    logic [SCALE_BITS-1:0] scale;
  } qvec16_t;

  typedef struct packed {
    qvec16_t [0:1] row;
    logic [1:0] row_valid;
    logic [PAIR_BITS-1:0] pair_idx;
    logic [TILE_BITS-1:0] tile_idx;
    logic slot;
    logic [1:0] reserved;
  } a2_t;

  typedef struct packed {
    qvec16_t [0:3] row;
    logic [3:0] row_valid;
    logic [3:0] group_idx;
    logic [TILE_BITS-1:0] tile_idx;
    logic slot;
    logic [3:0] reserved;
  } xbc4_t;

  typedef struct packed {
    qvec16_t [0:1] col;
    logic [TILE_BITS-1:0] tile_idx;
    logic [2:0] group_idx;
    logic [EPOCH_BITS-1:0] epoch;
    logic [2:0] reserved;
  } b2_t;

  typedef struct packed {
    qvec16_t col;
    logic [TILE_BITS-1:0] tile_idx;
    logic [3:0] column;
    logic [EPOCH_BITS-1:0] epoch;
  } b1_t;

  typedef struct packed {
    logic [EPOCH_BITS-1:0] epoch;
    logic [2:0] head;
    logic [TILE_BITS-1:0] tile_idx;
    logic [PAIR_BITS-1:0] pair_idx;
    logic [3:0] nt;
    logic final_k;
    logic last;
    logic signed [EXP_FOLD_BITS-1:0] exp_fold;
    acc_sel_e acc_sel;
    // 0: replace the selected accumulator, 1: add the old accumulator.
    logic add_old;
  } pair_meta_t;

  typedef struct packed {
    logic signed [1:0][TILE-1:0][PSUM_BITS-1:0] psum;
    logic [1:0] row_valid;
    logic [1:0][SCALE_BITS-1:0] e_stream;
    logic [TILE-1:0][SCALE_BITS-1:0] e_stat;
    pair_meta_t meta;
  } mxu_rsp_t;

  // Generic scheduler command. The datapath never needs to know whether the
  // caller is Projection, QK, PV or a future G-U operation.
  typedef struct packed {
    matrix_mode_e mode;
    matrix_op_e op;
    // A and B are independent IDs.  Projection/QK normally advance both;
    // PV holds a_id and advances only b_id.
    logic [LOGICAL_ID_BITS-1:0] a_id;
    logic [LOGICAL_ID_BITS-1:0] b_id;
    logic [5:0] m_rows;
    logic [3:0] out_tile;
    acc_sel_e acc_sel;
    logic add_old;
    logic result_last;
    logic job_last;
    logic signed [EXP_FOLD_BITS-1:0] exp_fold;
    logic [EPOCH_BITS-1:0] epoch;
    logic [2:0] head;
    logic [5:0] block_id;
  } matrix_cmd_t;

  typedef enum logic [2:0] {VPU_QK_POST=0,VPU_P_POST=1,VPU_OACC_SCALE=2,
                            VPU_AFIN=3,VPU_RECIP=4} vpu_op_e;
  typedef enum logic [1:0] {SFU_ALPHA_EXP=0,SFU_P_EXP=1,SFU_RECIP=2} sfu_op_e;
  typedef struct packed {
    vpu_op_e op;
    logic [5:0] block_id;
    logic [EPOCH_BITS-1:0] epoch;
    logic [2:0] head;
    logic facc_bank,sbuf_bank,pbuf_bank,alpha_bank;
  } vpu_cmd_t;
  typedef struct packed {
    sfu_op_e op;
    logic [5:0] block_id;
    logic [EPOCH_BITS-1:0] epoch;
    logic [2:0] head;
    logic sbuf_bank,alpha_bank;
  } sfu_cmd_t;

  function automatic logic [1:0] row_mask(input int pair_idx);
    return (pair_idx==PAIRS-1 && (ROWS%2)!=0) ? 2'b01 : 2'b11;
  endfunction

  function automatic int unsigned oacc_addr(input int pair_idx,input int nt);
    return pair_idx*16+nt;
  endfunction
endpackage
