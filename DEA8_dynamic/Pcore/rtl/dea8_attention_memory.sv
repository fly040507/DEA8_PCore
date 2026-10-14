import pcore_pkg::*;

// Lifetime only. Q is bound at Attention start; P generations are acquired
// before producer use, bound before reads, and released after true PV retirement.
module dea8_attention_memory (
  input logic clk,reset,clear,start,
  input pcore_job_t context_job,input job_token_t context_token,input logic [ROW_COUNT_BITS-1:0] rows,
  input logic v_offer_valid,v_offer_ready,input unit_cmd_t v_offer,
  input logic work_valid,output logic work_ready,input compute_job_t work,
  input logic matrix_done,input compute_job_t completed,
  input logic q_release_request,o_acquire_request,
  input logic qoz_active,qoz_complete,input local_object_t qoz_object,
  input logic [1:0] pbuf_active,pbuf_complete,pbuf_bound,input local_object_t pbuf_object[0:1],
  output logic acquire_valid,input logic acquire_ready,output logic acquire_set,output local_object_t acquire_object,
  output logic bind_valid,input logic bind_ready,output logic bind_set,output local_object_t bind_object,
  output logic release_valid,input logic release_ready,output local_release_t release_request,
  output logic q_released,o_acquired,empty,protocol_error
);
  logic active,p_pending,bind_pending;
  logic [5:0] acquire_block,bind_block;
  logic [6:0] next_release;
  logic [KV_BLOCKS-1:0] pv_retired;
  function automatic logic [$bits(local_object_t)-1:0] object_for(input local_kind_e kind,input int block_id,
    input pcore_job_t parent,input logic [ROW_COUNT_BITS-1:0] row_count);
    return {kind,(kind==LOCAL_P?16'(block_id+1):(kind==LOCAL_Q?parent.input_version:parent.output_version)),
      parent.data_context,parent.profile_id,parent.profile_version,parent.head,row_count,
      6'(kind==LOCAL_P?block_id:0)};
  endfunction
  assign work_ready=!bind_pending&&!reset&&!clear&&!protocol_error;
  assign acquire_valid=active&&!protocol_error&&(p_pending||(o_acquire_request&&q_released&&!o_acquired));
  assign acquire_set=p_pending?acquire_block[0]:1'b0;
  assign acquire_object=p_pending?object_for(LOCAL_P,acquire_block,context_job,rows):object_for(LOCAL_O,0,context_job,rows);
  assign bind_set=bind_block[0];assign bind_object=object_for(LOCAL_P,bind_block,context_job,rows);
  assign bind_valid=active&&bind_pending&&pbuf_active[bind_set]&&pbuf_complete[bind_set]&&!pbuf_bound[bind_set]&&
    pbuf_object[bind_set]==bind_object&&!protocol_error;
  always_comb begin
    release_request='0;release_request.token=context_token;
    if(q_release_request&&!q_released)begin release_request.kind=LOCAL_Q;release_request.content_version=context_job.input_version;end
    else begin release_request.kind=LOCAL_P;release_request.set_id=next_release[0];release_request.content_version=16'(int'(next_release)+1);end
    release_valid=active&&!protocol_error&&q_release_request&&!q_released;
    if(next_release<KV_BLOCKS&&!(q_release_request&&!q_released))
      release_valid=active&&!protocol_error&&pv_retired[next_release];
  end
  assign empty=!p_pending&&!bind_pending&&next_release==KV_BLOCKS;
  always_ff @(posedge clk)begin
    if(reset||clear)begin active<=0;p_pending<=0;bind_pending<=0;acquire_block<=0;bind_block<=0;
      next_release<=0;pv_retired<=0;q_released<=0;o_acquired<=0;protocol_error<=0;end
    else begin
      if(start)begin active<=1;p_pending<=0;bind_pending<=0;next_release<=0;pv_retired<=0;q_released<=0;o_acquired<=0;end
      if(v_offer_valid&&v_offer_ready&&v_offer.function_id==UNIT_QK_POST)begin
        if(p_pending)protocol_error<=1;else begin p_pending<=1;acquire_block<=v_offer.block_id;end
      end
      if(acquire_valid&&acquire_ready)begin if(p_pending)p_pending<=0;else o_acquired<=1;end
      if(work_valid&&work_ready&&work.role==ROLE_V)begin bind_pending<=1;bind_block<=work.block_id;end
      if(bind_valid&&bind_ready)bind_pending<=0;
      if(matrix_done&&completed.role==ROLE_V)begin
        if(completed.block_id>=KV_BLOCKS||pv_retired[completed.block_id])protocol_error<=1;
        else pv_retired[completed.block_id]<=1;
      end
      if(release_valid&&release_ready)begin
        if(release_request.kind==LOCAL_Q)q_released<=1;
        else next_release<=next_release+1'b1;
      end
    end
  end
endmodule
