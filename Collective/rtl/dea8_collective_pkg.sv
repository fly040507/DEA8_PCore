package dea8_collective_pkg;
  import pcore_control_pkg::*;
  localparam int CORES=8, LANES=32, ROWS=51, TILE=16, PAIRS=26;
  localparam int KV_BITS=272, FP_BITS=1024, SEQ_BITS=11;
  localparam int ADD_STAGES=4, TREE_STAGES=3*ADD_STAGES;

  typedef struct packed {
    logic [63:0] collective_id;
    logic [15:0] destination_id,token_origin;
    collective_op_e op;
    control_job_t [CORES-1:0] expected_job;
  } collective_config_t;
  typedef enum logic [2:0] {COL_OK,COL_BAD_CONFIG,COL_BAD_PACKET,COL_CANCELLED} collective_status_e;
  typedef struct packed {
    logic [63:0] collective_id;
    collective_status_e status;
    logic [2:0] error_core;
    logic [SEQ_BITS-1:0] error_sequence;
  } collective_completion_t;
  typedef struct packed {
    logic [63:0] collective_id;
    logic [15:0] destination_id,token_origin;
    collective_op_e op;
    logic [2:0] core_id;
    logic [5:0] source_sequence;
    logic [8:0] word_index;
    logic [1:0] vector_valid;
    logic [15:0] token_mask;
    logic [255:0] data;
    logic [15:0] scales;
    logic core_last,job_last;
  } collective_kv_t;
  typedef struct packed {
    logic [63:0] collective_id;
    logic [15:0] destination_id,token_origin;
    collective_op_e op;
    logic [SEQ_BITS-1:0] word_index;
    logic [1:0] row_valid;
    logic [FP_BITS-1:0] data;
    logic last;
  } collective_fp_t;

  function automatic int packet_count(input collective_op_e op);
    case(op)
      COLLECT_K:return 52;
      COLLECT_V:return 64;
      default:return 1664;
    endcase
  endfunction
  function automatic logic is_kv(input collective_op_e op);
    return op==COLLECT_K||op==COLLECT_V;
  endfunction
  function automatic logic [8:0] kv_address(input collective_op_e op,input int core,seq);
    if(op==COLLECT_K)return 9'((8*(seq/26)+core)*26+seq%26);
    return 9'((16*core+8*(seq/32)+(seq%8))*4+(seq%32)/8);
  endfunction
endpackage
