module dea8_gcore_reduce_sink (
  input logic clk,reset,clear,
  input logic cmd_valid,
  output logic cmd_ready,
  input gcore_pkg::gcore_cmd_t cmd,
  input gcore_pkg::gcore_context_t context_data,
  input logic header_valid,
  output logic header_ready,
  input dea8_tile_link_pkg::tile_header_t header,
  input logic data_valid,
  output logic data_ready,
  input logic [511:0] data,
  input logic last,
  output logic commit_valid,
  input logic commit_ready,
  output dea8_tile_link_pkg::tile_commit_t commit,
  output logic work_valid,
  input logic work_ready,
  output gcore_pkg::residual_work_t work,
  input logic written_valid,
  output logic written_ready,
  input gcore_pkg::residual_commit_t written,
  output logic done_valid,
  input logic done_ready,
  output gcore_pkg::gcore_done_t done,
  output logic busy
);
  import gcore_pkg::*;
  import dea8_tile_link_pkg::*;
  import pcore_pkg::OP_O_PROJ;
  import pcore_pkg::OP_DOWN_PROJ;
  typedef enum logic [2:0] {IDLE,HEADER,RECEIVE,DRAIN,COMMIT,COMPLETE} state_e;
  state_e state_q;
  gcore_cmd_t command_q;
  tile_transfer_t transfer_q;
  tile_header_t header_q;
  logic [5:0] nt_q,received_q,written_q;
  logic header_good,data_good,numeric_bad,write_good;
  logic fifo_in_ready,fifo_empty;
  logic fifo_push;
  residual_work_t fifo_input;
  logic [1:0] fifo_count;

  assign busy=state_q!=IDLE;
  assign cmd_ready=state_q==IDLE&&!reset&&!clear;
  assign header_ready=state_q==HEADER&&!reset&&!clear;
  assign header_good=header.transfer_id==transfer_q.transfer_id &&
    header.transfer_epoch==transfer_q.transfer_epoch && header.destination_id==transfer_q.destination_id &&
    header.token_origin==transfer_q.token_origin && header.source_id==CORES &&
    header.rows==ROWS && header.columns==TILE && header.layout==LAYOUT_FP_ROWS &&
    header.kind==(command_q.pcore_op==OP_O_PROJ?TILE_O:TILE_DOWN) &&
    header.tile_seq==nt_q && header.column_base==nt_q*TILE && header.reserved==0;
  always_comb begin
    numeric_bad=0;
    for(int lane=0;lane<TILE;lane++) if(!gcore_fp_pkg::finite32(data[32*lane+:32])) numeric_bad=1;
  end
  assign data_good=last==(received_q==ROWS-1)&&!numeric_bad;
  assign data_ready=state_q==RECEIVE&&!reset&&!clear&&(data_good?fifo_in_ready:1'b1);
  assign fifo_push=data_valid&&data_ready&&data_good;
  always_comb begin
    fifo_input='0; fifo_input.token=command_token(command_q);
    fifo_input.index=VECTOR_ADDR_BITS'(nt_q*ROWS+received_q); fifo_input.data=data;
  end
  dea8_reduce_fifo #(.WIDTH($bits(residual_work_t)),.DEPTH(2)) input_holding (
    .clk,.reset,.clear(clear||state_q==COMPLETE),.in_valid(fifo_push),.in_ready(fifo_in_ready),
    .in_data(fifo_input),.out_valid(work_valid),.out_ready(work_ready),.out_data(work),
    .empty(fifo_empty),.occupancy(fifo_count)
  );
  assign written_ready=(state_q==RECEIVE||state_q==DRAIN)&&!reset&&!clear;
  assign write_good=written.token==command_token(command_q)&&written_q<received_q &&
    written.index==nt_q*ROWS+written_q;
  assign commit_valid=state_q==COMMIT&&!reset&&!clear;
  always_comb begin
    commit='0; commit.transfer_id=header_q.transfer_id; commit.transfer_epoch=header_q.transfer_epoch;
    commit.tile_seq=header_q.tile_seq; commit.source_id=header_q.source_id;
  end
  assign done_valid=state_q==COMPLETE&&!reset&&!clear;

  always_ff @(posedge clk) begin
    if(reset||clear) begin
      state_q<=IDLE; command_q<='0; transfer_q<='0; header_q<='0;
      nt_q<=0; received_q<=0; written_q<=0; done<='0;
    end else begin
      if(cmd_valid&&cmd_ready) begin
        command_q<=cmd; nt_q<=0; received_q<=0; written_q<=0;
        transfer_q<=cmd.pcore_op==OP_O_PROJ?context_data.o_transfer:context_data.down_transfer;
        if(cmd.opcode!=GC_RESIDUAL_APPLY || (cmd.pcore_op!=OP_O_PROJ&&cmd.pcore_op!=OP_DOWN_PROJ)) begin
          done<=make_done(cmd,GC_INVALID_CMD,0); state_q<=COMPLETE;
        end else state_q<=HEADER;
      end
      if(header_valid&&header_ready) begin
        if(!header_good) begin done<=make_done(command_q,GC_BAD_HEADER,16'(nt_q*ROWS)); state_q<=COMPLETE; end
        else begin header_q<=header; received_q<=0; written_q<=0; state_q<=RECEIVE; end
      end
      if(data_valid&&data_ready) begin
        if(!data_good) begin
          done<=make_done(command_q,numeric_bad?GC_NUMERIC_FAULT:GC_BAD_LENGTH,16'(nt_q*ROWS+written_q));
          state_q<=COMPLETE;
        end else begin received_q<=received_q+1'b1; if(received_q==ROWS-1) state_q<=DRAIN; end
      end
      if(written_valid&&written_ready) begin
        if(!write_good) begin
          done<=make_done(command_q,GC_SOURCE_PROTOCOL,16'(nt_q*ROWS+written_q)); state_q<=COMPLETE;
        end else written_q<=written_q+1'b1;
      end
      if(state_q==DRAIN&&received_q==ROWS&&written_q==ROWS&&fifo_empty) state_q<=COMMIT;
      if(commit_valid&&commit_ready) begin
        if(nt_q==HIDDEN_TILES-1) begin
          done<=make_done(command_q,GC_OK,16'(VECTOR_WORDS)); state_q<=COMPLETE;
        end else begin nt_q<=nt_q+1'b1; state_q<=HEADER; end
      end
      if(done_valid&&done_ready) state_q<=IDLE;
    end
  end
endmodule
