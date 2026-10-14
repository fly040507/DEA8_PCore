package pcore_pkg;
  parameter int TILE=16, ROWS=51, ROW_LANES=2;
  parameter int INT_BITS=8, SCALE_BITS=8, PSUM_BITS=32, FP_BITS=32;
  parameter int DATA_BITS=TILE*INT_BITS, ROW_BITS=DATA_BITS+SCALE_BITS;
  parameter int ROW_COUNT_BITS=$clog2(ROWS+1), PAIRS=(ROWS+ROW_LANES-1)/ROW_LANES;
  parameter int TILE_BITS=6, PAIR_BITS=$clog2(PAIRS), EPOCH_BITS=4;
  parameter int SEQ_BITS=16, TOKEN_BITS=32, MATRIX_TILE_COUNT_BITS=8;
  parameter int A_INPUT_ROWS=3, A_SLOTS=3, A_ROW_GROUPS=(ROWS+A_INPUT_ROWS-1)/A_INPUT_ROWS;
  parameter int A_GROUP_BITS=$clog2(A_ROW_GROUPS), A_SLOT_BITS=$clog2(A_SLOTS);
  parameter int B_SLOTS=8, B_LOAD_COLS=4, B_LOAD_GROUPS=TILE/B_LOAD_COLS;
  parameter int B_GROUP_BITS=$clog2(B_LOAD_GROUPS), B_BEAT_BITS=DATA_BITS*B_LOAD_COLS;
  parameter int B_PACKET_MAX_TILES=4, B_PACKET_BITS=256, B_BEAT_INDEX_BITS=5;
  parameter int ACC_RAW_INTERVAL=4, MXU_PIPE_STAGES=7, DEQACC_PIPE_STAGES=7;
  parameter int DOT_EXP_OFFSET=266, EXP_FOLD_BITS=6, KV_BLOCKS=55, ATTN_K_TILES=16;
  parameter int QOZ_Q_TILES=16, QOZ_O_TILES=16, QOZ_Z_TILES=32;

  typedef logic [TOKEN_BITS-1:0] job_token_t;
  typedef enum logic {A_XBC=0,A_LOCAL=1} a_source_e;
  typedef enum logic [1:0] {B_HBM=0,B_KVB=1} b_source_e;
  typedef enum logic [1:0] {ACC_FACC_A=0,ACC_FACC_B=1,ACC_OACC=2} acc_sel_e;
  typedef enum logic {ACC_READ_DEQACC=0,ACC_READ_RESULT=1} acc_read_owner_e;
  typedef enum logic [1:0] {MAT_PROJECTION=0,MAT_ATTENTION=1,MAT_GU=2} matrix_mode_e;
  typedef enum logic [2:0] {OP_Q_PROJ,OP_K_PROJ,OP_V_PROJ,OP_ATTENTION,
                            OP_O_PROJ,OP_GU,OP_DOWN_PROJ} pcore_op_e;
  typedef enum logic [1:0] {QOZ_NONE=0,QOZ_Q=1,QOZ_O=2,QOZ_Z=3} qoz_owner_e;
  typedef enum logic [2:0] {ROLE_WEIGHT,ROLE_K,ROLE_V,ROLE_GATE,ROLE_UP} b_role_e;
  typedef enum logic [2:0] {LOCAL_NONE,LOCAL_Q,LOCAL_O,LOCAL_Z,LOCAL_P} local_kind_e;
  typedef enum logic [2:0] {PCORE_OK,PCORE_INVALID,PCORE_PRECONDITION,PCORE_UNSUPPORTED,
                            PCORE_FAULT,PCORE_CANCELLED,PCORE_TOKEN_LIMIT} pcore_status_e;
  typedef struct packed {
    pcore_op_e op;
    logic [15:0] job_id;
    logic [31:0] user_tag;
    logic [2:0] core_id,head;
    logic [15:0] data_context,profile_id,profile_version;
    logic [15:0] position_base,feature_context,transfer_context;
    // Global transfer epoch is assigned by DEA8, not a per-core generation.
    logic [15:0] transfer_epoch;
    // Resolved layout coordinates, not the feature-context lookup key.
    logic [15:0] kv_column_base0,kv_column_base1;
    logic [15:0] input_version,output_version;
    logic [EPOCH_BITS-1:0] epoch;
  } pcore_job_t;
  typedef struct packed {
    job_token_t token;
    logic [15:0] job_id;
    logic [31:0] user_tag;
    pcore_op_e op;
    pcore_status_e status;
    logic empty;
    logic [ROW_COUNT_BITS-1:0] rows;
  } pcore_completion_t;
  typedef enum logic [1:0] {PAIR_ROPE,PAIR_V,PAIR_GU} pair_kind_e;
  typedef struct packed {
    job_token_t token;
    pair_kind_e kind;
    logic [5:0] pair_seq;
    logic [TILE_BITS-1:0] nt0,nt1;
    logic [ROW_COUNT_BITS-1:0] rows;
  } pair_object_t;
  typedef struct packed {
    job_token_t token;
    logic [SEQ_BITS-1:0] work_seq;
    acc_sel_e sel;
    logic [ROW_COUNT_BITS-1:0] rows;
    logic [TILE_BITS-1:0] nt;
    logic [5:0] pair_seq;
    logic half;
  } capture_desc_t;
  typedef struct packed {
    capture_desc_t owner;
    logic [PAIR_BITS-1:0] pair_idx;
    logic [ROW_LANES-1:0] mask;
    logic [ROW_LANES-1:0][TILE-1:0][FP_BITS-1:0] data;
  } pair_capture_t;
  typedef struct packed {
    job_token_t token;
    logic [ROW_COUNT_BITS-1:0] row;
  } pair_read_t;
  typedef struct packed {
    pair_read_t request;
    logic [1:0][TILE-1:0][FP_BITS-1:0] data;
  } pair_reply_t;
  typedef enum logic [3:0] {UNIT_ROPE_QUANT,UNIT_V_QUANT,UNIT_GU_MUL_QUANT,
    UNIT_QK_POST,UNIT_P_POST,UNIT_OACC_SCALE,UNIT_AFIN_QUANT,
    UNIT_GELU,UNIT_ALPHA_EXP,UNIT_P_EXP,UNIT_RECIP} unit_function_e;
  typedef struct packed {
    job_token_t token,parent_token;
    unit_function_e function_id;
    logic [ROW_COUNT_BITS-1:0] rows;
    logic [TILE_BITS-1:0] nt0,nt1;
    logic [15:0] profile_id,profile_version,position_base,feature_context,output_version;
    logic identity_rows;
    logic [15:0] column_base0,column_base1;
    logic [5:0] block_id;
    logic scan_pair_major;
  } unit_cmd_t;
  typedef struct packed {
    job_token_t token;
    logic [ROW_COUNT_BITS-1:0] row;
    logic [TILE-1:0] mask;
    logic [TILE-1:0][FP_BITS-1:0] data;
    logic last;
  } fp16_stream_t;
  typedef struct packed {
    job_token_t token;
    logic [ROW_COUNT_BITS-1:0] row;
    logic [1:0] group_id;
    logic [3:0] mask;
    logic [3:0][FP_BITS-1:0] data;
    logic last;
  } fp4_stream_t;
  typedef enum logic [2:0] {WS_SCORE,WS_M,WS_AA,WS_L,WS_ALPHA,WS_RECIP} workspace_kind_e;
  typedef struct packed {
    job_token_t token;
    workspace_kind_e kind;
    logic bank,write;
    logic [5:0] block_id;
    logic [ROW_COUNT_BITS-1:0] index;
    logic [1:0] group_id;
    logic [TILE-1:0] mask;
    logic [ROW_LANES-1:0] row_mask;
    logic [ROW_LANES-1:0][TILE-1:0][FP_BITS-1:0] data;
  } workspace_req_t;
  typedef struct packed {
    job_token_t token;
    workspace_kind_e kind;
    logic bank;
    logic [5:0] block_id;
    logic [ROW_COUNT_BITS-1:0] index;
    logic [1:0] group_id;
    logic [TILE-1:0] mask;
    logic [ROW_LANES-1:0] row_mask;
    logic [ROW_LANES-1:0][TILE-1:0][FP_BITS-1:0] data;
  } workspace_rsp_t;
  typedef struct packed {
    job_token_t token;
    workspace_kind_e kind;
    logic bank,write;
    logic [5:0] block_id;
    logic [ROW_COUNT_BITS-1:0] index;
    logic [1:0] group_id;
    logic [3:0] mask;
    logic [3:0][FP_BITS-1:0] data;
  } sfu_workspace_req_t;
  typedef struct packed {
    job_token_t token;
    workspace_kind_e kind;
    logic [5:0] block_id;
    logic [ROW_COUNT_BITS-1:0] index;
    logic [1:0] group_id;
    logic [3:0] mask;
    logic [3:0][FP_BITS-1:0] data;
  } sfu_workspace_rsp_t;
  typedef struct packed {
    logic [1:0] score_complete,alpha_complete;
    logic [1:0][5:0] score_block,alpha_block;
    logic [3:0] stat_complete;
    logic [3:0][5:0] stat_block;
  } workspace_status_t;
  typedef struct packed {
    job_token_t token;
    acc_sel_e sel;
    logic [PAIR_BITS-1:0] pair_idx;
    logic [TILE_BITS-1:0] nt;
  } unit_acc_read_t;
  typedef struct packed {
    unit_acc_read_t request;
    logic [ROW_LANES-1:0] mask;
    logic [ROW_LANES-1:0][TILE-1:0][FP_BITS-1:0] data;
  } unit_acc_reply_t;
  typedef struct packed {
    logic [DATA_BITS-1:0] data;
    logic [SCALE_BITS-1:0] scale;
  } qvec16_t;
  parameter int V_GROUPS=(ROWS+TILE-1)/TILE;
  parameter int V_PACKETS_PER_TILE=V_GROUPS*(TILE/ROW_LANES);
  typedef struct packed {
    job_token_t token;
    logic [TILE_BITS-1:0] tile;
    logic [5:0] index;
    logic [ROW_LANES-1:0] mask;
    logic [TILE-1:0] token_mask;
    qvec16_t [ROW_LANES-1:0] entry;
    logic last;
  } kv_quant_t;

  typedef struct packed {
    local_kind_e kind;
    logic [15:0] content_version,data_context,profile_id,profile_version;
    logic [2:0] head;
    logic [ROW_COUNT_BITS-1:0] m_rows;
    logic [5:0] block_id;
  } local_object_t;
  typedef struct packed {
    job_token_t token;
    local_kind_e kind;
    logic set_id;
    logic [15:0] content_version;
    logic [TILE_BITS-1:0] tile;
    logic [A_INPUT_ROWS-1:0][ROW_COUNT_BITS-1:0] row;
    logic [A_INPUT_ROWS-1:0] mask;
    qvec16_t [A_INPUT_ROWS-1:0] entry;
  } local_write_t;
  typedef struct packed {
    job_token_t token;
    local_kind_e kind;
    logic set_id;
    logic [15:0] content_version;
    logic [SEQ_BITS-1:0] request_seq;
    logic [TILE_BITS-1:0] tile;
    logic [A_GROUP_BITS-1:0] group_idx;
  } local_read_t;
  typedef struct packed {
    local_read_t request;
    logic [A_INPUT_ROWS-1:0] mask;
    qvec16_t [A_INPUT_ROWS-1:0] entry;
  } local_response_t;
  typedef struct packed {
    job_token_t token;
    local_kind_e kind;
    logic set_id;
    logic [15:0] content_version;
  } local_release_t;

  typedef struct packed {
    matrix_mode_e mode;
    a_source_e matrix_a;
    b_source_e b_source;
    logic [7:0] k_tiles,n_tiles;
    qoz_owner_e input_owner;
    logic output_qoz,geometry_valid;
  } operation_profile_t;

  // A vector return avoids the XSim packed-struct function issue.
  function automatic logic [$bits(operation_profile_t)-1:0] operation_profile(input pcore_op_e op);
    case(op)
      OP_Q_PROJ: return {MAT_PROJECTION,A_XBC,B_HBM,8'd64,8'd16,QOZ_NONE,1'b1,1'b1};
      OP_K_PROJ,OP_V_PROJ: return {MAT_PROJECTION,A_XBC,B_HBM,8'd64,8'd2,QOZ_NONE,1'b0,1'b1};
      OP_O_PROJ: return {MAT_PROJECTION,A_LOCAL,B_HBM,8'd16,8'd64,QOZ_O,1'b0,1'b1};
      OP_DOWN_PROJ: return {MAT_PROJECTION,A_LOCAL,B_HBM,8'd32,8'd64,QOZ_Z,1'b0,1'b1};
      OP_ATTENTION: return {MAT_ATTENTION,A_LOCAL,B_KVB,8'd0,8'd0,QOZ_Q,1'b0,1'b0};
      OP_GU: return {MAT_GU,A_XBC,B_HBM,8'd64,8'd32,QOZ_NONE,1'b1,1'b0};
      default: return '0;
    endcase
  endfunction
  function automatic int unsigned effective_rows(input pcore_op_e op,input int unsigned m);
    return (op==OP_K_PROJ||op==OP_V_PROJ)?ROWS:m;
  endfunction
  function automatic int unsigned pairs_for_rows(input int unsigned m);
    return (m+ROW_LANES-1)/ROW_LANES;
  endfunction
  function automatic logic [ROW_LANES-1:0] row_mask_for_rows(input int unsigned m,pair_idx);
    logic [ROW_LANES-1:0] mask;
    for(int r=0;r<ROW_LANES;r++)mask[r]=pair_idx*ROW_LANES+r<m;
    return mask;
  endfunction
  function automatic logic [A_INPUT_ROWS-1:0] a_group_mask(input int unsigned m,group_idx);
    logic [A_INPUT_ROWS-1:0] mask;
    for(int r=0;r<A_INPUT_ROWS;r++)mask[r]=group_idx*A_INPUT_ROWS+r<m;
    return mask;
  endfunction
  function automatic logic [ROWS-1:0] row_prefix(input int unsigned m);
    logic [ROWS-1:0] mask;
    for(int r=0;r<ROWS;r++)mask[r]=r<m;
    return mask;
  endfunction
  function automatic int unsigned oacc_addr(input int pair_idx,nt);
    return pair_idx*TILE+nt;
  endfunction
  function automatic int unsigned b_packet_tiles(input b_source_e source);
    return source==B_HBM?B_PACKET_MAX_TILES:2;
  endfunction

  typedef struct packed {
    job_token_t token;
    logic [SEQ_BITS-1:0] work_seq,tile_idx;
    qvec16_t [0:ROW_LANES-1] row;
    logic [ROW_LANES-1:0] row_valid;
    logic [PAIR_BITS-1:0] pair_idx;
  } a2_t;
  typedef struct packed {
    job_token_t token;
    logic [SEQ_BITS-1:0] work_seq,occurrence_seq,first_tile;
    logic [ROW_COUNT_BITS-1:0] m_rows;
    logic [4:0] uses;
  } a_slot_desc_t;
  typedef struct packed {
    a_slot_desc_t destination;
    local_kind_e kind;
    logic set_id;
    logic [15:0] content_version;
    logic [TILE_BITS-1:0] tile;
  } local_load_cmd_t;
  typedef struct packed {
    job_token_t token;
    logic [SEQ_BITS-1:0] work_seq,occurrence_seq;
    logic [A_GROUP_BITS-1:0] group_idx;
    logic [A_INPUT_ROWS-1:0] row_valid;
    qvec16_t [A_INPUT_ROWS-1:0] row;
  } a3_beat_t;
  typedef struct packed {
    job_token_t token;
    logic [SEQ_BITS-1:0] work_seq,packet_seq;
    logic [B_BEAT_INDEX_BITS-1:0] beat_idx;
    logic last;
  } b_beat_tag_t;
  typedef struct packed {
    job_token_t token;
    logic [SEQ_BITS-1:0] work_seq,packet_seq,first_tile;
    b_source_e source;
    matrix_mode_e mode;
    b_role_e role;
    logic [5:0] block_id;
  } b_packet_desc_t;
  typedef struct packed {
    job_token_t token;
    logic [SEQ_BITS-1:0] work_seq,tile_idx;
    b_role_e role;
    logic bank;
    logic [B_GROUP_BITS-1:0] group_idx;
    logic [B_LOAD_COLS-1:0][DATA_BITS-1:0] data;
    logic [TILE-1:0][SCALE_BITS-1:0] scales;
  } b4_t;
  typedef struct packed {
    acc_sel_e sel;
    logic [9:0] addr;
    logic [ROW_LANES-1:0] row_valid;
    logic [ROW_LANES-1:0][TILE-1:0][FP_BITS-1:0] data;
  } acc_write_t;
  typedef struct packed {
    job_token_t token;
    acc_write_t payload;
  } unit_acc_write_t;
  typedef struct packed {
    job_token_t token;
    logic [SEQ_BITS-1:0] work_seq;
    logic [ROW_COUNT_BITS-1:0] m_rows;
    logic [MATRIX_TILE_COUNT_BITS-1:0] tiles;
    matrix_mode_e mode;
    b_role_e role;
    logic [5:0] block_id;
    logic [EPOCH_BITS-1:0] epoch;
    logic [2:0] head;
    logic [TILE_BITS-1:0] nt;
    acc_sel_e acc_sel;
    logic add_old,nt_per_tile;
    logic signed [EXP_FOLD_BITS-1:0] exp_fold;
    logic [5:0] gu_n;
  } compute_job_t;
  typedef struct packed {
    job_token_t token;
    logic [SEQ_BITS-1:0] work_seq,tile_idx;
    b_role_e role;
    logic [5:0] block_id;
    logic [EPOCH_BITS-1:0] epoch;
    logic [2:0] head;
    logic [PAIR_BITS-1:0] pair_idx;
    logic [ROW_COUNT_BITS-1:0] m_rows;
    logic [TILE_BITS-1:0] nt;
    logic final_k,last;
    logic signed [EXP_FOLD_BITS-1:0] exp_fold;
    acc_sel_e acc_sel;
    logic add_old;
    matrix_mode_e mode;
    logic [5:0] gu_n;
  } pair_meta_t;
  typedef struct packed {
    logic signed [ROW_LANES-1:0][TILE-1:0][PSUM_BITS-1:0] psum;
    logic [ROW_LANES-1:0] row_valid;
    logic [ROW_LANES-1:0][SCALE_BITS-1:0] e_stream;
    logic [TILE-1:0][SCALE_BITS-1:0] e_stat;
    pair_meta_t meta;
  } mxu_rsp_t;
endpackage
