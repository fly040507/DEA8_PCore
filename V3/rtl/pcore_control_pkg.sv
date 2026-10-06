package pcore_control_pkg;
  import pcore3_pkg::*;

  parameter int USER_TAG_BITS=64, GENERATION_BITS=16, COMMAND_BITS=16;
  parameter int CORE_BITS=3, POSITION_BITS=16, INDEX_BITS=10;
  parameter int V_TOKEN_BLOCKS=(ROWS+TILE-1)/TILE;
  parameter int V_PACKETS_PER_TILE=V_TOKEN_BLOCKS*(TILE/ROW_LANES);

  // user_tag is opaque to PCore: DEA8 may encode layer/step/request identity.
  typedef struct packed {
    job_header_t header;
    logic [USER_TAG_BITS-1:0] user_tag;
    logic [CORE_BITS-1:0] core_id;
    logic [POSITION_BITS-1:0] position_base;
  } control_job_t;

  typedef enum logic [3:0] {
    CONTROL_OK,CONTROL_UNSUPPORTED,CONTROL_CHILD_ERROR,CONTROL_CONTEXT_ERROR,
    CONTROL_STREAM_ERROR,CONTROL_EARLY_DONE,CONTROL_UNIT_ERROR
  } control_status_e;
  typedef struct packed {
    control_job_t job;
    control_status_e status;
  } control_completion_t;
  typedef struct packed {
    logic [GENERATION_BITS-1:0] generation;
    logic [COMMAND_BITS-1:0] command_id;
  } control_token_t;

  typedef enum logic [4:0] {
    VECTOR_CAPTURE,VECTOR_ROPE,VECTOR_GU_MUL,VECTOR_QUANT,
    VECTOR_QK_POST,VECTOR_P_POST,VECTOR_OACC_SCALE,VECTOR_AFIN,
    FUNCTION_ROPE_COEFF,FUNCTION_GELU,FUNCTION_ALPHA_EXP,
    FUNCTION_P_EXP,FUNCTION_RECIP
  } control_function_e;
  typedef enum logic [2:0] {
    WORK_PAIR,WORK_GATE,WORK_Z,WORK_SCORE,WORK_P,WORK_ALPHA,WORK_OACC,WORK_QOZ
  } control_buffer_e;
  typedef enum logic {QUANT_FEATURE_B16,QUANT_TOKEN_B16} quant_axis_e;
  typedef struct packed {
    control_job_t job;
    control_token_t token;
    control_function_e function_id;
    control_buffer_e source,destination;
    quant_axis_e quant_axis;
    logic [5:0] tile;
    logic [5:0] tiles;
    logic [15:0] elements;
    // Both RoPE halves reside in WORK_PAIR. tile is the first physical tile.
    logic [7:0] rope_frequency_base;
    vpu_cmd_t attention_vpu;
    sfu_cmd_t attention_sfu;
  } control_command_t;
  typedef struct packed {
    control_command_t command;
    logic error;
  } control_unit_done_t;
  typedef struct packed {
    control_token_t token;
    post_data_t data;
  } control_post_data_t;
  typedef struct packed {
    control_token_t token;
    quant_axis_e quant_axis;
    logic [5:0] tile;
    logic [INDEX_BITS-1:0] index;
    logic [1:0] vector_valid;
    logic [TILE-1:0] token_mask;
    qvec16_t [0:1] vector_data;
    logic last;
  } control_quant_result_t;

  typedef enum logic [1:0] {COLLECT_K,COLLECT_V,REDUCE_O,REDUCE_DOWN} collective_op_e;
  typedef struct packed {
    control_job_t job;
    control_token_t token;
    collective_op_e op;
    logic [15:0] packets;
    // K gather must undo [16*c+i,128+16*c+i] column placement.
    logic rope_pair_layout;
  } collective_command_t;
  typedef struct packed {
    collective_command_t command;
    logic error;
  } collective_done_t;
  typedef struct packed {
    control_job_t job;
    control_token_t token;
    collective_op_e op;
    logic [5:0] tile;
    logic [INDEX_BITS-1:0] index;
    logic [1:0] vector_valid;
    logic [TILE-1:0] token_mask;
    logic quantized;
    logic [ROW_LANES-1:0][TILE-1:0][FP_BITS-1:0] payload;
    logic [ROW_LANES-1:0][SCALE_BITS-1:0] scales;
    logic last;
  } collective_packet_t;

  function automatic logic is_collective(input pcore_op_e op);
    return op==OP_K_PROJ||op==OP_V_PROJ||op==OP_O_PROJ||op==OP_DOWN_PROJ;
  endfunction
  function automatic logic is_rope(input pcore_op_e op);
    return op==OP_Q_PROJ||op==OP_K_PROJ;
  endfunction
  function automatic int output_tiles(input pcore_op_e op);
    case(op)
      OP_K_PROJ,OP_V_PROJ:return 2;
      OP_Q_PROJ:return QOZ_Q_TILES;
      OP_O_PROJ,OP_DOWN_PROJ:return 64;
      OP_GU:return QOZ_Z_TILES;
      default:return 0;
    endcase
  endfunction
  function automatic int collective_packets(input pcore_op_e op);
    return op==OP_V_PROJ ? output_tiles(op)*V_PACKETS_PER_TILE : output_tiles(op)*PAIRS;
  endfunction
endpackage
