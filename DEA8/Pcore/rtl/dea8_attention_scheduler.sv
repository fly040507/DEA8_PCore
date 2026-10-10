import pcore_pkg::*;

// One head/epoch in flight.  Matrix completion means the final DEQACC write,
// not the last MXU issue.  The non-matrix commands are explicit handshakes:
// their implementations and latency belong to VPU/SFU.
module dea8_attention_scheduler #(
  parameter int BLOCKS=KV_BLOCKS,
  parameter int TAIL_SCALE_SLOT_CYCLES=MATRIX_STEADY_BUDGET
) (
  input logic clk,reset,clear,
  input logic start_valid, output logic start_ready,busy,
  input logic [2:0] start_head,
  input logic [EPOCH_BITS-1:0] start_epoch,
  output logic done_valid, input logic done_ready,
  output logic matrix_valid, input logic matrix_ready,
  output matrix_cmd_t matrix_cmd,
  input logic matrix_done_valid, output logic matrix_done_ready,
  input matrix_cmd_t matrix_done,
  output logic vpu_valid, input logic vpu_ready,
  output vpu_cmd_t vpu_cmd,
  input logic vpu_done_valid, output logic vpu_done_ready,
  input vpu_cmd_t vpu_done,
  output logic sfu_valid, input logic sfu_ready,
  output sfu_cmd_t sfu_cmd,
  input logic sfu_done_valid, output logic sfu_done_ready,
  input sfu_cmd_t sfu_done
);
  typedef enum logic [3:0] {
    IDLE,FIRST_QK,NEXT_QK,RUN_PV,TAIL_SCALE,TAIL_PV,RECIP,FINALIZE,COMPLETE
  } phase_e;
  typedef enum logic [2:0] {POST_NONE,POST_QK,POST_ALPHA,POST_P,POST_DONE} post_e;
  localparam int TAIL_BITS=$clog2(TAIL_SCALE_SLOT_CYCLES+1);
  phase_e phase_q;
  post_e post_q;
  logic [5:0] b_q;
  logic [2:0] head_q;
  logic [EPOCH_BITS-1:0] epoch_q;
  logic matrix_sent_q,matrix_finished_q,vpu_sent_q,vpu_finished_q,sfu_sent_q,sfu_finished_q;
  matrix_cmd_t matrix_inflight_q;
  vpu_cmd_t vpu_inflight_q;
  sfu_cmd_t sfu_inflight_q;
  logic [TAIL_BITS-1:0] tail_remaining_q;
  logic advance,matrix_complete,matrix_handoff;
  phase_e launch_phase;
  logic [5:0] launch_block;
  logic [5:0] post_block;

  assign start_ready=!reset&&!clear&&(phase_q==IDLE);
  assign busy=phase_q!=IDLE;
  assign done_valid=!reset&&!clear&&(phase_q==COMPLETE);
  assign matrix_done_ready=!reset&&!clear&&matrix_sent_q&&!matrix_finished_q;
  assign vpu_done_ready=!reset&&!clear&&vpu_sent_q&&!vpu_finished_q;
  assign sfu_done_ready=!reset&&!clear&&sfu_sent_q&&!sfu_finished_q;
  assign matrix_complete=matrix_finished_q||(matrix_done_valid&&matrix_done_ready);
  assign post_block=(phase_q==NEXT_QK)?6'd0:b_q+1'b1;

  always_comb begin
    advance=0;
    case(phase_q)
      FIRST_QK,TAIL_PV: advance=matrix_complete;
      NEXT_QK: advance=matrix_complete && ((b_q==0)?(post_q==POST_DONE):vpu_finished_q);
      RUN_PV: advance=matrix_complete && post_q==POST_DONE;
      TAIL_SCALE: advance=vpu_finished_q && tail_remaining_q<=1;
      RECIP: advance=sfu_finished_q;
      FINALIZE: advance=vpu_finished_q;
      default: ;
    endcase

    launch_phase=phase_q;
    launch_block=b_q;
    matrix_handoff=1'b0;
    if(advance) begin
      case(phase_q)
        FIRST_QK: begin launch_phase=NEXT_QK;matrix_handoff=1'b1;end
        NEXT_QK: begin launch_phase=RUN_PV;matrix_handoff=1'b1;end
        RUN_PV: if(b_q!=BLOCKS-2) begin
          launch_phase=NEXT_QK;launch_block=b_q+1'b1;matrix_handoff=1'b1;
        end
        TAIL_SCALE: begin launch_phase=TAIL_PV;matrix_handoff=1'b1;end
        default: ;
      endcase
    end

    matrix_cmd='0;
    matrix_cmd.mode=MAT_ATTENTION;
    matrix_cmd.op=(launch_phase==RUN_PV||launch_phase==TAIL_PV)?MATRIX_PV:MATRIX_QK;
    matrix_cmd.block_id=(launch_phase==NEXT_QK)?launch_block+1'b1:launch_block;
    matrix_cmd.epoch=epoch_q;matrix_cmd.head=head_q;
    matrix_cmd.m_rows=ROWS;
    // QK advances Q and K together.  PV reuses P tile 0 while the V-side
    // output-tile window starts at a separate ID range.
    // These are logical source IDs, not FIFO transport counters.  Q is the
    // same QOZ source for every QK block; each KV block owns a K/V window.
    matrix_cmd.a_id=(matrix_cmd.op==MATRIX_PV)?LOGICAL_ID_BITS'(launch_block):LOGICAL_ID_BITS'(0);
    // NEXT_QK launches block b_q+1 while b_q is still the completed PV
    // block.  Its B logical window must advance together with block_id;
    // RUN_PV uses the current completed block's V window.
    matrix_cmd.b_id=LOGICAL_ID_BITS'(((launch_phase==NEXT_QK)?matrix_cmd.block_id:launch_block)*ATTN_K_TILES);
    matrix_cmd.out_tile=(matrix_cmd.op==MATRIX_PV)?LOGICAL_ID_BITS'(launch_block):0;
    matrix_cmd.acc_sel=matrix_cmd.op==MATRIX_QK?
      (matrix_cmd.block_id[0]?ACC_FACC_B:ACC_FACC_A):ACC_OACC;
    matrix_cmd.add_old=matrix_cmd.op==MATRIX_PV && matrix_cmd.block_id!=0;
    matrix_cmd.result_last=1;
    matrix_cmd.job_last=launch_phase==TAIL_PV;
    matrix_cmd.exp_fold=matrix_cmd.op==MATRIX_QK?-4:0;
    matrix_valid=!reset&&!clear&&(matrix_handoff||!matrix_sent_q) &&
      (phase_q==FIRST_QK||phase_q==NEXT_QK||phase_q==RUN_PV||phase_q==TAIL_PV);

    vpu_cmd='0;sfu_cmd='0;
    vpu_cmd.block_id=b_q;sfu_cmd.block_id=b_q;
    vpu_cmd.epoch=epoch_q;sfu_cmd.epoch=epoch_q;
    vpu_cmd.head=head_q;sfu_cmd.head=head_q;
    vpu_cmd.op=VPU_OACC_SCALE;sfu_cmd.op=SFU_RECIP;
    if(post_q==POST_QK||post_q==POST_ALPHA||post_q==POST_P) begin
      vpu_cmd.block_id=post_block;sfu_cmd.block_id=post_block;
      vpu_cmd.op=post_q==POST_P?VPU_P_POST:VPU_QK_POST;
      sfu_cmd.op=post_q==POST_P?SFU_P_EXP:SFU_ALPHA_EXP;
    end
    if(phase_q==FINALIZE) vpu_cmd.op=VPU_AFIN;
    vpu_cmd.facc_bank=vpu_cmd.block_id[0];
    vpu_cmd.sbuf_bank=vpu_cmd.block_id[0];
    vpu_cmd.pbuf_bank=vpu_cmd.block_id[0];
    vpu_cmd.alpha_bank=vpu_cmd.block_id[0];
    sfu_cmd.sbuf_bank=sfu_cmd.block_id[0];
    sfu_cmd.alpha_bank=sfu_cmd.block_id[0];
    vpu_valid=!reset&&!clear&&!vpu_sent_q &&
      (post_q==POST_QK||post_q==POST_P||
       (phase_q==NEXT_QK&&b_q!=0)||phase_q==TAIL_SCALE||phase_q==FINALIZE);
    // P's VPU consumer is armed before SFU starts producing EXP results.
    sfu_valid=!reset&&!clear&&!sfu_sent_q &&
      (post_q==POST_ALPHA||(post_q==POST_P&&vpu_sent_q)||phase_q==RECIP);
  end

  always_ff @(posedge clk) begin
    if(reset||clear) begin
      phase_q<=IDLE;post_q<=POST_NONE;b_q<=0;
      head_q<=0;epoch_q<=0;tail_remaining_q<=0;
      matrix_sent_q<=0;matrix_finished_q<=0;
      vpu_sent_q<=0;vpu_finished_q<=0;sfu_sent_q<=0;sfu_finished_q<=0;
      matrix_inflight_q<='0;vpu_inflight_q<='0;sfu_inflight_q<='0;
    end else begin
      if(tail_remaining_q!=0) tail_remaining_q<=tail_remaining_q-1'b1;
      if(matrix_valid&&matrix_ready) begin
        matrix_sent_q<=1;matrix_inflight_q<=matrix_cmd;
      end
      if(vpu_valid&&vpu_ready) begin vpu_sent_q<=1;vpu_inflight_q<=vpu_cmd;end
      if(sfu_valid&&sfu_ready) begin sfu_sent_q<=1;sfu_inflight_q<=sfu_cmd;end
      if(matrix_done_valid&&matrix_done_ready) begin
        matrix_finished_q<=1;
      end
      if(vpu_done_valid&&vpu_done_ready) vpu_finished_q<=1;
      if(sfu_done_valid&&sfu_done_ready) sfu_finished_q<=1;
      case(post_q)
        POST_QK: if(vpu_finished_q) begin
          post_q<=POST_ALPHA;vpu_sent_q<=0;vpu_finished_q<=0;
        end
        POST_ALPHA: if(sfu_finished_q) begin
          post_q<=POST_P;sfu_sent_q<=0;sfu_finished_q<=0;
        end
        POST_P: if(vpu_finished_q&&sfu_finished_q) begin
          post_q<=POST_DONE;
          vpu_sent_q<=0;vpu_finished_q<=0;sfu_sent_q<=0;sfu_finished_q<=0;
        end
        default: ;
      endcase
      if(start_valid&&start_ready) begin
        phase_q<=FIRST_QK;b_q<=0;
        head_q<=start_head;epoch_q<=start_epoch;
      end
      if(advance) begin
        matrix_sent_q<=matrix_handoff&&matrix_valid&&matrix_ready;
        matrix_finished_q<=0;
        vpu_sent_q<=0;vpu_finished_q<=0;sfu_sent_q<=0;sfu_finished_q<=0;
        case(phase_q)
          FIRST_QK: begin phase_q<=NEXT_QK;post_q<=POST_QK;end
          NEXT_QK: begin phase_q<=RUN_PV;post_q<=POST_QK;end
          RUN_PV: begin
            b_q<=b_q+1'b1;post_q<=POST_NONE;
            if(b_q==BLOCKS-2) begin
              phase_q<=TAIL_SCALE;
              tail_remaining_q<=TAIL_BITS'(TAIL_SCALE_SLOT_CYCLES-1);
            end else phase_q<=NEXT_QK;
          end
          TAIL_SCALE: phase_q<=TAIL_PV;
          TAIL_PV: phase_q<=RECIP;
          RECIP: phase_q<=FINALIZE;
          FINALIZE: phase_q<=COMPLETE;
          default: ;
        endcase
      end
      if(done_valid&&done_ready) begin phase_q<=IDLE;post_q<=POST_NONE;end
    end
  end

  // synthesis translate_off
  always @(posedge clk) if(!reset&&!clear) begin
    if(matrix_done_valid&&matrix_done_ready&&matrix_done!==matrix_inflight_q)
      $fatal(1,"Attention Matrix completion context mismatch");
    if(vpu_done_valid&&vpu_done_ready&&vpu_done!==vpu_inflight_q)
      $fatal(1,"Attention VPU completion context mismatch");
    if(sfu_done_valid&&sfu_done_ready&&sfu_done!==sfu_inflight_q)
      $fatal(1,"Attention SFU completion context mismatch");
  end
  initial begin
    if(BLOCKS<2) $fatal(1,"Attention scheduler needs at least two blocks");
    if(TAIL_SCALE_SLOT_CYCLES<2) $fatal(1,"Tail scale slot too short");
  end
  // synthesis translate_on
endmodule
