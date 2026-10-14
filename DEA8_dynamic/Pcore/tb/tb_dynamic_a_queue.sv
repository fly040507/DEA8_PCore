`timescale 1ns/1ps
import pcore_pkg::*;
module tb_dynamic_a_queue;
  logic clk=0;always #2 clk=~clk;
  logic reset=1,clear=0,desc_valid=0,desc_ready,in_valid=0,in_ready;
  a_slot_desc_t desc='0;a3_beat_t in_entry='0;
  logic out_valid,out_ready=0,tile_available,empty,protocol_error;
  logic input_closed;
  a2_t out_entry;
  logic [$clog2(A_SLOTS+1)-1:0] used_slots;
  dea8_a_queue dut(.*);
  a_slot_desc_t expected[0:8];
  int slot_index=0,use_index=0,pair_index=0,checks=0,cycle=0;
  bit consuming=0,held=0;
  a2_t held_entry;
  function automatic int data_value(input int occurrence,row,k);
    return (occurrence*13+row*17+k*29)&255;
  endfunction
  function automatic int scale_value(input int occurrence,row);
    return (128+occurrence+row)&255;
  endfunction
  task automatic fill(input int number,rows,uses,base);
    a_slot_desc_t d;a3_beat_t entry;
    d='0;d.token=32'hf1234567;d.work_seq=91;d.occurrence_seq=SEQ_BITS'(number);
    d.first_tile=SEQ_BITS'(base);d.m_rows=ROW_COUNT_BITS'(rows);d.uses=5'(uses);expected[number]=d;
    @(negedge clk);desc=d;desc_valid=1;
    do @(posedge clk);while(!desc_ready);
    @(negedge clk);desc_valid=0;
    for(int g=0;g<(rows+A_INPUT_ROWS-1)/A_INPUT_ROWS;g++)begin
      entry='0;entry.token=d.token;entry.work_seq=d.work_seq;entry.occurrence_seq=d.occurrence_seq;
      entry.group_idx=A_GROUP_BITS'(g);entry.row_valid=a_group_mask(rows,g);
      for(int r=0;r<A_INPUT_ROWS;r++)begin
        entry.row[r].scale=8'(scale_value(number,g*A_INPUT_ROWS+r));
        for(int k=0;k<TILE;k++)entry.row[r].data[k*INT_BITS+:INT_BITS]=8'(data_value(number,g*A_INPUT_ROWS+r,k));
      end
      in_entry=entry;in_valid=1;do @(posedge clk);while(!in_ready);@(negedge clk);
    end
    in_valid=0;
  endtask
  always @(negedge clk)if(!reset&&!clear)out_ready=consuming&&cycle%5!=2;
  always @(posedge clk)begin
    a_slot_desc_t d;int row;
    cycle++;
    if(reset||clear)held=0;
    else begin
      if(protocol_error)$fatal(1,"A queue protocol error");
      if(held&&(!out_valid||out_entry!==held_entry))$fatal(1,"A queue output changed while stalled");
      held=out_valid&&!out_ready;held_entry=out_entry;
      if(out_valid&&out_ready)begin
        d=expected[slot_index];
        if(out_entry.token!=d.token||out_entry.work_seq!=d.work_seq||
          out_entry.tile_idx!=int'(d.first_tile)+use_index||out_entry.pair_idx!=pair_index||
          out_entry.row_valid!==row_mask_for_rows(d.m_rows,pair_index)||tile_available!==(pair_index==0))
          $fatal(1,"A queue replay/metadata");
        for(int r=0;r<ROW_LANES;r++)begin
          row=pair_index*ROW_LANES+r;
          if(row<int'(d.m_rows))begin
            if(out_entry.row[r].scale!==8'(scale_value(d.occurrence_seq,row)))$fatal(1,"A queue scale");
            for(int k=0;k<TILE;k++)if(out_entry.row[r].data[k*INT_BITS+:INT_BITS]!==
              8'(data_value(d.occurrence_seq,row,k)))$fatal(1,"A row steering %0d",row);
          end else if(out_entry.row[r]!=='0)$fatal(1,"A queue stale tail");
        end
        checks++;
        if(pair_index+1==pairs_for_rows(d.m_rows))begin
          pair_index=0;
          if(use_index+1==int'(d.uses))begin use_index=0;slot_index++;end
          else use_index++;
        end else pair_index++;
      end
    end
  end
  initial begin
    repeat(4)@(negedge clk);reset=0;
    for(int batch=0;batch<3;batch++)begin
      fill(batch*3,51,1,300+batch*100);
      fill(batch*3+1,11,2,700+batch*100);
      fill(batch*3+2,1,16,1000+batch*100);
      if(used_slots!=A_SLOTS||desc_ready)$fatal(1,"A queue full reservation");
      consuming=1;
      while(slot_index<(batch+1)*3)@(negedge clk);
      consuming=0;@(negedge clk);
      if(!empty||used_slots!=0)$fatal(1,"A queue slot release");
    end
    $display("tb_dynamic_a_queue PASS slots=9 pair_checks=%0d replay=1,2,16 wrap=1 stall_hold=1 row2_row3=1",checks);
    $finish;
  end
  initial begin #200000;$fatal(1,"A queue watchdog");end
endmodule
