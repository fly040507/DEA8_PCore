// A CE-qualified fixed delay. Payload is not reset; valid travels separately.
module dea8_delay_ram #(parameter int WIDTH=32,DELAY=4,LATENCY=1,
  parameter PRIMITIVE="block",
  parameter int DEPTH=1<<$clog2(DELAY+1),AW=$clog2(DEPTH))(
  input logic clk,advance,input logic [WIDTH-1:0] in_data,output logic [WIDTH-1:0] out_data
);
  if(DELAY==1)begin
    always_ff @(posedge clk)if(advance)out_data<=in_data;
  end else begin
    logic [AW-1:0] pointer=0;
    logic [WIDTH-1:0] raw_data;
    always_ff @(posedge clk)if(advance)pointer<=pointer+1'b1;
    dea8_sdp_ram #(.WIDTH(WIDTH),.DEPTH(DEPTH),.PRIMITIVE(PRIMITIVE)) delay_store(
      .clk,.rd_en(advance),.wr_en(advance),.rd_addr(pointer-AW'(DELAY-LATENCY)),
      .wr_addr(pointer),.wr_data(in_data),.rd_data(raw_data),.dbg_addr('0),.dbg_data()
    );
    if(LATENCY==1)assign out_data=raw_data;
    else begin
      logic [WIDTH-1:0] output_pipe[LATENCY-1];
      always_ff @(posedge clk)if(advance)begin
        output_pipe[0]<=raw_data;
        for(int i=1;i<LATENCY-1;i++)output_pipe[i]<=output_pipe[i-1];
      end
      assign out_data=output_pipe[LATENCY-2];
    end
  end
  initial if(LATENCY<1||DELAY<LATENCY)$fatal(1,"Fixed delay geometry");
endmodule
