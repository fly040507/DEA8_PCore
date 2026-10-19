import pcore_ip_config_pkg::*;

// Native Single Add (DAZ/FTZ). Replace is a bit-exact delayed bypass.
module DEQACC_3_3ns_lane(
  input logic clk,reset,clear,in_valid,add_old,
  input logic [31:0] old_value,partial_value,
  output logic out_valid,output logic [31:0] result_value
);
  localparam int L=FPADD_IP_LATENCY;
  logic [L-1:0] valid_q,bypass_q;
  logic [31:0] partial_q[0:L-1];
  logic [1:0] reset_q=2'b11;
  logic native_valid;
  logic [31:0] native_result;
  wire ip_reset=reset||(|reset_q);
  always_ff @(posedge clk) begin
    if(reset) reset_q<=2'b11;
    else reset_q<={reset_q[0],1'b0};
    partial_q[0]<=partial_value;bypass_q[0]<=!add_old;
    for(int i=1;i<L;i++)begin partial_q[i]<=partial_q[i-1];bypass_q[i]<=bypass_q[i-1];end
    if(ip_reset||clear)valid_q<='0;
    else valid_q<={valid_q[L-2:0],in_valid};
  end
  pcore_fpadd_ip vendor_add(
    .aclk(clk),.aresetn(!ip_reset),
    .s_axis_a_tvalid(in_valid&&!ip_reset&&!clear),.s_axis_a_tdata(old_value),
    .s_axis_b_tvalid(in_valid&&!ip_reset&&!clear),.s_axis_b_tdata(partial_value),
    .m_axis_result_tvalid(native_valid),.m_axis_result_tdata(native_result)
  );
  assign out_valid=valid_q[L-1]&&!reset&&!clear;
  assign result_value=bypass_q[L-1]?partial_q[L-1]:
    ((&native_result[30:23])&&(|native_result[22:0]))?32'h7fc00000:native_result;
  // synthesis translate_off
  always @(negedge clk) if(!reset&&!clear)begin
    if(out_valid&&!native_valid)$fatal(1,"FPADD IP data/sideband latency mismatch");
    if(in_valid&&ip_reset)$fatal(1,"FPADD input before IP reset recovery");
  end
  // synthesis translate_on
endmodule
