`timescale 1ns/1ps
import pcore2_pkg::*;
module tb_dea8_mxu_2row;
  logic clk=0;always #2 clk=~clk;
  logic reset=1,clear=0,req_valid=0,req_bank=0,load_valid=0,load_bank=0;
  a2_t req;
  tag_t req_tag[0:1],rsp_tag[0:1];
  dest_t req_dest[0:1],rsp_dest[0:1];
  b_t load_entry;
  logic [$clog2(TILE)-1:0] load_column=0;
  logic rsp_valid;
  logic [1:0] rsp_row_valid;
  logic signed [1:0][TILE-1:0][PSUM_BITS-1:0] psum;
  logic [1:0][SCALE_BITS-1:0] rsp_scale;
  logic [TILE-1:0][SCALE_BITS-1:0] rsp_e_stat;
  int signed weights[0:1][0:TILE-1][0:TILE-1];
  int signed expected[0:511][0:1][0:TILE-1];
  a2_t expected_req[0:511];
  tag_t expected_tag[0:511][0:1];
  dest_t expected_dest[0:511][0:1];
  logic [TILE-1:0][SCALE_BITS-1:0] expected_stat[0:511],stats[0:1];
  int due[0:511],sent=0,seen=0,cycle=0;
  dea8_mxu_2row dut(.*);
  always @(posedge clk) begin
    cycle++;
    if(!reset && !clear && req_valid) begin
      due[sent]=cycle+STAGES-1;
      expected_req[sent]=req;expected_stat[sent]=stats[req_bank];
      for(int r=0;r<ROW_LANES;r++) begin
        expected_tag[sent][r]=req_tag[r];expected_dest[sent][r]=req_dest[r];
        for(int n=0;n<TILE;n++) begin
          expected[sent][r][n]=0;
          if(req.row_valid[r]) for(int k=0;k<TILE;k++)
            expected[sent][r][n]+=$signed(req.data[r][k*INT_BITS+:INT_BITS])*weights[req_bank][k][n];
        end
      end
      sent++;
    end
    #1;
    if(!reset && !clear) begin
      if(rsp_valid !== (seen<sent && due[seen]==cycle)) $fatal(1,"MXU latency cycle=%0d",cycle);
      if(rsp_valid) begin
        if(rsp_row_valid!==expected_req[seen].row_valid ||
           rsp_scale!==expected_req[seen].scale || rsp_e_stat!==expected_stat[seen])
          $fatal(1,"MXU scale/mask alignment");
        for(int r=0;r<ROW_LANES;r++) begin
          if(rsp_tag[r]!==expected_tag[seen][r] || rsp_dest[r]!==expected_dest[seen][r])
            $fatal(1,"MXU tag/dest alignment");
          for(int n=0;n<TILE;n++)
            if($signed(psum[r][n])!==expected[seen][r][n])
              $fatal(1,"MXU result pair=%0d r=%0d n=%0d got=%0d expected=%0d",seen,r,n,$signed(psum[r][n]),expected[seen][r][n]);
        end
        seen++;
      end
    end
  end
  initial begin
    req='0;load_entry='0;
    for(int r=0;r<ROW_LANES;r++) begin req_tag[r]='0;req_dest[r]='0;end
    repeat(32) @(negedge clk);reset=0;
    for(int bank=0;bank<2;bank++) begin
      for(int col=0;col<TILE;col++) begin
        @(negedge clk);load_valid=1;load_bank=bank;load_column=col;
        for(int k=0;k<TILE;k++) begin
          weights[bank][k][col]=((bank*67+k*29+col*13)%256)-128;
          load_entry.data[k*INT_BITS+:INT_BITS]=8'(weights[bank][k][col]);
        end
        load_entry.scale=8'(bank*53+col);stats[bank][col]=load_entry.scale;
      end
    end
    @(negedge clk);load_valid=0;
    for(int t=0;t<8;t++) begin
      for(int p=0;p<PAIRS;p++) begin
        @(negedge clk);req_valid=1;req_bank=t%2;
        req.pair_idx=p;req.tile_idx=t;req.slot=t%2;req.row_valid=row_mask(p);
        for(int r=0;r<ROW_LANES;r++) begin
          req.scale[r]=8'(t*17+p*3+r);
          req_tag[r].row=2*p+r;req_tag[r].kt=t;req_tag[r].nt=7;req_tag[r].last=p==PAIRS-1;
          req_dest[r].address=t*64+2*p+r;req_dest[r].bank=t%4;req_dest[r].zero=t==0;
          for(int k=0;k<TILE;k++) req.data[r][k*INT_BITS+:INT_BITS]=8'(t*47+p*19+r*97+k*11);
        end
      end
      @(negedge clk);req_valid=0;
      repeat(t%3) @(negedge clk);
    end
    wait(seen==sent);repeat(3) @(negedge clk);
    clear=1;@(negedge clk);clear=0;
    if(rsp_valid) $fatal(1,"MXU clear");
    $display("tb_dea8_mxu_2row PASS pairs=%0d checked_psums=%0d S0_to_S6=6_cycles",seen,seen*ROW_LANES*TILE);
    $finish;
  end
  initial begin #20000;$fatal(1,"MXU watchdog");end
endmodule
