import pcore_pkg::*;
// Results reuse M2V slots 2/3. Writes serialize halves; reads serialize rows.
// Input slots 0/1 remain intact for the producer until their row is consumed.
module dea8_vpu_saved_ram(
 input logic clk,reset,clear,lo_we,hi_we,rd_en,
 input logic [5:0] lo_row,hi_row,input logic [511:0] lo_data,hi_data,
 input logic rd_half,input logic [4:0] rd_pair,
 output logic [1:0][15:0][31:0] rd_data,output logic rd_ready,rd_valid,
 output vector_ram_port_t ram_a,ram_b,input logic [511:0] ram_data
);
 logic odd_pending,half_q;
 logic [511:0] odd_data,even_data;
 logic [5:0] odd_row;
 logic [4:0] pair_q;
 logic [1:0] phase;
 assign rd_ready=phase==0&&!odd_pending&&!lo_we&&!hi_we;
 always_comb begin
   ram_a='0;ram_b='0;
   if(lo_we||odd_pending)begin
     ram_a.en='1;ram_a.we='1;ram_a.data=odd_pending?odd_data:lo_data;
     for(int lane=0;lane<16;lane++)ram_a.addr[lane]=odd_pending?{2'b11,odd_row}:{2'b10,lo_row};
   end else if(hi_we)begin
     ram_a.en='1;ram_a.we='1;ram_a.data=hi_data;
     for(int lane=0;lane<16;lane++)ram_a.addr[lane]={2'b11,hi_row};
   end
   if((rd_en&&rd_ready)||phase==1)begin
     ram_b.en='1;
     for(int lane=0;lane<16;lane++)ram_b.addr[lane]=phase==1?
       {1'b1,half_q,pair_q,1'b1}:{1'b1,rd_half,rd_pair,1'b0};
   end
 end
 always_ff @(posedge clk)begin
   if(reset||clear)begin odd_pending<=0;phase<=0;rd_valid<=0;end
   else begin
     rd_valid<=0;odd_pending<=0;
     if(lo_we&&hi_we)begin odd_pending<=1;odd_data<=hi_data;odd_row<=hi_row;end
     if(rd_en&&rd_ready)begin phase<=1;pair_q<=rd_pair;half_q<=rd_half;end
     if(phase==1)begin even_data<=ram_data;phase<=2;end
     if(phase==2)begin rd_data[0]<=even_data;rd_data[1]<=pair_q==25?512'b0:ram_data;rd_valid<=1;phase<=0;end
   end
 end
 // synthesis translate_off
 always @(posedge clk)if(!reset&&!clear&&odd_pending&&(lo_we||hi_we))$fatal(1,"M2V result write serializer overrun");
 // synthesis translate_on
endmodule
