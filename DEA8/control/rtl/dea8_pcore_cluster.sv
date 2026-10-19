import pcore_pkg::*;
import pcore_control_pkg::*;
import dea8_tile_link_pkg::*;

// Eight independent job owners. DEA8 owns phase barriers; a PCore never has to
// understand denoising steps or layer numbers. Multicast payload ownership stays
// in GCore (one valid/ready bit per recipient, no AND-ready broadcast shortcut).
module dea8_pcore_cluster #(
  parameter int ROPE_POSITION_BASE=816,
  parameter logic [15:0] ROPE_VERSION=1,
  parameter MASK_FILE="Pcore/units/rom/mask.mem",ROPE_FILE="Pcore/units/rom/rope.mem"
)(
  input logic clk,reset,clear,
  input logic [7:0] config_valid,output logic [7:0] config_ready,configured,
  input logic [15:0] config_context,config_mask_version,config_rope_version,config_position,
  input logic [7:0] job_valid,output logic [7:0] job_ready,input control_job_t job[8],
  output logic [7:0] done_valid,input logic [7:0] done_ready,output control_completion_t done[8],
  output logic [7:0] busy,core_fault,
  input logic [7:0] xbc_valid,output logic [7:0] xbc_ready,input xbc4_t xbc,
  input logic [7:0] hbm_valid,output logic [7:0] hbm_ready,input b2_t hbm[8],
  input logic [7:0] kv_valid,output logic [7:0] kv_ready,input b2_t kv,
  output logic [7:0] tx_valid,input logic [7:0] tx_ready,
  output logic [7:0][255:0] tx_data,output logic [7:0] tx_last,
  input logic [7:0] kv_commit_valid,output logic [7:0] kv_commit_ready,input tile_commit_t kv_commit[8],
  output logic [7:0] gu_prefetch_valid,input logic [7:0] gu_prefetch_ready,
  output logic [7:0][5:0] gu_prefetch_n,
  input logic cancel_valid,output logic cancel_ready,
  output logic cancel_done_valid,input logic cancel_done_ready,
  output logic external_flush_req,input logic external_flush_ack,
  output logic fault_event,output logic [7:0] fault_mask
);
  typedef enum logic [1:0] {RUN,PULSE,FLUSH,RETIRE} state_e;
  state_e state;
  logic [7:0] inner_ready,inner_done_valid,inner_done_ready,inner_busy,flush_ack;
  logic [7:0] inner_cr,live,cancel_pending,seen_acks;
  logic [7:0] inner_xready,inner_hready,inner_kready,inner_commitready,inner_gp,inner_tx;
  logic request_seen,external_seen;
  control_completion_t inner_done[8],cancel_result[8];
  control_job_t owned_job[8];
  wire run=state==RUN&&!reset&&!clear;
  wire core_clear=clear||state==PULSE;
  wire abort_request=run&&((cancel_valid&&!request_seen)||(|core_fault));
  assign cancel_ready=run&&!request_seen;
  assign cancel_done_valid=state==RETIRE;
  assign external_flush_req=state==PULSE||state==FLUSH;
  assign fault_event=run&&(|core_fault);
  assign config_ready=inner_cr&{8{run}};
  assign job_ready=inner_ready&{8{run&&!abort_request}};
  assign xbc_ready=inner_xready&{8{run}};assign hbm_ready=inner_hready&{8{run}};
  assign kv_ready=inner_kready&{8{run}};assign kv_commit_ready=inner_commitready&{8{run}};
  assign gu_prefetch_valid=inner_gp&{8{run}};assign tx_valid=inner_tx&{8{run}};
  assign busy=inner_busy|live;
  for(genvar c=0;c<8;c++)begin: core
    assign done_valid[c]=state==RETIRE?cancel_pending[c]:(run&&!abort_request&&inner_done_valid[c]);
    assign done[c]=state==RETIRE?cancel_result[c]:inner_done[c];
    assign inner_done_ready[c]=run&&done_ready[c]&&!abort_request;
    dea8_pcore_top #(.PCORE_ID(3'(c)),.ROPE_POSITION_BASE(ROPE_POSITION_BASE),.ROPE_VERSION(ROPE_VERSION),
      .MASK_FILE(MASK_FILE),.ROPE_FILE(ROPE_FILE)) pcore(
      .clk,.reset,.clear(core_clear),.config_valid(config_valid[c]&&run),.config_ready(inner_cr[c]),.configured(configured[c]),
      .config_context,.config_mask_version,.config_rope_version,.config_position,
      .job_valid(job_valid[c]&&run&&!abort_request),.job_ready(inner_ready[c]),.job(job[c]),
      .done_valid(inner_done_valid[c]),.done_ready(inner_done_ready[c]),.done(inner_done[c]),
      .busy(inner_busy[c]),.protocol_error(core_fault[c]),.flush_done(flush_ack[c]),
      .xbc_valid(xbc_valid[c]&&run),.xbc_ready(inner_xready[c]),.xbc_entry(xbc),
      .hbm_valid(hbm_valid[c]&&run),.hbm_ready(inner_hready[c]),.hbm_entry(hbm[c]),
      .kv_valid(kv_valid[c]&&run),.kv_ready(inner_kready[c]),.kv_entry(kv),
      .tx_valid(inner_tx[c]),.tx_ready(tx_ready[c]&&run),.tx_data(tx_data[c]),.tx_last(tx_last[c]),
      .kv_commit_valid(kv_commit_valid[c]&&run),.kv_commit_ready(inner_commitready[c]),.kv_commit(kv_commit[c]),
      .gu_prefetch_valid(inner_gp[c]),.gu_prefetch_ready(gu_prefetch_ready[c]&&run),.gu_prefetch_n(gu_prefetch_n[c]));
  end
  always_ff @(posedge clk)begin
    if(reset||clear)begin state<=RUN;live<=0;cancel_pending<=0;seen_acks<=0;
      request_seen<=0;external_seen<=0;fault_mask<=0;
      for(int c=0;c<8;c++)begin owned_job[c]<='0;cancel_result[c]<='0;end
    end else begin
      if(!cancel_valid)request_seen<=0;
      for(int c=0;c<8;c++)begin
        if(job_valid[c]&&job_ready[c])begin live[c]<=1;owned_job[c]<=job[c];end
        if(run&&done_valid[c]&&done_ready[c])live[c]<=0;
        if(state==RETIRE&&done_valid[c]&&done_ready[c])cancel_pending[c]<=0;
      end
      if(abort_request)begin
        state<=PULSE;request_seen<=cancel_valid;seen_acks<=0;external_seen<=0;
        fault_mask<=core_fault;cancel_pending<=live;
        for(int c=0;c<8;c++)cancel_result[c]<='{job:owned_job[c],
          status:core_fault[c]?CONTROL_CHILD_ERROR:CONTROL_CANCELLED};
      end
      if(state==PULSE)state<=FLUSH;
      if(state==FLUSH)begin
        seen_acks<=seen_acks|flush_ack;external_seen<=external_seen||external_flush_ack;
        if(&(seen_acks|flush_ack)&&(external_seen||external_flush_ack))begin state<=RETIRE;live<=0;end
      end
      if(state==RETIRE&&cancel_done_ready&&((cancel_pending&~done_ready)==0))state<=RUN;
    end
  end
  // synthesis translate_off
  always @(posedge clk)if(!reset&&!clear)for(int c=0;c<8;c++)begin
    if(job_valid[c]&&job_ready[c])assert(!live[c])
      else $fatal(1,"Cluster job owner/core mismatch core=%0d",c);
  end
  // synthesis translate_on
endmodule
