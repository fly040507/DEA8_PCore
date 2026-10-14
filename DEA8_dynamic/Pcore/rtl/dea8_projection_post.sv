import pcore_pkg::*;

// One Pair, one post service for Q/K/V/G-U, common unit control for both units.
module dea8_projection_post (
  input logic clk,reset,clear,start_valid,output logic start_ready,
  input pcore_job_t context_job,input job_token_t context_token,
  input logic [ROW_COUNT_BITS-1:0] context_rows,
  input logic capture_cmd_valid,output logic capture_cmd_ready,input capture_desc_t capture_cmd,
  input logic capture_valid,output logic capture_ready,input pair_capture_t capture,
  output logic acquire_valid,input logic acquire_ready,output local_object_t acquire_object,
  output logic store_valid,input logic store_ready,output local_write_t store_write,input logic store_complete,
  output logic unit_cmd_valid,input logic unit_cmd_ready,output unit_cmd_t unit_cmd,
  input logic unit_armed_valid,output logic unit_armed_ready,input job_token_t unit_armed_token,
  output logic unit_go_valid,input logic unit_go_ready,output job_token_t unit_go_token,
  input logic unit_rd_valid,output logic unit_rd_ready,input pair_read_t unit_rd,
  output logic unit_out_valid,input logic unit_out_ready,output pair_reply_t unit_out_reply,
  input logic unit_wr_valid,output logic unit_wr_ready,input local_write_t unit_wr,
  input logic unit_quant_valid,output logic unit_quant_ready,input kv_quant_t unit_quant,
  output logic kv_quant_valid,input logic kv_quant_ready,output kv_quant_t kv_quant,input logic kv_output_done,
  input logic unit_done_valid,output logic unit_done_ready,input job_token_t unit_done_token,
  input unit_function_e unit_done_function,input logic unit_done_error,
  output logic function_cmd_valid,input logic function_cmd_ready,output unit_cmd_t function_cmd,
  input logic function_armed_valid,output logic function_armed_ready,input job_token_t function_armed_token,
  output logic function_go_valid,input logic function_go_ready,output job_token_t function_go_token,
  output logic function_data_valid,input logic function_data_ready,output fp16_stream_t function_data,
  input logic function_result_valid,output logic function_result_ready,input fp16_stream_t function_result,
  input logic function_done_valid,output logic function_done_ready,input job_token_t function_done_token,
  input unit_function_e function_done_function,input logic function_done_error,
  input logic profile_pending,output logic unit_running,output job_token_t active_unit_token,
  output logic done,protocol_error
);
  logic active,acquired,is_q,is_v,is_gu,is_store,release_pending,sfu_offered,gu_started,error_q;
  logic [TILE_BITS:0] finished_pairs;
  unit_cmd_t offer,command_q,f_offer,f_current,unused_prepared,unused_fprep,retired_cmd,retired_f;
  logic offer_valid,offer_ready,f_offer_valid,f_offer_ready,v_active,f_active,f_running,v_prepared,f_prepared;
  logic v_retired,f_retired,v_error,f_error;
  logic pair_acquire_valid,pair_acquire_ready,pair_active,pair_complete,pair_bound,pair_error;
  pair_object_t pair_acquire_object,pair_object;
  logic pair_bind_ready,pair_bind_valid,pair_rd_ready,pair_rd_valid,pair_release_ready;
  logic pair_out_valid,pair_out_ready;
  pair_read_t pair_rd;pair_reply_t pair_reply;
  logic [ROWS-1:0] read_seen,write_seen[0:1],new_written,quant_written;
  logic wr_legal,read_legal,wr_half,drained,quant_legal,quant_half;
  logic gu_rd_valid,gu_out_ready,gu_join_valid,gu_drained,gu_sfu_drained,gu_error;
  pair_read_t gu_rd;pair_reply_t gu_joined;
  int unsigned unit_reads,unit_writes,pair_count;
  assign is_q=context_job.op==OP_Q_PROJ;
  assign is_v=context_job.op==OP_V_PROJ;
  assign is_gu=context_job.op==OP_GU;
  assign is_store=is_q||is_gu;
  assign unit_reads=is_v?V_PACKETS_PER_TILE:int'(context_rows);
  assign unit_writes=is_v?V_PACKETS_PER_TILE:PAIRS;
  assign pair_count=is_q?QOZ_Q_TILES/2:(is_gu?QOZ_Z_TILES:(is_v?2:1));
  assign protocol_error=error_q||pair_error||v_error||f_error||gu_error;
  assign start_ready=!reset&&!clear&&!active&&!protocol_error&&!v_active&&!f_active;
  assign acquire_valid=active&&is_store&&!acquired&&!protocol_error;
  always_comb begin
    acquire_object='0;acquire_object.kind=is_gu?LOCAL_Z:LOCAL_Q;acquire_object.content_version=context_job.output_version;
    acquire_object.data_context=context_job.data_context;acquire_object.profile_id=context_job.profile_id;
    acquire_object.profile_version=context_job.profile_version;acquire_object.head=context_job.head;acquire_object.m_rows=context_rows;
    pair_acquire_object='0;pair_acquire_object.token=context_token;
    pair_acquire_object.kind=is_v?PAIR_V:(is_gu?PAIR_GU:PAIR_ROPE);
    pair_acquire_object.pair_seq=capture_cmd.pair_seq;pair_acquire_object.nt0=capture_cmd.nt;
    pair_acquire_object.nt1=is_q?TILE_BITS'(int'(capture_cmd.nt)+QOZ_Q_TILES/2):
      ((is_v||is_gu)?capture_cmd.nt:TILE_BITS'(int'(capture_cmd.nt)+1));pair_acquire_object.rows=context_rows;
    offer='0;offer.token={context_token[31:16],16'(finished_pairs+1'b1)};offer.parent_token=context_token;
    offer.function_id=is_v?UNIT_V_QUANT:(is_gu?UNIT_GU_MUL_QUANT:UNIT_ROPE_QUANT);
    offer.rows=context_rows;offer.nt0=pair_object.nt0;offer.nt1=pair_object.nt1;
    offer.profile_id=context_job.profile_id;offer.profile_version=context_job.profile_version;
    offer.position_base=context_job.position_base;offer.feature_context=context_job.feature_context;
    offer.output_version=context_job.output_version;offer.identity_rows=!(is_q||is_gu);
    offer.column_base0=is_q||is_gu?16'(int'(pair_object.nt0)*TILE):
      (pair_object.nt0==0?context_job.kv_column_base0:context_job.kv_column_base1);
    offer.column_base1=is_q?16'(int'(pair_object.nt1)*TILE):(is_v||is_gu?offer.column_base0:context_job.kv_column_base1);
    f_offer=command_q;f_offer.function_id=UNIT_GELU;f_offer.token={context_token[31:16],16'h8000|16'(finished_pairs+1'b1)};
    wr_half=is_q&&unit_wr.tile==command_q.nt1;wr_legal=0;new_written=write_seen[wr_half];
    if(unit_running&&is_store)begin
      wr_legal=unit_wr.token==command_q.token&&unit_wr.kind==(is_gu?LOCAL_Z:LOCAL_Q)&&unit_wr.set_id==0&&
        unit_wr.content_version==context_job.output_version&&unit_wr.mask!=0&&
        (unit_wr.tile==command_q.nt0||(is_q&&unit_wr.tile==command_q.nt1));
      for(int i=0;i<A_INPUT_ROWS;i++)if(unit_wr.mask[i])begin
        if(unit_wr.row[i]>=context_rows)wr_legal=0;
        else begin if(new_written[unit_wr.row[i]])wr_legal=0;new_written[unit_wr.row[i]]=1;end
        for(int j=0;j<i;j++)if(unit_wr.mask[j]&&unit_wr.row[i]%A_INPUT_ROWS==unit_wr.row[j]%A_INPUT_ROWS)wr_legal=0;
      end
    end
    read_legal=0;if(unit_running&&!is_gu&&unit_rd.row<unit_reads)
      read_legal=unit_rd.token==command_q.token&&!read_seen[unit_rd.row];
    quant_half=unit_quant.tile==command_q.nt1&&!is_v;quant_legal=0;quant_written=write_seen[quant_half];
    if(unit_running&&!is_store&&unit_quant.index<unit_writes)begin
      quant_legal=unit_quant.token==command_q.token&&
        (unit_quant.tile==command_q.nt0||(!is_v&&unit_quant.tile==command_q.nt1))&&!quant_written[unit_quant.index];
      quant_written[unit_quant.index]=1;
    end
    store_write=unit_wr;store_write.token=context_token;kv_quant=unit_quant;kv_quant.token=context_token;
  end
  assign capture_cmd_ready=active&&acquired&&!protocol_error&&pair_active&&!pair_bound&&
    pair_object.token==context_token&&pair_object.pair_seq==capture_cmd.pair_seq;
  assign pair_acquire_valid=capture_cmd_valid&&active&&acquired&&!protocol_error&&!pair_active&&!capture_cmd.half;
  assign offer_valid=active&&pair_complete&&pair_bind_ready&&!protocol_error;
  assign pair_bind_valid=offer_valid&&offer_ready;
  assign f_offer_valid=is_gu&&pair_bound&&v_active&&!sfu_offered;
  assign active_unit_token=command_q.token;
  assign pair_rd_valid=is_gu?gu_rd_valid:(unit_rd_valid&&read_legal&&!protocol_error);
  assign pair_rd=is_gu?gu_rd:unit_rd;
  assign unit_rd_ready=read_legal&&pair_rd_ready&&!protocol_error;
  assign pair_out_ready=is_gu?gu_out_ready:unit_out_ready;
  assign unit_out_valid=is_gu?gu_join_valid:pair_out_valid;
  assign unit_out_reply=is_gu?gu_joined:pair_reply;
  assign store_valid=unit_wr_valid&&wr_legal&&!protocol_error;
  assign unit_wr_ready=wr_legal&&store_ready&&!protocol_error;
  assign kv_quant_valid=unit_quant_valid&&quant_legal&&!protocol_error;
  assign unit_quant_ready=quant_legal&&kv_quant_ready&&!protocol_error;
  assign drained=read_seen==row_prefix(unit_reads)&&write_seen[0]==row_prefix(is_store?int'(context_rows):unit_writes)&&
    (is_v||is_gu||write_seen[1]==row_prefix(is_q?int'(context_rows):unit_writes))&&
    pair_release_ready&&!profile_pending&&(!is_gu||gu_drained);
  assign done=finished_pairs==pair_count&&(is_store?store_complete:kv_output_done)&&
    !pair_active&&!v_active&&!f_active&&!v_prepared&&!f_prepared&&!protocol_error;
  dea8_unit_control vector_control(.clk,.reset,.clear,.offer_valid,.offer_ready,.offer,
    .cmd_valid(unit_cmd_valid),.cmd_ready(unit_cmd_ready),.cmd(unit_cmd),
    .armed_valid(unit_armed_valid),.armed_ready(unit_armed_ready),.armed_token(unit_armed_token),
    .go_valid(unit_go_valid),.go_ready(unit_go_ready),.go_token(unit_go_token),.grant(!is_gu||f_active),
    .done_valid(unit_done_valid),.done_ready(unit_done_ready),.done_token(unit_done_token),.done_function(unit_done_function),.done_error(unit_done_error),.drained,
    .active(v_active),.running(unit_running),.prepared_valid(v_prepared),.current(command_q),.prepared(unused_prepared),
    .retired_valid(v_retired),.retired(retired_cmd),.protocol_error(v_error));
  dea8_unit_control function_control(.clk,.reset,.clear,.offer_valid(f_offer_valid),.offer_ready(f_offer_ready),.offer(f_offer),
    .cmd_valid(function_cmd_valid),.cmd_ready(function_cmd_ready),.cmd(function_cmd),
    .armed_valid(function_armed_valid),.armed_ready(function_armed_ready),.armed_token(function_armed_token),
    .go_valid(function_go_valid),.go_ready(function_go_ready),.go_token(function_go_token),.grant(is_gu&&unit_running),
    .done_valid(function_done_valid),.done_ready(function_done_ready),.done_token(function_done_token),
    .done_function(function_done_function),.done_error(function_done_error),.drained(gu_sfu_drained),
    .active(f_active),.running(f_running),.prepared_valid(f_prepared),.current(f_current),.prepared(unused_fprep),
    .retired_valid(f_retired),.retired(retired_f),.protocol_error(f_error));
  dea8_pair_buffer pair_buffer(.clk,.reset,.clear,
    .acquire_valid(pair_acquire_valid),.acquire_ready(pair_acquire_ready),.acquire_object(pair_acquire_object),
    .capture_valid,.capture_ready,.capture,.bind_valid(pair_bind_valid),.bind_ready(pair_bind_ready),.bind_token(offer.token),
    .rd_valid(pair_rd_valid),.rd_ready(pair_rd_ready),.rd(pair_rd),.out_valid(pair_out_valid),.out_ready(pair_out_ready),.out_reply(pair_reply),
    .release_valid(release_pending&&!f_active&&!protocol_error),.release_ready(pair_release_ready),.release_token(command_q.token),
    .active(pair_active),.complete(pair_complete),.bound(pair_bound),.object_state(pair_object),.protocol_error(pair_error));
  dea8_gu_join gu_join(.clk,.reset,.clear,.start(pair_bind_valid),.vpu_token(command_q.token),.sfu_token(f_current.token),.rows(context_rows),
    .run(is_gu&&unit_running&&gu_started),.pair_rd_valid(gu_rd_valid),.pair_rd_ready,.pair_rd(gu_rd),
    .pair_out_valid(pair_out_valid&&is_gu),.pair_out_ready(gu_out_ready),.pair_reply,
    .gate_valid(function_data_valid),.gate_ready(function_data_ready),.gate(function_data),
    .gelu_valid(function_result_valid),.gelu_ready(function_result_ready),.gelu(function_result),
    .join_valid(gu_join_valid),.join_ready(unit_out_ready),.joined(gu_joined),.drained(gu_drained),.sfu_drained(gu_sfu_drained),.protocol_error(gu_error));
  always_ff @(posedge clk)begin
    if(reset||clear)begin
      active<=0;acquired<=0;finished_pairs<=0;release_pending<=0;sfu_offered<=0;gu_started<=0;error_q<=0;
      read_seen<=0;write_seen[0]<=0;write_seen[1]<=0;
    end else begin
      if(start_valid&&start_ready)begin active<=1;finished_pairs<=0;acquired<=!is_store;end
      if(acquire_valid&&acquire_ready)acquired<=1;
      if(pair_bind_valid)begin read_seen<=0;write_seen[0]<=0;write_seen[1]<=0;sfu_offered<=0;gu_started<=0;end
      if(is_gu&&unit_running&&f_running)gu_started<=1;
      if(f_offer_valid&&f_offer_ready)sfu_offered<=1;
      if(function_result_valid&&(!is_gu||!f_running||function_result.token!=f_current.token))error_q<=1;
      if(unit_rd_valid&&!read_legal)error_q<=1;
      if(unit_rd_valid&&unit_rd_ready)read_seen[unit_rd.row]<=1;
      if(is_gu&&unit_out_valid&&unit_out_ready)read_seen[unit_out_reply.request.row]<=1;
      if(unit_wr_valid&&!wr_legal)error_q<=1;
      if(unit_wr_valid&&unit_wr_ready)write_seen[wr_half]<=new_written;
      if(unit_quant_valid&&!quant_legal)error_q<=1;
      if(unit_quant_valid&&unit_quant_ready)write_seen[quant_half]<=quant_written;
      if(v_retired)release_pending<=1;
      if(release_pending&&!f_active&&pair_release_ready)begin release_pending<=0;finished_pairs<=finished_pairs+1'b1;end
      if(done&&!(start_valid&&start_ready))active<=0;
    end
  end
endmodule
