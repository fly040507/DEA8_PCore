import dea8_pcore_pkg::*;

// Fixed-format HBM tile unpacker.
//
// HBM beat 0..7: two 128-bit weight words per beat.
// HBM beat 8:    one 128-bit E_stat word in the low half of the beat.
// There is no tile-sized staging RAM in this block; ready/valid backpressure
// directly controls whether the current HBM beat is accepted.
module dea8_hbm_tile_unpack #(
  parameter int unsigned HBM_BITS_I   = HBM_BITS,
  parameter int unsigned DATA_BITS_I  = WEIGHT_WORD_BITS,
  parameter int unsigned SCALE_BITS_I = SCALE_WORD_BITS
) (
  input  logic                                        clk,
  input  logic                                        rst_n,
  input  logic                                        hbm_valid,
  output logic                                        hbm_ready,
  input  logic [HBM_BITS_I-1:0]                       hbm_data,
  output logic [1:0]                                  data_wr_valid,
  input  logic [1:0]                                  data_wr_ready,
  output logic [1:0][DATA_BITS_I-1:0]                 data_wr_data,
  output logic                                        scale_wr_valid,
  input  logic                                        scale_wr_ready,
  output logic [SCALE_BITS_I-1:0]                     scale_wr_data,
  output logic                                        tile_complete
);
  localparam int unsigned PAYLOAD_BEATS =
      (TILE * TILE * WEIGHT_BITS + HBM_BITS_I - 1) / HBM_BITS_I;
  localparam int unsigned SCALE_BEATS =
      (SCALE_BITS_I + HBM_BITS_I - 1) / HBM_BITS_I;
  localparam int unsigned TOTAL_BEATS = PAYLOAD_BEATS + SCALE_BEATS;
  localparam int unsigned SCALE_BEAT  = PAYLOAD_BEATS;
  localparam int unsigned BEAT_COUNT_BITS =
      (TOTAL_BEATS <= 1) ? 1 : $clog2(TOTAL_BEATS);

  logic [BEAT_COUNT_BITS-1:0] beat_count_q;
  logic hbm_fire;

  assign data_wr_valid[0] = hbm_valid && (beat_count_q < SCALE_BEAT);
  assign data_wr_valid[1] = data_wr_valid[0];
  assign data_wr_data[0]  = hbm_data[0 +: DATA_BITS_I];
  assign data_wr_data[1]  = hbm_data[DATA_BITS_I +: DATA_BITS_I];
  assign scale_wr_valid   = hbm_valid && (beat_count_q == SCALE_BEAT);
  assign scale_wr_data    = hbm_data[0 +: SCALE_BITS_I];

  assign hbm_ready = (beat_count_q < SCALE_BEAT)
                   ? (data_wr_ready[0] && data_wr_ready[1])
                   : scale_wr_ready;
  assign hbm_fire  = hbm_valid && hbm_ready;
  assign tile_complete = hbm_fire && (beat_count_q == SCALE_BEAT);

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      beat_count_q <= '0;
    end else if (hbm_fire) begin
      if (beat_count_q == TOTAL_BEATS - 1) begin
        beat_count_q <= '0;
      end else begin
        beat_count_q <= beat_count_q + 1'b1;
      end
    end
  end

  ap_unpack_payload: assert property (@(posedge clk) disable iff (!rst_n)
    data_wr_valid[0] |-> (beat_count_q < PAYLOAD_BEATS));
  ap_unpack_scale_last: assert property (@(posedge clk) disable iff (!rst_n)
    tile_complete |-> scale_wr_valid);
endmodule
