`timescale 1ns/1ps
// Independent numeric ordering oracle for the production row serializer/MAX.
// Includes signed zeros, finite/subnormal inputs, masks, errors and stalls.
module tb_qk_max_order;
  import pcore_pkg::*;
  localparam int COUNT=256;
  logic clk=0;always #2 clk=~clk;
  logic reset=1,clear=0,in_valid=0,in_ready,out_valid,out_ready;
  vpu_cmd_t in_cmd,out_cmd,expected_cmd[COUNT];
  logic [PAIR_BITS-1:0] in_pair_idx,out_pair_idx,expected_pair[COUNT];
  logic [1:0] in_row_valid,out_row_valid;
  logic [1:0][15:0][31:0] in_score,capture_masked_score;
  logic [1:0][15:0] in_effective_mask;
  logic [1:0][31:0] in_m_old,out_row_max,out_m_new,out_aa;
  logic [1:0] out_empty_row,out_initial_row,out_numeric_error;
  logic [1:0][31:0] expected_max[COUNT],expected_new[COUNT];
  logic [1:0] expected_empty[COUNT],expected_initial[COUNT],expected_error[COUNT];
  int cycle=0,launched=0,received=0;
  dea8_vpu_qk_row16 dut(.*);

  function automatic logic [31:0] numeric_max(input logic [31:0] a,b);
    shortreal x,y;
    x=$bitstoshortreal(a);y=$bitstoshortreal(b);
    if(x==0.0&&y==0.0)return 32'b0;
    return x>=y?a:b;
  endfunction
  always @(negedge clk)out_ready=(cycle%17)<11;
  always @(posedge clk)begin
    cycle++;
    if(!reset)begin
      if(in_valid&&in_ready)begin
        expected_cmd[launched]=in_cmd;expected_pair[launched]=in_pair_idx;
        expected_max[launched]=0;expected_new[launched]=0;
        expected_empty[launched]=0;expected_initial[launched]=0;expected_error[launched]=0;
        for(int r=0;r<2;r++)if(in_row_valid[r])begin
          logic [31:0] maximum,value;
          bit bad,finite_seen,empty;
          maximum=32'hff800000;finite_seen=0;empty=in_effective_mask[r]==0;
          bad=((&in_m_old[r][30:23])&&(|in_m_old[r][22:0]))||in_m_old[r]==32'h7f800000;
          for(int lane=0;lane<16;lane++)begin
            value=32'hff800000;
            if(in_effective_mask[r][lane])begin
              value=in_score[r][lane];
              finite_seen|=value[30:23]!=255;
              if((value[30:23]==255&&value[22:0]!=0)||value==32'h7f800000)begin
                bad=1;value=32'hff800000;
              end
            end
            maximum=numeric_max(maximum,value);
          end
          if(!empty&&in_m_old[r]==32'hff800000&&!finite_seen)bad=1;
          expected_max[launched][r]=maximum;
          expected_new[launched][r]=(empty||bad)?in_m_old[r]:numeric_max(in_m_old[r],maximum);
          expected_empty[launched][r]=empty;expected_error[launched][r]=bad;
          expected_initial[launched][r]=!empty&&!bad&&in_m_old[r]==32'hff800000;
        end
        launched++;
      end
      if(out_valid&&out_ready)begin
        if(received>=launched||out_cmd!==expected_cmd[received]||out_pair_idx!==expected_pair[received]||
           out_row_valid!==row_mask(expected_pair[received]))$fatal(1,"QK order/identity transaction=%0d",received);
        for(int r=0;r<2;r++)if(out_row_valid[r])begin
          if(out_row_max[r]!==expected_max[received][r]||out_m_new[r]!==expected_new[received][r]||
             out_empty_row[r]!==expected_empty[received][r]||out_initial_row[r]!==expected_initial[received][r]||
             out_numeric_error[r]!==expected_error[received][r])
            $fatal(1,"QK MAX transaction=%0d row=%0d max=%h/%h new=%h/%h flags=%b%b%b/%b%b%b",received,r,
              out_row_max[r],expected_max[received][r],out_m_new[r],expected_new[received][r],
              out_empty_row[r],out_initial_row[r],out_numeric_error[r],
              expected_empty[received][r],expected_initial[received][r],expected_error[received][r]);
          if(expected_initial[received][r]&&out_aa[r]!==32'hff800000)$fatal(1,"QK initial bypass");
          if((expected_empty[received][r]||expected_error[received][r])&&out_aa[r]!==0)$fatal(1,"QK empty/error bypass");
        end
        received++;
      end
    end
  end
  initial begin
    int seed=91821;
    seed=$urandom(seed);in_cmd='0;in_score='0;in_effective_mask='0;in_m_old='0;
    in_pair_idx=0;in_row_valid=0;
    repeat(35)@(negedge clk);reset=0;repeat(8)@(negedge clk);
    for(int t=0;t<COUNT;t++)begin
      @(negedge clk);in_cmd='0;in_cmd.op=VPU_QK_POST;in_cmd.block_id=t%55;in_cmd.epoch=t%16;
      in_cmd.head=t%8;in_cmd.facc_bank=t%2;in_pair_idx=t%PAIRS;in_row_valid=row_mask(in_pair_idx);
      for(int r=0;r<2;r++)begin
        case(t%6)
          0:in_m_old[r]=32'hff800000;
          1:in_m_old[r]=32'h80000000;
          2:in_m_old[r]=0;
          3:in_m_old[r]=32'hbf800000;
          4:in_m_old[r]=32'h7fc00001;
          5:in_m_old[r]=32'h7f800000;
        endcase
        in_effective_mask[r]=(t%13==0)?0:(t%5==0?16'h0001:16'($urandom));
        for(int lane=0;lane<16;lane++)begin
          case(t%8)
            0:in_score[r][lane]=32'h80000000;
            1:in_score[r][lane]=(lane==0)?32'h80000000:32'hbf800000;
            2:in_score[r][lane]=lane%2?0:32'h80000000;
            3:in_score[r][lane]=32'hff800000;
            4:in_score[r][lane]=lane%2?32'h7fc00001:32'h7f800000;
            5:in_score[r][lane]=32'h80000001+32'(lane);
            default:begin
              in_score[r][lane]=$urandom;
              if(in_score[r][lane][30:23]==255)in_score[r][lane][30:23]=254;
            end
          endcase
        end
      end
      in_valid=1;do @(posedge clk);while(!in_ready);@(negedge clk);in_valid=0;
      repeat(t%3)@(negedge clk);
    end
    wait(received==COUNT);@(negedge clk);
    $display("tb_qk_max_order PASS pairs=%0d numeric_oracle=shortreal signed_zero=1 subnormal=1 nonfinite=1 masks=1 stalls=1",received);$finish;
  end
  initial begin #200000;$fatal(1,"QK MAX timeout launched=%0d received=%0d",launched,received);end
endmodule
