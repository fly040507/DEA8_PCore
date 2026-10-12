package dea8_tile_link_pkg;
  localparam int LINK_ROWS=51,LINK_COLUMNS=16,LINK_CORES=8;
  localparam int KV_WORD_BITS=136,FP_ROW_BITS=512;
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
endpackage
