import dea8_pcore_pkg::*;

// One PE in the MXU. Weights are stationary in two banks; activation is
// supplied by the broadcast network and is not retained in the PE.
module dea8_pe #(
  parameter int unsigned PE_INDEX = 0
) (
  input  logic      clk,
  input  logic      rst_n,
  input  logic      ce,
  input  logic      active_bank,
  input  logic      load_we,
  input  logic      load_bank,
  input  weight_t   load_weight,
  input  act_t      activation,
  output product_t  product
);
  weight_t weight_bank [0:BANK_COUNT-1];
  weight_t selected_weight;

  assign selected_weight = weight_bank[active_bank];

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      for (int bank = 0; bank < BANK_COUNT; bank = bank + 1) begin
        weight_bank[bank] <= '0;
      end
      product       <= '0;
    end else begin
      if (load_we) begin
        weight_bank[load_bank] <= load_weight;
      end
      if (ce) begin
        product <= activation * selected_weight;
      end
    end
  end
endmodule
