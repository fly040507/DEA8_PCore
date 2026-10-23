`timescale 1ns/1ps
import pcore_pkg::*;
import pcore_control_pkg::*;

module tb_compute_sfu #(parameter bit SHARED=0);
  logic clk=0;always #2 clk=~clk;
  logic reset=1,flush=0,flush_ack,protocol_error;
  logic function_valid=0,function_ready,function_done_valid,function_done_ready=1;
  control_command_t function_cmd;
  control_unit_done_t function_done;
  logic function_data_valid=0,function_data_ready,function_result_valid,function_result_ready=1;
  control_fp_data_t function_data,function_result;
  logic function_mem_valid,function_mem_ready,function_mem_out_valid,function_mem_out_ready;
  control_memory_req_t function_mem_req;
  control_memory_rsp_t function_mem_out;
  logic rope_valid=0,rope_ready,rope_out_valid,rope_out_ready=1;
  control_rope_req_t rope_req;
  control_rope_rsp_t rope_out;
  logic config_valid=0,config_ready,config_out_valid;
  control_memory_req_t config_req;
  control_memory_rsp_t config_out;
  logic [127:0] scalar[51];logic [95:0] score[816];logic [63:0] gelu[816];
  int cycle=0,reads=0,writes=0,results=0,commands=0,start_cycle;
  logic add_ready,guest_mode;
  logic [3:0] add_valid,add_out_valid;
  logic [3:0][31:0] add_a,add_b,add_y;
  logic [4:0] mul_valid,mul_out_valid;
  logic [4:0][31:0] mul_a,mul_b,mul_y;
  dea8_sfu_top #(.EXTERNAL_ARITHMETIC(SHARED)) dut(.rope_load_valid(1'b0),.rope_load_ready(),.rope_load_address('0),
    .rope_load_data('0),.rope_load_last(1'b0),.rope_loaded(),.*);
  if(SHARED)begin
    logic primary_valid=0,primary_ready,primary_out;
    dea8_vpu_math_pkg::pair_fp_t primary_a,primary_b,primary_y;
    int primary_issued=0,primary_received=0;
    always @(negedge clk)begin
      primary_valid=!reset&&guest_mode&&primary_ready&&primary_issued<100&&cycle%5==0;
      primary_a='0;primary_b='0;
      for(int lane=0;lane<16;lane++)begin
        primary_a[0][lane]=32'h3f800000|32'(primary_issued*32+lane);primary_b[0][lane]=32'h40000000;
      end
    end
    always @(posedge clk)if(!reset)begin
      if(primary_valid&&primary_ready)primary_issued++;
      if(primary_out)begin
        for(int lane=0;lane<16;lane++)if(primary_y[0][lane]!== (32'h40000000|32'(primary_received*32+lane)))
          $fatal(1,"GELU/Up MUL sharing corrupted row=%0d lane=%0d",primary_received,lane);
        primary_received++;
      end
      if(commands==4&&primary_received!=100)$fatal(1,"GELU/Up sharing accounting %0d",primary_received);
    end
    dea8_vpu_pair_mul16 #(.SHARED_GELU(1)) fabric_mul(.clk,.reset,.clear(flush),
      .in_valid(primary_valid),.in_ready(primary_ready),.out_valid(primary_out),.a(primary_a),.b(primary_b),.y(primary_y),.error(),
      .guest_mode,.guest_valid(mul_valid),.guest_a(mul_a),.guest_b(mul_b),.guest_out_valid(mul_out_valid),.guest_y(mul_y));
    dea8_vpu_p_pipe #(.SHARE_ADD(1)) fabric_add(.clk,.reset,.clear(flush),
      .in_valid(1'b0),.x('0),.product('0),.product_error('0),.input_error('0),.out_valid(),.lvalue(),.error(),
      .rope_mode(1'b0),.rope_in_valid(1'b0),.rope_a('0),.rope_b('0),.rope_out_valid(),.rope_y(),
      .guest_valid(add_valid),.guest_a(add_a),.guest_b(add_b),.guest_ready(add_ready),.guest_out_valid(add_out_valid),.guest_y(add_y));
  end else begin assign add_ready=1;assign add_out_valid=0;assign add_y=0;assign mul_out_valid=0;assign mul_y=0;end
  dea8_pcore_workspace workspace(.clk,.reset,.clear(flush),
    .v_valid(config_valid),.v_ready(config_ready),.v_req(config_req),
    .v_out_valid(config_out_valid),.v_out_ready(1'b1),.v_out(config_out),
    .f_valid(function_mem_valid),.f_ready(function_mem_ready),.f_req(function_mem_req),
    .f_out_valid(function_mem_out_valid),.f_out_ready(function_mem_out_ready),.f_out(function_mem_out));

  task automatic near_fp(input logic [31:0] actual,expected,input int address,input int tolerance);
    longint signed delta;
    if((^actual)===1'bx||actual[30:23]==255)$fatal(1,"Nonfinite SFU fn=%0d address=%0d got=%h",function_cmd.function_id,address,actual);
    delta=longint'({1'b0,actual[30:0]})-longint'({1'b0,expected[30:0]});
    if(expected[30:0]==0)begin
      if(actual[30:0]!=0)$fatal(1,"SFU zero fn=%0d address=%0d got=%h",function_cmd.function_id,address,actual);
    end else if(actual[31]!=expected[31]||delta>tolerance||delta< -tolerance)
      $fatal(1,"SFU numerical fn=%0d address=%0d got=%h expected=%h ulp=%0d",function_cmd.function_id,address,actual,expected,delta);
  endtask
  always @(posedge clk)begin
    cycle++;
    if(!reset&&!flush)begin
      if(protocol_error)$fatal(1,"SFU protocol state=%0d emit=%0d return=%0d",dut.state,dut.emitted,dut.returned);
      if(function_valid&&function_ready)begin reads=0;writes=0;results=0;start_cycle=cycle;end
      if(function_mem_valid&&function_mem_ready)begin
        if(!function_mem_req.write)reads++;
        else begin
          for(int j=0;j<16;j++)if(function_mem_req.mask[j])begin
            if(function_cmd.function_id==FUNCTION_ALPHA_EXP)
              near_fp(function_mem_req.data[j],scalar[function_mem_req.index+j][95:64],function_mem_req.index+j,4);
            else if(function_cmd.function_id==FUNCTION_RECIP)
              near_fp(function_mem_req.data[j],scalar[function_mem_req.index+j][31:0],function_mem_req.index+j,2);
            else $fatal(1,"Unexpected SFU memory write");
          end
          writes++;
        end
      end
      if(function_result_valid&&function_result_ready)begin
        if(function_result.token!=function_cmd.token||function_result.index!=results||function_result.job!=function_cmd.job)
          $fatal(1,"SFU result identity");
        if(function_cmd.function_id==FUNCTION_P_EXP)begin
          if(function_result.vector_valid!=row_mask(results)||function_result.last!=(results==PAIRS-1))$fatal(1,"P tail");
          for(int h=0;h<2;h++)if(function_result.vector_valid[h])for(int j=0;j<16;j++)
            near_fp(h?function_result.second[j]:function_result.first[j],score[(2*results+h)*16+j][31:0],(2*results+h)*16+j,4);
        end else begin
          if(function_result.vector_valid!=1||function_result.last!=(results==50))$fatal(1,"GELU tail");
          for(int j=0;j<16;j++)near_fp(function_result.first[j],gelu[16*results+j][31:0],16*results+j,12);
        end
        results++;
      end
      if(function_done_valid&&function_done_ready)begin
        if(function_done.error||function_done.command!==function_cmd)$fatal(1,"SFU done");
        case(function_cmd.function_id)
          FUNCTION_ALPHA_EXP,FUNCTION_RECIP:if(reads!=4||writes!=4||results!=0)$fatal(1,"Scalar transaction count");
          FUNCTION_P_EXP:if(reads!=55||writes!=0||results!=26)$fatal(1,"P transaction count");
          FUNCTION_GELU:if(reads!=0||writes!=0||results!=51)$fatal(1,"GELU transaction count");
        endcase
        commands++;
        $display("SFU_PASS fn=%0d cycles=%0d reads=%0d writes=%0d results=%0d",function_cmd.function_id,cycle-start_cycle,reads,writes,results);
      end
    end
  end
  always @(negedge clk)if(!reset)function_result_ready=(cycle%23)<17;
  task automatic write_word(input control_buffer_e object_id,input int row,input logic [15:0][31:0] value,input logic [15:0] mask);
    @(negedge clk);config_req='0;config_req.write=1;config_req.buffer_id=object_id;
    config_req.index=6'(row);config_req.data=value;config_req.mask=mask;config_valid=1;
    do @(posedge clk);while(!config_ready);
    @(negedge clk);config_valid=0;
  endtask
  task automatic start_command(input control_function_e fn);
    @(negedge clk);function_cmd='0;function_cmd.function_id=fn;function_cmd.token=commands+1;function_valid=1;
    do @(posedge clk);while(!function_ready);
    @(negedge clk);function_valid=0;
  endtask
  task automatic finish_command(input int expected_commands);
    wait(commands==expected_commands);@(negedge clk);
  endtask
  initial begin
    logic [15:0][31:0] value;
    $readmemh("tb/data/compute/sfu_scalar.mem",scalar);
    $readmemh("tb/data/compute/sfu_score.mem",score);
    $readmemh("tb/data/compute/sfu_gelu.mem",gelu);
    config_req='0;function_cmd='0;function_data='0;rope_req='0;
    repeat(35)@(negedge clk);reset=0;repeat(8)@(negedge clk);
    for(int row=0;row<51;row++)begin
      for(int j=0;j<16;j++)value[j]=score[16*row+j][95:64];
      write_word(WORK_SCORE,row,value,'1);
    end
    for(int base=0;base<51;base+=16)begin
      value='0;for(int j=0;j<16;j++)if(base+j<51)value[j]=scalar[base+j][127:96];
      write_word(WORK_AA,base,value,base==48?16'h7:16'hffff);
      value='0;for(int j=0;j<16;j++)if(base+j<51)value[j]=score[(base+j)*16][63:32];
      write_word(WORK_M,base,value,base==48?16'h7:16'hffff);
      value='0;for(int j=0;j<16;j++)if(base+j<51)value[j]=scalar[base+j][63:32];
      write_word(WORK_L,base,value,base==48?16'h7:16'hffff);
    end
    start_command(FUNCTION_ALPHA_EXP);finish_command(1);
    start_command(FUNCTION_P_EXP);finish_command(2);
    start_command(FUNCTION_RECIP);finish_command(3);
    start_command(FUNCTION_GELU);
    for(int row=0;row<51;row++)begin
      @(negedge clk);function_data='0;function_data.job=function_cmd.job;function_data.token=function_cmd.token;
      function_data.index=row;function_data.vector_valid=1;function_data.last=row==50;
      for(int j=0;j<16;j++)function_data.first[j]=gelu[row*16+j][63:32];
      function_data_valid=1;do @(posedge clk);while(!function_data_ready);
      @(negedge clk);function_data_valid=0;
    end
    finish_command(4);
    @(negedge clk);flush=1;wait(flush_ack);@(negedge clk);flush=0;
    $display("tb_compute_sfu PASS commands=4 P_elements=816 GELU_elements=816 real_workspace=1 backpressure=1");$finish;
  end
  initial begin #100000;$fatal(1,"SFU timeout state=%0d emitted=%0d returned=%0d",dut.state,dut.emitted,dut.returned);end
endmodule
