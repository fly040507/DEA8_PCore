package dea8_pcore_pkg;
  // --------------------------------------------------------------------------
  // Top-level architecture parameters
  // --------------------------------------------------------------------------
  parameter int unsigned N_CORE       = 8;
  parameter int unsigned TILE         = 16;
  parameter int unsigned ACT_BITS     = 8;
  parameter int unsigned WEIGHT_BITS  = 8;
  parameter int unsigned SCALE_BITS   = 8;
  parameter int unsigned PRODUCT_BITS = ACT_BITS + WEIGHT_BITS;
  parameter int unsigned PSUM_BITS    = 32;
  parameter int unsigned FP_BITS      = 32;
  parameter int unsigned BF_BITS      = 16;

  // HBM/FIFO packing. One HBM beat carries two 128-bit weight words.
  parameter int unsigned HBM_BITS             = 256;
  parameter int unsigned HBM_BYTES            = HBM_BITS / 8;
  parameter int unsigned WEIGHT_WORD_BITS     = TILE * WEIGHT_BITS;
  parameter int unsigned SCALE_WORD_BITS      = TILE * SCALE_BITS;
  parameter int unsigned WEIGHT_WORDS_PER_HBM = HBM_BITS / WEIGHT_WORD_BITS;
  parameter int unsigned WEIGHT_WORDS_PER_TILE = TILE;
  parameter int unsigned WEIGHT_HBM_BEATS_PER_TILE =
      (TILE * TILE * WEIGHT_BITS + HBM_BITS - 1) / HBM_BITS;
  parameter int unsigned SCALE_HBM_BEATS_PER_TILE =
      (SCALE_WORD_BITS + HBM_BITS - 1) / HBM_BITS;
  parameter int unsigned HBM_BEATS_PER_TILE =
      WEIGHT_HBM_BEATS_PER_TILE + SCALE_HBM_BEATS_PER_TILE;

  // Derived widths. Keep the minimum width of one for legal single-entry
  // configurations.
  parameter int unsigned TILE_IDX_BITS = (TILE <= 1) ? 1 : $clog2(TILE);
  parameter int unsigned TILE_CNT_BITS = (TILE <= 1) ? 1 : $clog2(TILE + 1);
  parameter int unsigned BANK_COUNT    = 2;
  parameter int unsigned BANK_IDX_BITS =
      (BANK_COUNT <= 1) ? 1 : $clog2(BANK_COUNT);
  parameter int unsigned EXP_FOLD_BITS = 6;
  parameter int unsigned BANK_ID_BITS  = 4;
  parameter int unsigned ROW_BITS      = 6;
  parameter int unsigned TOKEN_BITS    = 8;
  parameter int unsigned HEAD_BITS     = 3;
  parameter int unsigned BLOCK_BITS    = 6;
  parameter int unsigned POST_OP_BITS  = 5;
  parameter int unsigned EPOCH_BITS    = 4;
  parameter int unsigned ACC_ADDR_BITS = 10;
  parameter int unsigned MXU_STAGES    = 6;
  parameter int unsigned TREE_LEVELS   = (TILE <= 1) ? 0 : $clog2(TILE);
  parameter int unsigned L1_COUNT      = (TILE <= 1) ? 1 : (TILE / 2);
  parameter int unsigned L2_COUNT      = (TILE <= 2) ? 1 : (TILE / 4);
  parameter int unsigned L3_COUNT      = (TILE <= 4) ? 1 : (TILE / 8);
  parameter int unsigned TREE_SUM_BITS = PRODUCT_BITS +
                                         ((TILE <= 1) ? 0 : $clog2(TILE));

  parameter int unsigned M_MAX        = 64;
  parameter int unsigned D_MODEL      = 1024;
  parameter int unsigned D_HEAD       = 256;
  parameter int unsigned PREFIX_CAP   = 816;
  parameter int unsigned SUFFIX_LEN   = 51;
  parameter int unsigned PHYS_SEQ     = 880;
  parameter int unsigned N_KV_BLOCK   = 55;
  parameter int unsigned LOGICAL_SEQ  = PREFIX_CAP + SUFFIX_LEN;
  parameter int unsigned SUFFIX_BLK0  = PREFIX_CAP / TILE;
  parameter int unsigned HEAD_TILES   = D_HEAD / TILE;
  parameter int unsigned MATRIX_BLOCK_CYCLES = TILE + SUFFIX_LEN * HEAD_TILES;
  typedef enum logic [1:0] {BANK_NULL, BANK_LOAD, BANK_READY, BANK_ACTIVE} bank_state_e;

  parameter int unsigned MXU_LAT      = MXU_STAGES;
  parameter int unsigned DEQACC_LAT   = 5;
  parameter int unsigned PIPE_DRAIN   = MXU_LAT + DEQACC_LAT;
  parameter int          DOT_EXP_OFFSET = 266;
  parameter int          QK_EXP_FOLD    = -4;

  parameter int unsigned DW_ST        = TILE * SCALE_BITS;
  parameter int unsigned DW_ACT       = TILE * ACT_BITS;
  parameter int unsigned DW_SCALE     = TILE * SCALE_BITS;
  parameter int unsigned DW_PSUM      = TILE * PSUM_BITS;
  parameter int unsigned DW_VEC       = TILE * FP_BITS;
  parameter int unsigned DW_RES       = TILE * BF_BITS;
  parameter int unsigned DW_XBC       = TILE * BF_BITS;
  parameter int unsigned DW_CNET      = TILE * FP_BITS;
  parameter int unsigned N_LANE       = TILE;

  parameter int unsigned QOZ_WORDS    = 1632;
  parameter int unsigned OACC_WORDS   = 816;
  parameter int unsigned FACC_WORDS   = 51;
  parameter int unsigned WFIFO_DEPTH  = 512;
  parameter int unsigned WFIFO_DATA_DEPTH  = WFIFO_DEPTH;
  parameter int unsigned WFIFO_SCALE_DEPTH = 32;
  parameter int unsigned WFIFO_DATA_BITS   = WEIGHT_WORD_BITS;
  parameter int unsigned WFIFO_SCALE_BITS  = SCALE_WORD_BITS;
  parameter int unsigned KVFIFO_DEPTH = 128;
  parameter int unsigned XFIFO_DEPTH  = 128;

  typedef logic [FP_BITS-1:0] fp_t;
  typedef logic [BF_BITS-1:0] bf_t;
  typedef logic signed [ACT_BITS-1:0] act_t;
  typedef logic signed [WEIGHT_BITS-1:0] weight_t;
  typedef logic signed [PRODUCT_BITS-1:0] product_t;
  typedef logic signed [PSUM_BITS-1:0] psum_t;

  // Backward-compatible aliases used by the current workbench.
  typedef fp_t fp32_t;
  typedef bf_t bf16_t;
  typedef act_t int8_t;
  typedef psum_t int32_t;

  typedef enum logic [1:0] {
    ACC_FACC_A = 2'd0,
    ACC_FACC_B = 2'd1,
    ACC_OACC   = 2'd2,
    ACC_SBUF   = 2'd3
  } acc_sel_e;

  typedef struct packed {
    logic [BANK_ID_BITS-1:0] bank;
    logic [ROW_BITS-1:0]     row;
    logic [TOKEN_BITS-1:0]   nt;
    logic [TOKEN_BITS-1:0]   kt;
    logic [HEAD_BITS-1:0]    head;
    logic [BLOCK_BITS-1:0]   blk;
    logic [TILE-1:0] lane_mask;
    logic [POST_OP_BITS-1:0] post_op;
    logic signed [EXP_FOLD_BITS-1:0] exp_fold;
    logic        final_k;
    logic        last;
    logic [EPOCH_BITS-1:0] epoch;
  } pipe_tag_t;

  typedef struct packed {
    acc_sel_e    acc_sel;
    logic [ACC_ADDR_BITS-1:0] acc_addr;
    logic        tile_last;
  } deq_tag_t;

  typedef struct packed {
    logic signed [TILE-1:0][PSUM_BITS-1:0]   psum;
    logic        [TILE-1:0][SCALE_BITS-1:0]  e_stat;
    logic        [SCALE_BITS-1:0]            e_stream;
    pipe_tag_t                    tag;
  } mxu_rsp_t;

  typedef enum logic [2:0] {
    ATTN_QK,
    ATTN_EXP,
    ATTN_PV,
    ATTN_OACC_SCALE,
    ATTN_AFIN
  } attn_job_e;

  typedef enum logic [1:0] {
    QUERY_PREFIX,
    QUERY_STATE,
    QUERY_ACTION
  } query_kind_e;

  typedef enum logic [1:0] {
    OACC_OWNER_NONE,
    OACC_OWNER_PV,
    OACC_OWNER_SCALE,
    OACC_OWNER_AFIN
  } oacc_owner_e;

  typedef struct packed {
    attn_job_e job;
    logic [BLOCK_BITS-1:0] blk;
    logic pingpong;
    logic last;
  } attn_cmd_t;

endpackage
