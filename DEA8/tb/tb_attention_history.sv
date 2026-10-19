`timescale 1ns/1ps
import pcore_pkg::*;import pcore_control_pkg::*;import dea8_tile_link_pkg::*;
// Focused controller integration regression. A Q input fixture is installed
// through the control unit's explicit management port BEFORE Attention starts.
// This is not the production seven-Job acceptance and is never its evidence.
module tb_attention_history;
  logic clk=0;always #2 clk=~clk;
  logic reset=1,clear=0,job_valid=0,job_ready,done_valid,done_ready=0,busy,protocol_error;
  control_job_t job;control_completion_t done;logic [1:0] active_adapter;
  logic flush_valid,vpu_flush_ack,sfu_flush_ack;
  logic xbc_valid=0,xbc_ready,hbm_valid=0,hbm_ready,kv_valid=0,kv_ready;
  xbc4_t xbc_entry;b2_t hbm_entry,kv_entry;
  logic vector_valid,vector_ready,vector_done_valid,vector_done_ready;
  control_command_t vector_cmd;control_unit_done_t vector_done;
  logic function_valid,function_ready,function_done_valid,function_done_ready;
  control_command_t function_cmd;control_unit_done_t function_done;
  logic vector_data_valid,vector_data_ready,function_data_valid,function_data_ready;
  control_fp_data_t vector_data,function_data,function_result;
  logic function_result_valid,function_result_ready,vector_result_valid,vector_result_ready;
  control_quant_result_t vector_result;
  logic vector_mem_valid,vector_mem_ready,vector_mem_out_valid,vector_mem_out_ready;
  logic function_mem_valid,function_mem_ready,function_mem_out_valid,function_mem_out_ready;
  control_memory_req_t vector_mem_req,function_mem_req;control_memory_rsp_t vector_mem_out,function_mem_out;
  logic rope_req_valid,rope_req_ready,rope_sfu_valid,rope_sfu_ready,rope_sfu_out_valid,rope_sfu_out_ready,rope_out_valid,rope_out_ready;
  control_rope_req_t rope_req,rope_sfu_req;control_rope_rsp_t rope_sfu_out,rope_out;
  logic tx_valid,tx_ready=1,tx_last;logic [255:0] tx_data;
  logic kv_commit_valid=0,kv_commit_ready;tile_commit_t kv_commit;
  logic acc_rd_valid,acc_rd_ready,acc_data_valid,acc_data_ready,acc_wr_valid,acc_wr_ready;
  acc_sel_e acc_rd_sel;logic [9:0] acc_rd_addr;control_token_t acc_token;
  logic [15:0][31:0] acc_even,acc_odd;acc_write_t acc_wr;
  logic qoz_complete;qoz_region_req_t qoz_region;
  logic ext_qoz_region_valid=0,ext_qoz_region_ready,ext_qoz_wr_valid=0,ext_qoz_wr_ready;
  qoz_region_req_t ext_qoz_region;post_result_t ext_qoz_wr;logic [15:0] ext_qoz_context=16'h1234;
  logic gu_prefetch_valid,gu_prefetch_ready=1;logic [5:0] gu_prefetch_n;
  logic mask_config_valid=1;logic [15:0] mask_state='1,mask_action='1;
  logic sfu_error;
  logic [135:0] qgold[816];logic [127:0] stats[2805];
  int cycle=0,issue_job=0,previous_issue=-1;bit hiding_audit=0;
  dea8_pcore_control dut(.*);
  dea8_vpu_top vpu(.clk,.reset,.clear,.flush_valid,.vpu_flush_ack,
    .vector_valid,.vector_ready,.vector_cmd,.vector_done_valid,.vector_done_ready,.vector_done,
    .vector_data_valid,.vector_data_ready,.vector_data,.vector_result_valid,.vector_result_ready,.vector_result,
    .vector_mem_valid,.vector_mem_ready,.vector_mem_req,.vector_mem_out_valid,.vector_mem_out_ready,.vector_mem_out,
    .acc_rd_valid,.acc_rd_ready,.acc_rd_sel,.acc_rd_addr,.acc_token,.acc_data_valid,.acc_data_ready,.acc_even,.acc_odd,
    .acc_wr_valid,.acc_wr_ready,.acc_wr,.rope_req_valid,.rope_req_ready,.rope_req,.rope_out_valid,.rope_out_ready,.rope_out,
    .mask_config_valid,.mask_state,.mask_action);
  dea8_sfu_top #(.ROPE_FILE("Pcore/units/rom/rope.mem")) sfu(.clk,.reset,.flush(flush_valid||clear),.flush_ack(sfu_flush_ack),
    .function_valid,.function_ready,.function_cmd,.function_done_valid,.function_done_ready,.function_done,
    .function_data_valid,.function_data_ready,.function_data,.function_result_valid,.function_result_ready,.function_result,
    .function_mem_valid,.function_mem_ready,.function_mem_req,.function_mem_out_valid,.function_mem_out_ready,.function_mem_out,
    .rope_valid(rope_sfu_valid),.rope_ready(rope_sfu_ready),.rope_req(rope_sfu_req),
    .rope_out_valid(rope_sfu_out_valid),.rope_out_ready(rope_sfu_out_ready),.rope_out(rope_sfu_out),.protocol_error(sfu_error));
  always @(posedge clk)begin
    cycle++;
    if(!reset)begin
      if(protocol_error||sfu_error)$fatal(1,"History integration protocol");
      if(hiding_audit)begin
        if(vector_valid&&vector_ready)$display("HIDING_TRACE cycle=%0d event=V_START fn=%0d block=%0d",cycle,vector_cmd.function_id,vector_cmd.tile);
        if(vector_done_valid&&vector_done_ready)$display("HIDING_TRACE cycle=%0d event=V_DONE fn=%0d block=%0d",cycle,vector_done.command.function_id,vector_done.command.tile);
        if(function_valid&&function_ready)$display("HIDING_TRACE cycle=%0d event=F_START fn=%0d block=%0d",cycle,function_cmd.function_id,function_cmd.tile);
        if(function_done_valid&&function_done_ready)$display("HIDING_TRACE cycle=%0d event=F_DONE fn=%0d block=%0d",cycle,function_done.command.function_id,function_done.command.tile);
        if(dut.exec.dispatch.matrix.req_valid&&dut.exec.dispatch.matrix.tile_seq_q==0&&dut.exec.dispatch.matrix.req_meta.pair_idx==0)begin
          $display("HIDING_TRACE cycle=%0d event=FIRST_ISSUE index=%0d interval=%0d",cycle,issue_job,previous_issue<0?0:cycle-previous_issue);
          issue_job++;previous_issue=cycle;
        end
        if(dut.exec.attention.mdv&&dut.exec.attention.mdr)$display("HIDING_TRACE cycle=%0d event=MATRIX_COMMIT op=%0d block=%0d",cycle,dut.exec.attention.md.op,dut.exec.attention.md.block_id);
      end
      if(vector_mem_out_valid&&vector_mem_out_ready&&vpu.cmd.function_id==VECTOR_P_POST&&vpu.base_q==0)
        $display("HISTORY_READ block=%0d second=%b data0=%h",vpu.cmd.tile,vpu.read_second,vector_mem_out.data[0]);
      if(function_mem_valid&&function_mem_ready&&function_mem_req.write&&function_mem_req.index==0)
        $display("HISTORY_ALPHA block=%0d value0=%h",sfu.command_q.tile,function_mem_req.data[0]);
      if(vpu.p_in&&vpu.issued==0)$display("HISTORY_MUL block=%0d alpha=%h old_l=%h",vpu.cmd.tile,vpu.mul_a[0][0],vpu.mul_b[0][0]);
      if(vector_mem_valid&&vector_mem_ready&&vector_mem_req.write&&vector_mem_req.buffer_id==WORK_L)begin
        int b;b=vpu.cmd.tile;
        for(int j=0;j<16;j++)if(vector_mem_req.mask[j])begin
          longint signed d;logic [31:0] expected;expected=stats[51*b+vector_mem_req.index+j][31:0];
          d=longint'(vector_mem_req.data[j])-longint'(expected);
          if(d>24||d< -24)$fatal(1,"Integrated l block=%0d row=%0d got=%h expected=%h",b,vector_mem_req.index+j,vector_mem_req.data[j],expected);
        end
      end
      if(vector_done_valid&&vector_done_ready&&vector_done.command.function_id==VECTOR_P_POST&&vector_done.command.tile==(hiding_audit?8:1))begin
        $display("tb_attention_history PASS Q_input_fixture=1 P_POST_blocks=%0d integrated_workspace=1 hiding_audit=%0d",hiding_audit?9:2,hiding_audit);$finish;
      end
    end
  end
  initial begin
    job='0;xbc_entry='0;hbm_entry='0;kv_entry='0;kv_commit='0;ext_qoz_region='0;ext_qoz_wr='0;
    hiding_audit=$test$plusargs("HIDING_AUDIT");
    $readmemh("Pcore/tb/data/seven_job/q.mem",qgold);$readmemh("Pcore/tb/data/seven_job/stats.mem",stats);
    repeat(35)@(negedge clk);reset=0;repeat(8)@(negedge clk);
    ext_qoz_region='{header:'{job_id:16'd1,epoch:4'd3,head:3'd0,op:OP_Q_PROJ},owner:QOZ_Q,tiles:6'd16};
    ext_qoz_region_valid=1;do @(posedge clk);while(!ext_qoz_region_ready);@(negedge clk);ext_qoz_region_valid=0;
    for(int t=0;t<16;t++)for(int p=0;p<26;p++)begin
      ext_qoz_wr='0;ext_qoz_wr.header=ext_qoz_region.header;ext_qoz_wr.n=t;
      ext_qoz_wr.pair_data.tile_idx=t;ext_qoz_wr.pair_data.pair_idx=p;ext_qoz_wr.pair_data.row_valid=row_mask(p);
      ext_qoz_wr.pair_data.row[0]=qvec16_t'(qgold[t*51+2*p]);
      if(p<25)ext_qoz_wr.pair_data.row[1]=qvec16_t'(qgold[t*51+2*p+1]);
      ext_qoz_wr.last=p==25;ext_qoz_wr_valid=1;do @(posedge clk);while(!ext_qoz_wr_ready);@(negedge clk);
    end
    ext_qoz_wr_valid=0;wait(qoz_complete);
    job='0;job.header='{job_id:16'd2,epoch:4'd3,head:3'd0,op:OP_ATTENTION};job.data_context=ext_qoz_context;job.position_base=816;
    @(negedge clk);job_valid=1;do @(posedge clk);while(!job_ready);@(negedge clk);job_valid=0;
    for(int j=0;j<22;j++)for(int t=0;t<16;t++)for(int g=0;g<8;g++)begin
      int b;bit pv;b2_t next_kv;
      pv=j>0&&!j[0];b=j==0?0:(j[0]?(j+1)/2:j/2-1);
      next_kv='0;next_kv.tile_idx=(j*16+t)%64;next_kv.group_idx=g;next_kv.epoch=3;
      for(int c=0;c<2;c++)begin next_kv.col[c].scale=128;for(int k=0;k<16;k++)next_kv.col[c].data[k*8+:8]=pv?1:1+b%3;end
      @(negedge clk);kv_entry=next_kv;kv_valid=1;do @(posedge clk);while(!kv_ready);
    end
  end
  initial begin #50000;$fatal(1,"History integration timeout");end
endmodule
