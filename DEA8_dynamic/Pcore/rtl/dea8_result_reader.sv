import pcore_pkg::*;

// Synchronous ACC read with two reserved replies, not an extra FP32 tile RAM.
module dea8_result_reader (
  input logic clk,reset,clear,cmd_valid,output logic cmd_ready,input capture_desc_t cmd,
  output logic rd_valid,input logic rd_ready,output acc_sel_e rd_sel,output logic [9:0] rd_addr,
  input logic response_valid,input logic [ROW_LANES-1:0][TILE-1:0][FP_BITS-1:0] response_data,
  output logic out_valid,input logic out_ready,output pair_capture_t out_capture,
  output logic done,output capture_desc_t completed,output logic protocol_error
);
  capture_desc_t owner;
  pair_capture_t fifo[0:1];
  logic active,pending,rptr,wptr;
  logic [1:0] count;
  logic [PAIR_BITS:0] requested,consumed;
  logic [PAIR_BITS-1:0] pending_pair;
  logic pop,issue;
  assign cmd_ready=!reset&&!clear&&!active&&!protocol_error;
  assign rd_valid=active&&requested<pairs_for_rows(owner.rows)&&int'(count)+int'(pending)<2+(pop?1:0)&&!protocol_error;
  assign rd_sel=owner.sel;assign rd_addr=10'(requested);
  assign issue=rd_valid&&rd_ready;
  assign out_valid=active&&count!=0&&!reset&&!clear&&!protocol_error;
  assign pop=out_valid&&out_ready;
  assign done=pop&&int'(consumed)+1==pairs_for_rows(owner.rows);
  assign completed=owner;
  always_comb begin out_capture='0;if(count!=0)out_capture=fifo[rptr];end
  always_ff @(posedge clk)begin
    if(reset||clear)begin
      active<=0;pending<=0;rptr<=0;wptr<=0;count<=0;requested<=0;consumed<=0;
      owner<='0;pending_pair<=0;protocol_error<=0;
    end else begin
      pending<=issue;
      if(response_valid!=pending)protocol_error<=1;
      if(cmd_valid&&cmd_ready)begin
        if(cmd.rows==0||cmd.rows>ROWS||cmd.sel>ACC_FACC_B)protocol_error<=1;
        else begin owner<=cmd;active<=1;requested<=0;consumed<=0;end
      end
      if(issue)begin requested<=requested+1'b1;pending_pair<=PAIR_BITS'(requested);end
      case({pending,pop})
        2'b10:count<=count+1'b1;
        2'b01:count<=count-1'b1;
        default:;
      endcase
      if(pending&&response_valid)begin
        pair_capture_t entry;
        entry='0;entry.owner=owner;entry.pair_idx=pending_pair;
        entry.mask=row_mask_for_rows(owner.rows,pending_pair);entry.data=response_data;
        fifo[wptr]<=entry;wptr<=!wptr;
      end
      if(pop)begin rptr<=!rptr;consumed<=consumed+1'b1;if(done)active<=0;end
    end
  end
  // synthesis translate_off
  always @(posedge clk)if(!reset&&!clear&&response_valid!=pending)
    $fatal(1,"Result reader response alignment pending=%b response=%b issue=%b rd_valid=%b rd_ready=%b active=%b requested=%0d rows=%0d sel=%0d",pending,response_valid,issue,rd_valid,rd_ready,active,requested,owner.rows,owner.sel);
  always @(posedge clk)if(!reset&&!clear&&cmd_valid&&cmd_ready&&(cmd.rows==0||cmd.rows>ROWS||cmd.sel>ACC_FACC_B))
    $fatal(1,"Result reader illegal descriptor rows=%0d sel=%0d work=%0d token=%h",cmd.rows,cmd.sel,cmd.work_seq,cmd.token);
  // synthesis translate_on
endmodule
