import pcore3_pkg::*;
import pcore_control_pkg::*;

// A single shared copy of Attention statistics. Each reader has a held
// response. Score banks use full-row accesses; statistics use row-index spans.
module dea8_pcore_workspace_v3(
  input logic clk,reset,clear,
  input logic v_valid,output logic v_ready,input control_memory_req_t v_req,
  output logic v_out_valid,input logic v_out_ready,output control_memory_rsp_t v_out,
  input logic f_valid,output logic f_ready,input control_memory_req_t f_req,
  output logic f_out_valid,input logic f_out_ready,output control_memory_rsp_t f_out
);
  (* ram_style="block" *) logic [TILE-1:0][FP_BITS-1:0] score[0:1][0:ROWS-1];
  logic [FP_BITS-1:0] m[0:ROWS-1],aa[0:ROWS-1],l[0:ROWS-1],recip[0:ROWS-1],alpha[0:1][0:ROWS-1];
  logic [ROWS-1:0] m_valid,aa_valid,l_valid,recip_valid,alpha_valid[0:1];
  logic [ROWS-1:0] score_valid[0:1];
  control_memory_req_t read_req[0:1],write_req[0:1];
  control_memory_rsp_t response[0:1];
  logic [1:0] fire;
  assign v_ready=!reset&&!clear&&(v_req.write||!v_out_valid||v_out_ready);
  assign f_ready=!reset&&!clear&&(f_req.write||!f_out_valid||f_out_ready);
  assign fire={f_valid&&f_ready,v_valid&&v_ready};
  always_comb begin
    read_req[0]=v_req;read_req[1]=f_req;write_req[0]=v_req;write_req[1]=f_req;
    for(int port=0;port<2;port++)begin
      response[port]='0;response[port].token=read_req[port].token;
      if(read_req[port].buffer_id==WORK_SCORE)begin
        response[port].data=score[read_req[port].bank][read_req[port].index];
        response[port].mask=score_valid[read_req[port].bank][read_req[port].index]?'1:'0;
      end else for(int i=0;i<TILE;i++)if(read_req[port].index+i<ROWS)begin
        response[port].mask[i]=1;
        case(read_req[port].buffer_id)
          WORK_M:response[port].data[i]=m_valid[read_req[port].index+i]?m[read_req[port].index+i]:32'hff800000;
          WORK_AA:response[port].data[i]=aa_valid[read_req[port].index+i]?aa[read_req[port].index+i]:0;
          WORK_L:response[port].data[i]=l_valid[read_req[port].index+i]?l[read_req[port].index+i]:0;
          WORK_RECIP:response[port].data[i]=recip_valid[read_req[port].index+i]?recip[read_req[port].index+i]:0;
          WORK_ALPHA:response[port].data[i]=alpha_valid[read_req[port].bank][read_req[port].index+i]?alpha[read_req[port].bank][read_req[port].index+i]:0;
          default:response[port].mask[i]=0;
        endcase
      end
    end
  end
  always_ff @(posedge clk)begin
    if(reset||clear)begin
      m_valid<=0;aa_valid<=0;l_valid<=0;recip_valid<=0;
      for(int b=0;b<2;b++)begin score_valid[b]<=0;alpha_valid[b]<=0;end
      v_out_valid<=0;f_out_valid<=0;v_out<='0;f_out<='0;
    end else begin
      if(v_out_valid&&v_out_ready)v_out_valid<=0;
      if(f_out_valid&&f_out_ready)f_out_valid<=0;
      if(fire[0]&&!v_req.write)begin v_out<=response[0];v_out_valid<=1;end
      if(fire[1]&&!f_req.write)begin f_out<=response[1];f_out_valid<=1;end
      for(int port=0;port<2;port++)if(fire[port]&&write_req[port].write)begin
        if(write_req[port].buffer_id==WORK_SCORE)begin
          score[write_req[port].bank][write_req[port].index]<=write_req[port].data;
          score_valid[write_req[port].bank][write_req[port].index]<=1;
        end else for(int i=0;i<TILE;i++)if(write_req[port].mask[i]&&write_req[port].index+i<ROWS)begin
          case(write_req[port].buffer_id)
            WORK_M:begin m[write_req[port].index+i]<=write_req[port].data[i];m_valid[write_req[port].index+i]<=1;end
            WORK_AA:begin aa[write_req[port].index+i]<=write_req[port].data[i];aa_valid[write_req[port].index+i]<=1;end
            WORK_L:begin l[write_req[port].index+i]<=write_req[port].data[i];l_valid[write_req[port].index+i]<=1;end
            WORK_RECIP:begin recip[write_req[port].index+i]<=write_req[port].data[i];recip_valid[write_req[port].index+i]<=1;end
            WORK_ALPHA:begin alpha[write_req[port].bank][write_req[port].index+i]<=write_req[port].data[i];alpha_valid[write_req[port].bank][write_req[port].index+i]<=1;end
            default:;
          endcase
        end
      end
    end
  end
endmodule
