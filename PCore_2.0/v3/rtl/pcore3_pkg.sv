package pcore3_pkg;
  parameter int TILE=16, ROWS=51, ROW_LANES=2;
  parameter int PAIRS=(ROWS+ROW_LANES-1)/ROW_LANES;
  parameter int INT_BITS=8, SCALE_BITS=8, PSUM_BITS=32, FP_BITS=32;
  parameter int DATA_BITS=TILE*INT_BITS;
  parameter int TILE_BITS=6, PAIR_BITS=5, EPOCH_BITS=4;
  parameter int AFIFO_DEPTH=64, BFIFO_DEPTH=64;
  parameter int DOT_EXP_OFFSET=266, EXP_FOLD_BITS=6;
  parameter int XBC_GROUPS=(ROWS+3)/4;

  typedef enum logic [1:0] {B_HBM=0,B_KVB=1} b_source_e;
  typedef enum logic [1:0] {ACC_FACC_A=0,ACC_FACC_B=1,ACC_OACC=2} acc_sel_e;

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
    logic acc_clear;
  } pair_meta_t;

  typedef struct packed {
    logic signed [1:0][TILE-1:0][PSUM_BITS-1:0] psum;
    logic [1:0] row_valid;
    logic [1:0][SCALE_BITS-1:0] e_stream;
    logic [TILE-1:0][SCALE_BITS-1:0] e_stat;
    pair_meta_t meta;
  } mxu_rsp_t;

  function automatic logic [1:0] row_mask(input int pair_idx);
    return (pair_idx==PAIRS-1 && (ROWS%2)!=0) ? 2'b01 : 2'b11;
  endfunction

  function automatic int unsigned oacc_addr(input int pair_idx,input int nt);
    return pair_idx*16+nt;
  endfunction
endpackage
