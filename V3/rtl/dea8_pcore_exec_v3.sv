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
  input logic fixture_region_valid,output logic fixture_region_ready,input qoz_region_req_t fixture_region,
  input logic fixture_wr_valid,output logic fixture_wr_ready,input post_result_t fixture_wr,
  output logic gu_prefetch_valid,input logic gu_prefetch_ready,output logic [5:0] gu_prefetch_n
);
  logic operation_clear,local_clear,ctrl_error,matrix_error,qoz_error;
  logic [2:0] av,ar,dv,dr,errors;
  pcore_job_t aj;pcore_completion_t dc[0:2];
  matrix_service_req_t req[0:2];matrix_service_rsp_t rsp[0:2];
  logic [2:0] rv,rr,pv,pr,pdv,pdr,ddv,ddr;
  qoz_region_req_t regions[0:2];pcore_post_job_t posts[0:2];post_data_t datas[0:2];
  logic qrelease,qrelease_ready,qactive,qread,qread_ready,qout,qout_ready;
  logic attention_release,attention_release_ready,projection_release,projection_release_ready;
  logic projection_rd_valid,projection_rd_ready,projection_out_valid;
  logic [TILE_BITS-1:0] projection_rd_tile,projection_rd_transport;
  logic [PAIR_BITS-1:0] projection_rd_pair;
  qoz_owner_e projection_rd_owner;
  logic job_output_qoz;
  operation_profile_t active_profile;
  logic [5:0] qt;logic [PAIR_BITS-1:0] qp;logic [TILE_BITS-1:0] qtransport;a2_t qe;
  logic region_req_valid,region_req_ready; qoz_region_req_t region_req;
  logic qoz_req_valid,qoz_wr_valid,qoz_wr_ready; qoz_region_req_t qoz_req; post_result_t qoz_wr;
  logic z_commit;
  logic projection_local_ready,gu_a_ready_int;
  logic matrix_xbc_ready,gu_xbc_ready,gu_front_valid,gu_front_ready,gu_front_error;
  a2_t gu_front_entry;
  logic gu_input_valid,gu_input_ready;
  assign local_clear=clear||operation_clear;
  assign protocol_error=ctrl_error||matrix_error||qoz_error||gu_front_error||errors[active_adapter];
  assign region_req_valid=rv[active_adapter];assign region_req=regions[active_adapter];
  assign qoz_req_valid=fixture_region_valid?fixture_region_valid:region_req_valid;
  assign qoz_req=fixture_region_valid?fixture_region:region_req;
  assign fixture_region_ready=fixture_region_valid&&region_req_ready;
  always_comb begin
    active_profile=operation_profile(aj.header.op);
    job_output_qoz=active_profile.output_qoz;
  end
  assign qoz_wr_valid=fixture_wr_valid?fixture_wr_valid:(post_result_valid&&job_output_qoz);
  assign qoz_wr=fixture_wr_valid?fixture_wr:post_result;
  assign fixture_wr_ready=fixture_wr_valid&&qoz_wr_ready;
  assign post_result_ready=!fixture_wr_valid&&(job_output_qoz?qoz_wr_ready:1'b1);
  // A public fixture region has priority over an adapter acquire.  Mask the
  // adapter ready seen by the controller on that cycle, otherwise the QOZ
  // manager would accept the fixture while the adapter also retires its own
  // request.
  assign rr=3'((!fixture_region_valid)&&region_req_ready)<<active_adapter;
  assign post_valid=pv[active_adapter];assign post_job=posts[active_adapter];
  assign pr=3'(post_ready)<<active_adapter;
  assign pdv=3'(post_done_valid)<<active_adapter;assign post_done_ready=pdr[active_adapter];
  assign post_data_valid=ddv[active_adapter];assign post_data=datas[active_adapter];assign ddr=3'(post_data_ready)<<active_adapter;
  assign z_commit=post_result_valid&&post_result_ready&&post_result.last;
  assign qrelease=(active_adapter==1)?attention_release:projection_release;
  assign attention_release_ready=(active_adapter==1)?qrelease_ready:1'b0;
  assign projection_release_ready=(active_adapter==0)?qrelease_ready:1'b0;
  assign projection_rd_owner=active_profile.input_owner;
  assign rv[1]=0;assign regions[1]='0;assign pv[1]=0;assign posts[1]='0;assign pdr[1]=0;assign ddv[1]=0;assign datas[1]='0;
  dea8_pcore_ctrl_v3 ctrl(.clk,.reset,.clear,.job_valid,.job_ready,.job,.job_done_valid,.job_done_ready,.job_done,
    .busy,.protocol_error(ctrl_error),.owner(active_adapter),.adapter_valid(av),.adapter_ready(ar),.adapter_job(aj),
    .adapter_done_valid(dv),.adapter_done_ready(dr),.adapter_done(dc),.adapter_error(errors),.fabric_error(qoz_error||matrix_error),.operation_clear);
  dea8_projection_job_adapter_v3 projection(.clk,.reset,.clear(local_clear),.op_valid(av[0]),.op_ready(ar[0]),.op_job(aj),
    .done_valid(dv[0]),.done_ready(dr[0]),.done(dc[0]),.error(errors[0]),.matrix_req(req[0]),.matrix_rsp(rsp[0]),
    .region_valid(rv[0]),.region_ready(rr[0]),.region(regions[0]),.region_complete(qoz_complete),.input_region(qoz_region),
    .input_release_valid(projection_release),.input_release_ready(projection_release_ready),
    .post_valid(pv[0]),.post_ready(pr[0]),.post_job(posts[0]),.post_done_valid(pdv[0]),.post_done_ready(pdr[0]),.post_done,
    .data_valid(ddv[0]),.data_ready(ddr[0]),.data_out(datas[0]),.z_commit(z_commit&&active_adapter==0),.z_n(post_result.n),
    .local_a_valid(projection_out_valid),.local_a_ready(projection_local_ready),.local_a_entry(qe),
    .local_rd_valid(projection_rd_valid),.local_rd_ready(projection_rd_ready),.local_rd_tile(projection_rd_tile),
    .local_rd_pair(projection_rd_pair),.local_rd_transport(projection_rd_transport));
  dea8_gu_job_adapter_v3 gu(.clk,.reset,.clear(local_clear),.op_valid(av[2]),.op_ready(ar[2]),.op_job(aj),
    .done_valid(dv[2]),.done_ready(dr[2]),.done(dc[2]),.error(errors[2]),.matrix_req(req[2]),.matrix_rsp(rsp[2]),
    .region_valid(rv[2]),.region_ready(rr[2]),.region(regions[2]),.region_complete(qoz_complete),
    .post_valid(pv[2]),.post_ready(pr[2]),.post_job(posts[2]),.post_done_valid(pdv[2]),.post_done_ready(pdr[2]),.post_done,
    .data_valid(ddv[2]),.data_ready(ddr[2]),.data_out(datas[2]),.z_commit(z_commit&&active_adapter==2),.z_n(post_result.n),
    .a_valid(gu_input_valid&&active_adapter==2),.a_ready(gu_input_ready),.a_entry(gu_front_valid?gu_front_entry:gu_a_entry),
    .prefetch_valid(gu_prefetch_valid),.prefetch_ready(gu_prefetch_ready),.prefetch_n(gu_prefetch_n));
  // The legacy gu_a port is only the GU fixture boundary. Projection local-A
  // now comes from the shared QOZ reader above, not from this port.
  assign gu_front_ready=gu_input_ready;
  assign gu_input_valid=gu_front_valid||gu_a_valid;
  assign gu_a_ready=(active_adapter==2&&!gu_front_valid)?gu_input_ready:1'b0;
  dea8_gu_xbc_frontend_v3 gu_xbc(.clk,.reset,.clear(local_clear),.restart(av[2]&&ar[2]),
    .in_valid(xbc_valid&&active_adapter==2),.in_ready(gu_xbc_ready),.in_entry(xbc_entry),
    .out_valid(gu_front_valid),.out_ready(gu_front_ready),.out_entry(gu_front_entry),.protocol_error(gu_front_error));
  dea8_attention_job_adapter_v3 attention(.clk,.reset,.clear(local_clear),.op_valid(av[1]),.op_ready(ar[1]),.op_job(aj),
    .done_valid(dv[1]),.done_ready(dr[1]),.done(dc[1]),.error(errors[1]),.matrix_req(req[1]),.matrix_rsp(rsp[1]),
    .q_complete(qoz_complete),.q_region(qoz_region),.q_release(attention_release),.q_release_ready(attention_release_ready),
    .q_rd_valid(qread),.q_rd_ready(qread_ready),.q_rd_tile(qt),.q_rd_pair(qp),.q_rd_transport(qtransport),
    .q_out_valid(qout),.q_out_ready(qout_ready),.q_entry(qe),.p_valid,.p_ready,.p_entry,.p_block,.p_epoch,.p_head,
    .vpu_valid,.vpu_ready,.vpu_cmd,.vpu_done_valid,.vpu_done_ready,.vpu_done,
    .sfu_valid,.sfu_ready,.sfu_cmd,.sfu_done_valid,.sfu_done_ready,.sfu_done,
    .rd_valid(acc_rd_valid),.rd_ready(acc_rd_ready),.rd_sel(acc_rd_sel),.rd_addr(acc_rd_addr),
    .rd_data_valid(acc_data_valid),.even_data(acc_even),.odd_data(acc_odd),.wr_valid(acc_wr_valid),.wr_ready(acc_wr_ready),.wr(acc_wr));
  dea8_matrix_job_dispatch_v3 dispatch(.clk,.reset,.clear(local_clear),.owner(active_adapter),.requests(req),.responses(rsp),
    .xbc_valid,.xbc_ready(matrix_xbc_ready),.xbc_entry,.hbm_valid,.hbm_ready,.hbm_entry,.kv_valid,.kv_ready,.kv_entry,.protocol_error(matrix_error));
  assign xbc_ready=(active_adapter==2)?gu_xbc_ready:matrix_xbc_ready;
  logic store_read_ready,store_out_valid;a2_t store_entry;
  assign qread_ready=active_adapter==1&&store_read_ready;
  assign projection_rd_ready=active_adapter==0&&store_read_ready;
  assign z_rd_ready=active_adapter==2&&store_read_ready;
  assign qout=active_adapter==1&&store_out_valid;
  assign projection_out_valid=active_adapter==0&&store_out_valid;
  assign z_out_valid=active_adapter==2&&store_out_valid;
  assign qe=store_entry;assign z_entry=store_entry;
  dea8_qoz_manager_v3 qoz(.clk,.reset,.clear,.req_valid(qoz_req_valid),.req_ready(region_req_ready),.req(qoz_req),
    .region_active(qactive),.region_complete(qoz_complete),.active_req(qoz_region),
    .release_valid(qrelease),.release_ready(qrelease_ready),.consumer(aj.header),
    .wr_valid(qoz_wr_valid),.wr_ready(qoz_wr_ready),.wr(qoz_wr),
    .rd_valid(active_adapter==1?qread:(active_adapter==0?projection_rd_valid:z_rd_valid)),.rd_ready(store_read_ready),
    .rd_owner(active_adapter==1?QOZ_Q:(active_adapter==0?projection_rd_owner:QOZ_Z)),
    .rd_tile(active_adapter==1?qt:(active_adapter==0?projection_rd_tile:z_rd_tile)),
    .rd_pair(active_adapter==1?qp:(active_adapter==0?projection_rd_pair:z_rd_pair)),
    .rd_transport(active_adapter==1?qtransport:(active_adapter==0?projection_rd_transport:TILE_BITS'(z_rd_tile))),
    .out_valid(store_out_valid),.out_ready(active_adapter==1?qout_ready:(active_adapter==0?projection_local_ready:z_out_ready)),
    .out_entry(store_entry),.protocol_error(qoz_error));
endmodule
