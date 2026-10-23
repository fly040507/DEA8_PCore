module dea8_gcore_multicast #(
  parameter int WIDTH=32, OUTPUTS=8
) (
  input logic clk,reset,clear,
  input logic in_valid,
  output logic in_ready,
  input logic [WIDTH-1:0] in_data,
  input logic [OUTPUTS-1:0] in_mask,
  output logic [OUTPUTS-1:0] out_valid,
  input logic [OUTPUTS-1:0] out_ready,
  output logic [WIDTH-1:0] out_data,
  output logic retired,
  output logic empty
);
  logic valid_q;
  logic [OUTPUTS-1:0] pending_q,remaining;
  assign out_valid=pending_q&{OUTPUTS{valid_q&&!reset&&!clear}};
  assign remaining=pending_q&~(out_valid&out_ready);
  assign retired=valid_q&&(remaining=='0)&&!reset&&!clear;
  assign in_ready=(!valid_q||retired)&&!reset&&!clear;
  assign empty=!valid_q;
  always_ff @(posedge clk) begin
    if(reset||clear) begin valid_q<=0; pending_q<=0; out_data<=0; end
    else if(in_valid&&in_ready) begin
      valid_q<=1; pending_q<=in_mask; out_data<=in_data;
    end else if(valid_q) begin
      pending_q<=remaining;
      if(retired) valid_q<=0;
    end
  end
endmodule
