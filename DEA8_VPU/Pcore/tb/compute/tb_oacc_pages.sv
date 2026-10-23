`timescale 1ns/1ps
module tb_oacc_pages;
 import pcore_pkg::*;
 logic clk=0;always #2 clk=~clk;
 logic reset=1,clear=0,rd_valid=0,rd_data_valid,result_rd_valid=0,result_rd_ready,result_rd_data_valid;
 acc_sel_e rd_sel=ACC_OACC,result_rd_sel=ACC_OACC,wr_sel=ACC_OACC;
 logic [9:0] rd_addr=0,result_rd_addr=0,wr_addr=0;
 logic [15:0][31:0] rd_even_data,rd_odd_data,rd_even_raw,rd_odd_raw,result_even_data,result_odd_data,wr_even_data,wr_odd_data;
 logic [1:0] rd_word_valid;
 logic wr_valid=0,wr_even_valid=1,wr_odd_valid=1,vpu_wr_valid=0,vpu_wr_ready;
 acc_write_t vpu_wr;
 logic [3:0] matrix_tile=0;
 logic matrix_needs_scaled=1,matrix_tile_ready,raw_begin=0,raw_page=0;
 dea8_acc_store dut(.clk,.reset,.clear,.rd_valid,.rd_sel,.rd_addr,.rd_data_valid,
   .rd_even_data,.rd_odd_data,.rd_even_raw,.rd_odd_raw,.rd_word_valid,.matrix_tile,.matrix_needs_scaled,.matrix_tile_ready,.raw_begin,.raw_page,
   .result_rd_owner(ACC_READ_RESULT),.result_rd_valid,.result_rd_ready,.result_rd_sel,.result_rd_addr,
   .result_rd_data_valid,.result_even_data,.result_odd_data,.vpu_wr_valid,.vpu_wr_ready,.vpu_wr,
   .wr_valid,.wr_sel,.wr_even_valid,.wr_odd_valid,.wr_addr,.wr_even_data,.wr_odd_data,
   .dbg_valid(1'b0),.dbg_sel(ACC_OACC),.dbg_parity(1'b0),.dbg_addr('0),.dbg_lane('0),.dbg_data());
 initial begin
   vpu_wr='0;wr_even_data='0;wr_odd_data='0;
   repeat(35)@(negedge clk);reset=0;
   if(matrix_tile_ready||result_rd_ready)$fatal(1,"Uninitialized OACC advertised ready");
   for(int page=0;page<2;page++)begin
     raw_page=1'(page);raw_begin=1;@(negedge clk);raw_begin=0;
     for(int pair=0;pair<26;pair++)begin
       wr_addr=10'(page*416+pair*16);wr_valid=1;wr_odd_valid=pair!=25;
       for(int lane=0;lane<16;lane++)begin
         wr_even_data[lane]=32'(10000*page+100*pair+lane+1);
         wr_odd_data[lane]=32'(10000*page+100*pair+lane+33);
       end
       vpu_wr_valid=page==0;vpu_wr.sel=ACC_OACC;vpu_wr.addr=10'(pair*16);
       vpu_wr.row_valid=row_mask(pair);vpu_wr.data={wr_odd_data,wr_even_data};
       @(negedge clk);
     end
     wr_valid=0;vpu_wr_valid=0;
   end
   if(!matrix_tile_ready)$fatal(1,"Scaled tile did not become ready");
   for(int page=0;page<2;page++)for(int pair=0;pair<26;pair++)begin
     result_rd_addr=10'(page*416+pair*16);result_rd_valid=1;
     #0.1;if(!result_rd_ready)$fatal(1,"Raw page blocked page=%0d pair=%0d",page,pair);
     @(negedge clk);result_rd_valid=0;
     while(!result_rd_data_valid)@(negedge clk);
     for(int lane=0;lane<16;lane++)begin
       if(result_even_data[lane]!==32'(10000*page+100*pair+lane+1))$fatal(1,"Raw page/parity mismatch");
       if(result_odd_data[lane]!==((pair==25)?32'b0:32'(10000*page+100*pair+lane+33)))$fatal(1,"Raw odd tail mismatch");
     end
     @(negedge clk);
   end
   for(int pair=0;pair<26;pair++)begin
     rd_addr=10'(pair*16);rd_valid=1;@(negedge clk);rd_valid=0;
     while(!rd_data_valid)@(negedge clk);
     for(int lane=0;lane<16;lane++)begin
       if(rd_even_data[lane]!==32'(100*pair+lane+1))$fatal(1,"Scaled value mismatch");
     end
     @(negedge clk);
   end
   if(matrix_tile_ready||dut.scaled_valid!=0)$fatal(1,"Destructive read did not consume validity");
   raw_page=0;raw_begin=1;@(negedge clk);raw_begin=0;result_rd_addr=0;
   #0.1;if(result_rd_ready)$fatal(1,"Reused raw page retained old generation readiness");
   result_rd_addr=416;#0.1;if(!result_rd_ready)$fatal(1,"Other raw page was invalidated");
   $display("tb_oacc_pages PASS raw_pages=2 raw_pairs=52 scaled_pairs=26 tail=1 consume_once=1 page_reuse=1 URAM_banks=32");$finish;
 end
 initial begin #100000;$fatal(1,"OACC page timeout");end
endmodule
