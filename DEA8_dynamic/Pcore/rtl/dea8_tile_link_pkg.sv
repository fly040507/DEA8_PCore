package dea8_tile_link_pkg;
  // Same 128-bit Tile protocol as DEA8; context mapping lives at GCore.
  typedef enum logic [1:0] {TILE_K,TILE_V,TILE_O,TILE_DOWN} tile_kind_e;
  typedef enum logic [1:0] {LAYOUT_K_ROWS,LAYOUT_V_GROUPS,LAYOUT_FP_ROWS} tile_layout_e;
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
  function automatic logic commit_matches(input tile_commit_t c,input tile_header_t h);
    return c.transfer_id==h.transfer_id&&c.transfer_epoch==h.transfer_epoch&&
      c.tile_seq==h.tile_seq&&c.source_id==h.source_id&&c.status==0&&c.reserved==0;
  endfunction
endpackage
