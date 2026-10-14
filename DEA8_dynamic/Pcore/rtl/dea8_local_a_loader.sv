import pcore_pkg::*;

// Two descriptors decouple destination reservation, source requests and replies.
// The source managers provide two response credits; no second A tile is copied.
module dea8_local_a_loader (
  input logic clk,reset,clear,
  input logic cmd_valid,output logic cmd_ready,input local_load_cmd_t cmd,
  output logic desc_valid,input logic desc_ready,output a_slot_desc_t desc,
  output logic data_valid,input logic data_ready,output a3_beat_t data,
  output logic rd_valid,input logic rd_ready,output local_read_t rd,
  input logic out_valid,output logic out_ready,input local_response_t out_response,
  output logic empty,protocol_error,
  output logic consumed_valid,output a_slot_desc_t consumed
);
  local_load_cmd_t commands[0:1],request_cmd,descriptor_cmd,consume_cmd;
  logic [SEQ_BITS-1:0] serials[0:1],next_serial;
  logic [1:0] valid_q,sent_q,requested_q;
  logic wptr,dptr,rptr,cptr;
  logic [1:0] count;
  logic [A_GROUP_BITS-1:0] request_group,consume_group;
  logic cmd_legal,response_legal,last_response,cmd_fire,desc_fire,rd_fire,out_fire;
  always_comb begin
    request_cmd='0;descriptor_cmd='0;consume_cmd='0;
    for(int i=0;i<2;i++)begin
      if(rptr==i&&valid_q[i])request_cmd=commands[i];
      if(dptr==i&&valid_q[i])descriptor_cmd=commands[i];
      if(cptr==i&&valid_q[i])consume_cmd=commands[i];
    end
    cmd_legal=cmd.kind>=LOCAL_Q&&cmd.kind<=LOCAL_P&&cmd.destination.m_rows>0&&
      cmd.destination.m_rows<=ROWS&&cmd.destination.uses>0&&cmd.destination.uses<=TILE;
    response_legal=0;
    if(valid_q[cptr])response_legal=out_response.request.token==consume_cmd.destination.token&&
      out_response.request.request_seq==serials[cptr]&&out_response.request.kind==consume_cmd.kind&&
      out_response.request.set_id==consume_cmd.set_id&&out_response.request.content_version==consume_cmd.content_version&&
      out_response.request.tile==consume_cmd.tile&&out_response.request.group_idx==consume_group&&
      out_response.mask==a_group_mask(consume_cmd.destination.m_rows,consume_group);
    rd='0;rd.token=request_cmd.destination.token;rd.kind=request_cmd.kind;
    rd.set_id=request_cmd.set_id;rd.content_version=request_cmd.content_version;
    rd.request_seq=serials[rptr];rd.tile=request_cmd.tile;rd.group_idx=request_group;
    data='0;data.token=consume_cmd.destination.token;data.work_seq=consume_cmd.destination.work_seq;
    data.occurrence_seq=consume_cmd.destination.occurrence_seq;data.group_idx=consume_group;
    data.row_valid=out_response.mask;data.row=out_response.entry;
  end
  assign desc=descriptor_cmd.destination;
  assign desc_valid=!reset&&!clear&&!protocol_error&&valid_q[dptr]&&!sent_q[dptr];
  assign rd_valid=!reset&&!clear&&!protocol_error&&valid_q[rptr]&&!requested_q[rptr];
  assign data_valid=!reset&&!clear&&!protocol_error&&out_valid&&valid_q[cptr]&&sent_q[cptr]&&response_legal;
  assign out_ready=data_ready&&data_valid;
  assign out_fire=out_valid&&out_ready;
  assign last_response=out_fire&&(int'(consume_group)+1)*A_INPUT_ROWS>=int'(consume_cmd.destination.m_rows);
  assign cmd_ready=!reset&&!clear&&!protocol_error&&cmd_legal&&(count<2||last_response);
  assign cmd_fire=cmd_valid&&cmd_ready;
  assign desc_fire=desc_valid&&desc_ready;
  assign rd_fire=rd_valid&&rd_ready;
  assign empty=count==0;
  assign consumed_valid=last_response;
  assign consumed=consume_cmd.destination;
  always_ff @(posedge clk)begin
    if(reset||clear)begin
      valid_q<=0;sent_q<=0;requested_q<=0;wptr<=0;dptr<=0;rptr<=0;cptr<=0;count<=0;
      request_group<=0;consume_group<=0;next_serial<=0;protocol_error<=0;
      serials[0]<=0;serials[1]<=0;
    end else begin
      if(cmd_valid&&!cmd_legal)protocol_error<=1;
      if(out_valid&&!response_legal)protocol_error<=1;
      case({cmd_fire,last_response})
        2'b10:count<=count+1'b1;
        2'b01:count<=count-1'b1;
        default:;
      endcase
      if(desc_fire)begin sent_q[dptr]<=1;dptr<=!dptr;end
      if(rd_fire)begin
        if((int'(request_group)+1)*A_INPUT_ROWS>=int'(request_cmd.destination.m_rows))begin
          requested_q[rptr]<=1;request_group<=0;rptr<=!rptr;
        end else request_group<=request_group+1'b1;
      end
      if(out_fire)begin
        if(last_response)begin valid_q[cptr]<=0;consume_group<=0;cptr<=!cptr;end
        else consume_group<=consume_group+1'b1;
      end
      if(cmd_fire)begin
        commands[wptr]<=cmd;serials[wptr]<=next_serial;next_serial<=next_serial+1'b1;
        valid_q[wptr]<=1;sent_q[wptr]<=0;requested_q[wptr]<=0;wptr<=!wptr;
      end
    end
  end
endmodule
