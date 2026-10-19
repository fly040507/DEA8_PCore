`timescale 1ns/1ps
module tb_qk_special_rows;
  import pcore_pkg::*;
  logic clk=0;always #2 clk=~clk;
  logic reset=1,clear=0,in_valid=0,in_ready,out_valid,out_ready=1;
  vpu_cmd_t in_cmd,out_cmd;
  logic [PAIR_BITS-1:0] in_pair_idx,out_pair_idx;
  logic [1:0] in_row_valid,out_row_valid;
  logic [1:0][15:0][31:0] in_score,capture_masked_score;
  logic [1:0][15:0] in_effective_mask;
  logic [1:0][31:0] in_m_old,out_row_max,out_m_new,out_aa;
  logic [1:0] out_empty_row,out_initial_row,out_numeric_error;
  int count=0,cycle=0;
  dea8_vpu_qk_post_pair_v3 dut(.*);
  always @(posedge clk)begin
    cycle++;
    if(out_valid&&out_ready)begin
      case(count)
        0:if(out_pair_idx!=0||out_numeric_error!=0||out_empty_row!=1||out_initial_row!=2||
          out_m_new!=={32'hbf800000,32'hff800000}||out_aa!=={32'hff800000,32'b0})$fatal(1,"Empty/initial QK policy");
        1:if(out_pair_idx!=1||out_numeric_error!=0||out_empty_row!=1||out_initial_row!=0||
          out_m_new!=={32'hbf800000,32'h40a00000}||out_aa!=={32'hc1f80000,32'b0})$fatal(1,"QK signed maximum/history");
        2:if(out_pair_idx!=25||out_row_valid!=1||out_numeric_error!=0||out_initial_row!=1)$fatal(1,"QK row50 tail");
        default:$fatal(1,"Extra QK output");
      endcase
      count++;
    end
  end
  task automatic submit(input int p);
    @(negedge clk);in_pair_idx=PAIR_BITS'(p);in_row_valid=row_mask(p);in_valid=1;
    do @(posedge clk);while(!in_ready);@(negedge clk);in_valid=0;
  endtask
  initial begin
    in_cmd='0;in_cmd.op=VPU_QK_POST;in_score='0;in_m_old='0;in_effective_mask='0;
    repeat(35)@(negedge clk);reset=0;repeat(8)@(negedge clk);
    for(int j=0;j<16;j++)begin in_score[0][j]=32'h7fc00000;in_score[1][j]=32'hbf800000;end
    in_effective_mask={16'hffff,16'h0};in_m_old={2{32'hff800000}};submit(0);
    in_m_old={32'hc2000000,32'h40a00000};submit(1);
    in_effective_mask={16'h0,16'h1};in_score[0][0]=32'hbf800000;in_m_old={32'b0,32'hff800000};submit(25);
    wait(count==3);@(negedge clk);
    $display("tb_qk_special_rows PASS empty_block=1 first_nonempty=1 signed_max=1 masked_nan=1 row50=1");$finish;
  end
  initial begin #20000;$fatal(1,"QK policy watchdog");end
endmodule
