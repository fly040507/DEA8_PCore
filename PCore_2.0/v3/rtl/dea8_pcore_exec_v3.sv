import pcore3_pkg::*;
module dea8_pcore_exec_v3(
  input logic clk,reset,clear,
  input logic job_valid,output logic job_ready,input pcore_job_t job,
  output logic job_done_valid,input logic job_done_ready,output pcore_completion_t job_done,
  output logic busy,protocol_error,output logic [1:0] active_adapter,
  input logic xbc_valid,output logic xbc_ready,input xbc4_t xbc_entry,
  input logic gu_a_valid,output logic gu_a_ready,input a2_t gu_a_entry,
  input logic hbm_valid,output logic hbm_ready,input b2_t hbm_entry,
  input logic kv_valid,output logic kv_ready,input b2_t kv_entry,
  output logic post_valid,input logic post_ready,output pcore_post_job_t post_job,
  input logic post_done_valid,output logic post_done_ready,input pcore_post_job_t post_done,
  output logic post_data_valid,input logic post_data_ready,output post_data_t post_data,
  input logic post_result_valid,output logic post_result_ready,input post_result_t post_result,
  output logic vpu_valid,input logic vpu_ready,output vpu_cmd_t vpu_cmd,
  input logic vpu_done_valid,output logic vpu_done_ready,input vpu_cmd_t vpu_done,
  output logic sfu_valid,input logic sfu_ready,output sfu_cmd_t sfu_cmd,
  input logic sfu_done_valid,output logic sfu_done_ready,input sfu_cmd_t sfu_done,
  input logic p_valid,output logic p_ready,input a2_t p_entry,input logic [5:0] p_block,
  input logic [EPOCH_BITS-1:0] p_epoch,input logic [2:0] p_head,
  input logic acc_rd_valid,output logic acc_rd_ready,input acc_sel_e acc_rd_sel,input logic [9:0] acc_rd_addr,
  output logic acc_data_valid,output logic [15:0][31:0] acc_even,acc_odd,
  input logic acc_wr_valid,output logic acc_wr_ready,input acc_write_t acc_wr,
  input logic z_rd_valid,output logic z_rd_ready,input logic [5:0] z_rd_tile,
  input logic [PAIR_BITS-1:0] z_rd_pair,output logic z_out_valid,input logic z_out_ready,output a2_t z_entry,
  output logic qoz_complete,output qoz_region_req_t qoz_region,
  output logic gu_prefetch_valid,input logic gu_prefetch_ready,output logic [5:0] gu_prefetch_n
);
  logic operation_clear,local_clear,ctrl_error,matrix_error,qoz_error;
  logic [2:0] av,ar,dv,dr,errors;
  pcore_job_t aj;pcore_completion_t dc[0:2];
  matrix_service_req_t req[0:2];matrix_service_rsp_t rsp[0:2];
  logic [2:0] rv,rr,pv,pr,pdv,pdr,ddv,ddr;
  qoz_region_req_t regions[0:2];pcore_post_job_t posts[0:2];post_data_t datas[0:2];
  logic qrelease,qrelease_ready,qactive,qread,qread_ready,qout,qout_ready;
  logic [5:0] qt;logic [PAIR_BITS-1:0] qp;logic [TILE_BITS-1:0] qtransport;a2_t qe;
  logic region_req_valid,region_req_ready; qoz_region_req_t region_req;
  logic z_commit;
  assign local_clear=clear||operation_clear;
  assign protocol_error=ctrl_error||matrix_error||qoz_error||(|errors);
  assign region_req_valid=rv[active_adapter];assign region_req=regions[active_adapter];
  assign rr=3'(region_req_ready)<<active_adapter;
  assign post_valid=pv[active_adapter];assign post_job=posts[active_adapter];
  assign pr=3'(post_ready)<<active_adapter;
  assign pdv=3'(post_done_valid)<<active_adapter;assign post_done_ready=pdr[active_adapter];
  assign post_data_valid=ddv[active_adapter];assign post_data=datas[active_adapter];assign ddr=3'(post_data_ready)<<active_adapter;
  assign z_commit=post_result_valid&&post_result_ready&&post_result.last;
  assign rv[1]=0;assign regions[1]='0;assign pv[1]=0;assign posts[1]='0;assign pdr[1]=0;assign ddv[1]=0;assign datas[1]='0;
  dea8_pcore_ctrl_v3 ctrl(.clk,.reset,.clear,.job_valid,.job_ready,.job,.job_done_valid,.job_done_ready,.job_done,
    .busy,.protocol_error(ctrl_error),.owner(active_adapter),.adapter_valid(av),.adapter_ready(ar),.adapter_job(aj),
    .adapter_done_valid(dv),.adapter_done_ready(dr),.adapter_done(dc),.adapter_error(errors),.operation_clear);
  dea8_projection_job_adapter_v3 projection(.clk,.reset,.clear(local_clear),.op_valid(av[0]),.op_ready(ar[0]),.op_job(aj),
    .done_valid(dv[0]),.done_ready(dr[0]),.done(dc[0]),.error(errors[0]),.matrix_req(req[0]),.matrix_rsp(rsp[0]),
    .region_valid(rv[0]),.region_ready(rr[0]),.region(regions[0]),.region_complete(qoz_complete),
    .post_valid(pv[0]),.post_ready(pr[0]),.post_job(posts[0]),.post_done_valid(pdv[0]),.post_done_ready(pdr[0]),.post_done,
    .data_valid(ddv[0]),.data_ready(ddr[0]),.data_out(datas[0]),.z_commit(z_commit&&active_adapter==0),.z_n(post_result.n));
  dea8_gu_job_adapter_v3 gu(.clk,.reset,.clear(local_clear),.op_valid(av[2]),.op_ready(ar[2]),.op_job(aj),
    .done_valid(dv[2]),.done_ready(dr[2]),.done(dc[2]),.error(errors[2]),.matrix_req(req[2]),.matrix_rsp(rsp[2]),
    .region_valid(rv[2]),.region_ready(rr[2]),.region(regions[2]),.region_complete(qoz_complete),
    .post_valid(pv[2]),.post_ready(pr[2]),.post_job(posts[2]),.post_done_valid(pdv[2]),.post_done_ready(pdr[2]),.post_done,
    .data_valid(ddv[2]),.data_ready(ddr[2]),.data_out(datas[2]),.z_commit(z_commit&&active_adapter==2),.z_n(post_result.n),
    .a_valid(gu_a_valid&&active_adapter==2),.a_ready(gu_a_ready),.a_entry(gu_a_entry),
    .prefetch_valid(gu_prefetch_valid),.prefetch_ready(gu_prefetch_ready),.prefetch_n(gu_prefetch_n));
  dea8_attention_job_adapter_v3 attention(.clk,.reset,.clear(local_clear),.op_valid(av[1]),.op_ready(ar[1]),.op_job(aj),
    .done_valid(dv[1]),.done_ready(dr[1]),.done(dc[1]),.error(errors[1]),.matrix_req(req[1]),.matrix_rsp(rsp[1]),
    .q_complete(qoz_complete),.q_region(qoz_region),.q_release(qrelease),.q_release_ready(qrelease_ready),
    .q_rd_valid(qread),.q_rd_ready(qread_ready),.q_rd_tile(qt),.q_rd_pair(qp),.q_rd_transport(qtransport),
    .q_out_valid(qout),.q_out_ready(qout_ready),.q_entry(qe),.p_valid,.p_ready,.p_entry,.p_block,.p_epoch,.p_head,
    .vpu_valid,.vpu_ready,.vpu_cmd,.vpu_done_valid,.vpu_done_ready,.vpu_done,
    .sfu_valid,.sfu_ready,.sfu_cmd,.sfu_done_valid,.sfu_done_ready,.sfu_done,
    .rd_valid(acc_rd_valid),.rd_ready(acc_rd_ready),.rd_sel(acc_rd_sel),.rd_addr(acc_rd_addr),
    .rd_data_valid(acc_data_valid),.even_data(acc_even),.odd_data(acc_odd),.wr_valid(acc_wr_valid),.wr_ready(acc_wr_ready),.wr(acc_wr));
  dea8_matrix_job_dispatch_v3 dispatch(.clk,.reset,.clear(local_clear),.owner(active_adapter),.requests(req),.responses(rsp),
    .xbc_valid,.xbc_ready,.xbc_entry,.hbm_valid,.hbm_ready,.hbm_entry,.kv_valid,.kv_ready,.kv_entry,.protocol_error(matrix_error));
  logic store_read_ready,store_out_valid;a2_t store_entry;
  assign qread_ready=active_adapter==1&&store_read_ready;assign z_rd_ready=active_adapter!=1&&store_read_ready;
  assign qout=active_adapter==1&&store_out_valid;assign z_out_valid=active_adapter!=1&&store_out_valid;
  assign qe=store_entry;assign z_entry=store_entry;
  dea8_qoz_manager_v3 qoz(.clk,.reset,.clear,.req_valid(region_req_valid),.req_ready(region_req_ready),.req(region_req),
    .region_active(qactive),.region_complete(qoz_complete),.active_req(qoz_region),
    .release_valid(qrelease),.release_ready(qrelease_ready),.consumer(aj.header),
    .wr_valid(post_result_valid),.wr_ready(post_result_ready),.wr(post_result),
    .rd_valid(active_adapter==1?qread:z_rd_valid),.rd_ready(store_read_ready),.rd_owner(active_adapter==1?QOZ_Q:QOZ_Z),
    .rd_tile(active_adapter==1?qt:z_rd_tile),.rd_pair(active_adapter==1?qp:z_rd_pair),
    .rd_transport(active_adapter==1?qtransport:TILE_BITS'(z_rd_tile)),
    .out_valid(store_out_valid),.out_ready(active_adapter==1?qout_ready:z_out_ready),.out_entry(store_entry),.protocol_error(qoz_error));
endmodule
