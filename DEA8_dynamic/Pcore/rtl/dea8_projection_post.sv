import pcore_pkg::*;

// Shared Q/K/V post service; arithmetic remains in the external VPU.
module dea8_projection_post (
  input logic clk,reset,clear,start_valid,output logic start_ready,
  input pcore_job_t context_job,input job_token_t context_token,
  input logic [ROW_COUNT_BITS-1:0] context_rows,
  input logic capture_cmd_valid,output logic capture_cmd_ready,input capture_desc_t capture_cmd,
  input logic capture_valid,output logic capture_ready,input pair_capture_t capture,
  output logic acquire_valid,input logic acquire_ready,output local_object_t acquire_object,
  output logic store_valid,input logic store_ready,output local_write_t store_write,
  input logic store_complete,
  output logic unit_cmd_valid,input logic unit_cmd_ready,output unit_cmd_t unit_cmd,
  input logic unit_armed_valid,output logic unit_armed_ready,input job_token_t unit_armed_token,
  output logic unit_go_valid,input logic unit_go_ready,output job_token_t unit_go_token,
  input logic unit_rd_valid,output logic unit_rd_ready,input pair_read_t unit_rd,
  output logic unit_out_valid,input logic unit_out_ready,output pair_reply_t unit_out_reply,
  input logic unit_wr_valid,output logic unit_wr_ready,input local_write_t unit_wr,
  input logic unit_quant_valid,output logic unit_quant_ready,input kv_quant_t unit_quant,
  output logic kv_quant_valid,input logic kv_quant_ready,output kv_quant_t kv_quant,
  input logic kv_output_done,
  input logic unit_done_valid,output logic unit_done_ready,input job_token_t unit_done_token,
  input unit_function_e unit_done_function,input logic unit_done_error,
  input logic profile_pending,
  output logic unit_running,output job_token_t active_unit_token,
  output logic done,protocol_error
);
  typedef enum logic [2:0] {WAIT_PAIR,WAIT_ARM,GO,RUN,RELEASE} state_e;
  state_e state;
  logic active,acquired;
  logic [4:0] finished_pairs;
  unit_cmd_t command_q;
  logic pair_acquire_valid,pair_acquire_ready,pair_active,pair_complete,pair_bound,pair_error;
  pair_object_t pair_acquire_object,pair_object;
  logic pair_bind_ready,pair_bind_valid,pair_rd_ready,pair_rd_valid,pair_release_ready;
  logic [ROWS-1:0] read_seen,write_seen[0:1],new_written;
  logic wr_legal,read_legal,wr_half,drained;
  logic quant_legal,quant_half,is_q,is_v;
  logic [ROWS-1:0] quant_written;
  int unsigned unit_reads,unit_writes,pair_count;
  assign is_q=context_job.op==OP_Q_PROJ;
  assign is_v=context_job.op==OP_V_PROJ;
  assign unit_reads=is_v?V_PACKETS_PER_TILE:int'(context_rows);
  assign unit_writes=is_v?V_PACKETS_PER_TILE:PAIRS;
  assign pair_count=is_q?QOZ_Q_TILES/2:(is_v?2:1);
  assign start_ready=!reset&&!clear&&!active&&!protocol_error;
  assign acquire_valid=active&&is_q&&!acquired&&!protocol_error;
  always_comb begin
    acquire_object='0;acquire_object.kind=LOCAL_Q;acquire_object.content_version=context_job.output_version;
    acquire_object.data_context=context_job.data_context;acquire_object.profile_id=context_job.profile_id;
    acquire_object.profile_version=context_job.profile_version;acquire_object.head=context_job.head;
    acquire_object.m_rows=context_rows;
    pair_acquire_object='0;pair_acquire_object.token=context_token;pair_acquire_object.kind=is_v?PAIR_V:PAIR_ROPE;
    pair_acquire_object.pair_seq=capture_cmd.pair_seq;pair_acquire_object.nt0=capture_cmd.nt;
    pair_acquire_object.nt1=is_q?TILE_BITS'(int'(capture_cmd.nt)+QOZ_Q_TILES/2):
      (is_v?capture_cmd.nt:TILE_BITS'(int'(capture_cmd.nt)+1));pair_acquire_object.rows=context_rows;
    unit_cmd='0;unit_cmd.token={context_token[31:16],16'(finished_pairs+1'b1)};
    unit_cmd.parent_token=context_token;unit_cmd.function_id=is_v?UNIT_V_QUANT:UNIT_ROPE_QUANT;
    unit_cmd.rows=context_rows;unit_cmd.nt0=pair_object.nt0;unit_cmd.nt1=pair_object.nt1;
    unit_cmd.profile_id=context_job.profile_id;unit_cmd.profile_version=context_job.profile_version;
    unit_cmd.position_base=context_job.position_base;unit_cmd.feature_context=context_job.feature_context;
    unit_cmd.output_version=context_job.output_version;
    unit_cmd.identity_rows=!is_q;
    unit_cmd.column_base0=is_q?16'(int'(pair_object.nt0)*TILE):
      (pair_object.nt0==0?context_job.kv_column_base0:context_job.kv_column_base1);
    unit_cmd.column_base1=is_q?16'(int'(pair_object.nt1)*TILE):
      (is_v?unit_cmd.column_base0:context_job.kv_column_base1);
    wr_half=unit_wr.tile==command_q.nt1;wr_legal=0;new_written=write_seen[wr_half];
    if(state==RUN&&is_q)begin
      wr_legal=unit_wr.token==command_q.token&&unit_wr.kind==LOCAL_Q&&unit_wr.set_id==0&&
        unit_wr.content_version==context_job.output_version&&unit_wr.mask!=0&&
        (unit_wr.tile==command_q.nt0||unit_wr.tile==command_q.nt1);
      for(int i=0;i<A_INPUT_ROWS;i++)if(unit_wr.mask[i])begin
        if(unit_wr.row[i]>=context_rows)wr_legal=0;
        else begin if(new_written[unit_wr.row[i]])wr_legal=0;new_written[unit_wr.row[i]]=1;end
        for(int j=0;j<i;j++)if(unit_wr.mask[j]&&unit_wr.row[i]%A_INPUT_ROWS==unit_wr.row[j]%A_INPUT_ROWS)wr_legal=0;
      end
    end
    read_legal=0;
    if(state==RUN&&unit_rd.row<unit_reads)
      read_legal=unit_rd.token==command_q.token&&!read_seen[unit_rd.row];
    quant_half=unit_quant.tile==command_q.nt1&&!is_v;
    quant_legal=0;quant_written=write_seen[quant_half];
    if(state==RUN&&!is_q&&unit_quant.index<unit_writes)begin
      quant_legal=unit_quant.token==command_q.token&&
        (unit_quant.tile==command_q.nt0||(!is_v&&unit_quant.tile==command_q.nt1))&&
        !quant_written[unit_quant.index];
      quant_written[unit_quant.index]=1;
    end
    store_write=unit_wr;store_write.token=context_token;
    kv_quant=unit_quant;kv_quant.token=context_token;
  end
  // FACC already holds the complete result. Wait for Pair space before reads,
  // not before computing the next NTile in a different free FACC bank.
  assign capture_cmd_ready=active&&acquired&&!protocol_error&&pair_active&&!pair_bound&&
    pair_object.token==context_token&&pair_object.pair_seq==capture_cmd.pair_seq;
  assign pair_acquire_valid=capture_cmd_valid&&active&&acquired&&!protocol_error&&!pair_active&&!capture_cmd.half;
  assign unit_cmd_valid=active&&state==WAIT_PAIR&&pair_complete&&pair_bind_ready&&!protocol_error;
  assign pair_bind_valid=unit_cmd_valid&&unit_cmd_ready;
  assign unit_armed_ready=state==WAIT_ARM&&!protocol_error;
  assign unit_go_valid=state==GO&&!protocol_error;
  assign unit_go_token=command_q.token;
  assign unit_running=state==RUN&&!protocol_error;
  assign active_unit_token=command_q.token;
  assign pair_rd_valid=unit_rd_valid&&read_legal&&!protocol_error;
  assign unit_rd_ready=read_legal&&pair_rd_ready&&!protocol_error;
  assign store_valid=unit_wr_valid&&wr_legal&&!protocol_error;
  assign unit_wr_ready=wr_legal&&store_ready&&!protocol_error;
  assign kv_quant_valid=unit_quant_valid&&quant_legal&&!protocol_error;
  assign unit_quant_ready=quant_legal&&kv_quant_ready&&!protocol_error;
  assign unit_done_ready=state==RUN&&!protocol_error;
  assign drained=read_seen==row_prefix(unit_reads)&&write_seen[0]==row_prefix(is_q?int'(context_rows):unit_writes)&&
    (is_v||write_seen[1]==row_prefix(is_q?int'(context_rows):unit_writes))&&pair_release_ready&&!profile_pending;
  assign done=finished_pairs==pair_count&&(is_q?store_complete:kv_output_done)&&!pair_active&&!protocol_error;
  dea8_pair_buffer pair_buffer(.clk,.reset,.clear,
    .acquire_valid(pair_acquire_valid),.acquire_ready(pair_acquire_ready),.acquire_object(pair_acquire_object),
    .capture_valid,.capture_ready,.capture,
    .bind_valid(pair_bind_valid),.bind_ready(pair_bind_ready),.bind_token(unit_cmd.token),
    .rd_valid(pair_rd_valid),.rd_ready(pair_rd_ready),.rd(unit_rd),
    .out_valid(unit_out_valid),.out_ready(unit_out_ready),.out_reply(unit_out_reply),
    .release_valid(state==RELEASE&&!protocol_error),.release_ready(pair_release_ready),.release_token(command_q.token),
    .active(pair_active),.complete(pair_complete),.bound(pair_bound),.object_state(pair_object),.protocol_error(pair_error));
  always_ff @(posedge clk)begin
    if(reset||clear)begin
      active<=0;acquired<=0;finished_pairs<=0;state<=WAIT_PAIR;command_q<='0;
      read_seen<=0;write_seen[0]<=0;write_seen[1]<=0;protocol_error<=0;
    end else begin
      if(pair_error)protocol_error<=1;
      if(start_valid&&start_ready)begin active<=1;finished_pairs<=0;acquired<=!is_q;end
      if(acquire_valid&&acquire_ready)acquired<=1;
      if(unit_cmd_valid&&unit_cmd_ready)begin
        command_q<=unit_cmd;state<=WAIT_ARM;read_seen<=0;write_seen[0]<=0;write_seen[1]<=0;
      end
      if(unit_armed_valid)begin
        if(!unit_armed_ready||unit_armed_token!=command_q.token)protocol_error<=1;
        else state<=GO;
      end
      if(unit_go_valid&&unit_go_ready)state<=RUN;
      if(unit_rd_valid&&!read_legal)protocol_error<=1;
      if(unit_rd_valid&&unit_rd_ready)read_seen[unit_rd.row]<=1;
      if(unit_wr_valid&&!wr_legal)protocol_error<=1;
      if(unit_wr_valid&&unit_wr_ready)write_seen[wr_half]<=new_written;
      if(unit_quant_valid&&!quant_legal)protocol_error<=1;
      if(unit_quant_valid&&unit_quant_ready)write_seen[quant_half]<=quant_written;
      if(unit_done_valid)begin
        if(!unit_done_ready||unit_done_token!=command_q.token||unit_done_function!=command_q.function_id||
          unit_done_error||!drained)protocol_error<=1;
        else state<=RELEASE;
      end
      if(state==RELEASE&&pair_release_ready)begin finished_pairs<=finished_pairs+1'b1;state<=WAIT_PAIR;end
      if(done&&!(start_valid&&start_ready))active<=0;
    end
  end
endmodule
