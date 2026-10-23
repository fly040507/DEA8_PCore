module dea8_gcore_jobs (
  input logic clk,reset,clear,fault,
  input logic bind_valid,input gcore_pkg::gcore_layer_t bind_data,
  input gcore_pkg::gcore_object_t objects[gcore_pkg::OBJECTS],
  input logic kv_lease,input logic [gcore_pkg::SERVICES-1:0] service_busy,
  input logic job_valid,output logic job_ready,input gcore_pkg::gcore_job_t job,
  output logic job_done_valid,input logic job_done_ready,output gcore_pkg::gcore_job_done_t job_done,
  output logic owned,job_busy,bind_allowed,
  output gcore_pkg::gcore_xhat_t xhat_status,
  output logic cmd_valid,input logic cmd_ready,output gcore_pkg::gcore_cmd_t cmd,
  input logic done_valid,output logic done_ready,input gcore_pkg::gcore_done_t done,
  output logic fetch_valid,input logic fetch_ready,output gcore_pkg::gamma_fetch_t fetch,
  input logic fetch_done_valid,output logic fetch_done_ready,input gcore_pkg::gcore_status_e fetch_status,
  output gcore_pkg::gcore_job_t active_job
);
  import gcore_pkg::*;
  import pcore_pkg::*;
  typedef enum logic [3:0] {IDLE,START_FETCH,START_WAIT,NORM_SEND,NORM_WAIT,
    RX_SEND,XBC_SEND,IO_WAIT,KVB_SEND,KVB_WAIT,RES_SEND,RES_WAIT,NEXT_FETCH,DOWN_WAIT} state_e;
  state_e state;
  gcore_layer_t profile;
  logic profile_valid,fg_valid,bg_valid,recovering,failed;
  gcore_job_t foreground,background;
  gcore_job_done_t completions[2];
  logic [1:0] pending;
  logic selected;
  logic [31:0] clock_q,fg_start,bg_start;
  logic [15:0] sequence_q;
  gcore_cmd_t issued[SERVICES];
  logic [SERVICES-1:0] waiting;
  logic [2:0] phase;
  logic need_start,layer_finished,parameters_ready;
  logic legal_job,reply_good;

  assign active_job=foreground;
  assign job_busy=fg_valid||bg_valid;
  assign owned=job_busy||recovering||failed;
  assign bind_allowed=!owned&&!failed&&state==IDLE&&waiting==0&&(!profile_valid||layer_finished);
  assign job_done_valid=pending[selected];
  assign job_done=completions[selected];
  assign done_ready=owned;
  assign fetch_done_ready=bg_valid||state==START_WAIT;
  assign job_ready=profile_valid&&!fg_valid&&state==IDLE&&!recovering&&!failed&&!fault&&!reset&&!clear&&
    !(job.op==GJ_O&&bg_valid)&&!(job.op==GJ_O&&kv_lease);
  always_comb begin
    legal_job=job.context_id==profile.context_data.context_id&&job.generation==profile.context_data.generation&&
      job.layer_id==profile.layer_id&&!layer_finished&&
      (!bg_valid||job.command_id!=background.command_id);
    if(job.op==GJ_START)legal_job&=need_start&&profile.layer_id==1&&!bg_valid;
    else legal_job&=!need_start&&job.op==gcore_job_e'(phase);
    cmd='0;cmd.command_id=sequence_q;cmd.context_id=profile.context_data.context_id;
    cmd.generation=profile.context_data.generation;cmd.core_mask='1;cmd.pcore_op=OP_Q_PROJ;
    case(foreground.op)
      GJ_K:cmd.pcore_op=OP_K_PROJ;
      GJ_V:cmd.pcore_op=OP_V_PROJ;
      GJ_ATTENTION:cmd.pcore_op=OP_ATTENTION;
      GJ_O:cmd.pcore_op=OP_O_PROJ;
      GJ_GU:cmd.pcore_op=OP_GU;
      GJ_DOWN:cmd.pcore_op=OP_DOWN_PROJ;
      default:;
    endcase
    cmd_valid=0;
    if(state==NORM_SEND)begin
      cmd.opcode=GC_NORM;cmd.src_object=objects[OBJ_RESID].object_id;cmd.src_version=objects[OBJ_RESID].version;
      cmd.dst_object=profile.xhat_object;cmd.dst_version=cmd.src_version;cmd.epsilon_fp32=profile.epsilon_fp32;
      cmd.norm_param_id=foreground.op==GJ_START?profile.attn_gamma:
        (foreground.op==GJ_O?profile.ffn_gamma:(profile.layer_id==18?profile.final_gamma:profile.next_attn_gamma));
      if(foreground.op==GJ_DOWN&&profile.layer_id==18)cmd.flags=NORM_FP32;
      cmd_valid=1;
    end
    if(state==RX_SEND)begin
      cmd.opcode=GC_KV_RX;cmd.dst_object=foreground.op==GJ_K?profile.k_object:profile.v_object;
      cmd.dst_version=profile.context_data.suffix_version;cmd_valid=1;
    end
    if(state==XBC_SEND)begin
      cmd.opcode=GC_XBC_RUN;cmd.src_object=objects[OBJ_XHAT].object_id;
      cmd.src_version=objects[OBJ_XHAT].version;cmd_valid=1;
    end
    if(state==KVB_SEND)begin
      cmd.opcode=GC_KVB_RUN;cmd.src_object=objects[OBJ_PREFIX].object_id;
      cmd.src_version=objects[OBJ_PREFIX].version;cmd_valid=1;
    end
    if(state==RES_SEND)begin
      cmd.opcode=GC_RESIDUAL_APPLY;cmd.src_object=objects[OBJ_RESID].object_id;
      cmd.src_version=objects[OBJ_RESID].version;cmd.dst_object=cmd.src_object;
      cmd.dst_version=cmd.src_version+1'b1;cmd_valid=1;
    end
    cmd_valid&=!reset&&!clear&&!failed&&!fault;
    fetch_valid=(state==START_FETCH||state==NEXT_FETCH)&&!reset&&!clear&&!failed&&!fault;
    fetch='0;fetch.token={foreground.generation,foreground.command_id};
    fetch.context_id=foreground.context_id;fetch.generation=foreground.generation;
    fetch.layer_id=state==START_FETCH?profile.layer_id:(profile.layer_id==18?5'd18:profile.layer_id+1'b1);
    fetch.final_group=state==NEXT_FETCH&&profile.layer_id==18;
    fetch.param0=state==START_FETCH?profile.attn_gamma:(profile.layer_id==18?profile.final_gamma:profile.next_attn_gamma);
    fetch.param1=state==START_FETCH?profile.ffn_gamma:profile.next_ffn_gamma;
    reply_good=int'(done.opcode)<SERVICES;
    if(reply_good)reply_good=waiting[int'(done.opcode)]&&same_completion(done,issued[int'(done.opcode)])&&
      done.status==GC_OK&&done.completed_items==expected_items(issued[int'(done.opcode)]);
  end

  // Two bounded retirement slots: foreground and O's detached gamma transaction.
  // A slot remains owned until its completion is accepted by DEA8.
  always_ff @(posedge clk)begin
    if(reset)begin
      state<=IDLE;profile<='0;profile_valid<=0;fg_valid<=0;bg_valid<=0;recovering<=0;failed<=0;
      foreground<='0;background<='0;waiting<=0;pending<=0;selected<=0;
      clock_q<=0;fg_start<=0;bg_start<=0;sequence_q<=16'h8000;
      phase<=GJ_K;need_start<=1;layer_finished<=0;parameters_ready<=0;xhat_status<='0;
      for(int s=0;s<SERVICES;s++)issued[s]<='0;
      completions[0]<='0;completions[1]<='0;
    end else begin
      clock_q<=clock_q+1'b1;
      if(!job_done_valid||job_done_ready)begin
        if(pending[0]&&!(job_done_valid&&job_done_ready&&selected==0))selected<=0;
        else if(pending[1]&&!(job_done_valid&&job_done_ready&&selected==1))selected<=1;
      end
      if(job_done_valid&&job_done_ready)begin
        pending[selected]<=0;
        if(selected==0)fg_valid<=0;else bg_valid<=0;
      end
      if(bind_valid)begin
        profile<=bind_data;profile_valid<=1;phase<=GJ_K;layer_finished<=0;
        need_start<=objects[OBJ_XHAT].state!=OBJECT_COMPLETE;
        if(objects[OBJ_XHAT].state==OBJECT_COMPLETE)begin
          xhat_status.valid<=1;xhat_status.ffn<=0;xhat_status.layer_id<=bind_data.layer_id;
          xhat_status.context_id<=bind_data.context_data.context_id;xhat_status.generation<=bind_data.context_data.generation;
          xhat_status.object_id<=objects[OBJ_XHAT].object_id;xhat_status.version<=objects[OBJ_XHAT].version;
        end
      end
      if(job_valid&&job_ready)begin
        fg_valid<=1;foreground<=job;fg_start<=clock_q;
        if(!legal_job)begin
          completions[0].job<=job;completions[0].status<=GC_PRECONDITION;completions[0].cycles<=0;pending[0]<=1;
        end else case(job.op)
          GJ_START:state<=START_FETCH;
          GJ_K,GJ_V:state<=RX_SEND;
          GJ_Q,GJ_GU:state<=XBC_SEND;
          GJ_ATTENTION:state<=KVB_SEND;
          GJ_O,GJ_DOWN:begin state<=RES_SEND;xhat_status.valid<=0;end
        endcase
      end
      if(cmd_valid&&cmd_ready)begin
        issued[int'(cmd.opcode)]<=cmd;waiting[int'(cmd.opcode)]<=1;sequence_q<=sequence_q+1'b1;
        case(state)
          NORM_SEND:state<=NORM_WAIT;
          RX_SEND:state<=XBC_SEND;
          XBC_SEND:state<=IO_WAIT;
          KVB_SEND:state<=KVB_WAIT;
          RES_SEND:state<=RES_WAIT;
          default:;
        endcase
      end
      if(done_valid&&done_ready&&!recovering&&!clear&&!failed)begin
        if(!reply_good)begin
          failed<=1;state<=IDLE;waiting<=0;
          if(fg_valid&&!pending[0])begin
            completions[0].job<=foreground;completions[0].status<=done.status==GC_OK?GC_SOURCE_PROTOCOL:done.status;
            completions[0].cycles<=clock_q-fg_start;pending[0]<=1;
          end
        end else begin
          waiting[int'(done.opcode)]<=0;
          if(done.opcode==GC_RESIDUAL_APPLY)state<=foreground.op==GJ_DOWN?DOWN_WAIT:NORM_SEND;
          if(done.opcode==GC_NORM)begin
            xhat_status.valid<=!(foreground.op==GJ_DOWN&&profile.layer_id==18);
            xhat_status.ffn<=foreground.op==GJ_O;
            xhat_status.layer_id<=foreground.op==GJ_DOWN?profile.layer_id+1'b1:profile.layer_id;
            xhat_status.context_id<=foreground.context_id;xhat_status.generation<=foreground.generation;
            xhat_status.object_id<=profile.xhat_object;xhat_status.version<=objects[OBJ_RESID].version;
            if(foreground.op==GJ_O)begin phase<=GJ_GU;state<=NEXT_FETCH;end
            else begin
              completions[0].job<=foreground;completions[0].status<=GC_OK;completions[0].cycles<=clock_q-fg_start;
              pending[0]<=1;state<=IDLE;need_start<=0;
              if(foreground.op==GJ_DOWN)layer_finished<=1;
            end
          end
        end
      end
      if((state==IO_WAIT||state==KVB_WAIT)&&waiting==0&&!fault&&!failed&&!clear)begin
        completions[0].job<=foreground;completions[0].status<=GC_OK;completions[0].cycles<=clock_q-fg_start;
        pending[0]<=1;state<=IDLE;phase<=foreground.op==GJ_GU?GJ_DOWN:3'(foreground.op+1'b1);
      end
      if(fetch_valid&&fetch_ready)begin
        parameters_ready<=0;
        if(state==START_FETCH)state<=START_WAIT;
        else begin
          background<=foreground;bg_start<=fg_start;bg_valid<=1;fg_valid<=0;state<=IDLE;
        end
      end
      if(fetch_done_valid&&fetch_done_ready&&!clear&&!failed)begin
        parameters_ready<=fetch_status==GC_OK;
        if(state==START_WAIT)begin
          if(fetch_status==GC_OK)state<=NORM_SEND;
          else begin
            completions[0].job<=foreground;completions[0].status<=fetch_status;completions[0].cycles<=clock_q-fg_start;
            pending[0]<=1;state<=IDLE;failed<=1;
          end
        end else if(bg_valid)begin
          completions[1].job<=background;completions[1].status<=fetch_status;
          completions[1].cycles<=clock_q-bg_start;pending[1]<=1;
          if(fetch_status!=GC_OK)failed<=1;
        end
      end
      if(state==DOWN_WAIT&&parameters_ready)state<=NORM_SEND;
      if(recovering&&!clear&&service_busy==0)begin recovering<=0;waiting<=0;end
      if(fault&&!clear&&owned)begin
        failed<=1;state<=IDLE;
        if(fg_valid&&!pending[0])begin
          completions[0].job<=foreground;completions[0].status<=GC_SOURCE_PROTOCOL;
          completions[0].cycles<=clock_q-fg_start;pending[0]<=1;
        end
        if(bg_valid&&!pending[1])begin
          completions[1].job<=background;completions[1].status<=GC_SOURCE_PROTOCOL;
          completions[1].cycles<=clock_q-bg_start;pending[1]<=1;
        end
      end
      if(clear)begin
        state<=IDLE;profile_valid<=0;recovering<=owned;failed<=0;waiting<=0;
        xhat_status.valid<=0;parameters_ready<=0;need_start<=1;layer_finished<=0;
        if(fg_valid&&!pending[0])begin
          completions[0].job<=foreground;completions[0].status<=GC_CANCELLED;completions[0].cycles<=clock_q-fg_start;pending[0]<=1;
        end
        if(bg_valid&&!pending[1])begin
          completions[1].job<=background;completions[1].status<=GC_CANCELLED;completions[1].cycles<=clock_q-bg_start;pending[1]<=1;
        end
      end
    end
  end
endmodule
