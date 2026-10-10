import dea8_tile_link_pkg::*;

module dea8_reduce_top(
  input logic clk,reset,clear,
  input logic [7:0] in_hdr_valid,output logic [7:0] in_hdr_ready,input logic [7:0][127:0] in_hdr_bits,
  input logic [7:0] in_data_valid,output logic [7:0] in_data_ready,
  input logic [7:0][511:0] in_data,input logic [7:0] in_last,
  output logic out_hdr_valid,input logic out_hdr_ready,output logic [127:0] out_hdr_bits,
  output logic out_data_valid,input logic out_data_ready,output logic [511:0] out_data,output logic out_last,
  input logic commit_valid,output logic commit_ready,input tile_commit_t commit,
  output logic busy,protocol_error
);
  typedef enum logic [2:0] {COLLECT,SEND_HEADER,SEND_DATA,WAIT_COMMIT} state_e;
  state_e state_q;
  logic [7:0] seen_q;
  tile_header_t base_q,first_hdr;
  logic [5:0] recv_q[0:7];
  logic [5:0] issued_q,written_q,send_q;
  logic [511:0] result_mem[0:50];
  logic [7:0] fifo_valid,fifo_ready,fifo_pop;
  logic [7:0][511:0] fifo_data;
  logic [7:0][511:0] tree_in;
  logic tree_valid,tree_ready,tree_out_valid,tree_empty;
  logic [511:0] tree_out;
  logic [5:0] tree_row;
  logic error_q,have_header,have_live_header;
  tile_header_t in_hdr[0:7];
  for(genvar hc=0;hc<8;hc++)begin:header_unpack
    assign in_hdr[hc]=tile_header_t'(in_hdr_bits[hc]);
  end
  assign have_header=|seen_q;
  always_comb begin
    first_hdr='0;
    for(int i=7;i>=0;i--)if(in_hdr_valid[i]&&in_hdr_ready[i])first_hdr=in_hdr[i];
  end
  assign busy=have_header||state_q!=COLLECT;
  assign protocol_error=error_q;
  assign out_hdr_bits=base_q;
  assign out_hdr_valid=state_q==SEND_HEADER&&!reset&&!clear&&!error_q;
  assign out_data_valid=state_q==SEND_DATA&&!reset&&!clear&&!error_q;
  assign out_data=result_mem[send_q];
  assign out_last=send_q==50;
  assign commit_ready=state_q==WAIT_COMMIT&&!reset&&!clear&&!error_q;
  for(genvar c=0;c<8;c++)begin:inputs
    assign in_hdr_ready[c]=state_q==COLLECT&&!seen_q[c]&&!reset&&!clear&&!error_q;
    assign in_data_ready[c]=state_q==COLLECT&&seen_q[c]&&recv_q[c]<51&&fifo_ready[c]&&
      !reset&&!clear&&!error_q;
    dea8_reduce_fifo #(.WIDTH(512),.DEPTH(8)) fifo(
      .clk,.reset,.clear,
      .in_valid(in_data_valid[c]&&in_data_ready[c]),.in_ready(fifo_ready[c]),.in_data(in_data[c]),
      .out_valid(fifo_valid[c]),.out_ready(fifo_pop[c]),.out_data(fifo_data[c]),
      .empty(),.occupancy());
    assign tree_in[c]=fifo_data[c];
    assign fifo_pop[c]=tree_valid&&tree_ready;
  end
  assign tree_valid=state_q==COLLECT&&(&seen_q)&&(&fifo_valid)&&issued_q<51&&!error_q;
  dea8_reduce_tree tree(.clk,.reset,.clear,.in_valid(tree_valid),.in_ready(tree_ready),
    .in_data(tree_in),.in_row(issued_q),.out_valid(tree_out_valid),.out_ready(1'b1),
    .out_data(tree_out),.out_row(tree_row),.empty(tree_empty));
  always_ff @(posedge clk)begin
    if(reset||clear)begin
      state_q<=COLLECT;seen_q<=0;issued_q<=0;written_q<=0;send_q<=0;
      error_q<=0;
      for(int c=0;c<8;c++)recv_q[c]<=0;
    end else begin
      for(int c=0;c<8;c++)begin
        if(in_hdr_valid[c]&&in_hdr_ready[c])begin
          if(in_hdr[c].reserved!=0||in_hdr[c].rows!=51||in_hdr[c].columns!=16||
             in_hdr[c].source_id!=c||in_hdr[c].layout!=LAYOUT_FP_ROWS||
             !(in_hdr[c].kind==TILE_O||in_hdr[c].kind==TILE_DOWN)||
             in_hdr[c].column_base!=16'(in_hdr[c].tile_seq*16)||
             (have_header?in_hdr[c].transfer_id!=base_q.transfer_id||
                in_hdr[c].transfer_epoch!=base_q.transfer_epoch||
                in_hdr[c].destination_id!=base_q.destination_id||
                in_hdr[c].token_origin!=base_q.token_origin||
                in_hdr[c].column_base!=base_q.column_base||
                in_hdr[c].kind!=base_q.kind||in_hdr[c].tile_seq!=base_q.tile_seq:
                in_hdr[c].transfer_id!=first_hdr.transfer_id||
                in_hdr[c].transfer_epoch!=first_hdr.transfer_epoch||
                in_hdr[c].destination_id!=first_hdr.destination_id||
                in_hdr[c].token_origin!=first_hdr.token_origin||
                in_hdr[c].column_base!=first_hdr.column_base||
                in_hdr[c].kind!=first_hdr.kind||in_hdr[c].tile_seq!=first_hdr.tile_seq))error_q<=1;
          else begin
            seen_q[c]<=1;
            if(!have_header)begin
              base_q<=in_hdr[c];base_q.source_id<=4'd8;
            end
          end
        end
        if(in_data_valid[c]&&in_data_ready[c])begin
          if(in_last[c]!=(recv_q[c]==50))error_q<=1;
          else recv_q[c]<=recv_q[c]+1'b1;
        end
      end
      if(tree_valid&&tree_ready)issued_q<=issued_q+1'b1;
      if(tree_out_valid)begin
        if(tree_row!=written_q||written_q>=51)error_q<=1;
        else begin
          result_mem[written_q]<=tree_out;
          written_q<=written_q+1'b1;
          if(written_q==50)state_q<=SEND_HEADER;
        end
      end
      if(out_hdr_valid&&out_hdr_ready)state_q<=SEND_DATA;
      if(out_data_valid&&out_data_ready)begin
        send_q<=send_q+1'b1;
        if(out_last)state_q<=WAIT_COMMIT;
      end
      if(commit_valid&&commit_ready)begin
        if(!commit_matches(commit,base_q))error_q<=1;
        else begin
          state_q<=COLLECT;seen_q<=0;issued_q<=0;written_q<=0;send_q<=0;
          for(int c=0;c<8;c++)recv_q[c]<=0;
        end
      end
    end
  end
endmodule
