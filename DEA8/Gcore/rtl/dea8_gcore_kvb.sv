module dea8_gcore_kvb (
  input logic clk,reset,clear,
  input logic cmd_valid,
  output logic cmd_ready,
  input gcore_pkg::gcore_cmd_t cmd,
  input gcore_pkg::gcore_context_t context_data,
  output logic rd_valid,
  input logic rd_ready,
  output gcore_pkg::kv_read_t rd,
  input logic rsp_valid,
  output logic rsp_ready,
  input pcore_pkg::b2_t rsp,
  output logic [gcore_pkg::CORES-1:0] kv_valid,
  input logic [gcore_pkg::CORES-1:0] kv_ready,
  output pcore_pkg::b2_t kv,
  output logic done_valid,
  input logic done_ready,
  output gcore_pkg::gcore_done_t done,
  output logic busy,protocol_error
);
  import gcore_pkg::*;
  import pcore_pkg::OP_ATTENTION;
  import pcore_pkg::b2_t;
  gcore_cmd_t command_q;
  logic [3:0] epoch_q;
  logic [6:0] job_q;
  logic [3:0] tile_q;
  logic [2:0] group_q;
  logic [13:0] issued_q,received_q,retired_q;
  logic [STORE_CREDIT_BITS-1:0] credits;
  logic issued_all,multicast_ready,multicast_empty,retire,response_bad,failed;
  logic value_kind;
  int block_index,local_block;

  assign cmd_ready=!busy&&!done_valid&&!reset&&!clear&&!protocol_error;
  assign rd_valid=busy&&!failed&&!issued_all&&credits<STORE_RESPONSE_DEPTH&&!reset&&!clear;
  always_comb begin
    value_kind=job_q==KVB_JOBS-1 || (job_q!=0&&!job_q[0]);
    if(job_q==0) block_index=0;
    else if(job_q==KVB_JOBS-1) block_index=KV_BLOCK_COUNT-1;
    else if(job_q[0]) block_index=(int'(job_q)+1)/2;
    else block_index=int'(job_q)/2-1;
    local_block=block_index<PREFIX_BLOCKS?block_index:block_index-PREFIX_BLOCKS;
    rd='0; rd.value_kind=value_kind; rd.prefix=block_index<PREFIX_BLOCKS;
    rd.feature_tile=tile_q; rd.address=9'(local_block*8+group_q);
    rd.tile=6'(job_q*KV_FEATURE_TILES+tile_q); rd.group_index=group_q; rd.epoch=epoch_q;
    if(!value_kind&&!rd.prefix) begin
      rd.zero_mask[0]=local_block*16+group_q*2>=ROWS;
      rd.zero_mask[1]=local_block*16+group_q*2+1>=ROWS;
    end
    response_bad=credits==0 || rsp.tile_idx!=6'(received_q/8) ||
      rsp.group_idx!=3'(received_q%8) || rsp.epoch!=epoch_q || rsp.reserved!=0;
    for(int p=0;p<2;p++) if(rsp.col[p].scale==8'hff) response_bad=1;
  end
  assign rsp_ready=busy&&!reset&&!clear&&(failed||response_bad||multicast_ready);
  dea8_gcore_multicast #(.WIDTH($bits(b2_t)),.OUTPUTS(CORES)) fanout (
    .clk,.reset,.clear,.in_valid(rsp_valid&&busy&&!failed&&!response_bad),.in_ready(multicast_ready),
    .in_data(rsp),.in_mask(command_q.core_mask),.out_valid(kv_valid),.out_ready(kv_ready),
    .out_data(kv),.retired(retire),.empty(multicast_empty)
  );
  always_ff @(posedge clk) begin
    if(reset||clear) begin
      busy<=0; done_valid<=0; done<='0; command_q<='0; epoch_q<=0;
      job_q<=0; tile_q<=0; group_q<=0; issued_q<=0; received_q<=0; retired_q<=0;
      issued_all<=0; credits<=0; failed<=0; protocol_error<=0;
    end else begin
      if(done_valid&&done_ready) done_valid<=0;
      if(cmd_valid&&cmd_ready) begin
        command_q<=cmd; epoch_q<=context_data.pcore_epoch;
        job_q<=0; tile_q<=0; group_q<=0; issued_q<=0; received_q<=0; retired_q<=0;
        issued_all<=0; credits<=0; failed<=0;
        if(cmd.opcode!=GC_KVB_RUN||cmd.pcore_op!=OP_ATTENTION||cmd.core_mask!=8'hff) begin
          done<=make_done(cmd,GC_INVALID_CMD,0); done_valid<=1;
        end else busy<=1;
      end
      if(busy) begin
        case({rd_valid&&rd_ready,rsp_valid&&rsp_ready&&credits!=0})
          2'b10:credits<=credits+1'b1;
          2'b01:credits<=credits-1'b1;
          default:;
        endcase
        if(rd_valid&&rd_ready) begin
          issued_q<=issued_q+1'b1;
          if(issued_q==KVB_WORDS-1) issued_all<=1;
          if(group_q==7) begin
            group_q<=0;
            if(tile_q==KV_FEATURE_TILES-1) begin tile_q<=0; job_q<=job_q+1'b1; end
            else tile_q<=tile_q+1'b1;
          end else group_q<=group_q+1'b1;
        end
        if(rsp_valid&&rsp_ready&&!failed) begin
          if(response_bad) begin failed<=1; protocol_error<=1; end
          else received_q<=received_q+1'b1;
        end
        if(retire&&!failed&&!(rsp_valid&&rsp_ready&&response_bad)) begin
          retired_q<=retired_q+1'b1;
          if(retired_q==KVB_WORDS-1) begin
            done<=make_done(command_q,GC_OK,16'(KVB_WORDS)); done_valid<=1; busy<=0;
          end
        end
        if(failed&&credits==0&&multicast_empty) begin
          done<=make_done(command_q,GC_SOURCE_PROTOCOL,16'(retired_q)); done_valid<=1; busy<=0;
        end
      end
    end
  end
endmodule
