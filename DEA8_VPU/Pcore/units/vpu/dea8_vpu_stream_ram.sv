module dea8_vpu_stream_ram #(parameter int DW=1024,AW=5,RL=3,parameter PRIMITIVE="registers")(
 input logic clk,we,rd_en,advance,
 input logic [AW-1:0] wr_addr,rd_addr,
 input logic [DW-1:0] wr_data,output logic [DW-1:0] rd_data
);
 logic [DW-1:0] raw,pipe_data[RL-1];
 // A RAM read plus two CE-qualified boundaries. Stalls freeze all read data
 // and tag stages together, while the independent producer write port runs.
  dea8_sdp_ram #(.WIDTH(DW),.DEPTH(1<<AW),.PRIMITIVE(PRIMITIVE)) storage(
  .clk,.wr_en(we),.wr_addr,.wr_data,.rd_en(rd_en&&advance),.rd_addr,
  .rd_data(raw),.dbg_addr('0),.dbg_data());
 always_ff @(posedge clk)if(advance)begin
  pipe_data[0]<=raw;for(int i=1;i<RL-1;i++)pipe_data[i]<=pipe_data[i-1];
 end
 assign rd_data=pipe_data[RL-2];
 initial if(RL<2)$fatal(1,"Stream RAM requires registered read boundaries");
endmodule
