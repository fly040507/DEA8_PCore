// CE-qualified fixed wire delay. No address counters, read mux or shallow BRAM.
// Valid/reset belongs to the arithmetic pipeline, never reset payload storage.
module dea8_delay_ram #(parameter int WIDTH=32,DELAY=4,LATENCY=1,
  parameter PRIMITIVE="registers",
  parameter int DEPTH=1<<$clog2(DELAY+1),AW=$clog2(DEPTH))(
  input logic clk,advance,input logic [WIDTH-1:0] in_data,output logic [WIDTH-1:0] out_data
);
  (* shreg_extract="no" *) logic [WIDTH-1:0] data_q[DELAY];
  always_ff @(posedge clk)if(advance)begin
    data_q[0]<=in_data;
    for(int i=1;i<DELAY;i++)data_q[i]<=data_q[i-1];
  end
  assign out_data=data_q[DELAY-1];
  initial if(DELAY<1)$fatal(1,"Fixed delay geometry");
endmodule
