module dea8_gcore_kv_receive #(parameter bit BUFFERED=1'b1) (
  input logic clk,reset,clear,
  input logic cmd_valid,
  output logic cmd_ready,
  input gcore_pkg::gcore_cmd_t cmd,
  input gcore_pkg::gcore_context_t context_data,
  input logic [gcore_pkg::CORES-1:0] header_valid,
  output logic [gcore_pkg::CORES-1:0] header_ready,
  input dea8_tile_link_pkg::tile_header_t header [gcore_pkg::CORES],
  input logic [gcore_pkg::CORES-1:0] data_valid,
  output logic [gcore_pkg::CORES-1:0] data_ready,
  input logic [gcore_pkg::CORES-1:0][135:0] data,
  input logic [gcore_pkg::CORES-1:0] last,
  output logic [gcore_pkg::CORES-1:0] commit_valid,
  input logic [gcore_pkg::CORES-1:0] commit_ready,
  output dea8_tile_link_pkg::tile_commit_t commit [gcore_pkg::CORES],
  output logic [gcore_pkg::CORES-1:0] wr_valid,
  input logic [gcore_pkg::CORES-1:0] wr_ready,
  output gcore_pkg::kv_write_t wr [gcore_pkg::CORES],
  output logic done_valid,
  input logic done_ready,
  output gcore_pkg::gcore_done_t done,
  output logic busy
);
  import gcore_pkg::*;
  import dea8_tile_link_pkg::*;
  import pcore_pkg::OP_K_PROJ;
  import pcore_pkg::OP_V_PROJ;
  typedef enum logic [2:0] {WAIT_HEADER,RECEIVE,DRAIN,SEND_COMMIT,FINISHED} state_e;
  state_e state_q [CORES];
  gcore_cmd_t command_q;
  tile_transfer_t transfer_q;
  tile_header_t headers_q [CORES];
  logic value_q,failed;
  logic [CORES-1:0] tile_q,header_bad,word_bad,fifo_ready,fifo_valid,fifo_pop,commit_fire;
  logic [CORES-1:0][135:0] fifo_data;
  logic [6:0] received_q [CORES],written_q [CORES];
  logic [4:0] committed_q;
  int commits_now;
  logic bad_event;
  gcore_status_e bad_status;
  assign cmd_ready=!busy&&!done_valid&&!reset&&!clear&&!failed;
  always_comb begin
    commits_now=0; bad_event=0; bad_status=GC_BAD_HEADER;
    for(int c=0;c<CORES;c++) begin
      header_bad[c]=header[c].transfer_id!=transfer_q.transfer_id ||
        header[c].transfer_epoch!=transfer_q.transfer_epoch ||
        header[c].destination_id!=transfer_q.destination_id ||
        header[c].token_origin!=transfer_q.token_origin || header[c].source_id!=c ||
        header[c].rows!=ROWS || header[c].columns!=TILE || header[c].reserved!=0 ||
        header[c].kind!=(value_q?TILE_V:TILE_K) ||
        header[c].layout!=(value_q?LAYOUT_V_GROUPS:LAYOUT_K_ROWS) ||
        header[c].tile_seq!=tile_q[c] ||
        header[c].column_base!=16'(value_q?c*32+tile_q[c]*16:c*16+tile_q[c]*128);
      word_bad[c]=last[c]!=(received_q[c]==(value_q?63:ROWS-1)) || data[c][135:128]==8'hff;
      if(value_q&&received_q[c]>=48&&data[c][127:24]!=0) word_bad[c]=1;
      header_ready[c]=busy&&!failed&&state_q[c]==WAIT_HEADER&&!reset&&!clear;
      data_ready[c]=busy&&!failed&&state_q[c]==RECEIVE&&!reset&&!clear&&
        (word_bad[c]||fifo_ready[c]);
      wr_valid[c]=busy&&!failed&&(state_q[c]==RECEIVE||state_q[c]==DRAIN)&&fifo_valid[c]&&!reset&&!clear;
      wr[c]='0; wr[c].value_kind=value_q;
      wr[c].feature_tile=4'(headers_q[c].column_base/16);
      wr[c].parity=written_q[c][0]; wr[c].address=5'(written_q[c]/2); wr[c].word_data=fifo_data[c];
      fifo_pop[c]=wr_valid[c]&&wr_ready[c];
      commit[c]='0; commit[c].transfer_id=headers_q[c].transfer_id;
      commit[c].transfer_epoch=headers_q[c].transfer_epoch;
      commit[c].tile_seq=headers_q[c].tile_seq; commit[c].source_id=4'(c);
      commit_valid[c]=state_q[c]==SEND_COMMIT&&!reset&&!clear;
      commit_fire[c]=commit_valid[c]&&commit_ready[c];
      if(commit_fire[c]) commits_now++;
      if(header_valid[c]&&header_ready[c]&&header_bad[c]) begin bad_event=1; bad_status=GC_BAD_HEADER; end
      if(data_valid[c]&&data_ready[c]&&word_bad[c]) begin
        bad_event=1; bad_status=(data[c][135:128]==8'hff)?GC_NUMERIC_FAULT:GC_BAD_LENGTH;
      end
    end
  end
  for(genvar c=0;c<CORES;c++) begin: inputs
    if(BUFFERED)begin:buffered
    dea8_gcore_fifo #(.WIDTH(136),.DEPTH(2)) fifo (
      .clk,.reset,.clear,
      .in_valid(data_valid[c]&&data_ready[c]&&!word_bad[c]),.in_ready(fifo_ready[c]),.in_data(data[c]),
      .out_valid(fifo_valid[c]),.out_ready(fifo_pop[c]),.out_data(fifo_data[c]),.occupancy()
    );
    end else begin:direct
      assign fifo_valid[c]=state_q[c]==RECEIVE&&data_valid[c]&&!word_bad[c];
      assign fifo_ready[c]=wr_ready[c];
      assign fifo_data[c]=data[c];
    end
  end
  always_ff @(posedge clk) begin
    if(reset||clear) begin
      busy<=0; done_valid<=0; done<='0; command_q<='0; transfer_q<='0;
      value_q<=0; failed<=0; tile_q<=0; committed_q<=0;
      for(int c=0;c<CORES;c++) begin state_q[c]<=WAIT_HEADER; headers_q[c]<='0; received_q[c]<=0; written_q[c]<=0; end
    end else begin
      if(done_valid&&done_ready) done_valid<=0;
      if(cmd_valid&&cmd_ready) begin
        command_q<=cmd; value_q<=cmd.pcore_op==OP_V_PROJ;
        transfer_q<=cmd.pcore_op==OP_V_PROJ?context_data.v_transfer:context_data.k_transfer;
        committed_q<=0; tile_q<=0;
        for(int c=0;c<CORES;c++) begin state_q[c]<=WAIT_HEADER; received_q[c]<=0; written_q[c]<=0; end
        if(cmd.opcode!=GC_KV_RX || (cmd.pcore_op!=OP_K_PROJ&&cmd.pcore_op!=OP_V_PROJ)) begin
          done<=make_done(cmd,GC_INVALID_CMD,0); done_valid<=1;
        end else busy<=1;
      end
      if(busy&&!failed) begin
        for(int c=0;c<CORES;c++) begin
          if(header_valid[c]&&header_ready[c]&&!header_bad[c]) begin
            headers_q[c]<=header[c]; received_q[c]<=0; written_q[c]<=0; state_q[c]<=RECEIVE;
          end
          if(data_valid[c]&&data_ready[c]&&!word_bad[c]) begin
            received_q[c]<=received_q[c]+1'b1;
            if(last[c]) state_q[c]<=DRAIN;
          end
          if(fifo_pop[c]) begin
            written_q[c]<=written_q[c]+1'b1;
            if(written_q[c]==(value_q?63:ROWS-1)) state_q[c]<=SEND_COMMIT;
          end
          if(commit_fire[c]) begin
            if(tile_q[c]) state_q[c]<=FINISHED;
            else begin tile_q[c]<=1; state_q[c]<=WAIT_HEADER; end
          end
        end
        committed_q<=committed_q+5'(commits_now);
        if(committed_q+commits_now==2*CORES) begin
          done<=make_done(command_q,GC_OK,16'(2*CORES)); done_valid<=1; busy<=0;
        end
        // A malformed packet invalidates the whole object; no success completion.
        if(bad_event) begin
          done<=make_done(command_q,bad_status,16'(committed_q)); done_valid<=1; busy<=0; failed<=1;
        end
      end
      // A previously visible commit remains stable even if another port faults.
      if(failed)
        for(int c=0;c<CORES;c++) if(commit_fire[c]) state_q[c]<=FINISHED;
    end
  end
endmodule
