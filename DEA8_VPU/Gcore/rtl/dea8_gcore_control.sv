module dea8_gcore_control (
  input logic clk,reset,
  input logic config_valid,
  output logic config_ready,
  input gcore_pkg::gcore_context_t config_data,
  output logic config_done_valid,
  input logic config_done_ready,
  output gcore_pkg::gcore_status_e config_status,
  output gcore_pkg::gcore_context_t active_context,
  output logic context_valid,
  input logic preloaded_valid,
  output logic preloaded_ready,
  input gcore_pkg::gcore_preloaded_t preloaded,
  output logic preloaded_done_valid,
  input logic preloaded_done_ready,
  output gcore_pkg::gcore_status_e preloaded_status,
  input logic layer_valid,
  output logic layer_ready,
  input gcore_pkg::gcore_layer_t layer_data,
  output logic layer_done_valid,
  input logic layer_done_ready,
  output gcore_pkg::gcore_status_e layer_status,
  input logic cmd_valid,
  output logic cmd_ready,
  input gcore_pkg::gcore_cmd_t cmd,
  output logic done_valid,
  input logic done_ready,
  output gcore_pkg::gcore_done_t done,
  output logic [gcore_pkg::SERVICES-1:0] service_cmd_valid,
  input logic [gcore_pkg::SERVICES-1:0] service_cmd_ready,
  output gcore_pkg::gcore_cmd_t service_cmd,
  input logic [gcore_pkg::SERVICES-1:0] service_done_valid,
  output logic [gcore_pkg::SERVICES-1:0] service_done_ready,
  input gcore_pkg::gcore_done_t service_done [gcore_pkg::SERVICES],
  input logic [gcore_pkg::SERVICES-1:0] service_fault,
  output logic [gcore_pkg::SERVICES-1:0] busy,
  output gcore_pkg::gcore_object_t objects [gcore_pkg::OBJECTS],
  input logic invalidate_valid,
  output logic invalidate_ready,
  input logic [gcore_pkg::OBJECTS-1:0] invalidate_mask,
  input logic kv_release_valid,
  output logic kv_release_ready,
  output logic kv_lease,
  input logic cancel_valid,
  output logic cancel_ready,
  output logic flush_valid,
  input logic [gcore_pkg::SERVICES-1:0] flush_ack,
  input logic external_flush_ack,
  output logic service_clear,
  output logic fault
);
  import gcore_pkg::*;
  import pcore_pkg::*;
  localparam int SLOTS=SERVICES+1, ERROR_SLOT=SERVICES;
  localparam int SLOT_BITS=$clog2(SLOTS);
  gcore_cmd_t commands_q [SERVICES];
  gcore_done_t pending_data [SLOTS];
  logic [SLOTS-1:0] pending_q;
  logic [SERVICES-1:0] finished_q;
  logic [SLOT_BITS-1:0] selected_q,rr_q;
  logic [SERVICES-1:0] ack_q;
  logic external_ack_q;
  logic occupied,any_object,resource_busy,config_legal,source_ok,preloaded_legal;
  logic bad_reply;
  gcore_status_e command_status;
  int target,destination,choice,scan_slot;

  function automatic int destination_index(input gcore_cmd_t c);
    case(c.opcode)
      GC_IMPORT_RESID,GC_RESIDUAL_APPLY:return OBJ_RESID;
      GC_PREFIX_LOAD:return OBJ_PREFIX;
      GC_NORM:return c.flags==NORM_FP32?-1:OBJ_XHAT;
      GC_KV_RX:return (c.pcore_op==OP_K_PROJ)?OBJ_K:OBJ_V;
      default:return -1;
    endcase
  endfunction
  function automatic bit object_matches(input int index,input logic [15:0] id,version);
    return objects[index].state==OBJECT_COMPLETE &&
      objects[index].object_id==id && objects[index].version==version;
  endfunction

  always_comb begin
    occupied=(|busy)||done_valid||(|pending_q);
    any_object=0;
    for(int o=0;o<OBJECTS;o++) if(objects[o].state!=OBJECT_INVALID) any_object=1;
    config_legal=config_data.gamma_online && config_data.quant_profile==0 && config_data.mask_profile==0;
    if(transfer_key_equal(config_data.k_transfer,config_data.v_transfer) ||
       transfer_key_equal(config_data.k_transfer,config_data.o_transfer) ||
       transfer_key_equal(config_data.k_transfer,config_data.down_transfer) ||
       transfer_key_equal(config_data.v_transfer,config_data.o_transfer) ||
       transfer_key_equal(config_data.v_transfer,config_data.down_transfer) ||
       transfer_key_equal(config_data.o_transfer,config_data.down_transfer)) config_legal=0;
    config_ready=!reset&&!fault&&!(|service_fault)&&!flush_valid&&!occupied&&!any_object&&!kv_lease&&
      !config_done_valid&&!preloaded_done_valid&&!layer_done_valid&&!layer_valid&&!preloaded_valid&&!cmd_valid&&!invalidate_valid&&!cancel_valid;
    preloaded_ready=!reset&&!fault&&!(|service_fault)&&!flush_valid&&!occupied&&!any_object&&!kv_lease&&
      context_valid&&!config_done_valid&&!preloaded_done_valid&&!layer_valid&&!layer_done_valid&&!invalidate_valid&&!cancel_valid;
    layer_ready=!reset&&!fault&&!(|service_fault)&&!flush_valid&&!occupied&&!kv_lease&&context_valid&&
      !config_done_valid&&!preloaded_done_valid&&!layer_done_valid&&!preloaded_valid&&!invalidate_valid&&!cancel_valid;
    preloaded_legal=preloaded.context_id==active_context.context_id &&
      preloaded.generation==active_context.generation && preloaded.prefix_version==active_context.prefix_version &&
      preloaded.residual_object!=preloaded.prefix_object;
    invalidate_ready=!reset&&!flush_valid&&!occupied&&!kv_lease&&!config_done_valid&&
      !preloaded_valid&&!preloaded_done_valid&&!layer_valid&&!layer_done_valid&&!cancel_valid;
    kv_release_ready=kv_lease&&!busy[S_KVB]&&!flush_valid&&!reset;
    cancel_ready=!reset&&!flush_valid;

    target=int'(cmd.opcode);
    destination=destination_index(cmd);
    command_status=GC_OK; resource_busy=0; source_ok=1;
    if(target>=SERVICES || (cmd.flags!=0&&!(cmd.opcode==GC_NORM&&cmd.flags==NORM_FP32)) || cmd.reserved!=0 || cmd.core_mask!=8'hff ||
        (cmd.opcode!=GC_NORM&&cmd.epsilon_fp32!=0)) command_status=GC_INVALID_CMD;
    else if(!context_valid || cmd.context_id!=active_context.context_id ||
        cmd.generation!=active_context.generation) command_status=GC_BAD_CONTEXT;
    else begin
      resource_busy=busy[target];
      case(cmd.opcode)
        GC_IMPORT_RESID: resource_busy|=busy[S_NORM]||busy[S_RESIDUAL];
        GC_PREFIX_LOAD: begin
          resource_busy|=kv_lease;
          if(cmd.dst_version!=active_context.prefix_version) command_status=GC_BAD_CONTEXT;
        end
        GC_NORM: begin
          resource_busy|=busy[S_IMPORT]||busy[S_RESIDUAL]||busy[S_XBC];
          source_ok=object_matches(OBJ_RESID,cmd.src_object,cmd.src_version);
          if(cmd.epsilon_fp32[31] || cmd.epsilon_fp32[30:0]==0 ||
              cmd.epsilon_fp32[30:23]==8'hff) command_status=GC_INVALID_CMD;
        end
        GC_XBC_RUN: begin
          resource_busy|=busy[S_NORM];
          source_ok=object_matches(OBJ_XHAT,cmd.src_object,cmd.src_version);
          if(xbc_tiles(cmd.pcore_op)==0) command_status=GC_INVALID_CMD;
        end
        GC_KV_RX: begin
          resource_busy|=kv_lease;
          if((cmd.pcore_op!=OP_K_PROJ&&cmd.pcore_op!=OP_V_PROJ) ||
              cmd.dst_version!=active_context.suffix_version) command_status=GC_BAD_CONTEXT;
        end
        GC_KVB_RUN: begin
          resource_busy|=busy[S_PREFIX]||busy[S_KV_RX]||kv_lease;
          source_ok=object_matches(OBJ_PREFIX,cmd.src_object,cmd.src_version) &&
            objects[OBJ_K].state==OBJECT_COMPLETE && objects[OBJ_V].state==OBJECT_COMPLETE &&
            objects[OBJ_K].version==active_context.suffix_version &&
            objects[OBJ_V].version==active_context.suffix_version;
          if(cmd.pcore_op!=OP_ATTENTION) command_status=GC_INVALID_CMD;
        end
        GC_RESIDUAL_APPLY: begin
          resource_busy|=busy[S_IMPORT]||busy[S_NORM];
          source_ok=object_matches(OBJ_RESID,cmd.src_object,cmd.src_version);
          if(cmd.pcore_op!=OP_O_PROJ&&cmd.pcore_op!=OP_DOWN_PROJ) command_status=GC_INVALID_CMD;
        end
        default:;
      endcase
      if(command_status==GC_OK&&!source_ok) command_status=GC_PRECONDITION;
      if(destination>=0) begin
        for(int o=0;o<OBJECTS;o++)
          if(o!=destination && objects[o].state!=OBJECT_INVALID &&
              objects[o].object_id==cmd.dst_object) command_status=GC_INVALID_CMD;
      end
    end
    // A token identifies one active command across all service classes.
    // Retaining busy until host retirement also covers stalled completions.
    for(int s=0;s<SERVICES;s++)
      if(busy[s] && cmd.command_id==commands_q[s].command_id &&
          cmd.generation==commands_q[s].generation) command_status=GC_INVALID_CMD;
    service_cmd=cmd; service_cmd_valid=0; cmd_ready=0;
    if(!reset&&!fault&&!(|service_fault)&&!flush_valid&&!cancel_valid&&!invalidate_valid&&
        !config_done_valid&&!preloaded_valid&&!preloaded_done_valid&&!layer_valid&&!layer_done_valid) begin
      if(command_status!=GC_OK)
        cmd_ready=!pending_q[ERROR_SLOT]&&!(done_valid&&selected_q==ERROR_SLOT);
      else if(!resource_busy) begin
        service_cmd_valid[target]=cmd_valid;
        cmd_ready=service_cmd_ready[target];
      end
    end
    service_done_ready=busy&~finished_q&{SERVICES{!reset&&!flush_valid&&!cancel_valid}};
    bad_reply=0;
    for(int s=0;s<SERVICES;s++)
      if(service_done_valid[s] && (!busy[s]||finished_q[s])) bad_reply=1;

    choice=-1; scan_slot=0;
    for(int offset=0;offset<SLOTS;offset++) begin
      scan_slot=(int'(rr_q)+offset)%SLOTS;
      if(choice<0&&pending_q[scan_slot]) choice=scan_slot;
    end
  end

  always_ff @(posedge clk) begin
    if(reset) begin
      active_context<='0; context_valid<=0; config_done_valid<=0; config_status<=GC_OK;
      preloaded_done_valid<=0; preloaded_status<=GC_OK;
      layer_done_valid<=0;layer_status<=GC_OK;
      done_valid<=0; done<='0; selected_q<=0; rr_q<=0;
      pending_q<=0; finished_q<=0; busy<=0; kv_lease<=0; fault<=0;
      flush_valid<=0; service_clear<=0; ack_q<=0; external_ack_q<=0;
      for(int s=0;s<SERVICES;s++) commands_q[s]<='0;
      for(int s=0;s<SLOTS;s++) pending_data[s]<='0;
      for(int o=0;o<OBJECTS;o++) objects[o]<='0;
    end else begin
      service_clear<=0;
      if(config_done_valid&&config_done_ready) config_done_valid<=0;
      if(preloaded_done_valid&&preloaded_done_ready) preloaded_done_valid<=0;
      if(layer_done_valid&&layer_done_ready)layer_done_valid<=0;
      if(layer_valid&&layer_ready)begin
        layer_done_valid<=1;layer_status<=GC_BAD_CONTEXT;
        if(layer_data.layer_id>=1&&layer_data.layer_id<=18&&
          layer_data.context_data.context_id==active_context.context_id&&
          layer_data.context_data.generation==active_context.generation&&
          layer_data.context_data.gamma_online&&layer_data.context_data.quant_profile==0&&
          layer_data.context_data.mask_profile==0&&
          !transfer_key_equal(layer_data.context_data.k_transfer,layer_data.context_data.v_transfer)&&
          !transfer_key_equal(layer_data.context_data.k_transfer,layer_data.context_data.o_transfer)&&
          !transfer_key_equal(layer_data.context_data.k_transfer,layer_data.context_data.down_transfer)&&
          !transfer_key_equal(layer_data.context_data.v_transfer,layer_data.context_data.o_transfer)&&
          !transfer_key_equal(layer_data.context_data.v_transfer,layer_data.context_data.down_transfer)&&
          !transfer_key_equal(layer_data.context_data.o_transfer,layer_data.context_data.down_transfer)&&
          objects[OBJ_RESID].state==OBJECT_COMPLETE&&
          ((layer_data.layer_id==1&&objects[OBJ_XHAT].state!=OBJECT_COMPLETE)||(objects[OBJ_XHAT].state==OBJECT_COMPLETE&&
            objects[OBJ_XHAT].object_id==layer_data.xhat_object&&
            objects[OBJ_XHAT].version==objects[OBJ_RESID].version))&&
          layer_data.prefix_object!=objects[OBJ_RESID].object_id&&
          layer_data.xhat_object!=objects[OBJ_RESID].object_id&&
          layer_data.prefix_object!=layer_data.xhat_object&&
          layer_data.k_object!=layer_data.v_object&&
          layer_data.k_object!=layer_data.prefix_object&&layer_data.v_object!=layer_data.prefix_object&&
          layer_data.k_object!=layer_data.xhat_object&&layer_data.v_object!=layer_data.xhat_object&&
          layer_data.k_object!=objects[OBJ_RESID].object_id&&layer_data.v_object!=objects[OBJ_RESID].object_id&&
          layer_data.attn_gamma!=layer_data.ffn_gamma&&
          (layer_data.layer_id==18||layer_data.next_attn_gamma!=layer_data.next_ffn_gamma)&&
          !layer_data.epsilon_fp32[31]&&layer_data.epsilon_fp32[30:0]!=0&&layer_data.epsilon_fp32[30:23]!=8'hff)begin
          layer_status<=GC_OK;active_context<=layer_data.context_data;
          objects[OBJ_PREFIX].object_id<=layer_data.prefix_object;
          objects[OBJ_PREFIX].version<=layer_data.context_data.prefix_version;
          objects[OBJ_PREFIX].state<=OBJECT_COMPLETE;
          objects[OBJ_K].state<=OBJECT_INVALID;objects[OBJ_V].state<=OBJECT_INVALID;
        end
      end
      if(preloaded_valid&&preloaded_ready) begin
        preloaded_done_valid<=1; preloaded_status<=preloaded_legal?GC_OK:GC_BAD_CONTEXT;
        if(preloaded_legal) begin
          objects[OBJ_RESID].object_id<=preloaded.residual_object;
          objects[OBJ_RESID].version<=preloaded.residual_version;
          objects[OBJ_RESID].state<=OBJECT_COMPLETE;
          objects[OBJ_PREFIX].object_id<=preloaded.prefix_object;
          objects[OBJ_PREFIX].version<=preloaded.prefix_version;
          objects[OBJ_PREFIX].state<=OBJECT_COMPLETE;
        end
      end
      if(config_valid&&config_ready) begin
        config_done_valid<=1; config_status<=config_legal?GC_OK:GC_BAD_CONTEXT;
        if(config_legal) begin active_context<=config_data; context_valid<=1; end
      end
      if(invalidate_valid&&invalidate_ready)
        for(int o=0;o<OBJECTS;o++) if(invalidate_mask[o]) objects[o].state<=OBJECT_INVALID;
      if(kv_release_valid&&kv_release_ready) kv_lease<=0;

      // Hold the chosen completion immutable through arbitrary host backpressure.
      if(done_valid&&done_ready) begin
        done_valid<=0;
        if(selected_q<SERVICES) begin busy[selected_q]<=0; finished_q[selected_q]<=0; end
      end
      if((!done_valid||done_ready)&&choice>=0) begin
        done<=pending_data[choice]; done_valid<=1; selected_q<=SLOT_BITS'(choice);
        pending_q[choice]<=0; rr_q<=SLOT_BITS'((choice+1)%SLOTS);
      end
      if(cmd_valid&&cmd_ready) begin
        if(command_status!=GC_OK) begin
          pending_data[ERROR_SLOT]<=make_done(cmd,command_status,0); pending_q[ERROR_SLOT]<=1;
        end else begin
          busy[target]<=1; finished_q[target]<=0; commands_q[target]<=cmd;
          if(destination>=0) begin
            objects[destination].object_id<=cmd.dst_object;
            objects[destination].version<=cmd.dst_version;
            objects[destination].state<=OBJECT_WRITING;
          end
          if(cmd.opcode==GC_KVB_RUN) kv_lease<=1;
        end
      end
      if((bad_reply||(|service_fault))&&!flush_valid) fault<=1;
      for(int s=0;s<SERVICES;s++) begin
        if(service_done_valid[s]&&service_done_ready[s]) begin
          finished_q[s]<=1; pending_q[s]<=1;
          if(!same_completion(service_done[s],commands_q[s]) ||
              (service_done[s].status==GC_OK&&service_done[s].completed_items!=expected_items(commands_q[s]))) begin
            pending_data[s]<=make_done(commands_q[s],GC_SOURCE_PROTOCOL,0); fault<=1;
            if(destination_index(commands_q[s])>=0)
              objects[destination_index(commands_q[s])].state<=OBJECT_INVALID;
          end else begin
            pending_data[s]<=service_done[s];
            if(destination_index(commands_q[s])>=0)
              objects[destination_index(commands_q[s])].state<=
                service_done[s].status==GC_OK?OBJECT_COMPLETE:OBJECT_INVALID;
            if(service_done[s].status!=GC_OK) fault<=1;
          end
        end
      end

      if(cancel_valid&&cancel_ready) begin flush_valid<=1; ack_q<=0; external_ack_q<=0; end
      if(flush_valid) begin
        ack_q<=ack_q|flush_ack; external_ack_q<=external_ack_q|external_flush_ack;
        if((ack_q|flush_ack)=='1 && (external_ack_q||external_flush_ack)) begin
          flush_valid<=0; service_clear<=1; fault<=0; context_valid<=0; kv_lease<=0;
          for(int o=0;o<OBJECTS;o++) objects[o].state<=OBJECT_INVALID;
          // Do not overwrite a completion that has already been made visible.
          for(int s=0;s<SERVICES;s++) if(busy[s]&&!finished_q[s]) begin
            pending_data[s]<=make_done(commands_q[s],GC_CANCELLED,0);
            pending_q[s]<=1; finished_q[s]<=1;
          end
        end
      end
    end
  end
endmodule
