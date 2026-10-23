// One observation-level Mask image. Query flush does not invalidate its context.
module dea8_mask_context #(parameter MASK_FILE="units/rom/mask.mem")(
  input logic clk,reset,flush,
  input logic config_valid,output logic config_ready,
  input logic [15:0] config_context,config_version,config_position,
  output logic configured,config_error,
  output logic [15:0] context_id,version,position_base,
  input logic query_valid,output logic query_ready,input logic [5:0] block_id,
  output logic result_valid,input logic result_ready,
  output logic [15:0] state_mask,action_mask,
  output logic protocol_error
);
  typedef enum logic [2:0] {IDLE,SCAN,QUERY_FIRST,QUERY_SECOND,QUERY_LATCH,HOLD} state_e;
  state_e state;
  (* ram_style="block" *) logic [15:0] memory[0:63];
  initial $readmemh(MASK_FILE,memory);
  logic [15:0] ram_data;
  logic [5:0] address,issued,returned,block_q;
  logic pending,bad;
  logic [10:0] valid_tokens;
  wire read_enable=state==SCAN&&issued<59||state==QUERY_FIRST||state==QUERY_SECOND;
  always_comb begin
    address=issued;
    if(state==QUERY_FIRST)address=block_q<51?block_q:6'(block_q);
    if(state==QUERY_SECOND)address=6'(55+block_q-51);
  end
  always_ff @(posedge clk)if(read_enable)ram_data<=memory[address];
  assign config_ready=state==IDLE;
  assign query_ready=state==IDLE&&configured&&!config_valid&&!flush;
  assign result_valid=state==HOLD&&!flush;
  function automatic logic [15:0] suffix_expected(input int i);
    case(i)
      51:return 16'h0001;52,53,54:return 0;
      55,56,57:return 16'hffff;default:return 16'h0007;
    endcase
  endfunction
  always_ff @(posedge clk)begin
    if(reset)begin
      state<=IDLE;configured<=0;config_error<=0;context_id<=0;version<=0;position_base<=0;
      pending<=0;issued<=0;returned<=0;bad<=0;valid_tokens<=0;protocol_error<=0;
      state_mask<=0;action_mask<=0;block_q<=0;
    end else begin
      pending<=read_enable;
      if(config_valid&&config_ready)begin
        context_id<=config_context;version<=config_version;position_base<=config_position;
        configured<=0;config_error<=0;protocol_error<=0;issued<=0;returned<=0;bad<=0;valid_tokens<=0;state<=SCAN;
      end
      if(state==SCAN)begin
        if(read_enable)issued<=issued+1;
        if(pending)begin
          returned<=returned+1;
          if(returned<51)valid_tokens<=valid_tokens+11'($countones(ram_data));
          else if(ram_data!=suffix_expected(returned))bad<=1;
          if(returned==58)begin
            config_error<=bad||ram_data!=16'h0007||valid_tokens!=position_base;
            configured<=!bad&&ram_data==16'h0007&&valid_tokens==position_base;state<=IDLE;
          end
        end
      end
      if(query_valid&&query_ready)begin
        block_q<=block_id;
        if(block_id>=55)protocol_error<=1;else state<=QUERY_FIRST;
      end
      if(state==QUERY_FIRST)state<=block_q<51?QUERY_LATCH:QUERY_SECOND;
      if(state==QUERY_SECOND)begin state_mask<=ram_data;state<=QUERY_LATCH;end
      if(state==QUERY_LATCH)begin
        action_mask<=ram_data;
        if(block_q<51)state_mask<=ram_data;
        state<=HOLD;
      end
      if(result_valid&&result_ready)state<=IDLE;
      if(flush&&state!=SCAN)begin state<=IDLE;pending<=0;protocol_error<=0;end
    end
  end
endmodule
