package dea8_tile_link_pkg;
  localparam int LINK_ROWS=51,LINK_COLUMNS=16,LINK_CORES=8;
  localparam int KV_WORD_BITS=136,FP_ROW_BITS=512;
  localparam int PACKET_BITS=256,PACKET_VERSION=1;
  typedef enum logic [1:0] {PACKET_FP32=0,PACKET_MXINT8=1} packet_dtype_e;
  typedef enum logic [1:0] {SCALE_NONE=0,SCALE_FEATURE=1,SCALE_TOKEN=2} packet_scale_e;
  typedef struct packed {
    logic [2:0] protocol_version;
    logic [7:0] payload_beats;
    packet_dtype_e dtype;
    packet_scale_e scale_axis;
    logic [7:0] reserved;
  } packet_info_t;
  typedef struct packed {
    logic [15:0] transfer_id,transfer_epoch,destination_id,token_origin;
  } tile_transfer_t;
  typedef enum logic [1:0] {TILE_K=2'd0,TILE_V=2'd1,TILE_O=2'd2,TILE_DOWN=2'd3} tile_kind_e;
  typedef enum logic [1:0] {LAYOUT_K_ROWS=2'd0,LAYOUT_V_GROUPS=2'd1,LAYOUT_FP_ROWS=2'd2} tile_layout_e;
  typedef struct packed {
    logic [15:0] transfer_id,transfer_epoch,destination_id,token_origin,column_base;
    logic [5:0] rows;
    logic [4:0] columns;
    tile_kind_e kind;
    tile_layout_e layout;
    logic [3:0] source_id;
    logic [5:0] tile_seq;
    logic [22:0] reserved;
  } tile_header_t;
  typedef struct packed {
    logic [15:0] transfer_id,transfer_epoch;
    logic [5:0] tile_seq;
    logic [3:0] source_id,status;
    logic [17:0] reserved;
  } tile_commit_t;
  function automatic logic same_tile(input tile_header_t a,b);
    tile_header_t x,y;
    x=a;y=b;x.source_id=0;y.source_id=0;
    return x==y;
  endfunction
  function automatic logic commit_matches(input tile_commit_t c,input tile_header_t h);
    return c.transfer_id==h.transfer_id && c.transfer_epoch==h.transfer_epoch &&
      c.tile_seq==h.tile_seq && c.source_id==h.source_id && c.status==0 && c.reserved==0;
  endfunction
  function automatic int packet_beats(input tile_kind_e kind);
    case(kind)
      TILE_K:return LINK_ROWS;
      TILE_V:return LINK_COLUMNS*((LINK_ROWS+LINK_COLUMNS-1)/LINK_COLUMNS);
      default:return LINK_ROWS*FP_ROW_BITS/PACKET_BITS;
    endcase
  endfunction
  function automatic logic [PACKET_BITS-1:0] encode_packet_header(input tile_header_t header);
    tile_header_t h;
    packet_info_t p;
    h=header;p='0;p.protocol_version=3'(PACKET_VERSION);
    p.payload_beats=8'(packet_beats(h.kind));
    p.dtype=(h.kind==TILE_K||h.kind==TILE_V)?PACKET_MXINT8:PACKET_FP32;
    p.scale_axis=h.kind==TILE_K?SCALE_FEATURE:(h.kind==TILE_V?SCALE_TOKEN:SCALE_NONE);
    h.reserved=p;
    return {{(PACKET_BITS-$bits(tile_header_t)){1'b0}},h};
  endfunction
  function automatic logic packet_header_legal(input logic [PACKET_BITS-1:0] bits_in);
    tile_header_t h;
    packet_info_t p;
    h=tile_header_t'(bits_in[127:0]);p=packet_info_t'(h.reserved);
    return bits_in[255:128]==0&&p.protocol_version==PACKET_VERSION&&p.reserved==0&&
      p.payload_beats==packet_beats(h.kind)&&h.rows==LINK_ROWS&&h.columns==LINK_COLUMNS&&
      (h.kind==TILE_K?(h.layout==LAYOUT_K_ROWS&&p.dtype==PACKET_MXINT8&&p.scale_axis==SCALE_FEATURE):
       h.kind==TILE_V?(h.layout==LAYOUT_V_GROUPS&&p.dtype==PACKET_MXINT8&&p.scale_axis==SCALE_TOKEN):
       (h.layout==LAYOUT_FP_ROWS&&p.dtype==PACKET_FP32&&p.scale_axis==SCALE_NONE));
  endfunction
endpackage
