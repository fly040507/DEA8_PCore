import pcore_pkg::*;

// No arithmetic here: this is the common unit, ACC, workspace and quantized
// write contract. Successful fences come from actual accepted data, not timers.
module dea8_attention_units (
  input logic clk,reset,clear,begin_job,
  input pcore_job_t context_job,input job_token_t context_token,input logic [ROW_COUNT_BITS-1:0] rows,
  input logic v_offer_valid,output logic v_offer_ready,input unit_cmd_t v_offer,input logic v_grant,
  input logic f_offer_valid,output logic f_offer_ready,input unit_cmd_t f_offer,input logic f_grant,
  output logic v_cmd_valid,input logic v_cmd_ready,output unit_cmd_t v_cmd,
  input logic v_armed_valid,output logic v_armed_ready,input job_token_t v_armed_token,
  output logic v_go_valid,input logic v_go_ready,output job_token_t v_go_token,
  input logic v_done_valid,output logic v_done_ready,input job_token_t v_done_token,input unit_function_e v_done_function,input logic v_done_error,
  output logic f_cmd_valid,input logic f_cmd_ready,output unit_cmd_t f_cmd,
  input logic f_armed_valid,output logic f_armed_ready,input job_token_t f_armed_token,
  output logic f_go_valid,input logic f_go_ready,output job_token_t f_go_token,
  input logic f_done_valid,output logic f_done_ready,input job_token_t f_done_token,input unit_function_e f_done_function,input logic f_done_error,
  input logic v_ws_valid,output logic v_ws_ready,input workspace_req_t v_ws,
  output logic v_ws_out_valid,input logic v_ws_out_ready,output workspace_rsp_t v_ws_out,
  input logic f_ws_valid,output logic f_ws_ready,input sfu_workspace_req_t f_ws,
  output logic f_ws_out_valid,input logic f_ws_out_ready,output sfu_workspace_rsp_t f_ws_out,
  input logic acc_req_valid,output logic acc_req_ready,input unit_acc_read_t acc_req,
  output logic acc_out_valid,input logic acc_out_ready,output unit_acc_reply_t acc_out,
  input logic acc_write_valid,output logic acc_write_ready,input unit_acc_write_t acc_write,
  output logic raw_rd_valid,input logic raw_rd_ready,output acc_sel_e raw_rd_sel,output logic [9:0] raw_rd_addr,
  input logic raw_out_valid,input logic [ROW_LANES-1:0][TILE-1:0][FP_BITS-1:0] raw_data,
  output logic raw_wr_valid,input logic raw_wr_ready,output acc_write_t raw_write,
  input logic exp_valid,output logic exp_ready,input fp4_stream_t exp,
  output logic p_valid,input logic p_ready,output fp4_stream_t p,
  input logic quant_valid,output logic quant_ready,input local_write_t quant,
  output logic store_valid,input logic store_ready,output local_write_t store,
  input logic [1:0] pbuf_active,pbuf_complete,input local_object_t pbuf_object[0:1],input logic o_complete,
  output logic p_fence,scale_fence,output logic [5:0] p_fence_block,scale_fence_block,
  output logic v_active,v_running,f_active,f_running,output unit_cmd_t v_current,f_current,
  output logic v_retired,f_retired,output unit_cmd_t v_completed,f_completed,
  output logic idle,protocol_error
);
  unit_cmd_t v_prepared_cmd,f_prepared_cmd;
  logic v_prepared,f_prepared,v_error,f_error,workspace_error,error_q;
  logic v_drained,f_drained,v_auth,f_auth,v_raw_ready,f_raw_ready;
  logic raw_v_out_valid,raw_f_out_valid;
  workspace_req_t f_wide;
  workspace_rsp_t f_wide_reply;
  workspace_status_t ws;
  logic [TILE-1:0][ROWS-1:0] quant_seen,next_quant;
  logic [TILE-1:0][PAIRS-1:0] read_seen,write_seen,next_write;
  logic [ROWS-1:0] score_seen,m_seen,aa_seen,l_seen,f_read_seen,f_write_seen,next_stat;
  logic [ROWS-1:0][3:0] f_score_seen;
  logic read_legal,write_legal,quant_legal,exp_legal,read_fire,read_pop,p_pop;
  logic [1:0] read_count;
  logic read_pending,rptr,wptr;
  unit_acc_read_t read_request;
  unit_acc_reply_t replies[0:1];
  localparam int STREAM_BITS=$clog2(4*ROWS+1);
  logic [STREAM_BITS-1:0] received_p,consumed_p;
  logic p_held;
  fp4_stream_t p_q;
  logic v_start,f_start,all_reads,all_writes,all_score_reads;
  logic [PAIRS-1:0] pair_prefix;
  always_comb begin
    pair_prefix='0;for(int i=0;i<PAIRS;i++)pair_prefix[i]=i<pairs_for_rows(rows);
    all_reads=1;all_writes=1;all_score_reads=1;
    for(int n=0;n<TILE;n++)begin all_reads&=read_seen[n]==pair_prefix;all_writes&=write_seen[n]==pair_prefix;end
    for(int r=0;r<ROWS;r++)if(r<rows)all_score_reads&=f_score_seen[r]=='1;
    read_legal=v_running&&acc_req.token==v_current.token&&acc_req.pair_idx<pairs_for_rows(rows)&&acc_req.nt<TILE;
    if(v_current.function_id==UNIT_QK_POST)read_legal&=acc_req.sel==(v_current.block_id[0]?ACC_FACC_B:ACC_FACC_A)&&acc_req.nt==0;
    else read_legal&=(v_current.function_id==UNIT_OACC_SCALE||v_current.function_id==UNIT_AFIN_QUANT)&&acc_req.sel==ACC_OACC;
    if(acc_req.pair_idx<PAIRS&&acc_req.nt<TILE)read_legal&=!read_seen[acc_req.nt][acc_req.pair_idx];
    write_legal=v_running&&v_current.function_id==UNIT_OACC_SCALE&&acc_write.token==v_current.token&&
      acc_write.payload.sel==ACC_OACC&&int'(acc_write.payload.addr)/TILE<pairs_for_rows(rows)&&
      acc_write.payload.row_valid==row_mask_for_rows(rows,int'(acc_write.payload.addr)/TILE);
    next_write=write_seen;
    if(int'(acc_write.payload.addr)/TILE<PAIRS)begin
      write_legal&=!write_seen[acc_write.payload.addr%TILE][acc_write.payload.addr/TILE];
      next_write[acc_write.payload.addr%TILE][acc_write.payload.addr/TILE]=1;
    end
    quant_legal=v_running&&quant.token==v_current.token&&quant.mask!=0;
    if(v_current.function_id==UNIT_P_POST)quant_legal&=quant.kind==LOCAL_P&&quant.tile==0&&quant.set_id==v_current.block_id[0]&&
      quant.content_version==16'(int'(v_current.block_id)+1);
    else quant_legal&=v_current.function_id==UNIT_AFIN_QUANT&&quant.kind==LOCAL_O&&quant.tile<TILE&&quant.set_id==0&&
      quant.content_version==context_job.output_version;
    next_quant=quant_seen;
    if(quant.tile<TILE)begin
      for(int h=0;h<A_INPUT_ROWS;h++)if(quant.mask[h])begin
        if(quant.row[h]>=rows)quant_legal=0;
        else begin if(next_quant[quant.tile][quant.row[h]])quant_legal=0;next_quant[quant.tile][quant.row[h]]=1;end
        for(int j=0;j<h;j++)if(quant.mask[j]&&quant.row[h]%A_INPUT_ROWS==quant.row[j]%A_INPUT_ROWS)quant_legal=0;
      end
    end else quant_legal=0;
    v_auth=v_running&&v_ws.token==v_current.token&&v_ws.block_id==v_current.block_id;
    case(v_current.function_id)
      UNIT_QK_POST:v_auth&=v_ws.write?(v_ws.kind==WS_SCORE||v_ws.kind==WS_M||v_ws.kind==WS_AA):v_ws.kind==WS_M;
      UNIT_P_POST:v_auth&=v_ws.write?v_ws.kind==WS_L:(v_ws.kind==WS_ALPHA||v_ws.kind==WS_L);
      UNIT_OACC_SCALE:v_auth&=!v_ws.write&&v_ws.kind==WS_ALPHA;
      UNIT_AFIN_QUANT:v_auth&=!v_ws.write&&v_ws.kind==WS_RECIP;
      default:v_auth=0;
    endcase
    next_stat=v_ws.kind==WS_M?m_seen:(v_ws.kind==WS_AA?aa_seen:l_seen);
    if(v_ws.write)begin
      if(v_ws.kind==WS_SCORE)begin
        v_auth&=v_ws.index%2==0&&v_ws.row_mask==row_mask_for_rows(rows,int'(v_ws.index)/2);
        for(int h=0;h<ROW_LANES;h++)if(v_ws.row_mask[h]&&int'(v_ws.index)+h<ROWS&&score_seen[int'(v_ws.index)+h])v_auth=0;
      end else for(int i=0;i<TILE;i++)if(v_ws.mask[i]&&int'(v_ws.index)+i<ROWS)begin
        if(next_stat[int'(v_ws.index)+i])v_auth=0;next_stat[int'(v_ws.index)+i]=1;
      end
    end
    f_auth=f_running&&f_ws.token==f_current.token&&f_ws.block_id==f_current.block_id;
    case(f_current.function_id)
      UNIT_ALPHA_EXP:f_auth&=f_ws.write?f_ws.kind==WS_ALPHA:f_ws.kind==WS_AA;
      UNIT_P_EXP:f_auth&=!f_ws.write&&(f_ws.kind==WS_SCORE||f_ws.kind==WS_M);
      UNIT_RECIP:f_auth&=f_ws.write?f_ws.kind==WS_RECIP:f_ws.kind==WS_L;
      default:f_auth=0;
    endcase
    if(f_ws.write)for(int i=0;i<4;i++)if(f_ws.mask[i]&&int'(f_ws.index)+i<ROWS&&f_write_seen[int'(f_ws.index)+i])f_auth=0;
    if(f_ws.kind==WS_SCORE)begin
      f_auth&=f_ws.mask=='1;
      if(f_ws.index<ROWS&&f_score_seen[f_ws.index][f_ws.group_id])f_auth=0;
    end
    exp_legal=f_running&&f_current.function_id==UNIT_P_EXP&&v_running&&v_current.function_id==UNIT_P_POST&&
      f_current.block_id==v_current.block_id&&exp.token==f_current.token&&exp.row==int'(received_p)/4&&
      exp.group_id==int'(received_p)%4&&exp.mask=='1&&received_p<4*int'(rows)&&exp.last==(int'(received_p)+1==4*int'(rows));
    v_drained=read_count==0&&!read_pending&&!raw_v_out_valid;
    case(v_current.function_id)
      UNIT_QK_POST:v_drained&=read_seen[0]==pair_prefix&&score_seen==row_prefix(rows)&&m_seen==row_prefix(rows)&&aa_seen==row_prefix(rows);
      UNIT_P_POST:v_drained&=consumed_p==4*int'(rows)&&quant_seen[0]==row_prefix(rows)&&l_seen==row_prefix(rows)&&!p_held;
      UNIT_OACC_SCALE:v_drained&=all_reads&&all_writes;
      UNIT_AFIN_QUANT:begin v_drained&=all_reads&&o_complete;for(int n=0;n<TILE;n++)v_drained&=quant_seen[n]==row_prefix(rows);end
      default:v_drained=0;
    endcase
    f_drained=!raw_f_out_valid&&f_read_seen==row_prefix(rows);
    case(f_current.function_id)
      UNIT_ALPHA_EXP:f_drained&=f_write_seen==row_prefix(rows)&&ws.alpha_complete[f_current.block_id[0]]&&ws.alpha_block[f_current.block_id[0]]==f_current.block_id;
      UNIT_P_EXP:f_drained&=all_score_reads&&received_p==4*int'(rows);
      UNIT_RECIP:f_drained&=f_write_seen==row_prefix(rows)&&ws.stat_complete[3]&&ws.stat_block[3]==f_current.block_id;
      default:f_drained=0;
    endcase
  end
  // Interface conversion does not depend on the workspace ready/status return.
  // Publish each packed object once, avoiding transient field feedback.
  always_comb begin
    workspace_req_t request;
    request='0;request.token=f_ws.token;request.kind=f_ws.kind;request.bank=f_ws.bank;request.write=f_ws.write;
    request.block_id=f_ws.block_id;request.index=f_ws.index;request.group_id=f_ws.group_id;request.row_mask=1;
    request.mask=f_ws.kind==WS_SCORE?TILE'(f_ws.mask)<<(int'(f_ws.group_id)*4):TILE'(f_ws.mask);
    for(int i=0;i<4;i++)request.data[0][i]=f_ws.data[i];
    f_wide=request;
  end
  always_comb begin
    sfu_workspace_rsp_t response;
    response='0;response.token=f_wide_reply.token;response.kind=f_wide_reply.kind;
    response.block_id=f_wide_reply.block_id;response.index=f_wide_reply.index;response.group_id=f_wide_reply.group_id;
    for(int i=0;i<4;i++)begin
      int n;n=f_wide_reply.kind==WS_SCORE?int'(f_wide_reply.group_id)*4+i:i;
      if(n<TILE)begin
        response.mask[i]=f_wide_reply.mask[n]&&(f_wide_reply.kind!=WS_SCORE||f_wide_reply.row_mask[0]);
        response.data[i]=response.mask[i]?f_wide_reply.data[0][n]:32'd0;
      end
    end
    f_ws_out=response;
  end
  assign protocol_error=error_q||v_error||f_error||workspace_error;
  assign idle=!v_active&&!f_active&&!v_prepared&&!f_prepared&&!p_held&&read_count==0&&!read_pending&&!raw_v_out_valid&&!raw_f_out_valid;
  assign v_start=v_go_valid&&v_go_ready;assign f_start=f_go_valid&&f_go_ready;
  assign raw_rd_valid=acc_req_valid&&read_legal&&int'(read_count)+int'(read_pending)<2+(read_pop?1:0)&&!protocol_error;
  assign raw_rd_sel=acc_req.sel;
  assign raw_rd_addr=acc_req.sel==ACC_OACC?10'(int'(acc_req.pair_idx)*TILE+int'(acc_req.nt)):10'(acc_req.pair_idx);
  assign acc_req_ready=read_legal&&int'(read_count)+int'(read_pending)<2+(read_pop?1:0)&&raw_rd_ready&&!protocol_error;
  assign read_fire=acc_req_valid&&acc_req_ready;
  assign acc_out_valid=read_count!=0&&!reset&&!clear&&!protocol_error;
  assign read_pop=acc_out_valid&&acc_out_ready;
  always_comb begin acc_out='0;if(read_count!=0)acc_out=replies[rptr];end
  assign raw_wr_valid=acc_write_valid&&write_legal&&!protocol_error;
  assign raw_write=acc_write.payload;
  assign acc_write_ready=write_legal&&raw_wr_ready&&!protocol_error;
  assign store_valid=quant_valid&&quant_legal&&!protocol_error;
  assign quant_ready=quant_legal&&store_ready&&!protocol_error;
  always_comb begin store=quant;store.token=context_token;end
  assign exp_ready=exp_legal&&(!p_held||p_ready)&&!protocol_error;
  assign p_valid=p_held&&v_running&&v_current.function_id==UNIT_P_POST&&!protocol_error;
  assign p_pop=p_valid&&p_ready;
  assign p=p_q;
  assign v_ws_ready=v_auth&&v_raw_ready&&!protocol_error;
  assign f_ws_ready=f_auth&&f_raw_ready&&!protocol_error;
  assign v_ws_out_valid=raw_v_out_valid&&!protocol_error;
  assign f_ws_out_valid=raw_f_out_valid&&!protocol_error;
  assign p_fence=v_running&&v_current.function_id==UNIT_P_POST&&pbuf_complete[v_current.block_id[0]]&&
    pbuf_object[v_current.block_id[0]].block_id==v_current.block_id&&ws.stat_complete[2]&&ws.stat_block[2]==v_current.block_id&&
    consumed_p==4*int'(rows)&&!p_held;
  assign p_fence_block=v_current.block_id;
  assign scale_fence=v_running&&v_current.function_id==UNIT_OACC_SCALE&&all_reads&&read_count==0&&!read_pending&&
    (all_writes||(raw_wr_valid&&raw_wr_ready&&next_write=={TILE{pair_prefix}}));
  assign scale_fence_block=v_current.block_id;
  dea8_unit_control vector_control(.clk,.reset,.clear,.offer_valid(v_offer_valid),.offer_ready(v_offer_ready),.offer(v_offer),
    .cmd_valid(v_cmd_valid),.cmd_ready(v_cmd_ready),.cmd(v_cmd),.armed_valid(v_armed_valid),.armed_ready(v_armed_ready),.armed_token(v_armed_token),
    .go_valid(v_go_valid),.go_ready(v_go_ready),.go_token(v_go_token),.grant(v_grant),
    .done_valid(v_done_valid),.done_ready(v_done_ready),.done_token(v_done_token),.done_function(v_done_function),.done_error(v_done_error),.drained(v_drained),
    .active(v_active),.running(v_running),.prepared_valid(v_prepared),.current(v_current),.prepared(v_prepared_cmd),
    .retired_valid(v_retired),.retired(v_completed),.protocol_error(v_error));
  dea8_unit_control function_control(.clk,.reset,.clear,.offer_valid(f_offer_valid),.offer_ready(f_offer_ready),.offer(f_offer),
    .cmd_valid(f_cmd_valid),.cmd_ready(f_cmd_ready),.cmd(f_cmd),.armed_valid(f_armed_valid),.armed_ready(f_armed_ready),.armed_token(f_armed_token),
    .go_valid(f_go_valid),.go_ready(f_go_ready),.go_token(f_go_token),.grant(f_grant),
    .done_valid(f_done_valid),.done_ready(f_done_ready),.done_token(f_done_token),.done_function(f_done_function),.done_error(f_done_error),.drained(f_drained),
    .active(f_active),.running(f_running),.prepared_valid(f_prepared),.current(f_current),.prepared(f_prepared_cmd),
    .retired_valid(f_retired),.retired(f_completed),.protocol_error(f_error));
  dea8_workspace workspace(.clk,.reset,.clear,.begin_job,.rows,
    .score_begin(v_offer_valid&&v_offer_ready&&v_offer.function_id==UNIT_QK_POST),.score_begin_block(v_offer.block_id),
    .alpha_begin(f_offer_valid&&f_offer_ready&&f_offer.function_id==UNIT_ALPHA_EXP),.alpha_begin_block(f_offer.block_id),
    .v_valid(v_ws_valid&&v_auth),.v_ready(v_raw_ready),.v_req(v_ws),.v_out_valid(raw_v_out_valid),.v_out_ready(v_ws_out_ready),.v_out(v_ws_out),
    .f_valid(f_ws_valid&&f_auth),.f_ready(f_raw_ready),.f_req(f_wide),.f_out_valid(raw_f_out_valid),.f_out_ready(f_ws_out_ready),.f_out(f_wide_reply),
    .status(ws),.protocol_error(workspace_error));
  always_ff @(posedge clk)begin
    if(reset||clear||begin_job)begin
      read_count<=0;read_pending<=0;rptr<=0;wptr<=0;error_q<=0;p_held<=0;received_p<=0;consumed_p<=0;
      read_seen<=0;write_seen<=0;quant_seen<=0;score_seen<=0;m_seen<=0;aa_seen<=0;l_seen<=0;f_score_seen<=0;f_read_seen<=0;f_write_seen<=0;
    end else begin
      if(v_start)begin read_seen<=0;write_seen<=0;quant_seen<=0;score_seen<=0;m_seen<=0;aa_seen<=0;l_seen<=0;consumed_p<=0;end
      if(f_start)begin f_read_seen<=0;f_write_seen<=0;f_score_seen<=0;if(f_current.function_id==UNIT_P_EXP)received_p<=0;end
      read_pending<=read_fire;
      if(raw_out_valid!=read_pending)error_q<=1;
      case({read_pending,read_pop})
        2'b10:read_count<=read_count+1'b1;
        2'b01:read_count<=read_count-1'b1;
        default:;
      endcase
      if(read_fire)begin read_request<=acc_req;read_seen[acc_req.nt][acc_req.pair_idx]<=1;end
      if(read_pending&&raw_out_valid)begin
        unit_acc_reply_t reply;reply='0;reply.request=read_request;reply.mask=row_mask_for_rows(rows,read_request.pair_idx);reply.data=raw_data;
        replies[wptr]<=reply;wptr<=!wptr;
      end
      if(read_pop)rptr<=!rptr;
      if(acc_req_valid&&!read_legal||acc_write_valid&&!write_legal||quant_valid&&!quant_legal||v_ws_valid&&!v_auth||f_ws_valid&&!f_auth||exp_valid&&!exp_legal)error_q<=1;
      if(acc_write_valid&&acc_write_ready)write_seen<=next_write;
      if(quant_valid&&quant_ready)quant_seen<=next_quant;
      if(v_ws_valid&&v_ws_ready&&v_ws.write)begin
        if(v_ws.kind==WS_SCORE)begin
          for(int r=0;r<ROW_LANES;r++)if(v_ws.row_mask[r])score_seen[int'(v_ws.index)+r]<=1;
        end else case(v_ws.kind) WS_M:m_seen<=next_stat;WS_AA:aa_seen<=next_stat;WS_L:l_seen<=next_stat;default:;endcase
      end
      if(f_ws_valid&&f_ws_ready)begin
        if(f_ws.kind==WS_SCORE)f_score_seen[f_ws.index][f_ws.group_id]<=1;
        else for(int i=0;i<4;i++)if(f_ws.mask[i])begin
          if(f_ws.write)f_write_seen[int'(f_ws.index)+i]<=1;
          else f_read_seen[int'(f_ws.index)+i]<=1;
        end
      end
      if(p_pop)begin p_held<=0;consumed_p<=consumed_p+1'b1;end
      if(exp_valid&&exp_ready)begin
        fp4_stream_t entry;entry=exp;entry.token=v_current.token;p_q<=entry;p_held<=1;received_p<=received_p+1'b1;
      end
    end
  end
endmodule
