import pcore3_pkg::*;
import pcore_control_pkg::*;

module tb_v3_pcore_control_v3;
  logic clk=0,reset=1,clear=0;
  always #5 clk=~clk;

  logic job_valid=0,job_ready;control_job_t job;
  logic done_valid,done_ready=1;control_completion_t done;
  logic busy,protocol_error;logic [1:0] active_adapter;
  logic xbc_valid=0,xbc_ready;xbc4_t xbc_entry='0;
  logic hbm_valid=0,hbm_ready;b2_t hbm_entry='0;
  logic kv_valid=0,kv_ready;b2_t kv_entry='0;
  logic post_valid,post_ready=1;pcore_post_job_t post_job;
  logic post_done_valid=0,post_done_ready;pcore_post_job_t post_done='0;
  logic post_data_valid,post_data_ready=1;post_data_t post_data;
  logic post_result_valid=0,post_result_ready;post_result_t post_result='0;
  logic collective_cmd_valid,collective_cmd_ready=1;pcore_post_job_t collective_cmd;
  logic collective_data_valid,collective_data_ready=1;post_data_t collective_data;
  logic collective_result_valid,collective_result_ready=1;post_result_t collective_result;
  logic collective_done_valid=0,collective_done_ready;pcore_post_job_t collective_done='0;
  logic vpu_valid,vpu_ready=1;vpu_cmd_t vpu_cmd;
  logic vpu_done_valid=0,vpu_done_ready;vpu_cmd_t vpu_done='0;
  logic sfu_valid,sfu_ready=1;sfu_cmd_t sfu_cmd;
  logic sfu_done_valid=0,sfu_done_ready;sfu_cmd_t sfu_done='0;
  logic p_valid=0,p_ready;a2_t p_entry='0;logic [5:0] p_block=0;
  logic [EPOCH_BITS-1:0] p_epoch=0;logic [2:0] p_head=0;
  logic acc_rd_valid=0,acc_rd_ready;acc_sel_e acc_rd_sel=ACC_FACC_A;logic [9:0] acc_rd_addr=0;
  logic acc_data_valid;logic [15:0][31:0] acc_even,acc_odd;
  logic acc_wr_valid=0,acc_wr_ready;acc_write_t acc_wr='0;
  logic z_rd_valid=0,z_rd_ready;logic [5:0] z_rd_tile=0;logic [PAIR_BITS-1:0] z_rd_pair=0;
  logic z_out_valid,z_out_ready=1;a2_t z_entry;
  logic qoz_complete;qoz_region_req_t qoz_region;
  logic ext_qoz_region_valid=0,ext_qoz_region_ready;qoz_region_req_t ext_qoz_region='0;
  logic ext_qoz_wr_valid=0,ext_qoz_wr_ready;post_result_t ext_qoz_wr='0;
  logic gu_prefetch_valid,gu_prefetch_ready=1;logic [5:0] gu_prefetch_n;

  dea8_pcore_control_v3 dut(
    .clk,.reset,.clear,.job_valid,.job_ready,.job,.done_valid,.done_ready,.done,
    .busy,.protocol_error,.active_adapter,
    .xbc_valid,.xbc_ready,.xbc_entry,.hbm_valid,.hbm_ready,.hbm_entry,
    .kv_valid,.kv_ready,.kv_entry,.post_valid,.post_ready,.post_job,
    .post_done_valid,.post_done_ready,.post_done,.post_data_valid,.post_data_ready,.post_data,
    .post_result_valid,.post_result_ready,.post_result,
    .collective_cmd_valid,.collective_cmd_ready,.collective_cmd,
    .collective_data_valid,.collective_data_ready,.collective_data,
    .collective_result_valid,.collective_result_ready,.collective_result,
    .collective_done_valid,.collective_done_ready,.collective_done,
    .vpu_valid,.vpu_ready,.vpu_cmd,.vpu_done_valid,.vpu_done_ready,.vpu_done,
    .sfu_valid,.sfu_ready,.sfu_cmd,.sfu_done_valid,.sfu_done_ready,.sfu_done,
    .p_valid,.p_ready,.p_entry,.p_block,.p_epoch,.p_head,
    .acc_rd_valid,.acc_rd_ready,.acc_rd_sel,.acc_rd_addr,.acc_data_valid,.acc_even,.acc_odd,
    .acc_wr_valid,.acc_wr_ready,.acc_wr,.z_rd_valid,.z_rd_ready,.z_rd_tile,.z_rd_pair,
    .z_out_valid,.z_out_ready,.z_entry,.qoz_complete,.qoz_region,
    .ext_qoz_region_valid,.ext_qoz_region_ready,.ext_qoz_region,
    .ext_qoz_wr_valid,.ext_qoz_wr_ready,.ext_qoz_wr,
    .gu_prefetch_valid,.gu_prefetch_ready,.gu_prefetch_n);

  task automatic check_route(input pcore_op_e op,input logic [1:0] expected);
    job='0;job.header.job_id=16'(op+1);job.header.epoch=4'h3;job.header.head=3'h2;job.header.op=op;
    job.user_tag=64'h5a00_0000_0000_0000|op;job.core_id=3'h1;job.position_base=16'(op*51);
    @(negedge clk);
    if(!job_ready) $fatal(1,"control center not ready before op=%0d",op);
    job_valid=1;
    @(posedge clk);
    @(negedge clk);job_valid=0; #1;
    if(active_adapter!==expected) $fatal(1,"route op=%0d owner=%0d expected=%0d",op,active_adapter,expected);
    if(!busy) $fatal(1,"route op=%0d did not enter busy",op);
    @(negedge clk);clear=1;@(posedge clk);@(negedge clk);clear=0;repeat(2)@(posedge clk);
  endtask

  initial begin
    repeat(30)@(posedge clk);reset=0;repeat(2)@(posedge clk);
    check_route(OP_K_PROJ,0);check_route(OP_V_PROJ,0);check_route(OP_Q_PROJ,0);
    check_route(OP_ATTENTION,1);check_route(OP_O_PROJ,0);check_route(OP_GU,2);check_route(OP_DOWN_PROJ,0);
    $display("tb_v3_pcore_control_v3 PASS jobs=7 context=opaque adapters=3 collective_boundary=1");
    $finish;
  end
endmodule
