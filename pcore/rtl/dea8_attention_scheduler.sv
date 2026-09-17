import dea8_pcore_pkg::*;
import dea8_job_pkg::*;

// One head/epoch in flight. Command accept and completion are separate events.
// Matrix done MUST mean final L4 commit. VPU done means final output write;
// SFU done means final result accepted, not last EXP input issued.
// This controller is independent of the legacy ready-only attention_ctrl.
module dea8_attention_scheduler #(
  parameter int TAIL_SCALE_SLOT_CYCLES = MATRIX_STEADY_BUDGET
) (
  input logic clk, rst_n,
  input logic start_valid,
  output logic start_ready, busy,
  input logic [HEAD_BITS-1:0] start_head,
  input logic [EPOCH_BITS-1:0] start_epoch,
  output logic done_valid,
  input logic done_ready,
  output logic matrix_valid,
  input logic matrix_ready,
  output matrix_job_t matrix_cmd,
  input logic matrix_done_valid,
  output logic matrix_done_ready,
  input matrix_job_t matrix_done,
  output logic vpu_valid,
  input logic vpu_ready,
  output vpu_job_t vpu_cmd,
  input logic vpu_done_valid,
  output logic vpu_done_ready,
  input vpu_job_t vpu_done,
  output logic sfu_valid,
  input logic sfu_ready,
  output sfu_job_t sfu_cmd,
  input logic sfu_done_valid,
  output logic sfu_done_ready,
  input sfu_job_t sfu_done
);
  typedef enum logic [3:0] {
    IDLE, FIRST_QK, NEXT_QK, RUN_PV, TAIL_SCALE, TAIL_PV, RECIP, FINALIZE, COMPLETE
  } phase_e;
  typedef enum logic [2:0] {POST_NONE, POST_QK, POST_ALPHA, POST_P, POST_DONE} post_e;
  phase_e phase;
  post_e post;
  logic [BLOCK_BITS-1:0] b_q;
  logic [HEAD_BITS-1:0] head_q;
  logic [EPOCH_BITS-1:0] epoch_q;
  logic matrix_sent, matrix_finished, vpu_sent, vpu_finished, sfu_sent, sfu_finished;
  matrix_job_t matrix_inflight;
  vpu_job_t vpu_inflight;
  sfu_job_t sfu_inflight;
  logic advance;
  logic matrix_complete, matrix_handoff;
  phase_e launch_phase;
  logic [BLOCK_BITS-1:0] launch_block;
  logic [BLOCK_BITS-1:0] post_block;
  localparam int TAIL_COUNT_BITS = $clog2(TAIL_SCALE_SLOT_CYCLES+1);
  logic [TAIL_COUNT_BITS-1:0] tail_remaining_q;

  assign start_ready = rst_n && phase == IDLE;
  assign busy = phase != IDLE;
  assign done_valid = rst_n && phase == COMPLETE;
  assign matrix_done_ready = rst_n && matrix_sent && !matrix_finished;
  assign vpu_done_ready = rst_n && vpu_sent && !vpu_finished;
  assign sfu_done_ready = rst_n && sfu_sent && !sfu_finished;
  assign post_block = phase == NEXT_QK ? BLOCK_BITS'(0) : b_q + 1'b1;
  assign matrix_complete = matrix_finished || (matrix_done_valid && matrix_done_ready);

  always_comb begin
    advance = 0;
    case (phase)
      FIRST_QK, TAIL_PV: advance = matrix_complete;
      NEXT_QK: advance = matrix_complete && (b_q == 0 ? post == POST_DONE : vpu_finished);
      RUN_PV: advance = matrix_complete && post == POST_DONE;
      // At remaining==1 this acceptance edge closes the full reserved slot.
      TAIL_SCALE: advance = vpu_finished && tail_remaining_q<=1;
      FINALIZE: advance = vpu_finished;
      RECIP: advance = sfu_finished;
      default: ;
    endcase
    launch_phase=phase;launch_block=b_q;matrix_handoff=0;
    // Completion and acceptance may share an edge, but computation cannot:
    // the matrix engine has already drained all old DEQACC commits.
    if(advance) begin
      case(phase)
        FIRST_QK: begin launch_phase=NEXT_QK;matrix_handoff=1;end
        NEXT_QK: begin launch_phase=RUN_PV;matrix_handoff=1;end
        RUN_PV: if(b_q!=N_KV_BLOCK-2) begin
          launch_phase=NEXT_QK;launch_block=b_q+1'b1;matrix_handoff=1;
        end
        TAIL_SCALE: begin launch_phase=TAIL_PV;matrix_handoff=1;end
        default: ;
      endcase
    end
    matrix_cmd = '0; vpu_cmd = '0; sfu_cmd = '0;
    matrix_cmd.ctx = '{block_id:launch_block, head:head_q, epoch:epoch_q};
    matrix_cmd.op = (launch_phase == RUN_PV || launch_phase == TAIL_PV) ? MATRIX_PV : MATRIX_QK;
    if (launch_phase == NEXT_QK) matrix_cmd.ctx.block_id = launch_block + 1'b1;
    matrix_cmd.facc_bank = matrix_cmd.ctx.block_id[0];
    matrix_cmd.pbuf_bank = matrix_cmd.ctx.block_id[0];
    matrix_cmd.init_oacc = matrix_cmd.op == MATRIX_PV && launch_block == 0;
    vpu_cmd.ctx = '{block_id:b_q, head:head_q, epoch:epoch_q};
    sfu_cmd.ctx = vpu_cmd.ctx;
    vpu_cmd.op = VPU_OACC_SCALE;
    sfu_cmd.op = SFU_RECIP;
    if (post == POST_QK || post == POST_ALPHA || post == POST_P) begin
      vpu_cmd.ctx.block_id = post_block;
      sfu_cmd.ctx.block_id = post_block;
      vpu_cmd.op = post == POST_P ? VPU_P_POST : VPU_QK_POST;
      sfu_cmd.op = post == POST_P ? SFU_P_EXP : SFU_ALPHA_EXP;
    end
    if (phase == FINALIZE) vpu_cmd.op = VPU_AFIN;
    vpu_cmd.facc_bank = vpu_cmd.ctx.block_id[0];
    vpu_cmd.sbuf_bank = vpu_cmd.ctx.block_id[0];
    vpu_cmd.pbuf_bank = vpu_cmd.ctx.block_id[0];
    vpu_cmd.alpha_bank = vpu_cmd.ctx.block_id[0];
    sfu_cmd.sbuf_bank = sfu_cmd.ctx.block_id[0];
    sfu_cmd.alpha_bank = sfu_cmd.ctx.block_id[0];
    matrix_valid = rst_n && (matrix_handoff || (!matrix_sent &&
                   (phase == FIRST_QK || phase == NEXT_QK || phase == RUN_PV || phase == TAIL_PV)));
    vpu_valid = rst_n && !vpu_sent &&
                (post == POST_QK || post == POST_P ||
                 (phase == NEXT_QK && b_q != 0) || phase == TAIL_SCALE || phase == FINALIZE);
    // Arm the P consumer before starting the SFU producer to avoid a startup
    // deadlock or an unbuffered result being dropped by a not-yet-started VPU.
    sfu_valid = rst_n && !sfu_sent &&
                (post == POST_ALPHA || (post == POST_P && vpu_sent) || phase == RECIP);
  end

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      phase <= IDLE; post <= POST_NONE; b_q <= '0; head_q <= '0; epoch_q <= '0;
      tail_remaining_q <= '0;
      matrix_sent <= 0; matrix_finished <= 0;
      vpu_sent <= 0; vpu_finished <= 0; sfu_sent <= 0; sfu_finished <= 0;
      matrix_inflight <= '0; vpu_inflight <= '0; sfu_inflight <= '0;
    end else begin
      // There is no QK55 to hide alpha54 * OACC. Reserve a full matrix slot,
      // measured from PV53 completion, AND wait for the actual VPU commit.
      if(tail_remaining_q!=0) tail_remaining_q<=tail_remaining_q-1'b1;
      if(matrix_done_valid && matrix_done_ready && matrix_done.op==MATRIX_PV &&
         matrix_done.ctx.block_id==N_KV_BLOCK-2)
        tail_remaining_q<=TAIL_COUNT_BITS'(TAIL_SCALE_SLOT_CYCLES);
      if (matrix_valid && matrix_ready) begin matrix_sent <= 1; matrix_inflight <= matrix_cmd; end
      if (vpu_valid && vpu_ready) begin vpu_sent <= 1; vpu_inflight <= vpu_cmd; end
      if (sfu_valid && sfu_ready) begin sfu_sent <= 1; sfu_inflight <= sfu_cmd; end
      if (matrix_done_valid && matrix_done_ready) matrix_finished <= 1;
      if (vpu_done_valid && vpu_done_ready) vpu_finished <= 1;
      if (sfu_done_valid && sfu_done_ready) sfu_finished <= 1;
      case (post)
        POST_QK: if (vpu_finished) begin
          post <= POST_ALPHA; vpu_sent <= 0; vpu_finished <= 0;
        end
        POST_ALPHA: if (sfu_finished) begin
          post <= POST_P; sfu_sent <= 0; sfu_finished <= 0;
        end
        POST_P: if (vpu_finished && sfu_finished) begin
          post <= POST_DONE;
          vpu_sent <= 0; vpu_finished <= 0; sfu_sent <= 0; sfu_finished <= 0;
        end
        default: ;
      endcase
      if (start_valid && start_ready) begin
        phase <= FIRST_QK; b_q <= '0; head_q <= start_head; epoch_q <= start_epoch;
      end
      if (advance) begin
        matrix_sent <= matrix_handoff && matrix_valid && matrix_ready;
        matrix_finished <= 0;
        vpu_sent <= 0; vpu_finished <= 0; sfu_sent <= 0; sfu_finished <= 0;
        case (phase)
          FIRST_QK: begin phase <= NEXT_QK; post <= POST_QK; end
          NEXT_QK: begin phase <= RUN_PV; post <= POST_QK; end
          RUN_PV: begin
            b_q <= b_q + 1'b1; post <= POST_NONE;
            phase <= b_q == N_KV_BLOCK-2 ? TAIL_SCALE : NEXT_QK;
          end
          TAIL_SCALE: phase <= TAIL_PV;
          TAIL_PV: phase <= RECIP;
          RECIP: phase <= FINALIZE;
          FINALIZE: phase <= COMPLETE;
          default: ;
        endcase
      end
      if (done_valid && done_ready) begin phase <= IDLE; post <= POST_NONE; end
    end
  end
  // synthesis translate_off
  always @(posedge clk) if (rst_n) begin
    if (matrix_done_valid && matrix_done_ready && matrix_done !== matrix_inflight)
      $fatal(1, "Matrix completion context mismatch");
    if (vpu_done_valid && vpu_done_ready && vpu_done !== vpu_inflight)
      $fatal(1, "VPU completion context mismatch");
    if (sfu_done_valid && sfu_done_ready && sfu_done !== sfu_inflight)
      $fatal(1, "SFU completion context mismatch");
  end
  initial begin
    if (N_KV_BLOCK < 2) $fatal(1, "Scheduler requires at least two KV blocks");
    if (TAIL_SCALE_SLOT_CYCLES < 1) $fatal(1,"Tail scale slot must be positive");
  end
  // synthesis translate_on
endmodule
