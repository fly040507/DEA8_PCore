import pcore_pkg::*;

// Common command identity/prepare/go/done checker. At most one active and
// one prepared command; preparing never grants memory access.
module dea8_unit_control (
  input logic clk,reset,clear,
  input logic offer_valid,output logic offer_ready,input unit_cmd_t offer,
  output logic cmd_valid,input logic cmd_ready,output unit_cmd_t cmd,
  input logic armed_valid,output logic armed_ready,input job_token_t armed_token,
  output logic go_valid,input logic go_ready,output job_token_t go_token,input logic grant,
  input logic done_valid,output logic done_ready,input job_token_t done_token,
  input unit_function_e done_function,input logic done_error,input logic drained,
  output logic active,running,prepared_valid,output unit_cmd_t current,prepared,
  output logic retired_valid,output unit_cmd_t retired,output logic protocol_error
);
  logic armed,prepared_armed,accept,retire,enabled,sent,prepared_sent;
  assign enabled=!reset&&!clear&&!protocol_error;
  assign cmd_valid=enabled&&((active&&!sent)||(prepared_valid&&!prepared_sent));
  assign cmd=active&&!sent?current:prepared;
  assign offer_ready=enabled&&!prepared_valid;
  assign accept=offer_valid&&offer_ready;
  assign armed_ready=enabled&&((active&&sent&&!running&&!armed&&armed_token==current.token)||
    (prepared_valid&&prepared_sent&&!prepared_armed&&armed_token==prepared.token));
  assign go_valid=enabled&&active&&armed&&!running&&grant;
  assign go_token=current.token;
  assign done_ready=enabled&&active&&running&&drained;
  assign retire=done_valid&&done_ready&&done_token==current.token&&done_function==current.function_id&&!done_error;
  assign retired_valid=retire;
  assign retired=current;
  always_ff @(posedge clk)begin
    if(reset||clear)begin
      active<=0;running<=0;prepared_valid<=0;armed<=0;prepared_armed<=0;
      current<='0;prepared<='0;sent<=0;prepared_sent<=0;protocol_error<=0;
    end else begin
      if(armed_valid)begin
        if(!armed_ready)protocol_error<=1;
        else if(active&&armed_token==current.token)armed<=1;
        else prepared_armed<=1;
      end
      if(go_valid&&go_ready)running<=1;
      if(cmd_valid&&cmd_ready)begin if(active&&!sent)sent<=1;else prepared_sent<=1;end
      if(done_valid&&(!done_ready||done_token!=current.token||done_function!=current.function_id||done_error))protocol_error<=1;
      if(retire)begin
        active<=prepared_valid;running<=0;
        // Promotion must include handshakes accepted on this retirement edge.
        armed<=prepared_armed||(prepared_valid&&armed_valid&&armed_ready&&armed_token==prepared.token);
        sent<=prepared_sent||(prepared_valid&&cmd_valid&&cmd_ready);
        if(prepared_valid)current<=prepared;
        prepared_valid<=0;prepared_armed<=0;prepared_sent<=0;
      end
      if(accept)begin
        if(!active||(retire&&!prepared_valid))begin current<=offer;active<=1;running<=0;armed<=0;sent<=0;end
        else begin prepared<=offer;prepared_valid<=1;prepared_armed<=0;prepared_sent<=0;end
      end
    end
  end
endmodule
