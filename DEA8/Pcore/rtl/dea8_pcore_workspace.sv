import pcore_pkg::*;
import pcore_control_pkg::*;

module dea8_pcore_workspace #(parameter bit EXTERNAL_VECTOR=0)(
  input logic clk,reset,clear,
  output vector_ram_port_t ram_a,ram_b,
  input logic [TILE-1:0][FP_BITS-1:0] ram_a_data,ram_b_data,
  input logic v_valid,output logic v_ready,input control_memory_req_t v_req,
  output logic v_out_valid,input logic v_out_ready,output control_memory_rsp_t v_out,
  input logic f_valid,output logic f_ready,input control_memory_req_t f_req,
  output logic f_out_valid,input logic f_out_ready,output control_memory_rsp_t f_out
);
  logic [ROWS-1:0] stats_valid[0:5],score_valid[0:1];
  vector_ram_port_t ports[0:1],candidate[0:1];
  logic [TILE-1:0][FP_BITS-1:0] data[0:1];
  control_memory_req_t requests[0:1],read_req_q[0:1];
  control_memory_rsp_t held[0:1];
  logic [1:0] pending_q,held_valid_q,base_ready,ready,valid,fire,conflict,advance;
  logic [TILE-1:0] read_mask_q[0:1];
  function automatic logic [2:0] object_id(input control_memory_req_t req);
    case(req.buffer_id)
      WORK_M:return 0;WORK_AA:return 1;WORK_L:return 2;WORK_RECIP:return 3;
      WORK_ALPHA:return 3'd4+3'(req.bank);default:return 0;
    endcase
  endfunction
  assign requests[0]=v_req;assign requests[1]=f_req;assign valid={f_valid,v_valid};
  assign v_ready=ready[0];assign f_ready=ready[1];assign fire=ready&valid;
  assign v_out=held[0];assign f_out=held[1];
  assign v_out_valid=held_valid_q[0]&&!reset&&!clear;
  assign f_out_valid=held_valid_q[1]&&!reset&&!clear;
  assign ram_a=ports[0];assign ram_b=ports[1];
  if(EXTERNAL_VECTOR)begin assign data[0]=ram_a_data;assign data[1]=ram_b_data;end
  else begin: private_store
    dea8_vector_ram memory(.clk,.a(ram_a),.b(ram_b),.a_data(data[0]),.b_data(data[1]));
  end
  always_comb begin
    base_ready='0;conflict='0;
    for(int p=0;p<2;p++)begin
      advance[p]=!held_valid_q[p]||(p==0?v_out_ready:f_out_ready);
      // The RAM output and held response are two elastic stages. A write
      // also waits when it would overwrite an unretired RAM read result.
      base_ready[p]=!reset&&!clear&&(!pending_q[p]||advance[p]);
      candidate[p]='0;
      candidate[p].data=requests[p].data;
      candidate[p].rotate=requests[p].buffer_id==WORK_SCORE?'0:$clog2(TILE)'(requests[p].index);
      for(int b=0;b<TILE;b++)begin
        logic [$clog2(TILE)-1:0] lane;
        logic [6:0] row;
        lane=$clog2(TILE)'(b)-candidate[p].rotate;
        row={1'b0,requests[p].index}+7'(lane);
        if(requests[p].buffer_id==WORK_SCORE)begin
          candidate[p].en[b]=requests[p].index<ROWS;
          candidate[p].we[b]=requests[p].write;
          candidate[p].addr[b]=8'(128+int'(requests[p].bank)*ROWS+requests[p].index);
        end else if(row<ROWS)begin
          candidate[p].en[b]=!requests[p].write||requests[p].mask[lane];
          candidate[p].we[b]=requests[p].write;
          candidate[p].addr[b]=8'(230+8'(object_id(requests[p])*4)+row/TILE);
        end
      end
    end
    if(valid[0]&&valid[1]&&(&base_ready))for(int b=0;b<TILE;b++)
      if(candidate[0].en[b]&&candidate[1].en[b]&&candidate[0].addr[b]==candidate[1].addr[b])begin
        if(requests[0].write)conflict[0]=1;
        else if(requests[1].write)conflict[1]=1;
      end
    ready=base_ready&~conflict;
    for(int p=0;p<2;p++)begin
      ports[p]=candidate[p];
      ports[p].en&={TILE{fire[p]}};ports[p].we&={TILE{fire[p]}};
    end
  end
  always_ff @(posedge clk)begin
    if(reset||clear)begin
      pending_q<=0;held_valid_q<=0;
      for(int i=0;i<6;i++)stats_valid[i]<=0;
      for(int i=0;i<2;i++)score_valid[i]<=0;
    end else begin
      for(int p=0;p<2;p++)begin
        if(!pending_q[p]||advance[p])pending_q[p]<=fire[p]&&!requests[p].write;
        if(held_valid_q[p]&&(p==0?v_out_ready:f_out_ready))held_valid_q[p]<=0;
        if(fire[p])begin
          if(requests[p].write)begin
            if(requests[p].buffer_id==WORK_SCORE)score_valid[requests[p].bank][requests[p].index]<=1;
            else for(int i=0;i<TILE;i++)if(requests[p].mask[i]&&requests[p].index+i<ROWS)
              stats_valid[object_id(requests[p])][requests[p].index+i]<=1;
          end else begin
            read_req_q[p]<=requests[p];read_mask_q[p]<='0;
            if(requests[p].buffer_id==WORK_SCORE)read_mask_q[p]<={TILE{score_valid[requests[p].bank][requests[p].index]}};
            else for(int i=0;i<TILE;i++)if(requests[p].index+i<ROWS)
              read_mask_q[p][i]<=stats_valid[object_id(requests[p])][requests[p].index+i];
          end
        end
        if(pending_q[p]&&advance[p])begin
          held_valid_q[p]<=1;held[p]<='0;held[p].token<=read_req_q[p].token;
          for(int i=0;i<TILE;i++)begin
            if(read_req_q[p].buffer_id==WORK_SCORE)begin
              held[p].data[i]<=read_mask_q[p][i]?data[p][i]:32'b0;
              held[p].mask[i]<=read_mask_q[p][i];
            end else if(read_req_q[p].index+i<ROWS)begin
              held[p].mask[i]<=1;
              held[p].data[i]<=read_mask_q[p][i]?data[p][i]:
                (read_req_q[p].buffer_id==WORK_M?32'hff800000:32'b0);
            end
          end
        end
      end
    end
  end
endmodule
