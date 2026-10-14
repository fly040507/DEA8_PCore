import pcore_pkg::*;

// One shared pair: two independent halves, each with sixteen 1R1W row banks.
// V request.row is the group/feature-pair ordinal, not a token row.
module dea8_pair_buffer (
  input logic clk,reset,clear,acquire_valid,output logic acquire_ready,input pair_object_t acquire_object,
  input logic capture_valid,output logic capture_ready,input pair_capture_t capture,
  input logic bind_valid,output logic bind_ready,input job_token_t bind_token,
  input logic rd_valid,output logic rd_ready,input pair_read_t rd,
  output logic out_valid,input logic out_ready,output pair_reply_t out_reply,
  input logic release_valid,output logic release_ready,input job_token_t release_token,
  output logic active,complete,bound,output pair_object_t object_state,output logic protocol_error
);
  localparam int ROW_BANKS=TILE,DEPTH=(ROWS+ROW_BANKS-1)/ROW_BANKS;
  logic [ROWS-1:0] written[0:1];
  job_token_t reader;
  logic [1:0][TILE-1:0][FP_BITS-1:0] ram_data;
  logic [TILE-1:0][FP_BITS-1:0] bank_data[0:1][0:ROW_BANKS-1];
  logic [$clog2(ROW_BANKS)-1:0] read_bank;
  pair_read_t request_q;
  pair_reply_t fifo[0:1];
  logic [1:0] count,refs;
  logic rptr,wptr,pending,wr_legal,rd_legal,wr_fire,rd_fire,pop;
  logic [ROWS-1:0] new_written;
  always_comb begin
    wr_legal=0;new_written=0;
    if(active)begin
      wr_legal=!bound&&!complete&&capture.owner.token==object_state.token&&
        (object_state.kind!=PAIR_V||!capture.owner.half)&&
        capture.owner.pair_seq==object_state.pair_seq&&capture.owner.rows==object_state.rows&&
        capture.owner.nt==(capture.owner.half?object_state.nt1:object_state.nt0)&&
        capture.mask==row_mask_for_rows(object_state.rows,capture.pair_idx)&&capture.mask!=0;
      new_written=written[capture.owner.half];
      for(int r=0;r<ROW_LANES;r++)if(capture.mask[r])begin
        if(int'(capture.pair_idx)*ROW_LANES+r>=object_state.rows)wr_legal=0;
        else begin
          if(new_written[int'(capture.pair_idx)*ROW_LANES+r])wr_legal=0;
          new_written[int'(capture.pair_idx)*ROW_LANES+r]=1;
        end
      end
    end
    rd_legal=active&&complete&&bound&&rd.token==reader&&
      rd.row<(object_state.kind==PAIR_V?V_PACKETS_PER_TILE:object_state.rows);
  end
  assign acquire_ready=!reset&&!clear&&!protocol_error&&!active&&acquire_object.rows>0&&acquire_object.rows<=ROWS;
  assign capture_ready=!reset&&!clear&&!protocol_error&&wr_legal;
  assign bind_ready=!reset&&!clear&&!protocol_error&&active&&complete&&!bound;
  assign release_ready=!reset&&!clear&&!protocol_error&&bound&&release_token==reader&&refs==0;
  assign out_valid=!reset&&!clear&&!protocol_error&&count!=0;
  assign pop=out_valid&&out_ready;
  assign rd_ready=!reset&&!clear&&!protocol_error&&rd_legal&&!release_valid&&int'(count)+int'(pending)<2+(pop?1:0);
  assign wr_fire=capture_valid&&capture_ready;assign rd_fire=rd_valid&&rd_ready;
  always_comb begin out_reply='0;if(count!=0)out_reply=fifo[rptr];end
  for(genvar h=0;h<2;h++)begin: halves
    for(genvar b=0;b<ROW_BANKS;b++)begin: banks
      (* ram_style="distributed" *) logic [TILE-1:0][FP_BITS-1:0] mem[0:DEPTH-1];
      always_ff @(posedge clk)begin
        for(int r=0;r<ROW_LANES;r++)if(wr_fire&&capture.owner.half==h&&capture.mask[r]&&
          (int'(capture.pair_idx)*ROW_LANES+r)%ROW_BANKS==b)
          mem[(int'(capture.pair_idx)*ROW_LANES+r)/ROW_BANKS]<=capture.data[r];
        if(rd_fire)begin
          if(object_state.kind==PAIR_V)begin
            if(h==0)bank_data[h][b]<=mem[int'(rd.row)/(TILE/ROW_LANES)];
          end else if(int'(rd.row)%ROW_BANKS==b)bank_data[h][b]<=mem[int'(rd.row)/ROW_BANKS];
        end
      end
    end
  end
  always_comb begin
    ram_data='0;
    if(pending)begin
      if(object_state.kind==PAIR_V)begin
        for(int r=0;r<TILE;r++)if(int'(request_q.row)/(TILE/ROW_LANES)*TILE+r<object_state.rows)
          for(int h=0;h<ROW_LANES;h++)ram_data[h][r]=
            bank_data[0][r][int'(request_q.row)%(TILE/ROW_LANES)*ROW_LANES+h];
      end else for(int h=0;h<2;h++)ram_data[h]=bank_data[h][read_bank];
    end
  end
  always_ff @(posedge clk)begin
    if(reset||clear)begin
      active<=0;complete<=0;bound<=0;object_state<='0;reader<=0;
      written[0]<=0;written[1]<=0;pending<=0;count<=0;refs<=0;rptr<=0;wptr<=0;
      request_q<='0;read_bank<=0;protocol_error<=0;
    end else begin
      if(acquire_valid&&!active&&(acquire_object.rows==0||acquire_object.rows>ROWS))protocol_error<=1;
      if(capture_valid&&!wr_legal)protocol_error<=1;
      if(rd_valid&&!rd_legal)protocol_error<=1;
      if(release_valid&&(!bound||release_token!=reader))protocol_error<=1;
      if(acquire_valid&&acquire_ready)begin
        object_state<=acquire_object;active<=1;complete<=0;bound<=0;written[0]<=0;written[1]<=0;
      end
      if(wr_fire)begin
        written[capture.owner.half]<=new_written;
        if(new_written==row_prefix(object_state.rows)&&
          (object_state.kind==PAIR_V||written[!capture.owner.half]==row_prefix(object_state.rows)))complete<=1;
      end
      if(bind_valid&&bind_ready)begin bound<=1;reader<=bind_token;end
      pending<=rd_fire;if(rd_fire)begin request_q<=rd;read_bank<=$clog2(ROW_BANKS)'(rd.row%ROW_BANKS);end
      case({pending,pop})
        2'b10:count<=count+1'b1;
        2'b01:count<=count-1'b1;
        default:;
      endcase
      case({rd_fire,pop})
        2'b10:refs<=refs+1'b1;
        2'b01:refs<=refs-1'b1;
        default:;
      endcase
      if(pending)begin
        pair_reply_t reply;reply='0;reply.request=request_q;reply.data=ram_data;
        fifo[wptr]<=reply;wptr<=!wptr;
      end
      if(pop)rptr<=!rptr;
      if(release_valid&&release_ready)begin active<=0;complete<=0;bound<=0;end
    end
  end
endmodule
