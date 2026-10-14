`timescale 1ns/1ps
import dea8_tile_link_pkg::*;
module tb_dynamic_reduce;
  logic clk=0;always #2 clk=~clk;
  logic reset=1,clear=0;
  logic [7:0] in_hdr_valid=0,in_hdr_ready,in_data_valid=0,in_data_ready,in_last=0;
  logic [7:0][127:0] in_hdr_bits=0;logic [7:0][511:0] in_data=0;
  logic out_hdr_valid,out_hdr_ready=0,out_data_valid,out_data_ready=0,out_last,commit_valid=0,commit_ready,busy,protocol_error;
  logic [127:0] out_hdr_bits;logic [511:0] out_data;tile_commit_t commit='0;
  dea8_reduce_top dut(.*);
  int cycles=0,cases=0,words=0,negative=0;bit allow_error=0;
  tile_header_t expected_header;
  function automatic logic [31:0] sample(input int c,row,n);
    shortreal x;
    case((c+row+n)%19)
      0:return 32'h00000001;
      1:return 32'h80000001;
      2:return 32'h3f800001;
      3:return 32'hbf800000;
      default:begin x=(c*13-row*3+n*7)/32.0;return $shortrealtobits(x);end
    endcase
  endfunction
  function automatic logic [31:0] gold(input int row,n);
    logic [31:0] a,b,c,d;
    a=fp32_legacy_ref_pkg::fp32_add(sample(0,row,n),sample(1,row,n));
    b=fp32_legacy_ref_pkg::fp32_add(sample(2,row,n),sample(3,row,n));
    c=fp32_legacy_ref_pkg::fp32_add(sample(4,row,n),sample(5,row,n));
    d=fp32_legacy_ref_pkg::fp32_add(sample(6,row,n),sample(7,row,n));
    return fp32_legacy_ref_pkg::fp32_add(fp32_legacy_ref_pkg::fp32_add(a,b),fp32_legacy_ref_pkg::fp32_add(c,d));
  endfunction
  task automatic producer(input int c,m);
    tile_header_t h;
    repeat(c%4)@(negedge clk);h=expected_header;h.source_id=4'(c);
    in_hdr_bits[c]=h;in_hdr_valid[c]=1;do @(posedge clk);while(!in_hdr_ready[c]);@(negedge clk);in_hdr_valid[c]=0;
    for(int r=0;r<m;r++)begin
      if((r+c)%7==3)repeat(c%3+1)@(negedge clk);
      for(int n=0;n<16;n++)in_data[c][n*32+:32]=sample(c,r,n);
      in_last[c]=r==m-1;in_data_valid[c]=1;do @(posedge clk);while(!in_data_ready[c]);@(negedge clk);in_data_valid[c]=0;
    end
  endtask
  task automatic consumer(input int m);
    tile_header_t h;
    while(!out_hdr_valid)@(negedge clk);repeat(3)@(negedge clk);out_hdr_ready=1;
    @(posedge clk);h=tile_header_t'(out_hdr_bits);if(h!==expected_header)$fatal(1,"Dynamic reduce output header mismatch");
    @(negedge clk);out_hdr_ready=0;
    for(int r=0;r<m;r++)begin
      out_data_ready=0;repeat(r%4)@(negedge clk);out_data_ready=1;
      do @(posedge clk);while(!out_data_valid);
      if(out_last!=(r==m-1))$fatal(1,"Dynamic reduce last mismatch");
      for(int n=0;n<16;n++)if(out_data[n*32+:32]!==gold(r,n))$fatal(1,"Eight-core FP32 reduction mismatch r=%0d n=%0d",r,n);
      words++;@(negedge clk);out_data_ready=0;
    end
    repeat(5)@(negedge clk);
    if(!busy||!commit_ready||in_hdr_ready!=0)$fatal(1,"Reduce Tile ownership released before commit");
    commit='0;commit.transfer_id=h.transfer_id;commit.transfer_epoch=h.transfer_epoch;commit.tile_seq=h.tile_seq;commit.source_id=h.source_id;
    commit_valid=1;@(posedge clk);if(!commit_ready)$fatal(1,"Reduce commit unexpectedly blocked");@(negedge clk);commit_valid=0;
  endtask
  task automatic run_case(input int m);
    @(negedge clk);expected_header='0;expected_header.transfer_id=16'(cases+1);expected_header.transfer_epoch=16'h7654;
    expected_header.destination_id=23;expected_header.token_origin=7;expected_header.column_base=16'((cases%64)*16);
    expected_header.rows=6'(m);expected_header.columns=16;expected_header.kind=cases%2?TILE_DOWN:TILE_O;
    expected_header.layout=LAYOUT_FP_ROWS;expected_header.source_id=8;expected_header.tile_seq=6'(cases%64);
    fork
      producer(0,m);producer(1,m);producer(2,m);producer(3,m);
      producer(4,m);producer(5,m);producer(6,m);producer(7,m);consumer(m);
    join
    if(protocol_error||busy)$fatal(1,"Reduce did not retire cleanly");cases++;
  endtask
  task automatic rejection(input int which);
    tile_header_t h;
    @(negedge clk);clear=1;in_hdr_valid=0;in_data_valid=0;commit_valid=0;
    @(negedge clk);clear=0;allow_error=1;
    h=expected_header;h.source_id=0;h.rows=1;h.column_base=0;h.tile_seq=0;
    if(which==0)h.rows=0;if(which==1)h.reserved=1;
    in_hdr_bits[0]=h;in_hdr_valid[0]=1;@(posedge clk);@(negedge clk);in_hdr_valid=0;
    if(which==2)begin h.source_id=1;h.rows=2;in_hdr_bits[1]=h;in_hdr_valid[1]=1;@(posedge clk);@(negedge clk);in_hdr_valid=0;end
    if(which==3)begin in_last[0]=0;in_data_valid[0]=1;@(posedge clk);@(negedge clk);in_data_valid=0;end
    if(!protocol_error||out_hdr_valid||out_data_valid||in_hdr_ready!=0||in_data_ready!=0)$fatal(1,"Malformed reduce transaction not rejected");
    negative++;clear=1;@(negedge clk);clear=0;allow_error=0;
  endtask
  always @(posedge clk)begin cycles++;if(!reset&&!clear&&!allow_error&&protocol_error)$fatal(1,"Unexpected reduce protocol error");end
  initial begin
    repeat(32)@(negedge clk);reset=0;
    for(int m=1;m<=51;m++)run_case(m);
    for(int n=0;n<4;n++)rejection(n);
    run_case(51);run_case(1);
    $display("tb_dynamic_reduce PASS cases=%0d all_M1_to_M51=1 words=%0d eight_FIFO_depth8=1 tree_order_bit_exact=1 backpressure=1 commit_fence=1 negative=%0d",cases,words,negative);$finish;
  end
  initial begin #1000000;$fatal(1,"Dynamic reduce watchdog");end
endmodule
