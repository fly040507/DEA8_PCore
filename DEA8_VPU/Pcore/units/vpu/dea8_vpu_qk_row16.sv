// One physical row-max tree and subtractor, with paired boundary compatibility.
module dea8_vpu_qk_row16(
 input logic clk,reset,clear,in_valid,output logic in_ready,
 input pcore_pkg::vpu_cmd_t in_cmd,input logic [pcore_pkg::PAIR_BITS-1:0] in_pair_idx,
 input logic [1:0] in_row_valid,input logic [1:0][15:0][31:0] in_score,
 input logic [1:0][15:0] in_effective_mask,input logic [1:0][31:0] in_m_old,
 output logic out_valid,input logic out_ready,output pcore_pkg::vpu_cmd_t out_cmd,
 output logic [pcore_pkg::PAIR_BITS-1:0] out_pair_idx,output logic [1:0] out_row_valid,
 output logic [1:0][15:0][31:0] capture_masked_score,
 output logic [1:0][31:0] out_row_max,out_m_new,out_aa,
 output logic [1:0] out_empty_row,out_initial_row,out_numeric_error
);
 import pcore_pkg::*;
 logic second,output_half,inner_ready,inner_valid;
 vpu_cmd_t held_cmd,inner_cmd;
 logic [PAIR_BITS-1:0] held_pair,inner_pair;
 logic [15:0][31:0] held_score;
 logic [15:0] held_mask;
 logic [31:0] held_m;
 logic held_rv;
 logic [1:0] inner_rv,inner_empty,inner_initial,inner_error;
 logic [1:0][31:0] inner_max,inner_m,inner_aa;
 wire output_advance=!out_valid||out_ready;
 assign in_ready=inner_ready&&!second;
 wire take=in_valid&&in_ready;
 always_comb for(int r=0;r<2;r++)for(int lane=0;lane<16;lane++)
   capture_masked_score[r][lane]=in_effective_mask[r][lane]?in_score[r][lane]:32'hff800000;
 dea8_vpu_qk_post_pair_v3 #(.ROW_UNITS(1)) row(
   .clk,.reset,.clear,.in_valid(take||second),.in_ready(inner_ready),
   .in_cmd(second?held_cmd:in_cmd),.in_pair_idx(second?held_pair:in_pair_idx),
   .in_row_valid({1'b0,second?held_rv:in_row_valid[0]}),
   .in_score({512'b0,second?held_score:in_score[0]}),
   .in_effective_mask({16'b0,second?held_mask:in_effective_mask[0]}),
   .in_m_old({32'b0,second?held_m:in_m_old[0]}),
   .out_valid(inner_valid),.out_ready(output_advance),.out_cmd(inner_cmd),.out_pair_idx(inner_pair),
   .out_row_valid(inner_rv),.capture_masked_score(),.out_row_max(inner_max),.out_m_new(inner_m),.out_aa(inner_aa),
   .out_empty_row(inner_empty),.out_initial_row(inner_initial),.out_numeric_error(inner_error));
 always_ff @(posedge clk)begin
   if(reset||clear)begin second<=0;output_half<=0;out_valid<=0;end
   else begin
     if(out_valid&&out_ready)out_valid<=0;
     if(take)begin
       second<=1;held_cmd<=in_cmd;held_pair<=in_pair_idx;held_score<=in_score[1];
       held_mask<=in_effective_mask[1];held_m<=in_m_old[1];held_rv<=in_row_valid[1];
     end else if(second&&inner_ready)second<=0;
     if(inner_valid&&output_advance)begin
       output_half<=!output_half;
       out_cmd<=inner_cmd;out_pair_idx<=inner_pair;
       out_row_valid[output_half]<=inner_rv[0];out_row_max[output_half]<=inner_max[0];
       out_m_new[output_half]<=inner_m[0];out_aa[output_half]<=inner_aa[0];
       out_empty_row[output_half]<=inner_empty[0];out_initial_row[output_half]<=inner_initial[0];
       out_numeric_error[output_half]<=inner_error[0];
       if(output_half)out_valid<=1;
     end
   end
 end
 // synthesis translate_off
 always @(posedge clk)if(!reset&&!clear&&take&&in_row_valid!=row_mask(in_pair_idx))
   $fatal(1,"QK row serializer input pair mask mismatch");
 // synthesis translate_on
endmodule
