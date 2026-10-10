package pcore_pkg;
  parameter int TILE=16, ROWS=51, ROW_LANES=2;
  parameter int PAIRS=(ROWS+ROW_LANES-1)/ROW_LANES;
  parameter int INT_BITS=8, SCALE_BITS=8, PSUM_BITS=32, FP_BITS=32;
  parameter int DATA_BITS=TILE*INT_BITS;
  parameter int TILE_BITS=6, PAIR_BITS=5, EPOCH_BITS=4;
  parameter int MATRIX_TILE_COUNT_BITS=8;
  parameter int LOGICAL_ID_BITS=10;
  parameter int AFIFO_DEPTH=64, BFIFO_DEPTH=64;
  parameter int KV_BLOCKS=55;
  parameter int ATTN_K_TILES=16;
  parameter int ATTN_ISSUES=PAIRS*ATTN_K_TILES;
  parameter int MXU_PIPE_STAGES=7;
  // The external completion point includes the synchronous accumulator RAM
  // DEQACC_3.3ns D0..D10: split abs/lead and normalize/exponent,
  // partial pack, synchronous ACC response, lane arithmetic and commit.
  parameter int DEQACC_PIPE_STAGES=11;
  parameter int MXU_TAIL_EDGES=MXU_PIPE_STAGES-1;
  parameter int DEQACC_COMMIT_CYCLES=DEQACC_PIPE_STAGES;
  parameter int ATTN_NOMINAL_SLOT=ATTN_ISSUES+MXU_TAIL_EDGES+DEQACC_COMMIT_CYCLES;
  // Compatibility alias; steady throughput is measured between first issues.
  parameter int MATRIX_STEADY_BUDGET=ATTN_NOMINAL_SLOT;
  parameter int MATRIX_COLD_BUDGET=MATRIX_STEADY_BUDGET+16;
  parameter int DOT_EXP_OFFSET=266, EXP_FOLD_BITS=6;
  parameter int XBC_GROUPS=(ROWS+3)/4;

  typedef enum logic {A_XBC=0,A_LOCAL=1} a_source_e;
  typedef enum logic [1:0] {B_HBM=0,B_KVB=1} b_source_e;
  typedef enum logic [1:0] {ACC_FACC_A=0,ACC_FACC_B=1,ACC_OACC=2} acc_sel_e;
  typedef enum logic {ACC_READ_DEQACC=0,ACC_READ_RESULT=1} acc_read_owner_e;
  typedef struct packed {
    acc_sel_e sel;
    logic [9:0] addr;
    logic [1:0] row_valid;
    logic [1:0][15:0][31:0] data;
  } acc_write_t;
  typedef enum logic [1:0] {MAT_PROJECTION=0,MAT_ATTENTION=1,MAT_GU=2} matrix_mode_e;
  typedef enum logic [2:0] {OP_Q_PROJ,OP_K_PROJ,OP_V_PROJ,OP_ATTENTION,
                            OP_O_PROJ,OP_GU,OP_DOWN_PROJ} pcore_op_e;
  typedef struct packed {
    logic [15:0] job_id;
    logic [EPOCH_BITS-1:0] epoch;
    logic [2:0] head;
    pcore_op_e op;
  } job_header_t;
  typedef struct packed {job_header_t header;} pcore_job_t;
  typedef enum logic [1:0] {JOB_OK,JOB_UNSUPPORTED,JOB_PROTOCOL_ERROR} job_status_e;
  typedef struct packed {job_header_t header;job_status_e status;} pcore_completion_t;
  typedef enum logic [1:0] {POST_GU=0,POST_PROJ_QUANT=1,POST_RESERVED=2} pcore_post_op_e;
  typedef struct packed {job_header_t header;pcore_post_op_e op;logic [5:0] n;} pcore_post_job_t;
  typedef enum logic [1:0] {QOZ_NONE=0,QOZ_Q=1,QOZ_O=2,QOZ_Z=3} qoz_owner_e;
  // One 32-tile physical region: acquire -> ordered writes -> complete ->
  // consumer reads -> release. O is produced by Attention and consumed by O_PROJ.
  parameter int QOZ_Q_TILES=16,QOZ_O_TILES=16,QOZ_Z_TILES=32;
  typedef struct packed {
    job_header_t header;
    qoz_owner_e owner;
    logic [5:0] tiles;
  } qoz_region_req_t;
  typedef enum logic {MATRIX_QK=0,MATRIX_PV=1} matrix_op_e;

  // Static operation contract: seven PCore jobs map to three physical
  // Matrix implementations and share one execution core.
  typedef struct packed {
    matrix_mode_e mode;
    a_source_e matrix_a;
    b_source_e b_source;
    logic [7:0] k_tiles;
    logic [7:0] n_tiles;
    qoz_owner_e input_owner;
    logic output_qoz;
    // k_tiles/n_tiles describe Projection only. Other adapters own geometry.
    logic geometry_valid;
  } operation_profile_t;

  function automatic logic [$bits(operation_profile_t)-1:0] operation_profile(input pcore_op_e op);
    case(op)
      OP_Q_PROJ: return {MAT_PROJECTION,A_XBC,B_HBM,8'd64,8'd16,QOZ_NONE,1'b1,1'b1};
      OP_K_PROJ: return {MAT_PROJECTION,A_XBC,B_HBM,8'd64,8'd2,QOZ_NONE,1'b0,1'b1};
      OP_V_PROJ: return {MAT_PROJECTION,A_XBC,B_HBM,8'd64,8'd2,QOZ_NONE,1'b0,1'b1};
      OP_O_PROJ: return {MAT_PROJECTION,A_LOCAL,B_HBM,8'd16,8'd64,QOZ_O,1'b0,1'b1};
      OP_DOWN_PROJ: return {MAT_PROJECTION,A_LOCAL,B_HBM,8'd32,8'd64,QOZ_Z,1'b0,1'b1};
      OP_ATTENTION: return {MAT_ATTENTION,A_LOCAL,B_KVB,8'd0,8'd0,QOZ_Q,1'b0,1'b0};
      OP_GU: return {MAT_GU,A_LOCAL,B_HBM,8'd0,8'd0,QOZ_NONE,1'b1,1'b0};
      default: return '0;
    endcase
  endfunction

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
  // Interpreted by the accepted post_job.op:
  // POST_PROJ_QUANT: row=pair 0..25, first=even, second=odd, row_valid=11/01.
  // POST_GU: row=0..50, first=Gate, second=Up, row_valid=01.
  // valid && !ready holds the complete payload; clear cancels the generation.
  typedef struct packed {
    job_header_t header;
    logic [5:0] n,row;
    logic [1:0] row_valid;
    logic last;
    logic [15:0][31:0] first,second;
  } post_data_t;
  typedef struct packed {
    job_header_t header;
    logic [5:0] n;
    a2_t pair_data;
    logic last;
  } post_result_t;

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
    logic [TILE_BITS-1:0] nt;
    logic final_k;
    logic last;
    logic signed [EXP_FOLD_BITS-1:0] exp_fold;
    acc_sel_e acc_sel;
    // 0: replace the selected accumulator, 1: add the old accumulator.
    logic add_old;
    // G-U context is carried with the commit, so a same-edge next-job launch
    // cannot relabel the previous Gate/Up result with live wrapper state.
    matrix_mode_e mode;
    logic [5:0] gu_n;
  } pair_meta_t;

  typedef struct packed {
    logic signed [1:0][TILE-1:0][PSUM_BITS-1:0] psum;
    logic [1:0] row_valid;
    logic [1:0][SCALE_BITS-1:0] e_stream;
    logic [TILE-1:0][SCALE_BITS-1:0] e_stat;
    pair_meta_t meta;
  } mxu_rsp_t;

  // Physical Matrix service port; algorithms remain in operation adapters.
  typedef struct packed {
    logic start;
    a_source_e a_source;
    logic a_streaming;
    b_source_e b_source;
    matrix_mode_e mode;
    logic [5:0] gu_n;
    logic [TILE_BITS-1:0] a_stream,b_stream;
    logic [MATRIX_TILE_COUNT_BITS-1:0] tiles;
    logic [5:0] rows;
    logic [EPOCH_BITS-1:0] epoch;
    logic [2:0] head;
    logic [TILE_BITS-1:0] nt;
    logic nt_per_tile,clear_each_tile,final_k,add_old,slot_ready;
    logic signed [EXP_FOLD_BITS-1:0] exp_fold;
    acc_sel_e acc_sel;
    logic local_valid;
    a2_t local_entry;
    logic rd_valid;
    acc_sel_e rd_sel;
    logic [9:0] rd_addr;
    logic wr_valid;
    acc_write_t wr;
  } matrix_service_req_t;
  typedef struct packed {
    logic ready,busy,done,issue_done,commit_valid,write_valid,slot_reserve;
    pair_meta_t meta;
    acc_write_t write_data;
    logic local_ready,a_error,b_error;
    logic rd_ready,rd_valid,wr_ready;
    logic [15:0][31:0] even_data,odd_data;
  } matrix_service_rsp_t;

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
    logic [TILE_BITS-1:0] out_tile;
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
