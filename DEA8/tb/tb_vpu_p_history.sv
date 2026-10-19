`timescale 1ns/1ps
import pcore_pkg::*;
import pcore_control_pkg::*;
module tb_vpu_p_history;
  logic clk=0;always #2 clk=~clk;
  logic reset=1,clear=0,flush_valid=0,vpu_flush_ack;
  logic vector_valid=0,vector_ready,vector_done_valid,vector_done_ready=1;
  control_command_t vector_cmd;control_unit_done_t vector_done;
  logic vector_data_valid=0,vector_data_ready;control_fp_data_t vector_data;
  logic vector_result_valid,vector_result_ready=1;control_quant_result_t vector_result;
  logic vector_mem_valid,vector_mem_ready,vector_mem_out_valid,vector_mem_out_ready;
  control_memory_req_t vector_mem_req;control_memory_rsp_t vector_mem_out;
  logic acc_rd_valid,acc_rd_ready=0,acc_data_valid=0,acc_data_ready;
  acc_sel_e acc_rd_sel;logic [9:0] acc_rd_addr;control_token_t acc_token;
  logic [15:0][31:0] acc_even=0,acc_odd=0;
  logic acc_wr_valid,acc_wr_ready=0;acc_write_t acc_wr;
  logic rope_req_valid,rope_req_ready=0,rope_out_valid=0,rope_out_ready;
  control_rope_req_t rope_req;control_rope_rsp_t rope_out;
  logic mask_config_valid=0;logic [15:0] mask_state=0,mask_action=0;
  logic cfg_valid=0,cfg_ready,cfg_out_valid;control_memory_req_t cfg;control_memory_rsp_t cfg_out;
  int writes=0,results=0;
  dea8_vpu_top dut(.*);
  dea8_pcore_workspace workspace(.clk,.reset,.clear,
    .v_valid(vector_mem_valid),.v_ready(vector_mem_ready),.v_req(vector_mem_req),
    .v_out_valid(vector_mem_out_valid),.v_out_ready(vector_mem_out_ready),.v_out(vector_mem_out),
    .f_valid(cfg_valid),.f_ready(cfg_ready),.f_req(cfg),.f_out_valid(cfg_out_valid),.f_out_ready(1'b1),.f_out(cfg_out));
  task automatic init_stat(input control_buffer_e obj,input int row,input logic [31:0] value);
    @(negedge clk);cfg='0;cfg.write=1;cfg.buffer_id=obj;cfg.bank=obj==WORK_ALPHA;cfg.index=6'(row);cfg.mask=row==48?16'h7:16'hffff;
    for(int j=0;j<16;j++)cfg.data[j]=value;
    cfg_valid=1;do @(posedge clk);while(!cfg_ready);@(negedge clk);cfg_valid=0;
  endtask
  always @(posedge clk)if(!reset)begin
    if(vector_mem_valid&&vector_mem_ready&&vector_mem_req.write)begin
      for(int j=0;j<16;j++)if(vector_mem_req.mask[j]&&vector_mem_req.data[j]!==32'h41c00000)
        $fatal(1,"P_POST lost old history row=%0d got=%h expected=24",vector_mem_req.index+j,vector_mem_req.data[j]);
      writes++;
    end
    if(vector_result_valid&&vector_result_ready)results++;
    if(vector_done_valid&&vector_done.error)$fatal(1,"VPU numerical error");
    if(dut.p_in&&dut.issued==0)$display("P_HISTORY_INPUT alpha=%h old_l=%h",dut.mul_a[0][0],dut.mul_b[0][0]);
    if(dut.p_pipe.valid_q[43])$display("P_HISTORY_FINAL a=%h b=%h",dut.p_pipe.product_aligned[0],dut.p_pipe.rows[0].node_y[14]);
  end
  initial begin
    vector_cmd='0;vector_data='0;rope_out='0;cfg='0;
    repeat(35)@(negedge clk);reset=0;repeat(8)@(negedge clk);
    for(int row=0;row<51;row+=16)begin init_stat(WORK_L,row,32'h41800000);init_stat(WORK_ALPHA,row,32'h3f000000);end
    vector_cmd='0;vector_cmd.function_id=VECTOR_P_POST;vector_cmd.job.header.op=OP_ATTENTION;vector_cmd.token=1;vector_cmd.tile=1;
    @(negedge clk);vector_valid=1;do @(posedge clk);while(!vector_ready);@(negedge clk);vector_valid=0;
    for(int p=0;p<26;p++)begin
      vector_data='0;vector_data.job=vector_cmd.job;vector_data.token=vector_cmd.token;
      vector_data.tile=1;vector_data.index=p;vector_data.vector_valid=row_mask(p);vector_data.last=p==25;vector_data.token_mask='1;
      for(int j=0;j<16;j++)begin vector_data.first[j]=32'h3f800000;vector_data.second[j]=p==25?0:32'h3f800000;end
      @(negedge clk);vector_data_valid=1;do @(posedge clk);while(!vector_data_ready);
      @(negedge clk);vector_data_valid=0;repeat(7)@(negedge clk);
    end
    wait(vector_done_valid);if(writes!=4||results!=26)$fatal(1,"P_POST accounting");
    $display("tb_vpu_p_history PASS rows=51 old_l=16 alpha=0.5 sumP=16 result=24");$finish;
  end
  initial begin #30000;$fatal(1,"P history watchdog");end
endmodule
