package pcore2_pkg;
  parameter int TILE=16, ROWS=51, ROW_LANES=2;
  parameter int INT_BITS=8, SCALE_BITS=8, PSUM_BITS=32;
  parameter int PAIRS=(ROWS+ROW_LANES-1)/ROW_LANES;
  parameter int PAIR_BITS=$clog2(PAIRS), TILE_BITS=6, EPOCH_BITS=4;
  parameter int DATA_BITS=TILE*INT_BITS, STAGES=7;
  parameter int A_DEPTH=64, B_DEPTH=64, HBM_BITS=256;
  parameter int DATA_BEATS=TILE*TILE*INT_BITS/HBM_BITS;
  parameter int HBM_BEATS=DATA_BEATS+1;
  typedef enum logic [1:0] {A_XBC=0,A_QOZ=1,A_PBUF=2} a_source_t;
  // One ordered job; configuration cannot change until done or clear.
  typedef struct packed {
    a_source_t a_source;
    logic b_from_kv;
    logic [TILE_BITS:0] tiles;
    logic slot;
    logic [EPOCH_BITS-1:0] epoch;
    logic [2:0] head;
    logic along_n;
    logic init_dest;
    logic [7:0] kt_base,nt_base;
    logic [1:0] dest_bank;
    logic [9:0] dest_base,dest_stride;
    logic [TILE_BITS-1:0] a_mem_base;
    logic pbuf_bank;
  } job_t;
  typedef struct packed {
    logic valid;
    logic bank;
    logic [EPOCH_BITS-1:0] epoch;
    logic [TILE_BITS-1:0] tile_base;
    logic [TILE_BITS:0] tile_count;
  } a_bank_ctrl_t;
  typedef struct packed {
    logic [1:0] mask;
    logic bank;
    logic [TILE_BITS-1:0] tile_idx;
    logic [PAIR_BITS-1:0] pair_idx;
    logic [1:0][DATA_BITS-1:0] data;
    logic [1:0][SCALE_BITS-1:0] scale;
  } a_write_t;
  typedef struct packed {
    logic [1:0] reserved;
    logic [1:0][DATA_BITS-1:0] data;
    logic [1:0][SCALE_BITS-1:0] scale;
    logic [1:0] row_valid;
    logic [PAIR_BITS-1:0] pair_idx;
    logic [TILE_BITS-1:0] tile_idx;
    logic slot;
  } a2_t;
  typedef struct packed {
    logic [DATA_BITS-1:0] data;
    logic [SCALE_BITS-1:0] scale;
  } b_t;
  // Context is supplied by the job owner, never stored inside a PE.
  typedef struct packed {
    logic [EPOCH_BITS-1:0] epoch;
    logic [2:0] head;
    logic [5:0] row;
    logic [7:0] kt,nt;
    logic final_k,last;
  } tag_t;
  typedef struct packed {
    logic [1:0] bank;
    logic [9:0] address;
    logic zero;
  } dest_t;
  function automatic logic [1:0] row_mask(input int pair_idx);
    return pair_idx==PAIRS-1 && ROWS%2!=0 ? 2'b01 : 2'b11;
  endfunction
endpackage
