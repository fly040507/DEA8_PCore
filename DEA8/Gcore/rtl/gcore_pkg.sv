package gcore_pkg;
  localparam int CORES=8, ROWS=51, TILE=16, HIDDEN=1024;
  localparam int HIDDEN_TILES=HIDDEN/TILE, ROW_GROUPS=(ROWS+3)/4;
  localparam int VECTOR_WORDS=ROWS*HIDDEN_TILES;
  localparam int VECTOR_ADDR_BITS=$clog2(VECTOR_WORDS);
  localparam int ACT_BANK_DEPTH=ROW_GROUPS*HIDDEN_TILES;
  localparam int SERVICES=7, OBJECTS=5;
  localparam int REDUCE_LANES=4,RX_DEPTH=4,ADD_LATENCY=4,MUL_LATENCY=3;
  localparam int GAMMA_SLOTS=2,GAMMA_INDEX_BITS=$clog2(HIDDEN);
  localparam int KV_FEATURE_TILES=16, PREFIX_BLOCKS=51, KV_BLOCK_COUNT=55;
  localparam int PREFIX_BANK_DEPTH=PREFIX_BLOCKS*8, SUFFIX_BANK_DEPTH=32;
  localparam int KVB_JOBS=2*KV_BLOCK_COUNT, KVB_WORDS=KVB_JOBS*KV_FEATURE_TILES*8;
  localparam int S_IMPORT=0, S_PREFIX=1, S_NORM=2, S_XBC=3;
  localparam int S_KV_RX=4, S_KVB=5, S_RESIDUAL=6;
  localparam int OBJ_RESID=0, OBJ_XHAT=1, OBJ_PREFIX=2, OBJ_K=3, OBJ_V=4;

  typedef enum logic [3:0] {
    GC_IMPORT_RESID=0, GC_PREFIX_LOAD=1, GC_NORM=2, GC_XBC_RUN=3,
    GC_KV_RX=4, GC_KVB_RUN=5, GC_RESIDUAL_APPLY=6
  } gcore_opcode_e;
  typedef enum logic [3:0] {
    GC_OK=0, GC_INVALID_CMD=1, GC_PRECONDITION=2, GC_BAD_CONTEXT=3,
    GC_BAD_HEADER=4, GC_BAD_LENGTH=5, GC_DUPLICATE_TILE=6,
    GC_NUMERIC_FAULT=7, GC_SOURCE_PROTOCOL=8, GC_CANCELLED=9
  } gcore_status_e;
  typedef enum logic [1:0] {OBJECT_INVALID, OBJECT_WRITING, OBJECT_COMPLETE} object_state_e;

  typedef struct packed {
    gcore_opcode_e opcode;
    logic [15:0] command_id, generation, context_id;
    logic [15:0] src_object, src_version, dst_object, dst_version;
    pcore_pkg::pcore_op_e pcore_op;
    logic [CORES-1:0] core_mask;
    logic [31:0] epsilon_fp32;
    logic [7:0] flags;
    logic [15:0] norm_param_id;
    logic [8:0] reserved;
  } gcore_cmd_t;
  typedef struct packed {
    gcore_opcode_e opcode;
    gcore_status_e status;
    logic [15:0] command_id, generation, context_id;
    logic [15:0] dst_object, dst_version, completed_items;
    logic [23:0] reserved;
  } gcore_done_t;
  typedef struct packed {
    logic [15:0] object_id, version;
    object_state_e state;
  } gcore_object_t;

  // One immutable layer context. Address translation belongs to HBM/DEA8.
  typedef struct packed {
    logic [15:0] context_id, generation;
    logic [3:0] pcore_epoch;
    logic [15:0] data_context, position_base, rope_version;
    logic gamma_online;
    logic [1:0] quant_profile; // 0 = Q_COVER127_RNE
    logic [1:0] mask_profile;  // 0 = fixed pi0 suffix mask
    logic [15:0] prefix_version, suffix_version;
    dea8_tile_link_pkg::tile_transfer_t k_transfer, v_transfer, o_transfer, down_transfer;
  } gcore_context_t;
  // Registration only: the caller guarantees these RAM objects already exist.
  // It is neither a payload stream nor a prefix DMA completion.
  typedef struct packed {
    logic [15:0] context_id,generation;
    logic [15:0] residual_object,residual_version,prefix_object,prefix_version;
  } gcore_preloaded_t;
  localparam logic [7:0] NORM_FP32=8'h01;
  typedef enum logic [2:0] {GJ_START,GJ_K,GJ_V,GJ_Q,GJ_ATTENTION,GJ_O,GJ_GU,GJ_DOWN} gcore_job_e;
  typedef struct packed {
    gcore_job_e op;
    logic [15:0] command_id,context_id,generation;
    logic [4:0] layer_id;
  } gcore_job_t;
  typedef struct packed {
    gcore_job_t job;
    gcore_status_e status;
    logic [31:0] cycles;
  } gcore_job_done_t;
  // Layer binding preserves the data identity and residual statistics.
  typedef struct packed {
    gcore_context_t context_data;
    logic [4:0] layer_id;
    logic [15:0] prefix_object,xhat_object,k_object,v_object;
    logic [15:0] attn_gamma,ffn_gamma,next_attn_gamma,next_ffn_gamma,final_gamma;
    logic [31:0] epsilon_fp32;
  } gcore_layer_t;
  typedef struct packed {
    logic valid,ffn;
    logic [4:0] layer_id;
    logic [15:0] context_id,generation,object_id,version;
  } gcore_xhat_t;
  typedef struct packed {
    logic [31:0] token;
    logic [15:0] context_id,generation;
    logic [4:0] layer_id;
    logic final_group;
    logic [15:0] param0,param1;
  } gamma_fetch_t;
  typedef struct packed {
    logic [31:0] token,value;
    logic last;
  } gamma_beat_t;
  typedef struct packed {
    logic [15:0] command_id,context_id,generation;
    logic [4:0] layer_id;
    logic [VECTOR_ADDR_BITS-1:0] index;
    logic [511:0] data;
    logic last;
  } gcore_final_t;
  typedef struct packed {
    logic [15:0] context_id,generation,param_id;
    logic slot;
    logic [GAMMA_INDEX_BITS-1:0] index;
    logic [31:0] value;
    logic last;
  } gamma_load_t;
  typedef struct packed {
    logic value_kind;
    logic [3:0] feature_tile;
    logic parity;
    logic [4:0] address;
    logic [135:0] word_data;
  } kv_write_t;
  typedef struct packed {
    logic value_kind,prefix;
    logic [3:0] feature_tile;
    logic [8:0] address;
    logic [1:0] zero_mask;
    logic [5:0] tile;
    logic [2:0] group_index;
    logic [3:0] epoch;
  } kv_read_t;
  typedef struct packed {
    logic [255:0] data;
    logic [VECTOR_ADDR_BITS-1:0] index;
    logic last;
    logic [31:0] token;
  } residual_import_t;
  typedef struct packed {
    logic [135:0] word_data;
    logic kind;
    logic [13:0] index;
    logic last;
    logic [31:0] token;
  } prefix_import_t;
  typedef struct packed {
    logic [31:0] token;
    logic [5:0] row0, row1;
    logic [1:0] mask;
    logic [63:0] data;
  } rsqrt_packet_t;

  typedef enum logic [1:0] {VECTOR_SCAN, VECTOR_RESIDUAL, VECTOR_APPLY} vector_mode_e;
  typedef struct packed {
    vector_mode_e mode;
    logic [31:0] token;
    logic [VECTOR_ADDR_BITS-1:0] index;
    logic [5:0] row,nt;
  } vector_meta_t;
  typedef struct packed {
    vector_meta_t meta;
    logic [255:0] residual;
    logic [511:0] delta;
    logic [31:0] inverse;
  } vector_request_t;
  typedef struct packed {
    vector_meta_t meta;
    logic [255:0] residual;
    logic [135:0] quantized;
    logic [31:0] square_sum;
    logic numeric_fault;
  } vector_result_t;
  typedef struct packed {
    logic [31:0] token;
    logic [VECTOR_ADDR_BITS-1:0] index;
    logic [511:0] data;
  } residual_work_t;
  typedef struct packed {
    logic [31:0] token;
    logic [VECTOR_ADDR_BITS-1:0] index;
  } residual_commit_t;

  function automatic logic [31:0] command_token(input gcore_cmd_t c);
    return {c.generation,c.command_id};
  endfunction
  function automatic int xbc_tiles(input pcore_pkg::pcore_op_e op);
    case(op)
      pcore_pkg::OP_K_PROJ,pcore_pkg::OP_V_PROJ: return 2;
      pcore_pkg::OP_Q_PROJ: return 16;
      pcore_pkg::OP_GU: return 32;
      default: return 0;
    endcase
  endfunction
  function automatic logic [15:0] expected_items(input gcore_cmd_t c);
    case(c.opcode)
      GC_IMPORT_RESID,GC_NORM,GC_RESIDUAL_APPLY: return 16'(VECTOR_WORDS);
      GC_PREFIX_LOAD: return 16'(2*16*816);
      GC_XBC_RUN: return 16'(xbc_tiles(c.pcore_op)*HIDDEN_TILES*ROW_GROUPS);
      GC_KV_RX: return 16'd16;
      GC_KVB_RUN: return 16'(KVB_WORDS);
      default: return 0;
    endcase
  endfunction
  // Packed vector return also avoids Vivado 2022.2's struct-return optimizer bug.
  function automatic logic [$bits(gcore_done_t)-1:0] make_done(input gcore_cmd_t c,
      input gcore_status_e status, input logic [15:0] items);
    return {c.opcode,status,c.command_id,c.generation,c.context_id,
      c.dst_object,c.dst_version,items,24'b0};
  endfunction
  function automatic bit same_completion(input gcore_done_t d,input gcore_cmd_t c);
    return d.opcode==c.opcode && d.command_id==c.command_id &&
      d.generation==c.generation && d.context_id==c.context_id &&
      d.dst_object==c.dst_object && d.dst_version==c.dst_version && d.reserved==0;
  endfunction
  function automatic bit transfer_key_equal(
      input dea8_tile_link_pkg::tile_transfer_t a,b);
    return a.transfer_id==b.transfer_id && a.transfer_epoch==b.transfer_epoch;
  endfunction
endpackage
