import pcore_pkg::*;
import pcore_control_pkg::*;

module dea8_sfu_top #(
  parameter int ROPE_POSITION_BASE=816,
  parameter ROPE_FILE="units/rom/rope_wide.mem"
)(
  input logic clk,reset,flush,output logic flush_ack,
  input logic function_valid,output logic function_ready,input control_command_t function_cmd,
  output logic function_done_valid,input logic function_done_ready,output control_unit_done_t function_done,
  input logic function_data_valid,output logic function_data_ready,input control_fp_data_t function_data,
  output logic function_result_valid,input logic function_result_ready,output control_fp_data_t function_result,
  output logic function_mem_valid,input logic function_mem_ready,output control_memory_req_t function_mem_req,
  input logic function_mem_out_valid,output logic function_mem_out_ready,input control_memory_rsp_t function_mem_out,
  input logic rope_valid,output logic rope_ready,input control_rope_req_t rope_req,
  output logic rope_out_valid,input logic rope_out_ready,output control_rope_rsp_t rope_out,
  output logic protocol_error
);
  typedef enum logic [3:0] {IDLE,STAT_REQ,STAT_RSP,STAT_FETCH,STAT_LATCH,
    SCORE_FETCH,SCORE_LATCH,WORK,DONE} state_e;
  state_e state;
  control_command_t command_q;
  logic [1:0] mode;
  logic error_q,rope_error,rope_ack;
  logic [3:0] warmup;
  logic [1:0] flush_count;
  logic stats_ready,gelu_full,score_early;
  logic [5:0] stat_index,score_issued,score_received,gelu_received;
  logic [2:0] stat_issued,stat_received;
  logic [10:0] emitted,returned;
  logic [7:0] produced_groups,read_groups;
  logic [5:0] output_packet;
  logic [511:0] stat_hold,score_hold,gelu_hold,stat_ram_data,score_ram_data;
  logic [1023:0] packet_payload;
  logic [127:0] scalar_pack,group_write_data,group_read_data;
  logic stat_rd,score_rd,group_we,group_rd;
  logic [1:0] stat_read_address,score_read_address;
  logic packet_full,group_pending;
  logic [1:0] packet_full_q;
  logic [1023:0] packet_slots[2];
  logic reader_slot,pending_slot;
  logic [5:0] reader_packet;
  logic [3:0] reader_word,pending_word,reader_groups;
  logic pending_last;
  logic [3:0] packet_groups;
  logic [10:0] limit,retired_elements;
  logic [5:0] packet_limit;
  logic math_valid,math_take,math_out;
  logic [3:0][31:0] math_a,math_b,math_y;
  wire active=!(reset||flush)&&(&warmup);
  wire running=active&&state!=IDLE&&state!=DONE;
  wire p_mode=mode==1;
  wire scalar_mode=mode[1];
  wire score_request=running&&p_mode&&stats_ready&&score_issued<ROWS&&
    int'(score_issued)-int'(emitted/16)<4;
  wire score_response=running&&p_mode&&stats_ready&&state!=STAT_RSP&&function_mem_out_valid&&function_mem_out_ready;
  wire loading_stats=state==STAT_REQ||state==STAT_RSP;
  wire stat_response=loading_stats&&function_mem_out_valid&&function_mem_out_ready;
  wire packet_take=packet_full&&running&&
    ((mode==0||mode==3)?(function_mem_valid&&function_mem_ready):function_result_ready);

  always_ff @(posedge clk)begin
    if(reset||flush)warmup<=0;else warmup<={warmup[2:0],1'b1};
    if(reset||!flush)flush_count<=0;else if(flush_count!=3)flush_count<=flush_count+1;
  end
  assign flush_ack=flush&&(flush_count==3)&&rope_ack;
  assign protocol_error=error_q||rope_error;
  assign function_ready=active&&state==IDLE&&!protocol_error;
  assign function_done_valid=active&&state==DONE;
  assign function_done='{command:command_q,error:error_q};
  assign limit=(mode==0||mode==3)?11'(ROWS):11'(ROWS*TILE);
  assign packet_limit=p_mode?6'(PAIRS):mode==2?6'(ROWS):6'((ROWS+15)/16);
  assign retired_elements=p_mode?11'(output_packet*32):11'(output_packet*16);
  assign packet_full=packet_full_q[output_packet[0]];
  assign packet_payload=packet_slots[output_packet[0]];
  assign function_data_ready=running&&mode==2&&!gelu_full&&gelu_received<ROWS;
  assign math_valid=running&&state==WORK&&emitted<limit&&
    int'(emitted)-int'(retired_elements)<252&&(!scalar_mode||mode==3||gelu_full);
  assign math_take=math_valid;
  always_comb begin
    math_a='0;math_b='0;
    for(int j=0;j<4;j++)begin
      if(mode==0)math_a[j]=stat_hold[(int'(emitted%16)+j)*32+:32];
      if(mode==1)begin
        math_a[j]=score_hold[(int'(emitted%16)+j)*32+:32];
        math_b[j]=stat_hold[(int'((emitted/16)%16))*32+:32];
      end
    end
    if(mode==2)math_a[0]=gelu_hold[int'(emitted%16)*32+:32];
    if(mode==3)math_a[0]=stat_hold[int'(emitted%16)*32+:32];
  end
  dea8_sfu_arithmetic arithmetic(.clk,.active,.mode,.in_valid(math_valid),.a(math_a),.b(math_b),
    .gelu_lane(emitted[0]),.out_valid(math_out),.y(math_y));

  assign stat_rd=state==STAT_FETCH||(state==SCORE_FETCH&&(emitted/16)%16==0)||
    (state==WORK&&p_mode&&math_take&&emitted%16==8&&
     (emitted/16)%16==15&&score_received>emitted/16+1);
  assign stat_read_address=state==STAT_FETCH?2'(p_mode?0:emitted/16):
    state==SCORE_FETCH?2'((emitted/16)/16):2'((emitted/16+1)/16);
  dea8_sdp_ram #(.WIDTH(512),.DEPTH(4)) stat_cache(.clk,.rd_en(stat_rd),
    .wr_en(stat_response),.rd_addr(stat_read_address),.wr_addr(stat_index[5:4]),
    .wr_data(function_mem_out.data),.rd_data(stat_ram_data),.dbg_addr('0),.dbg_data());
  assign score_rd=(state==SCORE_FETCH&&score_received>emitted/16)||
    (state==WORK&&p_mode&&math_take&&emitted%16==8&&score_received>emitted/16+1);
  assign score_read_address=2'(state==SCORE_FETCH?emitted/16:emitted/16+1);
  dea8_sdp_ram #(.WIDTH(512),.DEPTH(4)) score_fifo(.clk,.rd_en(score_rd),
    .wr_en(score_response),.rd_addr(score_read_address),.wr_addr(score_received[1:0]),
    .wr_data(function_mem_out.data),.rd_data(score_ram_data),.dbg_addr('0),.dbg_data());

  always_comb begin
    group_write_data=math_y;
    if(scalar_mode)begin
      group_write_data=scalar_pack;
      group_write_data[(returned%4)*32+:32]=math_y[0];
    end
  end
  assign group_we=running&&math_out&&(!scalar_mode||returned%4==3||returned+1==limit);
  assign packet_groups=p_mode?(output_packet==PAIRS-1?4:8):
    mode==2?4:(output_packet==3?1:4);
  // Two bounded assembly slots overlap reading the next packet with retiring
  // the previous one. The BRAM reader issues one group/cycle, including across
  // packet boundaries; no read-all/then-send bubble per two-row P packet.
  assign reader_groups=p_mode?(reader_packet==PAIRS-1?4:8):
    mode==2?4:(reader_packet==3?1:4);
  assign group_rd=running&&reader_packet<packet_limit&&
    !packet_full_q[reader_slot]&&produced_groups>read_groups;
  dea8_sdp_ram #(.WIDTH(128),.DEPTH(64)) output_fifo(.clk,.rd_en(group_rd),.wr_en(group_we),
    .rd_addr(read_groups[5:0]),.wr_addr(produced_groups[5:0]),.wr_data(group_write_data),
    .rd_data(group_read_data),.dbg_addr('0),.dbg_data());
  always_comb begin
    function_result='0;function_result.job=command_q.job;function_result.token=command_q.token;
    function_result.tile=command_q.tile;function_result.index=output_packet;
    function_result.first=packet_payload[511:0];
    function_result.second=p_mode&&output_packet<PAIRS-1?packet_payload[1023:512]:'0;
    function_result.vector_valid=p_mode?row_mask(output_packet):2'b01;
    function_result.last=output_packet==packet_limit-1;function_result.token_mask='1;
    function_result_valid=running&&packet_full&&(mode==1||mode==2);
    function_mem_req='0;function_mem_req.token=command_q.token;
    function_mem_req.bank=(mode==0||mode==1)?command_q.tile[0]:0;
    function_mem_req.index=6'(stat_issued*TILE);
    function_mem_req.mask=stat_issued==3?16'h0007:16'hffff;
    function_mem_req.buffer_id=mode==0?WORK_AA:mode==1?WORK_M:WORK_L;
    function_mem_valid=running&&loading_stats&&stat_issued<4;
    if(score_request)begin
      function_mem_valid=1;function_mem_req.buffer_id=WORK_SCORE;
      function_mem_req.index=score_issued;function_mem_req.mask='1;
    end
    if(packet_full&&(mode==0||mode==3))begin
      function_mem_valid=running;function_mem_req.write=1;
      function_mem_req.buffer_id=mode==0?WORK_ALPHA:WORK_RECIP;
      function_mem_req.index=6'(output_packet*16);
      function_mem_req.mask=output_packet==3?16'h0007:16'hffff;
      function_mem_req.data=packet_payload[511:0];
    end
    if(function_mem_req.buffer_id!=WORK_ALPHA&&function_mem_req.buffer_id!=WORK_SCORE)
      function_mem_req.bank=0;
    function_mem_out_ready=running&&(loading_stats||
      (p_mode&&stats_ready&&score_received<score_issued));
  end
  dea8_sfu_rope_rom #(.POSITION_BASE(ROPE_POSITION_BASE),.ROM_FILE(ROPE_FILE)) rope(
    .clk,.reset,.flush,.flush_ack(rope_ack),.req_valid(rope_valid),.req_ready(rope_ready),.req(rope_req),
    .rsp_valid(rope_out_valid),.rsp_ready(rope_out_ready),.rsp(rope_out),.protocol_error(rope_error));

  always_ff @(posedge clk)begin
    if(reset||flush)begin
      state<=IDLE;command_q<='0;mode<=0;error_q<=0;stats_ready<=0;
      stat_index<=0;stat_issued<=0;stat_received<=0;score_issued<=0;score_received<=0;gelu_received<=0;
      emitted<=0;returned<=0;produced_groups<=0;read_groups<=0;output_packet<=0;
      packet_full_q<=0;group_pending<=0;reader_slot<=0;reader_packet<=0;reader_word<=0;
      pending_slot<=0;pending_word<=0;pending_last<=0;
      gelu_full<=0;score_early<=0;scalar_pack<=0;
    end else begin
      group_pending<=group_rd;
      if(function_valid&&function_ready)begin
        command_q<=function_cmd;error_q<=0;stat_index<=0;stat_issued<=0;stat_received<=0;stats_ready<=0;
        emitted<=0;returned<=0;produced_groups<=0;read_groups<=0;output_packet<=0;
        packet_full_q<=0;group_pending<=0;reader_slot<=0;reader_packet<=0;reader_word<=0;
        score_issued<=0;score_received<=0;gelu_received<=0;gelu_full<=0;score_early<=0;
        case(function_cmd.function_id)
          FUNCTION_ALPHA_EXP:begin mode<=0;state<=STAT_REQ;end
          FUNCTION_P_EXP:begin mode<=1;state<=STAT_REQ;end
          FUNCTION_GELU:begin mode<=2;state<=WORK;end
          FUNCTION_RECIP:begin mode<=3;state<=STAT_REQ;end
          default:begin error_q<=1;state<=DONE;end
        endcase
      end
      if(loading_stats&&function_mem_valid&&function_mem_ready)begin
        stat_issued<=stat_issued+1;
        if(stat_issued==3)state<=STAT_RSP;
      end
      if(stat_response)begin
        stat_received<=stat_received+1;
        if(stat_received==3)begin stats_ready<=1;state<=STAT_FETCH;end
        else stat_index<=stat_index+16;
        if(function_mem_out.mask!=(stat_received==3?16'h0007:16'hffff))begin error_q<=1;state<=DONE;end
      end
      if(state==STAT_FETCH)state<=STAT_LATCH;
      if(state==STAT_LATCH)begin stat_hold<=stat_ram_data;state<=p_mode?SCORE_FETCH:WORK;end
      if(score_request&&function_mem_valid&&function_mem_ready)score_issued<=score_issued+1;
      if(score_response)score_received<=score_received+1;
      if(state==SCORE_FETCH&&score_rd)state<=SCORE_LATCH;
      if(state==SCORE_LATCH)begin
        score_hold<=score_ram_data;
        if((emitted/16)%16==0)stat_hold<=stat_ram_data;
        state<=WORK;
      end
      if(state==WORK&&p_mode&&math_take&&emitted%16==8&&score_rd)score_early<=1;
      if(function_data_valid&&function_data_ready)begin
        if(function_data.job!=command_q.job||function_data.token!=command_q.token||
           function_data.tile!=command_q.tile||function_data.index!=gelu_received||
           function_data.vector_valid!=2'b01||function_data.last!=(gelu_received==ROWS-1))begin
          error_q<=1;state<=DONE;
        end
        gelu_hold<=function_data.first;gelu_full<=1;gelu_received<=gelu_received+1;
      end
      if(math_take)begin
        emitted<=emitted+(scalar_mode?1:4);
        if(mode==2&&emitted%16==15)gelu_full<=0;
        if((mode==0&&emitted%16==12&&emitted+4<limit)||
           (mode==3&&emitted%16==15&&emitted+1<limit))state<=STAT_FETCH;
        if(p_mode&&emitted%16==12&&emitted+4<limit)begin
          if(score_early)begin
            score_hold<=score_ram_data;
            if((emitted/16)%16==15)stat_hold<=stat_ram_data;
          end else state<=SCORE_FETCH;
          score_early<=0;
        end
        if(mode==3&&(math_a[0][31]||math_a[0][30:0]==0||(&math_a[0][30:23])))begin error_q<=1;state<=DONE;end
      end
      if(running&&math_out)begin
        returned<=returned+(scalar_mode?1:4);
        if(scalar_mode)scalar_pack[(returned%4)*32+:32]<=math_y[0];
        for(int j=0;j<4;j++)if((!scalar_mode||j==0)&&(&math_y[j][30:23]))begin error_q<=1;state<=DONE;end
      end
      if(group_we)produced_groups<=produced_groups+1;
      if(group_rd)begin
        read_groups<=read_groups+1;
        pending_slot<=reader_slot;pending_word<=reader_word;
        pending_last<=reader_word==reader_groups-1;
        if(reader_word==reader_groups-1)begin
          reader_word<=0;reader_packet<=reader_packet+1;reader_slot<=!reader_slot;
        end else reader_word<=reader_word+1;
      end
      if(group_pending)begin
        packet_slots[pending_slot][pending_word*128+:128]<=group_read_data;
        if(pending_last)packet_full_q[pending_slot]<=1;
      end
      if(packet_take)begin packet_full_q[output_packet[0]]<=0;output_packet<=output_packet+1;end
      if(running&&output_packet==packet_limit&&!(|packet_full_q)&&!group_pending&&
         returned>=limit&&emitted>=limit)state<=DONE;
      if(function_mem_out_valid&&function_mem_out_ready&&function_mem_out.token!=command_q.token)begin error_q<=1;state<=DONE;end
      if(function_done_valid&&function_done_ready)state<=IDLE;
    end
  end
  // synthesis translate_off
  always @(posedge clk)if(active&&state!=IDLE)begin
    assert(int'(produced_groups)-int'(read_groups)<=64)else $fatal(1,"SFU output credit overflow");
    assert(score_received<=score_issued)else $fatal(1,"SFU unordered Score response");
  end
  // synthesis translate_on
endmodule
