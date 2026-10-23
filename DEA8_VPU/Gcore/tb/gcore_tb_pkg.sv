package gcore_tb_pkg;
  function automatic logic [135:0] kv_word(input bit value_kind,prefix,input int feature_tile,index);
    logic [135:0] w;
    w='0;
    w[135:128]=8'(80+(feature_tile*7+index*11+int'(prefix)*19+int'(value_kind)*29)%100);
    for(int i=0;i<16;i++)
      if(!(value_kind&&!prefix&&index>=48&&i>=3))
        w[8*i+:8]=8'(feature_tile*13+index*17+i*23+int'(value_kind)*53+int'(prefix)*97);
    return w;
  endfunction
  // Independent linear wire-order oracle, not the RTL's job/parity counters.
  function automatic logic [$bits(pcore_pkg::b2_t)-1:0] kvb_expected(input int beat,input logic [3:0] epoch);
    pcore_pkg::b2_t b;
    logic [135:0] w;
    int j,t,g,block_number,index;
    bit is_value,is_prefix;
    j=beat/128; t=(beat%128)/8; g=beat%8;
    is_value=j>0&&j%2==0||j==109;
    block_number=j==109?54:(is_value?(j/2-1):((j+1)/2));
    is_prefix=block_number<51;
    b='0; b.tile_idx=6'(beat/8); b.group_idx=3'(g); b.epoch=epoch;
    for(int p=0;p<2;p++) begin
      index=(block_number-(is_prefix?0:51))*16+2*g+p;
      w=kv_word(is_value,is_prefix,t,index);
      if(!is_value&&!is_prefix&&index>=51) w=0;
      b.col[p].data=w[127:0]; b.col[p].scale=w[135:128];
    end
    return b;
  endfunction
  function automatic logic [135:0] activation_word(input int tile,row,salt=0);
    logic [135:0] w;
    w='0;
    for(int i=0;i<16;i++) w[8*i+:8]=8'(tile*23+row*11+i*7+salt*13);
    w[135:128]=8'((tile*3+row*5+salt*17)%180+40);
    return w;
  endfunction
  function automatic logic [255:0] residual_word(input int index,salt=0);
    logic [255:0] w;
    logic [15:0] b;
    for(int i=0;i<16;i++) begin
      b=16'h3000+16'((index*7+i*13+salt*31)%4096);
      b[15]=1'((index+i)%2);
      w[16*i+:16]=b;
    end
    return w;
  endfunction
endpackage
