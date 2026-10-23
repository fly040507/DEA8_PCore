// Fixed output stage; no pointer-selected wide RAM output or payload reset.
module dea8_elastic_fifo #(parameter int WIDTH=512,DEPTH=4)(
 input logic clk,reset,clear,in_valid,output logic in_ready,input logic [WIDTH-1:0] in_data,
 output logic out_valid,input logic out_ready,output logic [WIDTH-1:0] out_data,
 output logic [$clog2(DEPTH+1)-1:0] count
);
 logic [DEPTH-1:0] valid_q,advance;
 logic [WIDTH-1:0] data_q[DEPTH];
 assign out_valid=valid_q[0]&&!reset&&!clear;assign out_data=data_q[0];
 assign in_ready=advance[DEPTH-1]&&!reset&&!clear;
 for(genvar s=0;s<DEPTH;s++)begin: stages
   if(s==0)assign advance[s]=!valid_q[s]||out_ready;
   else assign advance[s]=!valid_q[s]||advance[s-1];
   always_ff @(posedge clk)begin
     if(reset||clear)valid_q[s]<=0;
     else if(advance[s])begin
       if(s==DEPTH-1)begin valid_q[s]<=in_valid;if(in_valid)data_q[s]<=in_data;end
       else begin valid_q[s]<=valid_q[s+1];if(valid_q[s+1])data_q[s]<=data_q[s+1];end
     end
   end
 end
 always_ff @(posedge clk)begin
   if(reset||clear)count<=0;
   else case({in_valid&&in_ready,out_valid&&out_ready})
     2'b10:count<=count+1'b1;
     2'b01:count<=count-1'b1;
     default:;
   endcase
 end
endmodule
