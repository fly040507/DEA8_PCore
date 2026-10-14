import pcore_pkg::*;

// One copy of Attention statistics and two parity-split Score generations.
// The unit service authorizes tokens/operations; this block checks range,
// physical collisions and held synchronous responses. Payload is never reset.
module dea8_workspace (
  input logic clk,reset,clear,begin_job,
  input logic [ROW_COUNT_BITS-1:0] rows,
  input logic score_begin,alpha_begin,input logic [5:0] score_begin_block,alpha_begin_block,
  input logic v_valid,output logic v_ready,input workspace_req_t v_req,
  output logic v_out_valid,input logic v_out_ready,output workspace_rsp_t v_out,
  input logic f_valid,output logic f_ready,input workspace_req_t f_req,
  output logic f_out_valid,input logic f_out_ready,output workspace_rsp_t f_out,
  output workspace_status_t status,output logic protocol_error
);
  (* ram_style="block" *) logic [TILE-1:0][FP_BITS-1:0] score_even[0:1][0:PAIRS-1];
  (* ram_style="block" *) logic [TILE-1:0][FP_BITS-1:0] score_odd[0:1][0:ROWS/2-1];
  logic [FP_BITS-1:0] m[0:ROWS-1],aa[0:ROWS-1],l[0:ROWS-1],reciprocal[0:ROWS-1];
  logic [FP_BITS-1:0] alpha[0:1][0:ROWS-1];
  logic [ROWS-1:0] stat_valid[0:3],stat_written[0:3],score_written[0:1],alpha_written[0:1];
  logic [5:0] stat_generation[0:3],score_generation[0:1],alpha_generation[0:1];
  workspace_req_t requests[0:1];workspace_rsp_t replies[0:1];
  logic [1:0] legal,fire;
  logic collision;
  function automatic int stat_index(input workspace_kind_e kind);
    case(kind) WS_M:return 0;WS_AA:return 1;WS_L:return 2;default:return 3;endcase
  endfunction
  assign requests[0]=v_req;
  assign requests[1]=f_req;
  always_comb begin
    legal=0;collision=0;
    for(int p=0;p<2;p++)begin
      legal[p]=requests[p].index<rows&&requests[p].kind<=WS_RECIP&&requests[p].block_id<KV_BLOCKS;
      if(requests[p].kind==WS_SCORE)begin
        legal[p]&=requests[p].bank==requests[p].block_id[0]&&
          requests[p].block_id==score_generation[requests[p].bank]&&requests[p].row_mask!=0;
        for(int r=0;r<ROW_LANES;r++)if(requests[p].row_mask[r]&&int'(requests[p].index)+r>=rows)legal[p]=0;
        if(requests[p].write)legal[p]&=requests[p].index%ROW_LANES==0&&requests[p].mask=='1;
      end else begin
        legal[p]&=requests[p].mask!=0;
        for(int i=0;i<TILE;i++)if(requests[p].mask[i]&&int'(requests[p].index)+i>=rows)legal[p]=0;
        if(requests[p].kind==WS_ALPHA)legal[p]&=requests[p].bank==requests[p].block_id[0]&&
          requests[p].block_id==alpha_generation[requests[p].bank];
      end
      replies[p]='0;replies[p].token=requests[p].token;replies[p].kind=requests[p].kind;replies[p].bank=requests[p].bank;
      replies[p].block_id=requests[p].block_id;replies[p].index=requests[p].index;replies[p].group_id=requests[p].group_id;
      if(legal[p])begin
        replies[p].mask=requests[p].mask;replies[p].row_mask=requests[p].row_mask;
        if(requests[p].kind==WS_SCORE)begin
          for(int r=0;r<ROW_LANES;r++)if(requests[p].row_mask[r])begin
            int row;row=int'(requests[p].index)+r;
            if(score_written[requests[p].bank][row])begin
              if(row%2==0)replies[p].data[r]=score_even[requests[p].bank][row/2];
              else replies[p].data[r]=score_odd[requests[p].bank][row/2];
            end else replies[p].row_mask[r]=0;
          end
        end else for(int i=0;i<TILE;i++)if(requests[p].mask[i])begin
          int row;row=int'(requests[p].index)+i;
          case(requests[p].kind)
            WS_M:replies[p].data[0][i]=stat_valid[0][row]?m[row]:32'hff800000;
            WS_AA:replies[p].data[0][i]=stat_valid[1][row]?aa[row]:32'd0;
            WS_L:replies[p].data[0][i]=stat_valid[2][row]?l[row]:32'd0;
            WS_RECIP:replies[p].data[0][i]=stat_valid[3][row]?reciprocal[row]:32'd0;
            WS_ALPHA:replies[p].data[0][i]=alpha_written[requests[p].bank][row]?alpha[requests[p].bank][row]:32'd0;
            default:;
          endcase
        end
      end
    end
    if(v_valid&&f_valid&&legal[0]&&legal[1]&&v_req.kind==f_req.kind&&(v_req.write||f_req.write))begin
      if(v_req.kind!=WS_SCORE&&v_req.kind!=WS_ALPHA)collision=1;
      else if(v_req.bank==f_req.bank)collision=1;
    end
  end
  always_comb begin
    workspace_status_t next_status;
    next_status='0;
    for(int b=0;b<2;b++)begin
      next_status.score_complete[b]=score_written[b]==row_prefix(rows)&&rows!=0;
      next_status.alpha_complete[b]=alpha_written[b]==row_prefix(rows)&&rows!=0;
      next_status.score_block[b]=score_generation[b];next_status.alpha_block[b]=alpha_generation[b];
    end
    for(int s=0;s<4;s++)begin next_status.stat_complete[s]=stat_written[s]==row_prefix(rows)&&rows!=0;next_status.stat_block[s]=stat_generation[s];end
    status=next_status;
  end
  assign v_ready=!reset&&!clear&&!begin_job&&!protocol_error&&legal[0]&&(v_req.write||!v_out_valid||v_out_ready);
  assign f_ready=!reset&&!clear&&!begin_job&&!protocol_error&&legal[1]&&!collision&&(f_req.write||!f_out_valid||f_out_ready);
  assign fire={f_valid&&f_ready,v_valid&&v_ready};
  always_ff @(posedge clk)begin
    if(reset||clear||begin_job)begin
      protocol_error<=0;v_out_valid<=0;f_out_valid<=0;
      for(int s=0;s<4;s++)begin stat_valid[s]<=0;stat_written[s]<=0;stat_generation[s]<=0;end
      for(int b=0;b<2;b++)begin score_written[b]<=0;alpha_written[b]<=0;score_generation[b]<=0;alpha_generation[b]<=0;end
    end else begin
      if(v_valid&&!legal[0]||f_valid&&!legal[1])protocol_error<=1;
      if(v_out_valid&&v_out_ready)v_out_valid<=0;
      if(f_out_valid&&f_out_ready)f_out_valid<=0;
      if(fire[0]&&!v_req.write)begin v_out<=replies[0];v_out_valid<=1;end
      if(fire[1]&&!f_req.write)begin f_out<=replies[1];f_out_valid<=1;end
      if(score_begin)begin score_generation[score_begin_block[0]]<=score_begin_block;score_written[score_begin_block[0]]<=0;end
      if(alpha_begin)begin alpha_generation[alpha_begin_block[0]]<=alpha_begin_block;alpha_written[alpha_begin_block[0]]<=0;end
      for(int p=0;p<2;p++)if(fire[p]&&requests[p].write)begin
        if(requests[p].kind==WS_SCORE)begin
          for(int r=0;r<ROW_LANES;r++)if(requests[p].row_mask[r])begin
            int row;row=int'(requests[p].index)+r;
            if(row%2==0)score_even[requests[p].bank][row/2]<=requests[p].data[r];
            else score_odd[requests[p].bank][row/2]<=requests[p].data[r];
            score_written[requests[p].bank][row]<=1;
          end
        end else if(requests[p].kind==WS_ALPHA)begin
          for(int i=0;i<TILE;i++)if(requests[p].mask[i])begin
            alpha[requests[p].bank][int'(requests[p].index)+i]<=requests[p].data[0][i];
            alpha_written[requests[p].bank][int'(requests[p].index)+i]<=1;
          end
        end else begin
          int s;logic [ROWS-1:0] next_mask;s=stat_index(requests[p].kind);
          next_mask=stat_generation[s]==requests[p].block_id?stat_written[s]:'0;
          for(int i=0;i<TILE;i++)if(requests[p].mask[i])begin
            int row;row=int'(requests[p].index)+i;next_mask[row]=1;stat_valid[s][row]<=1;
            case(requests[p].kind)
              WS_M:m[row]<=requests[p].data[0][i];
              WS_AA:aa[row]<=requests[p].data[0][i];
              WS_L:l[row]<=requests[p].data[0][i];
              WS_RECIP:reciprocal[row]<=requests[p].data[0][i];
              default:;
            endcase
          end
          stat_written[s]<=next_mask;stat_generation[s]<=requests[p].block_id;
        end
      end
    end
  end
endmodule
