`timescale 1ns/1ps
module tb_gcore_pcore_link;
  import pcore_pkg::*;
  import pcore_control_pkg::*;
  import dea8_tile_link_pkg::*;
  logic clk=0;always #2 clk=~clk;
  logic reset=1,clear=0;
  control_job_t job;
  logic quant_valid=0,quant_ready,facc_valid=0,facc_ready;
  control_quant_result_t quant;
  post_data_t facc;
  logic tx_valid,tx_ready,tx_last;
  logic [255:0] tx_data;
  logic kv_commit_valid=0,kv_commit_ready;
  tile_commit_t kv_commit;
  logic kv_word_sent,fp_row_sent,kv_empty,reduce_empty,output_busy,output_error;
  dea8_pcore_output source(.clk,.reset,.clear,.job,.quant_valid,.quant_ready,.quant,.facc_valid,.facc_ready,.facc,
    .tx_valid,.tx_ready,.tx_data,.tx_last,.kv_commit_valid,.kv_commit_ready,.kv_commit,
    .kv_word_sent,.fp_row_sent,.kv_empty,.reduce_empty,.busy(output_busy),.protocol_error(output_error));
  logic [7:0] in_valid,in_ready,in_last,kv_header_valid,kv_header_ready='1;
  logic [7:0][255:0] in_data;
  logic [7:0] kv_valid,kv_ready,kv_last,kv_retire,fp_header_valid,fp_header_ready='1,fp_valid,fp_ready;
  logic [7:0][135:0] kv_data;
  logic [7:0][255:0] fp_data;
  tile_header_t kv_header[8],fp_header[8],active_header;
  logic fp_retire,rx_busy,rx_error;
  dea8_gcore_packet_rx sink(.clk,.reset,.clear,.*,.busy(rx_busy),.protocol_error(rx_error));
  int cycle=0,headers=0,words=0,tiles=0,beats=0,total_beats=0,stalls=0,commits=0,rows_sent=0;
  bit held=0;
  logic [255:0] held_data;
  logic held_last;
  function automatic logic [135:0] kv_gold(input bit value_kind,input int tile,word_index);
    logic [135:0] value;
    value=0;value[135:128]=8'(60+tile*3+word_index);
    for(int i=0;i<16;i++)if(!value_kind||word_index<48||i<3)
      value[8*i+:8]=8'(tile*13+word_index*17+i*23);
    return value;
  endfunction
  function automatic logic [31:0] fp_gold(input int tile,row,col);
    return 32'h3f000000+32'(tile*4096+row*32+col);
  endfunction
  always_comb begin
    in_valid=0;in_data=0;in_last=0;in_valid[0]=tx_valid;in_data[0]=tx_data;in_last[0]=tx_last;tx_ready=in_ready[0];
    kv_ready=0;fp_ready=0;kv_ready[0]=cycle%11>3;fp_ready[0]=cycle%13>5;
    kv_retire=0;kv_retire[0]=kv_commit_valid&&kv_commit_ready;
  end
  always @(negedge clk)cycle++;
  always @(posedge clk)begin
    if(reset||clear)begin
      held=0;headers=0;words=0;tiles=0;beats=0;kv_commit_valid<=0;fp_retire<=0;
    end else begin
      if(output_error||rx_error)$fatal(1,"real link endpoint error");
      if(held&&(!tx_valid||tx_data!==held_data||tx_last!==held_last))$fatal(1,"TX changed under backpressure");
      held=tx_valid&&!tx_ready;held_data=tx_data;held_last=tx_last;
      if(held)stalls++;
      if(tx_valid&&tx_ready)total_beats++;
      if(fp_row_sent)rows_sent++;
      if(kv_commit_valid&&kv_commit_ready)begin kv_commit_valid<=0;commits++;end
      fp_retire<=0;
      if((kv_header_valid[0]&&kv_header_ready[0])||(fp_header_valid[0]&&fp_header_ready[0]))begin
        tile_header_t h;h=kv_header_valid[0]?kv_header[0]:fp_header[0];
        if(h.source_id!=0||h.tile_seq!=tiles||h.transfer_id!=job.transfer.transfer_id||h.rows!=51||h.columns!=16||
          h.column_base!=(job.header.op==OP_K_PROJ?tiles*128:tiles*16))$fatal(1,"link header identity/coordinate");
        active_header=h;headers++;
      end
      if(kv_valid[0]&&kv_ready[0])begin
        if(kv_data[0]!==kv_gold(job.header.op==OP_V_PROJ,tiles,beats))$fatal(1,"KV link payload");
        words++;beats++;
        if(kv_last[0])begin
          if(beats!=(job.header.op==OP_K_PROJ?51:64))$fatal(1,"KV packet length");
          kv_commit<='0;kv_commit.transfer_id<=active_header.transfer_id;kv_commit.transfer_epoch<=active_header.transfer_epoch;
          kv_commit.tile_seq<=active_header.tile_seq;kv_commit.source_id<=0;kv_commit_valid<=1;tiles++;beats=0;
        end
      end
      if(fp_valid[0]&&fp_ready[0])begin
        for(int i=0;i<8;i++)if(fp_data[0][32*i+:32]!==fp_gold(tiles,beats/2,8*(beats%2)+i))
          $fatal(1,"FP32 link split/order tile=%0d beat=%0d lane=%0d",tiles,beats,i);
        words++;beats++;
        if(beats==102)begin fp_retire<=1;tiles++;beats=0;end
      end
    end
  end
  task automatic start(input pcore_op_e op);
    @(negedge clk);clear=1;job='0;job.header.op=op;job.header.job_id=16'(op);
    job.transfer.transfer_id=16'(op+30);job.transfer.transfer_epoch=3;
    @(negedge clk);clear=0;
  endtask
  task automatic send_kv(input bit value_kind);
    for(int tile=0;tile<2;tile++)for(int p=0;p<(value_kind?32:26);p++)begin
      @(negedge clk);quant='0;quant.tile=6'(tile);quant.index=6'(p);
      quant.vector_valid=value_kind?2'b11:row_mask(p);quant.last=p==(value_kind?31:25);
      quant.quant_axis=value_kind?QUANT_TOKEN_B16:QUANT_FEATURE_B16;
      quant.token_mask=value_kind&&p>=24?16'h0007:16'hffff;
      for(int r=0;r<2;r++)begin
        logic [135:0] w;w=kv_gold(value_kind,tile,p*2+r);
        quant.vector_data[r].data=w[127:0];quant.vector_data[r].scale=w[135:128];
      end
      quant_valid=1;do @(posedge clk);while(!quant_ready);@(negedge clk);quant_valid=0;
    end
    wait(!output_busy&&!rx_busy);@(negedge clk);
    if(headers!=2||tiles!=2||words!=(value_kind?128:102))$fatal(1,"KV totals");
  endtask
  task automatic send_fp;
    for(int tile=0;tile<64;tile++)for(int p=0;p<26;p++)begin
      @(negedge clk);facc='0;facc.header=job.header;facc.n=6'(tile);facc.row=6'(p);
      facc.row_valid=row_mask(p);facc.last=p==25;
      for(int i=0;i<16;i++)begin facc.first[i]=fp_gold(tile,2*p,i);facc.second[i]=fp_gold(tile,2*p+1,i);end
      facc_valid=1;do @(posedge clk);while(!facc_ready);@(negedge clk);facc_valid=0;
    end
    wait(!output_busy&&!rx_busy);@(negedge clk);
    if(headers!=64||tiles!=64||words!=64*102)$fatal(1,"FP32 totals");
  endtask
  initial begin
    job='0;quant='0;facc='0;kv_commit='0;repeat(5)@(negedge clk);reset=0;
    start(OP_K_PROJ);send_kv(0);start(OP_V_PROJ);send_kv(1);
    start(OP_O_PROJ);send_fp();start(OP_DOWN_PROJ);send_fp();
    if(commits!=4||rows_sent!=2*64*51||stalls==0||total_beats!=13418)$fatal(1,"link coverage beats=%0d",total_beats);
    $display("tb_gcore_pcore_link PASS real_pcore_output=1 real_gcore_rx=1 K_tiles=2 V_tiles=2 O_tiles=64 Down_tiles=64 payload_beats=13286 headers=132 total_beats=%0d fp_rows=%0d stalls=%0d",total_beats,rows_sent,stalls);$finish;
  end
  initial begin #400000;$fatal(1,"PCore-GCore link watchdog");end
endmodule
