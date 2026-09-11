import dea8_pcore_pkg::*;

// FlashAttention block scheduler.
//
// Startup:
//   QK(0)
//   QK(1) || EXP(0)
//   PV(0) || EXP(1)
// Steady state:
//   QK(b+1) || OACC_SCALE(b)
//   PV(b)   || EXP(b+1)
// Tail:
//   OACC_SCALE(54)
//   PV(54)
//   A_FIN
//
// Paired commands use atomic ready/valid handshakes. Neither destination may
// consume its command until the other destination is ready in the same cycle.
module dea8_attention_ctrl (
  input  logic      clk,
  input  logic      rst_n,
  input  logic      start,

  output logic      busy,
  output logic      done,

  output logic      qk_valid,
  input  logic      qk_ready,
  output attn_cmd_t qk_cmd,

  output logic      exp_valid,
  input  logic      exp_ready,
  output attn_cmd_t exp_cmd,

  output logic      pv_valid,
  input  logic      pv_ready,
  output attn_cmd_t pv_cmd,

  output logic      scale_valid,
  input  logic      scale_ready,
  output attn_cmd_t scale_cmd,

  output logic      afin_valid,
  input  logic      afin_ready
);

  typedef enum logic [3:0] {
    ST_IDLE,
    ST_BOOT_QK,
    ST_BOOT_EXP,
    ST_BOOT_PV,
    ST_STEADY_QK,
    ST_STEADY_PV,
    ST_TAIL_SCALE,
    ST_TAIL_PV,
    ST_A_FIN
  } state_e;

  state_e state_q;
  logic [BLOCK_BITS-1:0] block_q;
  logic issue_fire;

  always_comb begin
    busy = (state_q != ST_IDLE);

    qk_valid    = 1'b0;
    exp_valid   = 1'b0;
    pv_valid    = 1'b0;
    scale_valid = 1'b0;
    afin_valid  = 1'b0;
    issue_fire  = 1'b0;

    qk_cmd    = '{job:ATTN_QK, blk:block_q, pingpong:block_q[0],
                  last:(block_q == N_KV_BLOCK - 1)};
    exp_cmd   = '{job:ATTN_EXP, blk:block_q, pingpong:block_q[0],
                  last:(block_q == N_KV_BLOCK - 1)};
    pv_cmd    = '{job:ATTN_PV, blk:block_q, pingpong:block_q[0],
                  last:(block_q == N_KV_BLOCK - 1)};
    scale_cmd = '{job:ATTN_OACC_SCALE, blk:block_q, pingpong:block_q[0],
                  last:(block_q == N_KV_BLOCK - 1)};

    unique case (state_q)
      ST_BOOT_QK: begin
        qk_valid   = 1'b1;
        issue_fire = qk_ready;
      end

      ST_BOOT_EXP: begin
        qk_cmd.blk      = 1;
        qk_cmd.pingpong = 1'b1;
        qk_cmd.last     = 1'b0;
        exp_cmd.blk      = 0;
        exp_cmd.pingpong = 1'b0;
        exp_cmd.last     = 1'b0;
        qk_valid    = exp_ready;
        exp_valid   = qk_ready;
        issue_fire  = qk_ready && exp_ready;
      end

      ST_BOOT_PV: begin
        pv_cmd.blk      = 0;
        pv_cmd.pingpong = 1'b0;
        pv_cmd.last     = 1'b0;
        exp_cmd.blk      = 1;
        exp_cmd.pingpong = 1'b1;
        exp_cmd.last     = 1'b0;
        pv_valid    = exp_ready;
        exp_valid   = pv_ready;
        issue_fire  = pv_ready && exp_ready;
      end

      ST_STEADY_QK: begin
        qk_cmd.blk      = block_q + 1'b1;
        qk_cmd.pingpong = ~block_q[0];
        qk_cmd.last     = (block_q == N_KV_BLOCK - 2);
        qk_valid    = scale_ready;
        scale_valid = qk_ready;
        issue_fire  = qk_ready && scale_ready;
      end

      ST_STEADY_PV: begin
        exp_cmd.blk      = block_q + 1'b1;
        exp_cmd.pingpong = ~block_q[0];
        exp_cmd.last     = (block_q == N_KV_BLOCK - 2);
        pv_valid    = exp_ready;
        exp_valid   = pv_ready;
        issue_fire  = pv_ready && exp_ready;
      end

      ST_TAIL_SCALE: begin
        scale_valid = 1'b1;
        issue_fire  = scale_ready;
      end

      ST_TAIL_PV: begin
        pv_valid   = 1'b1;
        issue_fire = pv_ready;
      end

      ST_A_FIN: begin
        afin_valid = 1'b1;
        issue_fire = afin_ready;
      end

      default: begin
      end
    endcase
  end

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      state_q <= ST_IDLE;
      block_q <= '0;
    end else begin
      unique case (state_q)
        ST_IDLE: begin
          if (start) begin
            state_q <= ST_BOOT_QK;
            block_q <= '0;
          end
        end

        ST_BOOT_QK: begin
          if (issue_fire) state_q <= ST_BOOT_EXP;
        end

        ST_BOOT_EXP: begin
          if (issue_fire) state_q <= ST_BOOT_PV;
        end

        ST_BOOT_PV: begin
          if (issue_fire) begin
            state_q <= ST_STEADY_QK;
            block_q <= 1;
          end
        end

        ST_STEADY_QK: begin
          if (issue_fire) state_q <= ST_STEADY_PV;
        end

        ST_STEADY_PV: begin
          if (issue_fire) begin
            if (block_q == N_KV_BLOCK - 2) begin
              state_q <= ST_TAIL_SCALE;
              block_q <= N_KV_BLOCK - 1;
            end else begin
              state_q <= ST_STEADY_QK;
              block_q <= block_q + 1'b1;
            end
          end
        end

        ST_TAIL_SCALE: begin
          if (issue_fire) state_q <= ST_TAIL_PV;
        end

        ST_TAIL_PV: begin
          if (issue_fire) state_q <= ST_A_FIN;
        end

        ST_A_FIN: begin
          if (issue_fire) state_q <= ST_IDLE;
        end

        default: begin
          state_q <= ST_IDLE;
          block_q <= '0;
        end
      endcase
    end
  end

  assign done = (state_q == ST_A_FIN) && issue_fire;

endmodule
