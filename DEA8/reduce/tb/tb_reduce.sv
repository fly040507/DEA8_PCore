`timescale 1ns/1ps
import dea8_tile_link_pkg::*;

module tb_reduce;
  logic clk=0,reset=1,clear=0;
  always #2 clk=~clk;
  logic [7:0] hv,hr,dv,dr,last;
  tile_header_t [0:7] hdr;
  logic [7:0][127:0] hdr_bits;
  logic [7:0][511:0] data;
  logic [511:0] result;
  logic [127:0] oh_bits; logic ov,ord,odv,odr,ol;
  tile_commit_t commit; logic cv,cr,busy,error;
  for(genvar c=0;c<8;c++)assign hdr_bits[c]=hdr[c];
  dea8_reduce_top dut(.clk,.reset,.clear,.in_hdr_valid(hv),.in_hdr_ready(hr),.in_hdr_bits(hdr_bits),
    .in_data_valid(dv),.in_data_ready(dr),.in_data(data),.in_last(last),
    .out_hdr_valid(ov),.out_hdr_ready(ord),.out_hdr_bits(oh_bits),.out_data_valid(odv),.out_data_ready(odr),
    .out_data(result),.out_last(ol),.commit_valid(cv),.commit_ready(cr),.commit(commit),.busy,.protocol_error(error));
  logic state_commit;
  int out_rows;
  assign odr=1'b1; assign ord=1'b1;
  int cycles;
  logic [7:0] row_accept;
  always @(posedge clk) if(!reset && dv) row_accept<=row_accept|dr;
  always @(posedge clk) begin
    if(!reset) begin
      cycles++;
      if(cycles%2000==0)$display("REDUCE_PROGRESS cycle=%0d state=%0d seen=%b recv0=%0d recv7=%0d issued=%0d written=%0d fifo=%b tree_out=%b",cycles,dut.state_q,dut.seen_q,dut.recv_q[0],dut.recv_q[7],dut.issued_q,dut.written_q,dut.fifo_valid,dut.tree_out_valid);
      if(cycles>40000)$fatal(1,"reduce watchdog state=%0d seen=%b recv0=%0d recv7=%0d issued=%0d written=%0d",dut.state_q,dut.seen_q,dut.recv_q[0],dut.recv_q[7],dut.issued_q,dut.written_q);
    end
  end
  always @(posedge clk) if(odv&&odr) begin
    for(int lane=0;lane<16;lane++)
      if(result[32*lane+:32]!==32'h41000000)$fatal(1,"reduce value lane=%0d value=%h",lane,result[32*lane+:32]);
    out_rows++;
  end
  initial begin
    hv=0;dv=0;last=0;cv=0;state_commit=0;cycles=0;row_accept=0;out_rows=0;
    repeat(35)@(posedge clk); reset=0;
    for(int c=0;c<8;c++)begin
      hdr[c]='0; hdr[c].transfer_id=16'h12;hdr[c].transfer_epoch=16'h34;
      hdr[c].destination_id=16'h56;hdr[c].token_origin=0;hdr[c].column_base=0;
      hdr[c].rows=51;hdr[c].columns=16;hdr[c].kind=TILE_O;hdr[c].layout=LAYOUT_FP_ROWS;
      hdr[c].source_id=c;hdr[c].tile_seq=0;
    end
    // All source descriptors may arrive in one cycle; data is deliberately skewed.
    @(negedge clk); hv='1; @(posedge clk); @(negedge clk); hv=0;
    for(int r=0;r<51;r++)begin
      for(int c=0;c<8;c++)begin
        data[c]='0;
        for(int lane=0;lane<16;lane++)data[c][32*lane+:32]=32'h3f800000; // 1.0
      end
      @(negedge clk); dv='1; last={8{r==50}}; row_accept=0;
      while(row_accept!=='1) @(negedge clk);
      dv=0;
    end
    wait(ov); @(posedge clk); wait(odv&&ol); @(posedge clk);
    if(error) $fatal(1,"reduce protocol error");
    @(negedge clk); state_commit=1; cv=1; commit.transfer_id=16'h12;commit.transfer_epoch=16'h34;
    commit.tile_seq=0;commit.source_id=8;commit.status=0;commit.reserved=0;
    @(posedge clk); @(negedge clk); state_commit=0; cv=0;
    repeat(10)@(posedge clk);
    if(error||busy||out_rows!=51) $fatal(1,"reduce did not commit rows=%0d",out_rows);
    $display("tb_reduce PASS"); $finish;
  end
endmodule
