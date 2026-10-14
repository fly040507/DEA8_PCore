import pcore_pkg::*;

// A manager owns metadata and read references; row3_store owns the only payload.
module dea8_quant_store #(
  parameter bit QOZ=1,
  parameter int SETS=QOZ?1:2,TILES_PER_SET=QOZ?QOZ_Z_TILES:1,
  parameter int RESPONSE_DEPTH=2,
  parameter int PHYS_BITS=$clog2(SETS*TILES_PER_SET),
  parameter int FIFO_BITS=(RESPONSE_DEPTH>1)?$clog2(RESPONSE_DEPTH):1
) (
  input logic clk,reset,clear,
  input logic acquire_valid,output logic acquire_ready,input logic acquire_set,
  input local_object_t acquire_object,input job_token_t producer_token,
  input logic bind_valid,output logic bind_ready,input logic bind_set,
  input local_object_t bind_object,input job_token_t consumer_token,
  input logic release_valid,output logic release_ready,input local_release_t release_request,
  input logic wr_valid,output logic wr_ready,input local_write_t wr,
  input logic rd_valid,output logic rd_ready,input local_read_t rd,
  output logic out_valid,input logic out_ready,output local_response_t out_response,
  output logic [SETS-1:0] active,complete,bound,
  output logic protocol_error,empty
);
  local_object_t objects[SETS];
  job_token_t writers[SETS],readers[SETS];
  logic [ROWS-1:0] written[SETS][TILES_PER_SET];
  logic [TILES_PER_SET-1:0] tile_done[SETS];
  logic [$clog2(RESPONSE_DEPTH+1)-1:0] refs[SETS];
  local_response_t fifo[RESPONSE_DEPTH];
  local_read_t request_q;
  logic [FIFO_BITS-1:0] rptr,wptr;
  logic [$clog2(RESPONSE_DEPTH+1)-1:0] count;
  logic pending,acquire_legal,bind_legal,wr_legal,rd_legal,release_legal;
  logic acquire_fire,bind_fire,wr_fire,rd_fire,out_fire,release_fire;
  logic ram_wr_ready,ram_rd_ready,ram_valid,ram_error;
  logic [PHYS_BITS-1:0] wr_physical,rd_physical;
  logic [A_INPUT_ROWS-1:0][ROW_COUNT_BITS-1:0] rd_rows;
  logic [A_INPUT_ROWS-1:0] rd_mask;
  qvec16_t [A_INPUT_ROWS-1:0] ram_data;
  logic [ROWS-1:0] new_written;
  logic [TILES_PER_SET-1:0] new_done;
  logic error_q;

  function automatic int unsigned tiles_for(input local_kind_e kind);
    if(!QOZ)return 1;
    return kind==LOCAL_Z?QOZ_Z_TILES:QOZ_Q_TILES;
  endfunction
  function automatic int unsigned physical(input int set_id,tile,input local_kind_e kind);
    return set_id*TILES_PER_SET+tile+((QOZ&&kind==LOCAL_O)?QOZ_Q_TILES:0);
  endfunction
  function automatic logic [TILES_PER_SET-1:0] tile_prefix(input int n);
    logic [TILES_PER_SET-1:0] mask;
    for(int t=0;t<TILES_PER_SET;t++)mask[t]=t<n;
    return mask;
  endfunction
  function automatic logic [FIFO_BITS-1:0] advance(input logic [FIFO_BITS-1:0] p);
    return p==RESPONSE_DEPTH-1?'0:p+1'b1;
  endfunction

  always_comb begin
    acquire_legal=acquire_set<SETS&&acquire_object.m_rows>0&&acquire_object.m_rows<=ROWS;
    if(QOZ)acquire_legal=acquire_legal&&acquire_object.kind>=LOCAL_Q&&acquire_object.kind<=LOCAL_Z;
    else acquire_legal=acquire_legal&&acquire_object.kind==LOCAL_P&&acquire_object.block_id<KV_BLOCKS&&
      acquire_set==acquire_object.block_id[0];
    bind_legal=0;wr_legal=0;rd_legal=0;release_legal=0;
    new_written='0;new_done='0;wr_physical=0;rd_physical=0;rd_rows='0;rd_mask='0;
    if(bind_set<SETS&&active[bind_set])bind_legal=bind_object==objects[bind_set];
    if(release_request.set_id<SETS&&active[release_request.set_id])
      release_legal=bound[release_request.set_id]&&release_request.token==readers[release_request.set_id]&&
        release_request.kind==objects[release_request.set_id].kind&&
        release_request.content_version==objects[release_request.set_id].content_version;
    if(wr.set_id<SETS&&active[wr.set_id])begin
      wr_legal=wr.token==writers[wr.set_id]&&wr.kind==objects[wr.set_id].kind&&
        wr.content_version==objects[wr.set_id].content_version&&wr.tile<tiles_for(wr.kind)&&wr.mask!=0;
      wr_physical=PHYS_BITS'(physical(wr.set_id,wr.tile,wr.kind));
      if(wr.tile<TILES_PER_SET)begin
        new_written=written[wr.set_id][wr.tile];new_done=tile_done[wr.set_id];
        for(int i=0;i<A_INPUT_ROWS;i++)if(wr.mask[i])begin
          if(wr.row[i]>=objects[wr.set_id].m_rows)wr_legal=0;
          else begin
            if(new_written[wr.row[i]])wr_legal=0;
            new_written[wr.row[i]]=1;
          end
          for(int j=0;j<i;j++)if(wr.mask[j]&&wr.row[i]%A_INPUT_ROWS==wr.row[j]%A_INPUT_ROWS)wr_legal=0;
        end
        if(new_written==row_prefix(objects[wr.set_id].m_rows))new_done[wr.tile]=1;
      end else wr_legal=0;
    end
    if(rd.set_id<SETS&&active[rd.set_id])begin
      rd_legal=bound[rd.set_id]&&rd.token==readers[rd.set_id]&&rd.kind==objects[rd.set_id].kind&&
        rd.content_version==objects[rd.set_id].content_version&&rd.tile<tiles_for(rd.kind)&&
        int'(rd.group_idx)*A_INPUT_ROWS<int'(objects[rd.set_id].m_rows);
      rd_physical=PHYS_BITS'(physical(rd.set_id,rd.tile,rd.kind));
      rd_mask=a_group_mask(objects[rd.set_id].m_rows,rd.group_idx);
      for(int i=0;i<A_INPUT_ROWS;i++)rd_rows[i]=ROW_COUNT_BITS'(int'(rd.group_idx)*A_INPUT_ROWS+i);
    end
  end
  assign protocol_error=error_q||ram_error;
  assign acquire_ready=!reset&&!clear&&!protocol_error&&acquire_legal&&!active[acquire_set];
  assign bind_ready=!reset&&!clear&&!protocol_error&&bind_legal&&complete[bind_set]&&!bound[bind_set];
  assign release_ready=!reset&&!clear&&!protocol_error&&release_legal&&refs[release_request.set_id]==0;
  assign wr_ready=!reset&&!clear&&!protocol_error&&wr_legal&&!complete[wr.set_id]&&!bound[wr.set_id]&&ram_wr_ready;
  assign out_valid=!reset&&!clear&&!protocol_error&&count!=0;
  assign out_fire=out_valid&&out_ready;
  assign rd_ready=!reset&&!clear&&!protocol_error&&rd_legal&&ram_rd_ready&&
    !(release_valid&&release_request.set_id==rd.set_id)&&int'(count)+int'(pending)<RESPONSE_DEPTH+(out_fire?1:0);
  assign acquire_fire=acquire_valid&&acquire_ready;
  assign bind_fire=bind_valid&&bind_ready;
  assign release_fire=release_valid&&release_ready;
  assign wr_fire=wr_valid&&wr_ready;
  assign rd_fire=rd_valid&&rd_ready;
  assign empty=active==0&&count==0&&!pending;
  always_comb begin
    out_response='0;
    if(count!=0&&rptr<RESPONSE_DEPTH)out_response=fifo[rptr];
  end
  dea8_row3_store #(.TILES(SETS*TILES_PER_SET),.ADDRESS_BITS(PHYS_BITS)) storage(
    .clk,.reset,.clear,.wr_valid(wr_fire),.wr_ready(ram_wr_ready),.wr_tile(wr_physical),
    .wr_row(wr.row),.wr_mask(wr.mask),.wr_entry(wr.entry),
    .rd_valid(rd_fire),.rd_ready(ram_rd_ready),.rd_tile(rd_physical),.rd_row(rd_rows),.rd_mask,
    .out_valid(ram_valid),.out_entry(ram_data),.protocol_error(ram_error));

  always_ff @(posedge clk)begin
    if(reset||clear)begin
      active<=0;complete<=0;bound<=0;count<=0;rptr<=0;wptr<=0;pending<=0;error_q<=0;request_q<='0;
      for(int s=0;s<SETS;s++)begin refs[s]<=0;tile_done[s]<=0;objects[s]<='0;writers[s]<=0;readers[s]<=0;end
    end else begin
      if(acquire_valid&&!acquire_legal)error_q<=1;
      if(bind_valid&&bind_set<SETS&&active[bind_set]&&!bind_legal)error_q<=1;
      if(release_valid&&!release_legal)error_q<=1;
      if(wr_valid&&(!wr_legal||complete[wr.set_id]||bound[wr.set_id]))error_q<=1;
      if(rd_valid&&!rd_legal)error_q<=1;
      pending<=rd_fire;
      if(rd_fire)request_q<=rd;
      case({pending,out_fire})
        2'b10:count<=count+1'b1;
        2'b01:count<=count-1'b1;
        default:;
      endcase
      if(pending)begin
        local_response_t response;
        response='0;response.request=request_q;response.mask=a_group_mask(objects[request_q.set_id].m_rows,request_q.group_idx);
        response.entry=ram_data;fifo[wptr]<=response;wptr<=advance(wptr);
      end
      if(out_fire)rptr<=advance(rptr);
      for(int s=0;s<SETS;s++)begin
        case({rd_fire&&rd.set_id==s,out_fire&&out_response.request.set_id==s})
          2'b10:refs[s]<=refs[s]+1'b1;
          2'b01:refs[s]<=refs[s]-1'b1;
          default:;
        endcase
      end
      if(acquire_fire)begin
        objects[acquire_set]<=acquire_object;writers[acquire_set]<=producer_token;
        active[acquire_set]<=1;complete[acquire_set]<=0;bound[acquire_set]<=0;
        tile_done[acquire_set]<=0;
        for(int t=0;t<TILES_PER_SET;t++)written[acquire_set][t]<=0;
      end
      if(wr_fire)begin
        written[wr.set_id][wr.tile]<=new_written;tile_done[wr.set_id]<=new_done;
        if(new_done==tile_prefix(tiles_for(wr.kind)))complete[wr.set_id]<=1;
      end
      if(bind_fire)begin bound[bind_set]<=1;readers[bind_set]<=consumer_token;end
      if(release_fire)begin
        active[release_request.set_id]<=0;complete[release_request.set_id]<=0;bound[release_request.set_id]<=0;
      end
    end
  end
  // synthesis translate_off
  always @(posedge clk)if(!reset&&!clear)begin
    if(pending&&!ram_valid)$fatal(1,"Quant store response alignment");
    if(int'(count)+int'(pending)>RESPONSE_DEPTH)$fatal(1,"Quant store credit overflow");
  end
  initial if(PHYS_BITS<1||RESPONSE_DEPTH<2||SETS>2||
    (QOZ&&(SETS!=1||TILES_PER_SET!=QOZ_Z_TILES))||(!QOZ&&(SETS!=2||TILES_PER_SET!=1)))
    $fatal(1,"Quant store geometry");
  // synthesis translate_on
endmodule
