import pcore_pkg::*;
// M2V: sixteen row-major 256x32 SDP banks. Exactly one vector read and one
// independently masked write per clock; no cyclic-bank rotation/crossbar.
module dea8_vector_ram #(parameter bit ROUTED_SDP=0)(
 input logic clk,input vector_ram_port_t a,b,
 output logic [TILE-1:0][FP_BITS-1:0] a_data,b_data
);
 vector_ram_port_t writer,reader;
 logic [511:0] read_data;
  if(ROUTED_SDP)begin
    // The complete PCore already routes one writer to A and one reader to B.
    // Avoid selecting the same wide payload a second time inside the RAM.
    assign writer=a;assign reader=b;
  end else always_comb begin
   writer='0;reader='0;
   if(|(a.en&a.we))writer=a;
   else if(|(b.en&b.we))writer=b;
   if(|(a.en&~a.we))reader=a;
   else if(|(b.en&~b.we))reader=b;
 end
 for(genvar lane=0;lane<16;lane++)begin: banks
   dea8_sdp_ram #(.WIDTH(32),.DEPTH(256)) memory(
     .clk,.rd_en(reader.en[lane]),.rd_addr(reader.addr[lane]),
     .wr_en(writer.en[lane]&&writer.we[lane]),.wr_addr(writer.addr[lane]),
     .wr_data(writer.data[lane]),.rd_data(read_data[32*lane+:32]),.dbg_addr('0),.dbg_data());
 end
 assign a_data=read_data;assign b_data=read_data;
 // synthesis translate_off
  always @(posedge clk)begin
   if((|(a.en&a.we))&&(|(b.en&b.we)))$fatal(1,"M2V has two vector writes in one clock");
    if((|(a.en&~a.we))&&(|(b.en&~b.we)))$fatal(1,"M2V has two vector reads in one clock");
    if(ROUTED_SDP&&((|(a.en&~a.we))||(|(b.en&b.we))))$fatal(1,"M2V routed SDP ownership");
 end
 // synthesis translate_on
endmodule
