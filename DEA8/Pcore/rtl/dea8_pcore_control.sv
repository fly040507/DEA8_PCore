import pcore_pkg::*;
import pcore_control_pkg::*;
import dea8_tile_link_pkg::*;

module dea8_pcore_control #(
  parameter logic [CORE_BITS-1:0] PCORE_ID='0
)(
  input logic clk,reset,clear,
  input logic job_valid,output logic job_ready,input control_job_t job,
  output logic done_valid,input logic done_ready,output control_completion_t done,
  output logic busy,protocol_error,output logic [1:0] active_adapter,
  output logic flush_valid,input logic vpu_flush_ack,sfu_flush_ack,
  input logic xbc_valid,output logic xbc_ready,input xbc4_t xbc_entry,
  input logic hbm_valid,output logic hbm_ready,input b2_t hbm_entry,
  input logic kv_valid,output logic kv_ready,input b2_t kv_entry,
  output logic vector_valid,input logic vector_ready,output control_command_t vector_cmd,
  input logic vector_done_valid,output logic vector_done_ready,input control_unit_done_t vector_done,
  output logic function_valid,input logic function_ready,output control_command_t function_cmd,
  input logic function_done_valid,output logic function_done_ready,input control_unit_done_t function_done,
  output logic vector_data_valid,input logic vector_data_ready,output control_fp_data_t vector_data,
  output logic function_data_valid,input logic function_data_ready,output control_fp_data_t function_data,
  input logic function_result_valid,output logic function_result_ready,input control_fp_data_t function_result,
  input logic vector_result_valid,output logic vector_result_ready,input control_quant_result_t vector_result,
  input logic vector_mem_valid,output logic vector_mem_ready,input control_memory_req_t vector_mem_req,
  output logic vector_mem_out_valid,input logic vector_mem_out_ready,output control_memory_rsp_t vector_mem_out,
  input logic function_mem_valid,output logic function_mem_ready,input control_memory_req_t function_mem_req,
  output logic function_mem_out_valid,input logic function_mem_out_ready,output control_memory_rsp_t function_mem_out,
  input logic rope_req_valid,output logic rope_req_ready,input control_rope_req_t rope_req,
  output logic rope_sfu_valid,input logic rope_sfu_ready,output control_rope_req_t rope_sfu_req,
  input logic rope_sfu_out_valid,output logic rope_sfu_out_ready,input control_rope_rsp_t rope_sfu_out,
  output logic rope_out_valid,input logic rope_out_ready,output control_rope_rsp_t rope_out,
  output logic kv_hdr_valid,input logic kv_hdr_ready,output tile_header_t kv_hdr,
  output logic kv_out_valid,input logic kv_out_ready,output logic [KV_WORD_BITS-1:0] kv_out,
  output logic kv_out_last,
  input logic kv_commit_valid,output logic kv_commit_ready,input tile_commit_t kv_commit,
  output logic reduce_hdr_valid,input logic reduce_hdr_ready,output tile_header_t reduce_hdr,
  output logic reduce_out_valid,input logic reduce_out_ready,output logic [FP_ROW_BITS-1:0] reduce_out,
  output logic reduce_out_last,
  input logic acc_rd_valid,output logic acc_rd_ready,input acc_sel_e acc_rd_sel,input logic [9:0] acc_rd_addr,
  input control_token_t acc_token,
  output logic acc_data_valid,input logic acc_data_ready,output logic [TILE-1:0][FP_BITS-1:0] acc_even,acc_odd,
  input logic acc_wr_valid,output logic acc_wr_ready,input acc_write_t acc_wr,
  output logic qoz_complete,output qoz_region_req_t qoz_region,
  input logic ext_qoz_region_valid,output logic ext_qoz_region_ready,input qoz_region_req_t ext_qoz_region,
  input logic [15:0] ext_qoz_context,
  input logic ext_qoz_wr_valid,output logic ext_qoz_wr_ready,input post_result_t ext_qoz_wr,
  output logic gu_prefetch_valid,input logic gu_prefetch_ready,output logic [5:0] gu_prefetch_n
);
  control_job_t job_q;
  pcore_job_t engine_job;
  pcore_completion_t engine_done;
  logic ejv,ejr,edv,edr,eb,ee,active_q,complete_q,fault_q,clear_q,flush_q;
  logic [1:0] flush_acks_q;
  control_status_e status_q;
  logic [GENERATION_BITS-1:0] generation_q;
  logic [COMMAND_BITS-2:0] vseq_q,fseq_q;
  logic [15:0] region_context_q;
  logic precondition,job_legal,core_match,is_reduce,is_kv;
  logic post_valid,post_ready,post_done_valid,post_done_ready,data_valid,data_ready;
  pcore_post_job_t post_job,post_done;
  post_data_t data;
  post_result_t result;
  logic result_valid,result_ready;
  logic av,ar,adv,adr,af,afr,afd,afdr;
  vpu_cmd_t ac,ad;sfu_cmd_t as,asd;
  logic sv,sr,sfv,sfr,sdv,sdr,sfdv,sfdr,svdone,sfdone,se,si,rl;
  logic svc_ready,svc_done_valid,svc_done_ready,svc_data_ready,svc_fr_ready;
  pcore_post_job_t svc_done;
  control_command_t sc,sfc,vheld_q,fheld_q;
  control_fp_data_t sd,sfd;
  logic vb_q,fb_q,vdmatch,fdmatch,vrmatch,frmatch;
  logic [15:0] vcount_q,fcount_q,kv_sent_q,reduce_sent_q;
  logic [5:0] afin_tile_q;
  logic [PAIR_BITS-1:0] afin_pair_q;
  logic pv,pr;a2_t pe;
  logic kin,kr,kempty,rin,rr,rempty;
  logic output_busy,output_error;
  logic rd_armed_q,rd_done_q,rd_legal;
  pcore_post_job_t rd_command_q;
  logic [PAIR_BITS-1:0] rd_pair_q;
  logic [5:0] rd_tile_q;
  logic raw_valid,raw_ready,raw_request,read_pending_q,response_q;
  logic [TILE-1:0][FP_BITS-1:0] raw_even,raw_odd;
  logic [2:0] read_pending_count_q,response_count_q;
  logic [1:0] response_rd_q,response_wr_q;
  logic [ROW_LANES*TILE*FP_BITS-1:0] response_mem[0:3];
  logic read_credit,read_fire,response_fire;
  logic fault_event;
  logic acc_read_legal,acc_write_legal,raw_write_ready,raw_xbc_ready,raw_hbm_ready,raw_kv_ready,source_enable;
  logic [9:0] matrix_acc_addr;
  acc_write_t matrix_acc_write;
  logic vm_legal,fm_legal,vm_ready,fm_ready;
  logic [ROWS-1:0] v_written_q[0:3],f_written_q[0:1];
  logic [9:0] acc_written_q;
  logic v_writes_complete,f_writes_complete,raw_ext_region_ready,raw_ext_write_ready;
  localparam int ROPE_OUTSTANDING=8;
  logic rope_pending_q,rope_legal,rope_response_match,rope_credit,rope_req_fire,rope_rsp_fire;
  logic [3:0] rope_count_q;
  logic [2:0] rope_rd_q,rope_wr_q;
  control_rope_req_t rope_requests[0:ROPE_OUTSTANDING-1];
  function automatic int v_write_slot(input control_buffer_e id);
    case(id) WORK_SCORE:return 0;WORK_M:return 1;WORK_AA:return 2;default:return 3;endcase
  endfunction
  function automatic logic range_legal(input control_memory_req_t req);
    logic good;good=req.index<ROWS;
    if(req.buffer_id==WORK_SCORE)good&=req.write?req.mask=='1:1'b1;
    else if(req.write)begin
      good&=req.mask!=0;
      for(int i=0;i<TILE;i++)if(req.mask[i]&&req.index+i>=ROWS)good=0;
    end
    return good;
  endfunction

  assign engine_job='{header:job.header};
  assign is_reduce=job_q.header.op==OP_O_PROJ||job_q.header.op==OP_DOWN_PROJ;
  assign is_kv=job_q.header.op==OP_K_PROJ||job_q.header.op==OP_V_PROJ;
  always_comb begin
    core_match=job.core_id==PCORE_ID;
    job_legal=int'(job.header.op)<7&&job.layout_id==0&&job.position_base<=((1<<POSITION_BITS)-ROWS)&&
      (job.header.op!=OP_K_PROJ||job.rope_pair_base<=128-TILE);
    precondition=1;
    case(job.header.op)
      OP_ATTENTION:precondition=qoz_complete&&qoz_region.owner==QOZ_Q;
      OP_O_PROJ:precondition=qoz_complete&&qoz_region.owner==QOZ_O;
      OP_DOWN_PROJ:precondition=qoz_complete&&qoz_region.owner==QOZ_Z;
      OP_Q_PROJ,OP_GU:precondition=qoz_region.owner==QOZ_NONE;
      default:;
    endcase
    if(job.header.op==OP_ATTENTION||job.header.op==OP_O_PROJ||job.header.op==OP_DOWN_PROJ)
      precondition&=region_context_q==job.data_context&&qoz_region.header.epoch==job.header.epoch&&qoz_region.header.head==job.header.head;
  end
  assign job_ready=!active_q&&!complete_q&&!fault_q&&!flush_q&&!output_busy&&!reset&&!clear&&ejr;
  assign ejv=job_valid&&job_ready&&job_legal&&precondition&&core_match;
  assign busy=active_q||complete_q||fault_q||flush_q;
  assign flush_valid=flush_q;
  assign protocol_error=fault_q||ee||se||output_error;
  assign done_valid=complete_q&&!reset&&!clear&&!flush_q;
  assign done='{job:job_q,status:status_q};
  assign edr=active_q&&!fault_q&&si&&kempty&&rempty&&!vb_q&&!fb_q&&!read_pending_q&&!response_q;

  // One inflight command per unit. Tokens identify every data/return channel.
  always_comb begin
    vector_cmd=active_adapter==1?'0:sc;
    function_cmd=active_adapter==1?'0:sfc;
    if(active_adapter==1)begin
      vector_cmd.job=job_q;vector_cmd.tile=ac.block_id;vector_cmd.attention_vpu=ac;
      vector_cmd.tiles=1;vector_cmd.elements=16'(ROWS*TILE);
      case(ac.op)
        VPU_QK_POST:begin vector_cmd.function_id=VECTOR_QK_POST;vector_cmd.source=WORK_FACC;vector_cmd.destination=WORK_SCORE;end
        VPU_P_POST:begin vector_cmd.function_id=VECTOR_P_POST;vector_cmd.source=WORK_P;vector_cmd.destination=WORK_P;end
        VPU_OACC_SCALE:begin
          vector_cmd.function_id=VECTOR_OACC_SCALE;vector_cmd.source=WORK_OACC;vector_cmd.destination=WORK_OACC;
          vector_cmd.tiles=QOZ_O_TILES;vector_cmd.elements=16'(ROWS*TILE*QOZ_O_TILES);
        end
        default:begin
          vector_cmd.function_id=VECTOR_AFIN_QUANT;vector_cmd.source=WORK_OACC;vector_cmd.destination=WORK_QOZ;
          vector_cmd.tiles=QOZ_O_TILES;vector_cmd.elements=16'(ROWS*TILE*QOZ_O_TILES);
        end
      endcase
      function_cmd.job=job_q;function_cmd.tile=as.block_id;function_cmd.attention_sfu=as;
      function_cmd.function_id=as.op==SFU_ALPHA_EXP?FUNCTION_ALPHA_EXP:(as.op==SFU_P_EXP?FUNCTION_P_EXP:FUNCTION_RECIP);
      function_cmd.elements=16'(as.op==SFU_P_EXP?ROWS*TILE:ROWS);
      function_cmd.tiles=1;
      case(as.op)
        SFU_ALPHA_EXP:begin function_cmd.source=WORK_AA;function_cmd.destination=WORK_ALPHA;end
        SFU_P_EXP:begin function_cmd.source=WORK_SCORE;function_cmd.destination=WORK_P;end
        default:begin function_cmd.source=WORK_L;function_cmd.destination=WORK_RECIP;end
      endcase
    end
    vector_cmd.token='{generation:generation_q,command_id:{vseq_q,1'b0}};
    function_cmd.token='{generation:generation_q,command_id:{fseq_q,1'b1}};
  end
  assign vector_valid=active_q&&!fault_q&&!flush_q&&!vb_q&&(active_adapter==1?av:sv);
  assign function_valid=active_q&&!fault_q&&!flush_q&&!fb_q&&(active_adapter==1?af:sfv);
  assign ar=vector_valid&&vector_ready&&active_adapter==1;
  assign sr=vector_valid&&vector_ready&&active_adapter!=1;
  assign afr=function_valid&&function_ready&&active_adapter==1;
  assign sfr=function_valid&&function_ready&&active_adapter!=1;
  always_comb begin
    v_writes_complete=1;f_writes_complete=1;
    case(vheld_q.function_id)
      VECTOR_QK_POST:v_writes_complete=(&v_written_q[0])&&(&v_written_q[1])&&(&v_written_q[2]);
      VECTOR_P_POST:v_writes_complete=&v_written_q[3];
      VECTOR_OACC_SCALE:v_writes_complete=acc_written_q==QOZ_O_TILES*PAIRS;
      default:;
    endcase
    if(fheld_q.function_id==FUNCTION_ALPHA_EXP)f_writes_complete=&f_written_q[0];
    if(fheld_q.function_id==FUNCTION_RECIP)f_writes_complete=&f_written_q[1];
  end
  assign vdmatch=vb_q&&v_writes_complete&&!rope_pending_q&&!rope_req_valid&&vector_done.command==vheld_q&&!vector_done.error&&!read_pending_q&&!response_q&&!acc_rd_valid&&!acc_wr_valid&&!vector_mem_valid&&!vector_mem_out_valid&&
    (vheld_q.function_id!=VECTOR_AFIN_QUANT||vcount_q==QOZ_O_TILES*PAIRS)&&
    (vheld_q.function_id!=VECTOR_P_POST||vcount_q==PAIRS)&&
    (vheld_q.function_id!=VECTOR_V_QUANT||vcount_q==V_PACKETS_PER_TILE)&&
    (vheld_q.function_id!=VECTOR_ROPE_QUANT||vcount_q==2*PAIRS)&&
    (vheld_q.function_id!=VECTOR_GU_POST||vcount_q==PAIRS);
  assign fdmatch=fb_q&&f_writes_complete&&function_done.command==fheld_q&&!function_done.error&&!function_mem_valid&&!function_mem_out_valid&&
    (fheld_q.function_id!=FUNCTION_P_EXP||fcount_q==PAIRS)&&
    (fheld_q.function_id!=FUNCTION_GELU||fcount_q==ROWS);
  assign vector_done_ready=!flush_q&&!fault_q&&vdmatch;
  assign function_done_ready=!flush_q&&!fault_q&&fdmatch;
  assign rope_legal=vb_q&&vheld_q.function_id==VECTOR_ROPE_QUANT&&rope_req.token==vheld_q.token&&
    rope_req.row<ROWS&&rope_req.position==job_q.position_base+rope_req.row&&rope_req.frequency_base==vheld_q.rope_frequency_base;
  assign rope_pending_q=rope_count_q!=0;
  assign rope_rsp_fire=rope_out_valid&&rope_out_ready;
  assign rope_credit=rope_count_q<ROPE_OUTSTANDING||rope_rsp_fire;
  assign rope_sfu_valid=rope_req_valid&&rope_legal&&rope_credit&&!fault_q&&!flush_q;
  assign rope_sfu_req=rope_req;
  assign rope_req_ready=rope_sfu_ready&&rope_legal&&rope_credit&&!fault_q&&!flush_q;
  assign rope_req_fire=rope_req_valid&&rope_req_ready;
  assign rope_response_match=rope_pending_q&&rope_sfu_out.request==rope_requests[rope_rd_q];
  assign rope_out_valid=rope_sfu_out_valid&&rope_response_match&&!fault_q&&!flush_q;
  assign rope_out=rope_sfu_out;
  assign rope_sfu_out_ready=rope_out_ready&&rope_response_match&&!fault_q&&!flush_q;
  assign adv=vector_done_valid&&vector_done_ready&&active_adapter==1;assign ad=vheld_q.attention_vpu;
  assign afd=function_done_valid&&function_done_ready&&active_adapter==1;assign asd=fheld_q.attention_sfu;
  assign svdone=vector_done_valid&&vector_done_ready&&active_adapter!=1;
  assign sfdone=function_done_valid&&function_done_ready&&active_adapter!=1;
  assign frmatch=fb_q&&function_result.job==job_q&&function_result.token==fheld_q.token&&
    function_result.tile==fheld_q.tile&&function_result.index==fcount_q&&
    (fheld_q.function_id==FUNCTION_GELU||fheld_q.function_id==FUNCTION_P_EXP)&&
    fcount_q<(active_adapter==1?PAIRS:ROWS)&&
    function_result.vector_valid==(active_adapter==1?row_mask(fcount_q):2'b01)&&
    function_result.last==(fcount_q==(active_adapter==1?PAIRS-1:ROWS-1));
  assign function_data_valid=sfdv&&!fault_q;
  always_comb begin function_data=sfd;function_data.token=fheld_q.token;end
  assign sfdr=function_data_ready&&!fault_q;
  assign vector_data_valid=!fault_q&&(active_adapter==1?
    (function_result_valid&&frmatch&&vb_q&&vheld_q.function_id==VECTOR_P_POST&&vheld_q.tile==function_result.tile):sdv);
  always_comb begin vector_data=active_adapter==1?function_result:sd;vector_data.token=vheld_q.token;end
  assign sdr=vector_data_ready&&active_adapter!=1&&!fault_q;
  assign function_result_ready=!fault_q&&!flush_q&&frmatch&&
    (active_adapter==1?(vector_data_valid&&vector_data_ready):svc_fr_ready);

  always_comb begin
    vrmatch=vb_q&&vector_result.token==vheld_q.token;
    if(active_adapter!=1)vrmatch&=rl;
    else if(vheld_q.function_id==VECTOR_P_POST)
      vrmatch&=vcount_q<PAIRS&&vector_result.tile==vheld_q.tile&&vector_result.index==vcount_q&&
        vector_result.vector_valid==row_mask(vcount_q)&&vector_result.quant_axis==QUANT_FEATURE_B16&&vector_result.last==(vcount_q==PAIRS-1);
    else if(vheld_q.function_id==VECTOR_AFIN_QUANT)
      vrmatch&=vcount_q<QOZ_O_TILES*PAIRS&&vector_result.tile==afin_tile_q&&vector_result.index==afin_pair_q&&
        vector_result.vector_valid==row_mask(afin_pair_q)&&vector_result.quant_axis==QUANT_FEATURE_B16&&vector_result.last==(afin_pair_q==PAIRS-1);
    else vrmatch=0;
    if(job_q.header.op==OP_V_PROJ)vrmatch&=vector_result.token_mask==(vector_result.index>=3*(TILE/ROW_LANES)?16'h0007:16'hffff);
  end
  assign vector_result_ready=!fault_q&&!flush_q&&vrmatch&&
    (is_kv?kr:((active_adapter==1&&vheld_q.function_id==VECTOR_P_POST)?pr:result_ready));
  assign kin=vector_result_valid&&vrmatch&&!fault_q&&is_kv;
  always_comb begin
    result='0;result.header=job_q.header;result.n=vector_result.tile;
    result.pair_data.tile_idx=vector_result.tile;result.pair_data.pair_idx=PAIR_BITS'(vector_result.index);
    result.pair_data.row_valid=vector_result.vector_valid;result.pair_data.row[0]=vector_result.vector_data[0];result.pair_data.row[1]=vector_result.vector_data[1];
    result.last=vector_result.last;
    pe=result.pair_data;pe.tile_idx=0;pe.slot=vheld_q.tile[0];
  end
  assign pv=vector_result_valid&&vrmatch&&!fault_q&&active_adapter==1&&vheld_q.function_id==VECTOR_P_POST;
  assign result_valid=vector_result_valid&&vrmatch&&!fault_q&&
    (job_q.header.op==OP_Q_PROJ||job_q.header.op==OP_GU||(active_adapter==1&&vheld_q.function_id==VECTOR_AFIN_QUANT));
  assign rd_legal=data.header==job_q.header&&data.n==rd_tile_q&&data.row==rd_pair_q&&
    data.row_valid==row_mask(rd_pair_q)&&data.last==(rd_pair_q==PAIRS-1);
  assign rin=is_reduce&&data_valid&&rd_armed_q&&!fault_q&&rd_legal;
  assign post_ready=!fault_q&&(is_reduce?(!rd_armed_q&&!rd_done_q):svc_ready);
  assign post_done_valid=is_reduce?rd_done_q:svc_done_valid;assign post_done=is_reduce?rd_command_q:svc_done;
  assign svc_done_ready=post_done_ready&&!is_reduce&&!fault_q;
  assign data_ready=!fault_q&&(is_reduce?(rr&&rd_armed_q&&rd_legal):svc_data_ready);
  dea8_pcore_post post_service(.clk,.reset,.clear(clear||ejv),.job(job_q),
    .in_cmd_valid(post_valid&&!is_reduce&&!fault_q),.in_cmd_ready(svc_ready),.in_cmd(post_job),
    .in_valid(data_valid&&!is_reduce&&!fault_q),.in_ready(svc_data_ready),.in_data(data),
    .done_valid(svc_done_valid),.done_ready(svc_done_ready),.done(svc_done),
    .vector_valid(sv),.vector_ready(sr),.vector_cmd(sc),.vector_done(svdone),
    .function_valid(sfv),.function_ready(sfr),.function_cmd(sfc),.function_done(sfdone),
    .vector_data_valid(sdv),.vector_data_ready(sdr),.vector_data(sd),
    .function_data_valid(sfdv),.function_data_ready(sfdr),.function_data(sfd),
    .function_result_valid(function_result_valid&&frmatch),.function_result_ready(svc_fr_ready),.function_result,
    .result_fire(vector_result_valid&&vector_result_ready&&active_adapter!=1),.result(vector_result),.result_legal(rl),.error(se),.idle(si));
  dea8_pcore_output output_stage(.clk,.reset,.clear(clear||ejv),.job(job_q),
    .quant_valid(kin),.quant_ready(kr),.quant(vector_result),
    .facc_valid(rin),.facc_ready(rr),.facc(data),
    .kv_hdr_valid,.kv_hdr_ready,.kv_hdr,.kv_out_valid,.kv_out_ready,.kv_out,.kv_out_last,
    .kv_commit_valid,.kv_commit_ready,.kv_commit,
    .reduce_hdr_valid,.reduce_hdr_ready,.reduce_hdr,.reduce_out_valid,.reduce_out_ready,.reduce_out,.reduce_out_last,
    .kv_empty(kempty),.reduce_empty(rempty),.busy(output_busy),.protocol_error(output_error));

  // Hold a RAM response until the unit consumes it; reserve capacity first.
  assign acc_read_legal=vb_q&&active_adapter==1&&acc_token==vheld_q.token&&
    ((vheld_q.function_id==VECTOR_QK_POST&&acc_rd_sel==(vheld_q.attention_vpu.facc_bank?ACC_FACC_B:ACC_FACC_A)&&acc_rd_addr<PAIRS)||
     ((vheld_q.function_id==VECTOR_OACC_SCALE||vheld_q.function_id==VECTOR_AFIN_QUANT)&&acc_rd_sel==ACC_OACC&&acc_rd_addr<QOZ_O_TILES*PAIRS));
  assign acc_write_legal=vb_q&&active_adapter==1&&acc_token==vheld_q.token&&
    vheld_q.function_id==VECTOR_OACC_SCALE&&acc_wr.sel==ACC_OACC&&acc_wr.addr==acc_written_q&&acc_wr.addr<QOZ_O_TILES*PAIRS&&acc_wr.row_valid==row_mask(acc_wr.addr%PAIRS);
  assign read_pending_q=read_pending_count_q!=0;
  assign response_q=response_count_q!=0;
  assign response_fire=response_q&&acc_data_ready;
  assign read_credit=read_pending_count_q+response_count_q<4||response_fire;
  assign raw_request=acc_rd_valid&&acc_read_legal&&read_credit&&!fault_q;
  assign acc_rd_ready=raw_ready&&acc_read_legal&&read_credit&&!fault_q;
  assign read_fire=raw_request&&raw_ready;
  assign acc_wr_ready=raw_write_ready&&acc_write_legal&&!fault_q;
  // Unit-facing OACC is tile-major; the existing DEQACC RAM is pair-major.
  // Keep this conversion outside the matrix read/modify/write pipeline.
  assign matrix_acc_addr=acc_rd_sel==ACC_OACC?
    10'((acc_rd_addr%PAIRS)*QOZ_O_TILES+acc_rd_addr/PAIRS):acc_rd_addr;
  always_comb begin
    matrix_acc_write=acc_wr;
    if(acc_wr.sel==ACC_OACC)
      matrix_acc_write.addr=10'((acc_wr.addr%PAIRS)*QOZ_O_TILES+acc_wr.addr/PAIRS);
  end
  assign acc_data_valid=response_q;
  assign {acc_odd,acc_even}=response_mem[response_rd_q];
  always_comb begin
    vm_legal=0;fm_legal=0;
    case(vheld_q.function_id)
      VECTOR_QK_POST:vm_legal=(vector_mem_req.buffer_id==WORK_M||
        ((vector_mem_req.buffer_id==WORK_AA||vector_mem_req.buffer_id==WORK_SCORE)&&vector_mem_req.write));
      VECTOR_P_POST:vm_legal=(vector_mem_req.buffer_id==WORK_L||
        (vector_mem_req.buffer_id==WORK_ALPHA&&!vector_mem_req.write));
      VECTOR_OACC_SCALE:vm_legal=vector_mem_req.buffer_id==WORK_ALPHA&&!vector_mem_req.write;
      VECTOR_AFIN_QUANT:vm_legal=vector_mem_req.buffer_id==WORK_RECIP&&!vector_mem_req.write;
      default:;
    endcase
    case(fheld_q.function_id)
      FUNCTION_ALPHA_EXP:fm_legal=(function_mem_req.buffer_id==WORK_AA&&!function_mem_req.write)||
        (function_mem_req.buffer_id==WORK_ALPHA&&function_mem_req.write);
      FUNCTION_P_EXP:fm_legal=(function_mem_req.buffer_id==WORK_SCORE||function_mem_req.buffer_id==WORK_M)&&!function_mem_req.write;
      FUNCTION_RECIP:fm_legal=(function_mem_req.buffer_id==WORK_L&&!function_mem_req.write)||
        (function_mem_req.buffer_id==WORK_RECIP&&function_mem_req.write);
      default:;
    endcase
    vm_legal&=vb_q&&active_adapter==1&&vector_mem_req.token==vheld_q.token&&range_legal(vector_mem_req)&&
      vector_mem_req.bank==((vector_mem_req.buffer_id==WORK_ALPHA||vector_mem_req.buffer_id==WORK_SCORE)?vheld_q.tile[0]:1'b0);
    fm_legal&=fb_q&&active_adapter==1&&function_mem_req.token==fheld_q.token&&range_legal(function_mem_req)&&
      function_mem_req.bank==((function_mem_req.buffer_id==WORK_ALPHA||function_mem_req.buffer_id==WORK_SCORE)?fheld_q.tile[0]:1'b0);
    if(vector_mem_req.write)begin
      if(vector_mem_req.buffer_id==WORK_SCORE)vm_legal&=!v_written_q[0][vector_mem_req.index];
      else for(int i=0;i<TILE;i++)if(vector_mem_req.mask[i]&&vector_mem_req.index+i<ROWS)
        vm_legal&=!v_written_q[v_write_slot(vector_mem_req.buffer_id)][vector_mem_req.index+i];
    end
    if(function_mem_req.write)for(int i=0;i<TILE;i++)if(function_mem_req.mask[i]&&function_mem_req.index+i<ROWS)
      fm_legal&=!f_written_q[function_mem_req.buffer_id==WORK_ALPHA?0:1][function_mem_req.index+i];
  end
  assign vector_mem_ready=vm_ready&&vm_legal&&!fault_q&&!flush_q;
  assign function_mem_ready=fm_ready&&fm_legal&&!fault_q&&!flush_q;
  dea8_pcore_workspace workspace(.clk,.reset,.clear(clear||ejv),
    .v_valid(vector_mem_valid&&vm_legal&&!fault_q&&!flush_q),.v_ready(vm_ready),.v_req(vector_mem_req),
    .v_out_valid(vector_mem_out_valid),.v_out_ready(vector_mem_out_ready),.v_out(vector_mem_out),
    .f_valid(function_mem_valid&&fm_legal&&!fault_q&&!flush_q),.f_ready(fm_ready),.f_req(function_mem_req),
    .f_out_valid(function_mem_out_valid),.f_out_ready(function_mem_out_ready),.f_out(function_mem_out));
  assign source_enable=active_q&&!fault_q&&!flush_q;
  assign xbc_ready=source_enable&&raw_xbc_ready;
  assign hbm_ready=source_enable&&raw_hbm_ready;
  assign kv_ready=source_enable&&raw_kv_ready;
  assign ext_qoz_region_ready=raw_ext_region_ready&&!active_q&&!fault_q&&!flush_q;
  assign ext_qoz_wr_ready=raw_ext_write_ready&&!active_q&&!fault_q&&!flush_q;
  dea8_pcore_exec #(.PAIRED_Q_POST(1),.COMPLETE_O_OUTPUT(1)) exec(.clk,.reset,.clear,.external_error(fault_q||se),
    .job_valid(ejv),.job_ready(ejr),.job(engine_job),.job_done_valid(edv),.job_done_ready(edr),.job_done(engine_done),
    .busy(eb),.protocol_error(ee),.active_adapter,
    .xbc_valid(xbc_valid&&source_enable),.xbc_ready(raw_xbc_ready),.xbc_entry,
    .hbm_valid(hbm_valid&&source_enable),.hbm_ready(raw_hbm_ready),.hbm_entry,
    .kv_valid(kv_valid&&source_enable),.kv_ready(raw_kv_ready),.kv_entry,
    .post_valid,.post_ready,.post_job,.post_done_valid,.post_done_ready,.post_done,.post_data_valid(data_valid),.post_data_ready(data_ready),.post_data(data),
    .post_result_valid(result_valid),.post_result_ready(result_ready),.post_result(result),
    .vpu_valid(av),.vpu_ready(ar),.vpu_cmd(ac),.vpu_done_valid(adv),.vpu_done_ready(adr),.vpu_done(ad),
    .sfu_valid(af),.sfu_ready(afr),.sfu_cmd(as),.sfu_done_valid(afd),.sfu_done_ready(afdr),.sfu_done(asd),
    .p_valid(pv),.p_ready(pr),.p_entry(pe),.p_block(vheld_q.tile),.p_epoch(job_q.header.epoch),.p_head(job_q.header.head),
    .acc_rd_valid(raw_request),.acc_rd_ready(raw_ready),.acc_rd_sel,.acc_rd_addr(matrix_acc_addr),.acc_data_valid(raw_valid),.acc_even(raw_even),.acc_odd(raw_odd),
    .acc_wr_valid(acc_wr_valid&&!fault_q&&acc_write_legal),.acc_wr_ready(raw_write_ready),.acc_wr(matrix_acc_write),
    .z_rd_valid(1'b0),.z_rd_ready(),.z_rd_tile('0),.z_rd_pair('0),.z_out_valid(),.z_out_ready(1'b0),.z_entry(),
    .qoz_complete,.qoz_region,
    .ext_qoz_region_valid(ext_qoz_region_valid&&!active_q&&!fault_q&&!flush_q),.ext_qoz_region_ready(raw_ext_region_ready),.ext_qoz_region,
    .ext_qoz_wr_valid(ext_qoz_wr_valid&&!active_q&&!fault_q&&!flush_q),.ext_qoz_wr_ready(raw_ext_write_ready),.ext_qoz_wr,
    .gu_prefetch_valid,.gu_prefetch_ready,.gu_prefetch_n);

  assign fault_event=se||ee||output_error||(vector_done_valid&&!vdmatch&&!flush_q)||
    (function_done_valid&&!fdmatch&&!flush_q)||(vector_result_valid&&!vrmatch&&!flush_q)||
    (function_result_valid&&!frmatch&&!flush_q)||(is_reduce&&data_valid&&rd_armed_q&&!rd_legal)||
    (acc_rd_valid&&!acc_read_legal&&!flush_q)||(acc_wr_valid&&!acc_write_legal&&!flush_q)||
    (vector_mem_valid&&!vm_legal&&!flush_q)||(function_mem_valid&&!fm_legal&&!flush_q)||
    ((ext_qoz_region_valid||ext_qoz_wr_valid)&&active_q&&!flush_q)||
    (rope_req_valid&&!rope_legal&&!flush_q)||(rope_sfu_out_valid&&!rope_response_match&&!flush_q);
  always_ff @(posedge clk)begin
    if(reset)begin
      job_q<='0;active_q<=0;complete_q<=0;fault_q<=0;status_q<=CONTROL_OK;
      generation_q<=0;clear_q<=0;flush_q<=0;flush_acks_q<=0;region_context_q<=0;
      vseq_q<=0;fseq_q<=0;vb_q<=0;fb_q<=0;vheld_q<='0;fheld_q<='0;vcount_q<=0;fcount_q<=0;
      kv_sent_q<=0;reduce_sent_q<=0;afin_tile_q<=0;afin_pair_q<=0;
      rd_armed_q<=0;rd_done_q<=0;rd_pair_q<=0;rd_tile_q<=0;rd_command_q<='0;
      read_pending_count_q<=0;response_count_q<=0;response_rd_q<=0;response_wr_q<=0;
      acc_written_q<=0;
      rope_count_q<=0;rope_rd_q<=0;rope_wr_q<=0;
      for(int i=0;i<4;i++)v_written_q[i]<=0;
      for(int i=0;i<2;i++)f_written_q[i]<=0;
    end else if(clear)begin
      if(!clear_q)generation_q<=generation_q+1'b1;
      clear_q<=1;flush_q<=1;flush_acks_q<=0;active_q<=0;complete_q<=0;fault_q<=0;
      vb_q<=0;fb_q<=0;rd_armed_q<=0;rd_done_q<=0;
      read_pending_count_q<=0;response_count_q<=0;response_rd_q<=0;response_wr_q<=0;region_context_q<=0;
      acc_written_q<=0;
      rope_count_q<=0;rope_rd_q<=0;rope_wr_q<=0;
      for(int i=0;i<4;i++)v_written_q[i]<=0;
      for(int i=0;i<2;i++)f_written_q[i]<=0;
    end else begin
      clear_q<=0;
      if(rope_req_fire)begin rope_requests[rope_wr_q]<=rope_req;rope_wr_q<=rope_wr_q+1'b1;end
      if(rope_rsp_fire)rope_rd_q<=rope_rd_q+1'b1;
      case({rope_req_fire,rope_rsp_fire})
        2'b10:rope_count_q<=rope_count_q+1'b1;
        2'b01:rope_count_q<=rope_count_q-1'b1;
        default:;
      endcase
      if(flush_q)begin
        flush_acks_q<=flush_acks_q|{sfu_flush_ack,vpu_flush_ack};
        if(&(flush_acks_q|{sfu_flush_ack,vpu_flush_ack}))flush_q<=0;
      end
      if(job_valid&&job_ready)begin
        job_q<=job;generation_q<=generation_q+1'b1;vseq_q<=0;fseq_q<=0;kv_sent_q<=0;reduce_sent_q<=0;status_q<=CONTROL_OK;
        if(!core_match||!job_legal||!precondition)begin
          complete_q<=1;
          status_q<=!core_match?CONTROL_CONTEXT_ERROR:(!job_legal?CONTROL_UNSUPPORTED:CONTROL_PRECONDITION);
        end
        else begin active_q<=1;if(job.header.op==OP_Q_PROJ||job.header.op==OP_GU)region_context_q<=job.data_context;end
      end
      if(ext_qoz_region_valid&&ext_qoz_region_ready)region_context_q<=ext_qoz_context;
      if(vector_valid&&vector_ready)begin
        vb_q<=1;vheld_q<=vector_cmd;vseq_q<=vseq_q+1'b1;vcount_q<=0;afin_tile_q<=0;afin_pair_q<=0;acc_written_q<=0;
        for(int i=0;i<4;i++)v_written_q[i]<=0;
      end
      if(function_valid&&function_ready)begin
        fb_q<=1;fheld_q<=function_cmd;fseq_q<=fseq_q+1'b1;fcount_q<=0;
        for(int i=0;i<2;i++)f_written_q[i]<=0;
      end
      if(acc_wr_valid&&acc_wr_ready)acc_written_q<=acc_written_q+1'b1;
      if(vector_mem_valid&&vector_mem_ready&&vector_mem_req.write)begin
        if(vector_mem_req.buffer_id==WORK_SCORE)v_written_q[0][vector_mem_req.index]<=1;
        else for(int i=0;i<TILE;i++)if(vector_mem_req.mask[i]&&vector_mem_req.index+i<ROWS)
          v_written_q[v_write_slot(vector_mem_req.buffer_id)][vector_mem_req.index+i]<=1;
      end
      if(function_mem_valid&&function_mem_ready&&function_mem_req.write)
        for(int i=0;i<TILE;i++)if(function_mem_req.mask[i]&&function_mem_req.index+i<ROWS)
          f_written_q[function_mem_req.buffer_id==WORK_ALPHA?0:1][function_mem_req.index+i]<=1;
      if(vector_done_valid&&vector_done_ready)vb_q<=0;
      if(function_done_valid&&function_done_ready)fb_q<=0;
      if(function_result_valid&&function_result_ready)fcount_q<=fcount_q+1'b1;
      if(vector_result_valid&&vector_result_ready)begin
        vcount_q<=vcount_q+1'b1;
        if(vheld_q.function_id==VECTOR_AFIN_QUANT)begin
          if(afin_pair_q==PAIRS-1)begin afin_pair_q<=0;afin_tile_q<=afin_tile_q+1'b1;end
          else afin_pair_q<=afin_pair_q+1'b1;
        end
      end
      if(kv_out_valid&&kv_out_ready)kv_sent_q<=kv_sent_q+1'b1;
      if(reduce_out_valid&&reduce_out_ready)reduce_sent_q<=reduce_sent_q+1'b1;
      if(is_reduce&&post_valid&&post_ready)begin rd_command_q<=post_job;rd_armed_q<=1;rd_pair_q<=0;end
      if(rin&&rr)begin
        if(data.last)begin rd_done_q<=1;rd_armed_q<=0;rd_tile_q<=rd_tile_q+1'b1;end
        else rd_pair_q<=rd_pair_q+1'b1;
      end
      if(is_reduce&&post_done_valid&&post_done_ready)rd_done_q<=0;
      if(ejv)rd_tile_q<=0;
      case({read_fire,raw_valid})
        2'b10:read_pending_count_q<=read_pending_count_q+1'b1;
        2'b01:read_pending_count_q<=read_pending_count_q-1'b1;
        default:;
      endcase
      case({raw_valid,response_fire})
        2'b10:response_count_q<=response_count_q+1'b1;
        2'b01:response_count_q<=response_count_q-1'b1;
        default:;
      endcase
      if(raw_valid)begin response_mem[response_wr_q]<={raw_odd,raw_even};response_wr_q<=response_wr_q+1'b1;end
      if(response_fire)response_rd_q<=response_rd_q+1'b1;
      if(edv&&edr)begin
        active_q<=0;complete_q<=1;
        if((is_reduce&&reduce_sent_q!=output_tiles(job_q.header.op)*ROWS)||
           (job_q.header.op==OP_K_PROJ&&kv_sent_q!=2*ROWS)||
           (job_q.header.op==OP_V_PROJ&&kv_sent_q!=2*V_TOKEN_BLOCKS*TILE))begin fault_q<=1;status_q<=CONTROL_EARLY_DONE;end
      end
      if(done_valid&&done_ready)complete_q<=0;
      if(fault_event&&!fault_q&&!flush_q)begin
        fault_q<=1;
        // An already offered completion is immutable until accepted. A late
        // return still faults the core, but cannot rewrite that held packet.
        if(!complete_q)begin complete_q<=1;status_q<=CONTROL_UNIT_ERROR;end
      end
    end
  end
endmodule
