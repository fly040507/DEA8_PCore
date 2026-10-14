import dea8_tile_link_pkg::*;

// Eight independent 512-bit ingress FIFOs, one fixed FP32 tree and one
// result Tile. Compact row count comes from matching Tile headers.
module dea8_reduce_top (
  input logic clk,reset,clear,
  input logic [7:0] in_hdr_valid,output logic [7:0] in_hdr_ready,input logic [7:0][127:0] in_hdr_bits,
  input logic [7:0] in_data_valid,output logic [7:0] in_data_ready,
  input logic [7:0][511:0] in_data,input logic [7:0] in_last,
  output logic out_hdr_valid,input logic out_hdr_ready,output logic [127:0] out_hdr_bits,
  output logic out_data_valid,input logic out_data_ready,output logic [511:0] out_data,output logic out_last,
  input logic commit_valid,output logic commit_ready,input tile_commit_t commit,
  output logic busy,protocol_error
);
  localparam int SOURCES=8,MAX_ROWS=51;
  typedef enum logic [1:0] {COLLECT,SEND_HEADER,SEND_DATA,WAIT_COMMIT} state_e;
  state_e state;
  tile_header_t headers[0:SOURCES-1],base,first_header;
  logic [SOURCES-1:0] seen,fifo_valid,fifo_ready,fifo_pop;
  logic [5:0] received[0:SOURCES-1],issued,written,sent,tree_row;
  logic [SOURCES-1:0][511:0] fifo_data;
  logic tree_valid,tree_ready,tree_out_valid,tree_empty,error_q;
  logic [511:0] tree_out;
  (* ram_style="block" *) logic [511:0] result_mem[0:MAX_ROWS-1];
  logic [511:0] result_q;
  logic result_valid,read_pending;
  logic [5:0] fetched;
  function automatic logic [127:0] identity(input tile_header_t h);
    tile_header_t normalized;normalized=h;normalized.source_id=0;return normalized;
  endfunction
  for(genvar c=0;c<SOURCES;c++)begin: inputs
    assign headers[c]=tile_header_t'(in_hdr_bits[c]);
    assign in_hdr_ready[c]=state==COLLECT&&!seen[c]&&!reset&&!clear&&!error_q;
    assign in_data_ready[c]=state==COLLECT&&seen[c]&&received[c]<base.rows&&fifo_ready[c]&&!reset&&!clear&&!error_q;
    assign fifo_pop[c]=tree_valid&&tree_ready;
    dea8_reduce_fifo #(.WIDTH(512),.DEPTH(8)) fifo(.clk,.reset,.clear,
      .in_valid(in_data_valid[c]&&in_data_ready[c]),.in_ready(fifo_ready[c]),.in_data(in_data[c]),
      .out_valid(fifo_valid[c]),.out_ready(fifo_pop[c]),.out_data(fifo_data[c]),.empty(),.occupancy());
  end
  always_comb begin
    first_header='0;
    for(int c=SOURCES-1;c>=0;c--)if(in_hdr_valid[c]&&in_hdr_ready[c])first_header=headers[c];
  end
  assign busy=seen!=0||state!=COLLECT;
  assign protocol_error=error_q;
  assign tree_valid=state==COLLECT&&(&seen)&&(&fifo_valid)&&issued<base.rows&&!error_q;
  dea8_reduce_tree tree(.clk,.reset,.clear,.in_valid(tree_valid),.in_ready(tree_ready),.in_data(fifo_data),.in_row(issued),
    .out_valid(tree_out_valid),.out_ready(1'b1),.out_data(tree_out),.out_row(tree_row),.empty(tree_empty));
  assign out_hdr_valid=state==SEND_HEADER&&!reset&&!clear&&!error_q;
  assign out_hdr_bits=base;
  assign out_data_valid=state==SEND_DATA&&result_valid&&!reset&&!clear&&!error_q;
  assign out_data=result_q;
  assign out_last=int'(sent)+1==base.rows;
  assign commit_ready=state==WAIT_COMMIT&&!reset&&!clear&&!error_q;
  always_ff @(posedge clk)begin
    if(reset||clear)begin
      state<=COLLECT;seen<=0;base<='0;issued<=0;written<=0;sent<=0;error_q<=0;
      result_valid<=0;read_pending<=0;fetched<=0;
      for(int c=0;c<SOURCES;c++)received[c]<=0;
    end else begin
      for(int c=0;c<SOURCES;c++)begin
        if(in_hdr_valid[c]&&in_hdr_ready[c])begin
          if(headers[c].reserved!=0||headers[c].rows==0||headers[c].rows>MAX_ROWS||headers[c].columns!=16||
            headers[c].source_id!=c||headers[c].layout!=LAYOUT_FP_ROWS||
            !(headers[c].kind==TILE_O||headers[c].kind==TILE_DOWN)||headers[c].column_base!=16'(int'(headers[c].tile_seq)*16)||
            identity(headers[c])!=identity(seen!=0?base:first_header))error_q<=1;
          else begin
            seen[c]<=1;
            if(seen==0)begin tile_header_t h;h=first_header;h.source_id=8;base<=h;end
          end
        end
        if(in_data_valid[c]&&in_data_ready[c])begin
          if(in_last[c]!=(int'(received[c])+1==base.rows))error_q<=1;
          else received[c]<=received[c]+1'b1;
        end
      end
      if(tree_valid&&tree_ready)issued<=issued+1'b1;
      if(tree_out_valid)begin
        if(tree_row!=written||written>=base.rows)error_q<=1;
        else begin
          result_mem[written]<=tree_out;written<=written+1'b1;
          if(int'(written)+1==base.rows)state<=SEND_HEADER;
        end
      end
      if(out_hdr_valid&&out_hdr_ready)state<=SEND_DATA;
      // Synchronous RAM fetch plus a holding output. No combinational 51-row
      // payload mux and no duplicate result FIFO.
      read_pending<=0;
      if(state==SEND_DATA&&!result_valid&&!read_pending&&fetched<base.rows)begin
        result_q<=result_mem[fetched];fetched<=fetched+1'b1;read_pending<=1;
      end
      if(read_pending)result_valid<=1;
      if(out_data_valid&&out_data_ready)begin
        result_valid<=0;sent<=sent+1'b1;
        if(out_last)state<=WAIT_COMMIT;
      end
      if(commit_valid&&commit_ready)begin
        if(!commit_matches(commit,base))error_q<=1;
        else begin
          state<=COLLECT;seen<=0;issued<=0;written<=0;sent<=0;fetched<=0;result_valid<=0;read_pending<=0;
          for(int c=0;c<SOURCES;c++)received[c]<=0;
        end
      end
    end
  end
endmodule
