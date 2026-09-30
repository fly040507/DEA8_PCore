set_input_delay -clock core_clk -max 0.0 [get_ports -filter {DIRECTION == IN && NAME != clk}]
