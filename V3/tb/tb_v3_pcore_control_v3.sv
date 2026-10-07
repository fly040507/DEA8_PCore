`timescale 1ns/1ps
import pcore3_pkg::*;
import pcore_control_pkg::*;
import fp32_legacy_ref_pkg::*;

module tb_v3_pcore_control_v3;
  logic clk=0;always #2 clk=~clk;
  logic reset=1,clear=0,job_valid=0,job_ready,done_valid,done_ready=0,busy,protocol_error;
  control_job_t job;control_completion_t done;
  logic [1:0] active_adapter;
  logic flush_valid,vpu_flush_ack=1,sfu_flush_ack=1;
  logic xbc_valid=0,xbc_ready,hbm_valid=0,hbm_ready,kv_valid=0,kv_ready;
  xbc4_t xbc_entry;b2_t hbm_entry,kv_entry;
  logic vector_valid,vector_ready=1,vector_done_valid=0,vector_done_ready;
  control_command_t vector_cmd;control_unit_done_t vector_done;
  logic function_valid,function_ready=1,function_done_valid=0,function_done_ready;
  control_command_t function_cmd;control_unit_done_t function_done;
  logic vector_data_valid,vector_data_ready=0,function_data_valid,function_data_ready=0;
  control_fp_data_t vector_data,function_data,function_result;
  logic function_result_valid=0,function_result_ready;
  logic vector_result_valid=0,vector_result_ready;control_quant_result_t vector_result;
  logic vector_mem_valid=0,vector_mem_ready,vector_mem_out_valid,vector_mem_out_ready=0;
  control_memory_req_t vector_mem_req;control_memory_rsp_t vector_mem_out;
  logic function_mem_valid=0,function_mem_ready,function_mem_out_valid,function_mem_out_ready=0;
  control_memory_req_t function_mem_req;control_memory_rsp_t function_mem_out;
  logic rope_req_valid=0,rope_req_ready,rope_sfu_valid,rope_sfu_ready=1;
  control_rope_req_t rope_req,rope_sfu_req;
  logic rope_sfu_out_valid=0,rope_sfu_out_ready,rope_out_valid,rope_out_ready=0;
  control_rope_rsp_t rope_sfu_out,rope_out;
  logic kv_out_valid,kv_out_ready=1,reduce_out_valid,reduce_out_ready=1;
  collective_packet_t kv_out,reduce_out;
  logic acc_rd_valid=0,acc_rd_ready,acc_data_valid,acc_data_ready=0;
  acc_sel_e acc_rd_sel;logic [9:0] acc_rd_addr;
  control_token_t acc_token;
  logic [15:0][31:0] acc_even,acc_odd;
  logic acc_wr_valid=0,acc_wr_ready;acc_write_t acc_wr;
  logic qoz_complete;qoz_region_req_t qoz_region;
  logic ext_qoz_region_valid=0,ext_qoz_region_ready,ext_qoz_wr_valid=0,ext_qoz_wr_ready;
  qoz_region_req_t ext_qoz_region;post_result_t ext_qoz_wr;logic [15:0] ext_qoz_context=16'h1234;
  logic gu_prefetch_valid,gu_prefetch_ready=1;logic [5:0] gu_prefetch_n;
  int cycle=0,job_start,issues[7],sent[7],commands[7],outputs[7],completed=0;
  int matrix_jobs=0,allowed_n=0;
  // Keep reference storage independent of the interface struct layout.
  logic [$bits(qvec16_t)-1:0] qgold[16][51],ogold[16][51],zgold[32][51];
  logic [$bits(qvec16_t)-1:0] kgold[2][51],vgold[2][32],pgold[55][51];
  logic [15:0][31:0] score[55][51],alpha[55][51];
  logic [31:0] m[51],lsum[51],recip[51];
  logic [31:0] reduced_gold[7][51],attention_gold[51];
  logic [15:0][31:0] scratch0[51],scratch1[51];
  bit kv_stall=0,reduce_stall=0;collective_packet_t kv_hold,reduce_hold;
  bit vector_stall=0,function_stall=0;control_command_t vector_hold,function_hold;
  dea8_pcore_control_v3 dut(.*);

  function automatic logic [31:0] bits(input real x);shortreal s;s=x;return $shortrealtobits(s);endfunction
  function automatic real real32(input logic [31:0] x);return real'($bitstoshortreal(x));endfunction
  function automatic logic [31:0] mul32(input logic [31:0] a,b);return bits(real32(a)*real32(b));endfunction
  function automatic int aint(input int row);return row%3-1;endfunction
  function automatic qvec16_t qv(input int x);qvec16_t v;v.scale=128;for(int i=0;i<TILE;i++)v.data[i*8+:8]=8'(x);return v;endfunction
  function automatic qvec16_t quant(input logic [15:0][31:0] x);
    real mx,step,v,f;int e,b,q;qvec16_t out;
    mx=0;for(int i=0;i<TILE;i++)begin v=real32(x[i]);if(v<0)v=-v;if(v>mx)mx=v;end
    step=2.0**(-133);e=0;
    while(e<254&&mx>127.0*step)begin step*=2.0;e++;end
    out='0;out.scale=8'(e);
    for(int i=0;i<TILE;i++)begin
      v=real32(x[i])/step;b=int'($floor(v));f=v-real'(b);
      q=b+int'(f>0.5||(f==0.5&&(b%2)!=0));if(q>127)q=127;if(q< -128)q=-128;
      out.data[i*8+:8]=8'(q);
    end
    return out;
  endfunction
  function automatic int feature(input pcore_op_e op,input int n);
    return op==OP_Q_PROJ?n/2+(n%2)*8:n;
  endfunction
  function automatic int bint(input pcore_op_e op,input int n,col,input bit up);
    if(op==OP_GU)return up?2:1;
    if(op==OP_Q_PROJ||op==OP_K_PROJ||op==OP_V_PROJ)return 1+(feature(op,n)*TILE+col)%3;
    return 1;
  endfunction
  function automatic logic [31:0] dot_part(input qvec16_t a,input int b,e,fold);
    int dot,lead;logic [31:0] mag,norm;
    dot=0;for(int i=0;i<TILE;i++)dot+=int'($signed(a.data[8*i+:8]))*b;
    mag=dot<0?-dot:dot;lead=0;for(int i=0;i<32;i++)if(mag[i])lead=i;
    norm=mag<<(31-lead);
    return fp32_legacy_ref_pkg::pack_scaled32(dot<0,norm,lead+int'(a.scale)+e-266+fold,dot==0,0);
  endfunction
  function automatic logic [31:0] projection_golden(input pcore_op_e op,input int row,n,col);
    if(op==OP_O_PROJ||op==OP_DOWN_PROJ)return reduced_gold[op][row];
    return bits(real'(aint(row)*bint(op,n,col,0)));
  endfunction
  function automatic logic [31:0] local_projection_golden(input pcore_op_e op,input int row);
    logic [31:0] v;int count;qvec16_t a;
    count=op==OP_O_PROJ?16:(op==OP_DOWN_PROJ?32:64);v=0;
    for(int k=0;k<count;k++)begin
      a=op==OP_O_PROJ?ogold[k][row]:(op==OP_DOWN_PROJ?zgold[k][row]:qv(aint(row)));
      v=fp32_legacy_ref_pkg::fp32_add(v,dot_part(a,1,128,0));
    end
    return v;
  endfunction
  task automatic send_b(input int transport,group,n,input bit is_kvb,input int block,input bit pv);
    b2_t b;b='0;b.tile_idx=TILE_BITS'(transport);b.group_idx=3'(group);b.epoch=job.header.epoch;
    for(int c=0;c<2;c++)begin
      b.col[c]=qv(0);
      for(int i=0;i<TILE;i++)b.col[c].data[i*8+:8]=8'(is_kvb?(pv?1:1+block%3):bint(job.header.op,n,2*group+c,transport[0]));
    end
    @(negedge clk);
    if(is_kvb)begin kv_entry=b;kv_valid=1;do @(posedge clk);while(!kv_ready);@(negedge clk);kv_valid=0;end
    else begin hbm_entry=b;hbm_valid=1;do @(posedge clk);while(!hbm_ready);@(negedge clk);hbm_valid=0;end
  endtask
  task automatic feed_projection(input int nt,kt,input bit local_a);
    fork
      begin
        if(!local_a)for(int n=0;n<nt;n++)for(int k=0;k<kt;k++)for(int g=0;g<XBC_GROUPS;g++)begin
          @(negedge clk);xbc_entry='0;xbc_entry.tile_idx=TILE_BITS'(k);xbc_entry.group_idx=4'(g);
          xbc_entry.row_valid=g==XBC_GROUPS-1?4'b0111:4'b1111;
          for(int r=0;r<4;r++)xbc_entry.row[r]=qv(aint(4*g+r));
          xbc_valid=1;do @(posedge clk);while(!xbc_ready);@(negedge clk);xbc_valid=0;
        end
      end
      begin for(int n=0;n<nt;n++)for(int k=0;k<kt;k++)for(int g=0;g<TILE/2;g++)send_b(local_a?(n*kt+k)%64:k,g,n,0,0,0);end
    join
  endtask
  task automatic feed_gu;
    fork
      begin
        for(int n=0;n<32;n++)begin
          if(n>0)wait(allowed_n>=n);
          for(int k=0;k<64;k++)for(int g=0;g<XBC_GROUPS;g++)begin
            @(negedge clk);xbc_entry='0;xbc_entry.tile_idx=TILE_BITS'(k);xbc_entry.group_idx=4'(g);
            xbc_entry.row_valid=g==XBC_GROUPS-1?4'b0111:4'b1111;
            for(int r=0;r<4;r++)xbc_entry.row[r]=qv(aint(4*g+r));
            xbc_valid=1;do @(posedge clk);while(!xbc_ready);@(negedge clk);xbc_valid=0;
          end
        end
      end
      begin for(int n=0;n<32;n++)for(int t=0;t<128;t++)for(int g=0;g<8;g++)send_b(t%64,g,n,0,0,0);end
    join
  endtask
  task automatic feed_attention;
    int b;bit pv_job;
    for(int j=0;j<110;j++)begin
      if(j==0)begin b=0;pv_job=0;end
      else if(j==109)begin b=54;pv_job=1;end
      else begin pv_job=!j[0];b=j[0]?(j+1)/2:j/2-1;end
      for(int t=0;t<16;t++)for(int g=0;g<8;g++)send_b((j*16+t)%64,g,0,1,b,pv_job);
    end
  endtask
  task automatic result_pair(input control_command_t c,input int tile,p,input qvec16_t a,b,input bit token_axis,input logic [15:0] mask);
    @(negedge clk);vector_result='0;vector_result.token=c.token;vector_result.tile=6'(tile);vector_result.index=10'(p);
    vector_result.quant_axis=token_axis?QUANT_TOKEN_B16:QUANT_FEATURE_B16;
    vector_result.vector_valid=token_axis?2'b11:row_mask(p);vector_result.token_mask=mask;
    vector_result.vector_data[0]=a;vector_result.vector_data[1]=b;
    vector_result.last=p==(token_axis?31:PAIRS-1);vector_result_valid=1;
    do @(posedge clk);while(!vector_result_ready);@(negedge clk);vector_result_valid=0;
  endtask
  task automatic read_acc(input acc_sel_e sel,input int addr,output logic [15:0][31:0] a,b);
    @(negedge clk);acc_rd_sel=sel;acc_rd_addr=10'(addr);acc_rd_valid=1;
    do @(posedge clk);while(!acc_rd_ready);@(negedge clk);acc_rd_valid=0;
    acc_data_ready=1;do @(posedge clk);while(!acc_data_valid);a=acc_even;b=acc_odd;
    @(negedge clk);acc_data_ready=0;
  endtask
  task automatic write_acc(input int addr,input logic [15:0][31:0] a,b);
    @(negedge clk);acc_wr='0;acc_wr.sel=ACC_OACC;acc_wr.addr=10'(addr);acc_wr.row_valid=row_mask(addr%PAIRS);
    acc_wr.data[0]=a;acc_wr.data[1]=b;acc_wr_valid=1;
    do @(posedge clk);while(!acc_wr_ready);@(negedge clk);acc_wr_valid=0;
  endtask
  task automatic memory_access(input control_command_t c,input bit sf,input control_buffer_e buffer_id,
    input int index,input bit bank,write,input logic [15:0][31:0] payload,output logic [15:0][31:0] value);
    control_memory_req_t req;
    req='0;req.token=c.token;req.buffer_id=buffer_id;req.index=6'(index);req.bank=bank;req.write=write;
    req.mask=buffer_id==WORK_SCORE?'1:16'b1;req.data=payload;
    @(negedge clk);
    if(sf)begin
      function_mem_req=req;function_mem_valid=1;do @(posedge clk);while(!function_mem_ready);
      @(negedge clk);function_mem_valid=0;
      if(!write)begin
        function_mem_out_ready=1;do @(posedge clk);while(!function_mem_out_valid);
        if(function_mem_out.token!=c.token)$fatal(1,"SFU memory response identity");value=function_mem_out.data;
        @(negedge clk);function_mem_out_ready=0;
      end
    end else begin
      vector_mem_req=req;vector_mem_valid=1;do @(posedge clk);while(!vector_mem_ready);
      @(negedge clk);vector_mem_valid=0;
      if(!write)begin
        vector_mem_out_ready=1;do @(posedge clk);while(!vector_mem_out_valid);
        if(vector_mem_out.token!=c.token)$fatal(1,"VPU memory response identity");value=vector_mem_out.data;
        @(negedge clk);vector_mem_out_ready=0;
      end
    end
  endtask
  initial begin: vector_model
    control_command_t c;control_fp_data_t d;
    logic [15:0][31:0] a,b,x,y,stat,dummy;logic [31:0] v,old_m,new_m;
    real angle,cs,sn,frq;int tile;
    wait(!reset);
    forever begin
      @(posedge clk);
      if(vector_valid&&vector_ready)begin
        c=vector_cmd;commands[c.job.header.op]++;@(negedge clk);acc_token=c.token;
        if(c.function_id==VECTOR_OACC_SCALE||c.function_id==VECTOR_AFIN_QUANT)begin
          if(c.elements!=ROWS*TILE*QOZ_O_TILES||c.tiles!=QOZ_O_TILES||c.source!=WORK_OACC)
            $fatal(1,"OACC command descriptor");
        end else if(c.elements!=ROWS*TILE*(c.function_id==VECTOR_ROPE_QUANT?2:1))
          $fatal(1,"vector command element count");
        if(c.function_id==VECTOR_QK_POST&&(c.source!=WORK_FACC||c.destination!=WORK_SCORE))$fatal(1,"QK descriptor");
        if((c.job.header.op==OP_K_PROJ||c.job.header.op==OP_V_PROJ)&&c.destination!=WORK_KV_OUT)$fatal(1,"KV descriptor");
        case(c.function_id)
          VECTOR_ROPE_QUANT:begin
            for(int r=0;r<ROWS;r++)begin
              vector_data_ready=1;do @(posedge clk);while(!vector_data_valid);d=vector_data;
              if(d.index!=r||d.token!=c.token||d.job!=c.job||!d.vector_valid[0])$fatal(1,"RoPE stream identity");
              @(negedge clk);vector_data_ready=0;
              rope_req='{token:c.token,row:6'(r),position:16'(c.job.position_base+r),frequency_base:c.rope_frequency_base};
              rope_req_valid=1;do @(posedge clk);while(!rope_req_ready);@(negedge clk);rope_req_valid=0;
              rope_out_ready=1;do @(posedge clk);while(!rope_out_valid);
              for(int i=0;i<TILE;i++)begin
                if(d.first[i]!==projection_golden(c.job.header.op,r,c.tile-1,i)||d.second[i]!==projection_golden(c.job.header.op,r,c.tile,i))$fatal(1,"RoPE matrix golden");
                cs=real32(rope_out.cosine[i]);sn=real32(rope_out.sine[i]);
                scratch0[r][i]=bits(real32(d.first[i])*cs-real32(d.second[i])*sn);
                scratch1[r][i]=bits(real32(d.second[i])*cs+real32(d.first[i])*sn);
              end
              @(negedge clk);rope_out_ready=0;
            end
            for(int h=0;h<2;h++)begin
              tile=c.job.header.op==OP_Q_PROJ?c.tile/2+h*8:h;
              for(int r=0;r<ROWS;r++)begin
                if(c.job.header.op==OP_Q_PROJ)qgold[tile][r]=quant(h?scratch1[r]:scratch0[r]);
                else kgold[tile][r]=quant(h?scratch1[r]:scratch0[r]);
              end
              for(int p=0;p<PAIRS;p++)begin
                if(c.job.header.op==OP_Q_PROJ)result_pair(c,tile,p,qgold[tile][2*p],p<25?qgold[tile][2*p+1]:'0,0,'1);
                else result_pair(c,tile,p,kgold[tile][2*p],p<25?kgold[tile][2*p+1]:'0,0,'1);
              end
            end
          end
          VECTOR_V_QUANT:begin
            for(int j=0;j<32;j++)begin
              vector_data_ready=1;do @(posedge clk);while(!vector_data_valid);d=vector_data;
              for(int i=0;i<TILE;i++)begin
                int row,col;row=(j/8)*16+i;col=(j%8)*2;
                if(row<ROWS&&(d.first[i]!==projection_golden(OP_V_PROJ,row,c.tile,col)||d.second[i]!==projection_golden(OP_V_PROJ,row,c.tile,col+1)))$fatal(1,"V token packing golden");
                if(row>=ROWS&&(d.first[i]!=0||d.second[i]!=0||d.token_mask[i]))$fatal(1,"V padding");
              end
              a=d.first;b=d.second;@(negedge clk);vector_data_ready=0;
              vgold[c.tile][j]=quant(a);result_pair(c,c.tile,j,quant(a),quant(b),1,j>=24?16'h7:16'hffff);
            end
          end
          VECTOR_GU_POST:begin
            for(int r=0;r<ROWS;r++)begin
              vector_data_ready=1;do @(posedge clk);while(!vector_data_valid);d=vector_data;
              if(d.index!=r||d.second[0]!==bits(2.0*aint(r)))$fatal(1,"GU Up pair");
              for(int i=0;i<TILE;i++)scratch0[r][i]=mul32(d.first[i],d.second[i]);
              zgold[c.tile][r]=quant(scratch0[r]);@(negedge clk);vector_data_ready=0;
            end
            for(int p=0;p<PAIRS;p++)result_pair(c,c.tile,p,zgold[c.tile][2*p],p<25?zgold[c.tile][2*p+1]:'0,0,'1);
          end
          VECTOR_QK_POST:begin
            for(int p=0;p<PAIRS;p++)begin
              read_acc(c.attention_vpu.facc_bank?ACC_FACC_B:ACC_FACC_A,p,a,b);
              for(int r=0;r<2;r++)if(2*p+r<ROWS)begin
                v=0;for(int k=0;k<16;k++)v=fp32_legacy_ref_pkg::fp32_add(v,dot_part(qgold[k][2*p+r],1+c.tile%3,128,-4));
                for(int i=0;i<TILE;i++)begin
                  if((r?b[i]:a[i])!==v)$fatal(1,"QK numerical golden block=%0d row=%0d",c.tile,2*p+r);
                  score[c.tile][2*p+r][i]=(2*p+r==0||(c.tile==54&&i==15))?32'hff800000:v;
                end
                memory_access(c,0,WORK_M,2*p+r,0,0,'0,stat);
                if(stat[0]!==m[2*p+r])$fatal(1,"m memory generation");
                old_m=stat[0];new_m=2*p+r==0?32'hff800000:(c.tile==0?v:(real32(v)>real32(old_m)?v:old_m));
                alpha[c.tile][2*p+r]='0;alpha[c.tile][2*p+r][0]=(c.tile==0||2*p+r==0)?32'h3f800000:bits($exp(real32(old_m)-real32(new_m)));
                m[2*p+r]=new_m;
                memory_access(c,0,WORK_SCORE,2*p+r,c.tile[0],1,score[c.tile][2*p+r],dummy);
                stat='0;stat[0]=(c.tile==0||2*p+r==0)?0:bits(real32(old_m)-real32(new_m));
                memory_access(c,0,WORK_AA,2*p+r,0,1,stat,dummy);
                stat[0]=new_m;memory_access(c,0,WORK_M,2*p+r,0,1,stat,dummy);
              end
            end
          end
          VECTOR_P_POST:begin
            for(int p=0;p<PAIRS;p++)begin
              vector_data_ready=1;do @(posedge clk);while(!vector_data_valid);d=vector_data;
              if(d.index!=p||d.tile!=c.tile||d.token!=c.token)$fatal(1,"P stream identity");
              @(negedge clk);vector_data_ready=0;
              for(int r=0;r<2;r++)if(2*p+r<ROWS)begin
                x=r?d.second:d.first;v=0;for(int i=0;i<TILE;i++)v=fp32_legacy_ref_pkg::fp32_add(v,x[i]);
                memory_access(c,0,WORK_L,2*p+r,0,0,'0,stat);
                if(stat[0]!==lsum[2*p+r])$fatal(1,"l memory generation");
                memory_access(c,0,WORK_ALPHA,2*p+r,c.tile[0],0,'0,y);
                if(y[0]!==alpha[c.tile][2*p+r][0])$fatal(1,"alpha memory generation");
                lsum[2*p+r]=fp32_legacy_ref_pkg::fp32_add(mul32(y[0],stat[0]),v);
                stat[0]=lsum[2*p+r];memory_access(c,0,WORK_L,2*p+r,0,1,stat,dummy);
                pgold[c.tile][2*p+r]=quant(x);
              end
              result_pair(c,c.tile,p,pgold[c.tile][2*p],p<25?pgold[c.tile][2*p+1]:'0,0,'1);
            end
          end
          VECTOR_OACC_SCALE:begin
            for(int r=0;r<ROWS;r++)begin
              v=0;
              for(int block=0;block<int'(c.tile);block++)begin
                if(block>0)v=mul32(v,alpha[block][r][0]);
                v=fp32_legacy_ref_pkg::fp32_add(v,dot_part(pgold[block][r],1,128,0));
              end
              attention_gold[r]=v;
            end
            for(int t=0;t<16;t++)for(int p=0;p<PAIRS;p++)begin
              read_acc(ACC_OACC,t*PAIRS+p,a,b);
              for(int i=0;i<TILE;i++)begin
                if(a[i]!==attention_gold[2*p]||(p<25&&b[i]!==attention_gold[2*p+1]))
                  $fatal(1,"PV before SCALE block=%0d tile=%0d pair=%0d lane=%0d even=%h expected=%h odd=%h expected_odd=%h",c.tile,t,p,i,a[i],attention_gold[2*p],b[i],attention_gold[2*p+1]);
              end
              memory_access(c,0,WORK_ALPHA,2*p,c.tile[0],0,'0,stat);
              for(int i=0;i<TILE;i++)begin a[i]=mul32(a[i],stat[0]);if(p<25)b[i]=mul32(b[i],stat[1]);end
              write_acc(t*PAIRS+p,a,b);
            end
          end
          VECTOR_AFIN_QUANT:begin
            for(int r=0;r<ROWS;r++)begin
              v=0;
              for(int block=0;block<KV_BLOCKS;block++)begin
                if(block>0)v=mul32(v,alpha[block][r][0]);
                v=fp32_legacy_ref_pkg::fp32_add(v,dot_part(pgold[block][r],1,128,0));
              end
              attention_gold[r]=v;
            end
            for(int t=0;t<16;t++)for(int p=0;p<PAIRS;p++)begin
              read_acc(ACC_OACC,t*PAIRS+p,a,b);
              memory_access(c,0,WORK_RECIP,2*p,0,0,'0,stat);
              for(int i=0;i<TILE;i++)begin
                if(a[i]!==attention_gold[2*p]||(p<25&&b[i]!==attention_gold[2*p+1]))$fatal(1,"PV OACC golden tile=%0d pair=%0d even=%h expected=%h odd=%h expected_odd=%h",t,p,a[i],attention_gold[2*p],b[i],attention_gold[2*p+1]);
                if(stat[0]!==recip[2*p]||(p<25&&stat[1]!==recip[2*p+1]))$fatal(1,"reciprocal memory");
                a[i]=mul32(a[i],stat[0]);if(p<25)b[i]=mul32(b[i],stat[1]);
              end
              ogold[t][2*p]=quant(a);if(p<25)ogold[t][2*p+1]=quant(b);
              result_pair(c,t,p,ogold[t][2*p],p<25?ogold[t][2*p+1]:'0,0,'1);
            end
          end
          default:$fatal(1,"unexpected vector function");
        endcase
        @(negedge clk);vector_done='{command:c,error:0};vector_done_valid=1;
        do @(posedge clk);while(!vector_done_ready);@(negedge clk);vector_done_valid=0;
      end
    end
  end
  initial begin: function_model
    control_command_t c;control_fp_data_t d;real x,t;
    logic [15:0][31:0] sc,stat,dummy;
    wait(!reset);
    forever begin
      @(posedge clk);
      if(function_valid&&function_ready)begin
        c=function_cmd;@(negedge clk);
        if(c.elements!=((c.function_id==FUNCTION_GELU||c.function_id==FUNCTION_P_EXP)?ROWS*TILE:ROWS))
          $fatal(1,"SFU command element count");
        if(c.function_id==FUNCTION_GELU)begin
          for(int r=0;r<ROWS;r++)begin
            function_data_ready=1;do @(posedge clk);while(!function_data_valid);d=function_data;
            if(d.index!=r||d.token!=c.token)$fatal(1,"GELU input token");
            function_result=d;
            for(int i=0;i<TILE;i++)begin
              if(d.first[i]!==bits(aint(r)))$fatal(1,"Gate golden");
              x=real32(d.first[i]);t=$sqrt(2.0/3.141592653589793)*(x+0.044715*x*x*x);
              function_result.first[i]=bits(0.5*x*(2.0/(1.0+$exp(-2.0*t))));
            end
            @(negedge clk);function_data_ready=0;function_result_valid=1;
            do @(posedge clk);while(!function_result_ready);@(negedge clk);function_result_valid=0;
          end
        end else if(c.function_id==FUNCTION_P_EXP)begin
          for(int p=0;p<PAIRS;p++)begin
            function_result='0;function_result.job=c.job;function_result.token=c.token;function_result.tile=c.tile;
            function_result.index=6'(p);function_result.last=p==PAIRS-1;function_result.vector_valid=row_mask(p);
            for(int lane=0;lane<2;lane++)if(2*p+lane<ROWS)begin
              memory_access(c,1,WORK_SCORE,2*p+lane,c.tile[0],0,'0,sc);
              memory_access(c,1,WORK_M,2*p+lane,0,0,'0,stat);
              for(int i=0;i<TILE;i++)begin
                if(sc[i]!==score[c.tile][2*p+lane][i])$fatal(1,"SBUF readback");
                if(lane==0)function_result.first[i]=(sc[i]==32'hff800000) ? 0 : bits($exp(real32(sc[i])-real32(stat[0])));
                else function_result.second[i]=(sc[i]==32'hff800000) ? 0 : bits($exp(real32(sc[i])-real32(stat[0])));
              end
            end
            @(negedge clk);function_result_valid=1;do @(posedge clk);while(!function_result_ready);
            @(negedge clk);function_result_valid=0;
          end
        end else if(c.function_id==FUNCTION_RECIP)begin
          for(int r=0;r<ROWS;r++)begin
            memory_access(c,1,WORK_L,r,0,0,'0,stat);
            recip[r]=stat[0]==0?0:bits(1.0/real32(stat[0]));stat[0]=recip[r];
            memory_access(c,1,WORK_RECIP,r,0,1,stat,dummy);
          end
        end else if(c.function_id==FUNCTION_ALPHA_EXP)begin
          for(int r=0;r<ROWS;r++)begin
            memory_access(c,1,WORK_AA,r,0,0,'0,stat);
            stat[0]=bits($exp(real32(stat[0])));
            if(stat[0]!==alpha[c.tile][r][0])$fatal(1,"alpha exp golden");
            memory_access(c,1,WORK_ALPHA,r,c.tile[0],1,stat,dummy);
          end
        end else $fatal(1,"unexpected SFU function");
        @(negedge clk);function_done='{command:c,error:0};function_done_valid=1;
        do @(posedge clk);while(!function_done_ready);@(negedge clk);function_done_valid=0;
      end
    end
  end
  initial begin: rope_coefficient_model
    control_rope_req_t req;real angle;
    wait(!reset);
    forever begin
      @(posedge clk);
      if(rope_sfu_valid&&rope_sfu_ready)begin
        req=rope_sfu_req;@(negedge clk);rope_sfu_out='0;rope_sfu_out.request=req;
        for(int i=0;i<TILE;i++)begin
          angle=req.position*(10000.0**(-2.0*(req.frequency_base+i)/256.0));
          rope_sfu_out.cosine[i]=bits($cos(angle));rope_sfu_out.sine[i]=bits($sin(angle));
        end
        rope_sfu_out_valid=1;do @(posedge clk);while(!rope_sfu_out_ready);
        @(negedge clk);rope_sfu_out_valid=0;
      end
    end
  end
  always @(posedge clk)if(!reset&&!clear)begin
    cycle++;
    if(cycle%10000==0)$display("CONTROL_PROGRESS cycle=%0d op=%0d issues=%0d post=%0d capture=%0d index=%0d vec=%0d sfu=%0d region=%0d",
      cycle,job.header.op,issues[job.header.op],dut.post_service.state_q,dut.post_service.capture_q,dut.post_service.index_q,
      dut.vheld_q.function_id,dut.fheld_q.function_id,qoz_region.owner);
    if(protocol_error)$fatal(1,"control fault status=%0d post=%b engine=%b op=%0d",dut.status_q,dut.se,dut.ee,job.header.op);
    if(dut.exec.dispatch.matrix.req_valid)issues[job.header.op]++;
    if(dut.exec.dispatch.req.start&&active_adapter==1)matrix_jobs++;
    if(gu_prefetch_valid&&gu_prefetch_ready)allowed_n=gu_prefetch_n;
    if(kv_stall&&(!kv_out_valid||kv_out!==kv_hold))$fatal(1,"KV changed while stalled");
    if(reduce_stall&&(!reduce_out_valid||reduce_out!==reduce_hold))$fatal(1,"reduce changed while stalled");
    kv_stall=kv_out_valid&&!kv_out_ready;reduce_stall=reduce_out_valid&&!reduce_out_ready;kv_hold=kv_out;reduce_hold=reduce_out;
    if(vector_stall&&(!vector_valid||vector_cmd!==vector_hold))$fatal(1,"vector command changed while stalled");
    if(function_stall&&(!function_valid||function_cmd!==function_hold))$fatal(1,"function command changed while stalled");
    vector_stall=vector_valid&&!vector_ready;function_stall=function_valid&&!function_ready;vector_hold=vector_cmd;function_hold=function_cmd;
    if(kv_out_valid&&kv_out_ready)begin
      qvec16_t expected;int tile,p,r;
      tile=kv_out.tile;p=kv_out.index;
      if(kv_out.job!=job||sent[job.header.op]!=(job.header.op==OP_K_PROJ?tile*PAIRS+p:tile*32+p))$fatal(1,"KV order/context");
      for(int lane=0;lane<2;lane++)if(kv_out.vector_valid[lane])begin
        if(job.header.op==OP_K_PROJ)expected=kgold[tile][2*p+lane];
        else begin
          logic [15:0][31:0] vals;
          for(int i=0;i<16;i++)vals[i]=(p/8*16+i<ROWS)?projection_golden(OP_V_PROJ,p/8*16+i,tile,p%8*2+lane):0;
          expected=quant(vals);
        end
        if(kv_out.scales[lane]!==expected.scale)$fatal(1,"KV scale");
        for(int i=0;i<TILE;i++)if(kv_out.payload[lane][i][7:0]!==expected.data[i*8+:8])$fatal(1,"KV data");
      end
      if(kv_out.last!=(tile==1&&kv_out.tile_last))$fatal(1,"KV last");
      sent[job.header.op]++;
    end
    if(reduce_out_valid&&reduce_out_ready)begin
      if(reduce_out.job!=job||sent[job.header.op]!=reduce_out.tile*PAIRS+reduce_out.index)$fatal(1,"reduce order/context");
      for(int r=0;r<2;r++)if(reduce_out.vector_valid[r])for(int i=0;i<TILE;i++)
        if(reduce_out.payload[r][i]!==projection_golden(job.header.op,2*reduce_out.index+r,reduce_out.tile,i))$fatal(1,"reduce numerical golden");
      sent[job.header.op]++;
    end
  end
  always @(negedge clk)if(!reset)begin
    kv_out_ready=cycle%7!=0;reduce_out_ready=cycle%5!=0;
    vector_ready=cycle%11!=0;function_ready=cycle%13!=0;
  end
  task automatic run_job(input pcore_op_e op,input int id,expected_issues);
    if(op==OP_O_PROJ||op==OP_DOWN_PROJ)
      for(int r=0;r<ROWS;r++)reduced_gold[op][r]=local_projection_golden(op,r);
    @(negedge clk);job='0;job.header='{job_id:16'(id),epoch:4'd3,head:3'd1,op:op};
    job.data_context=16'h1234;job.user_tag=64'ha5a5000000000000|id;job.position_base=7;job.core_id=2;job.rope_pair_base=32;
    job_valid=1;do @(posedge clk);while(!job_ready);job_start=cycle;@(negedge clk);job_valid=0;
    fork
      begin
        case(op)
          OP_K_PROJ,OP_V_PROJ:feed_projection(2,64,0);
          OP_Q_PROJ:feed_projection(16,64,0);
          OP_ATTENTION:feed_attention();
          OP_O_PROJ:feed_projection(64,16,1);
          OP_GU:feed_gu();
          OP_DOWN_PROJ:feed_projection(64,32,1);
        endcase
      end
      begin
        wait(done_valid);
        if(done.job!==job||done.status!=CONTROL_OK||issues[op]!=expected_issues)$fatal(1,"Job completion op=%0d issues=%0d expected=%0d",op,issues[op],expected_issues);
        $display("CONTROL_JOB op=%0d cycles=%0d issues=%0d sent=%0d commands=%0d",op,cycle-job_start,issues[op],sent[op],commands[op]);
        repeat(4)begin @(negedge clk);if(!done_valid||job_ready||done.job!==job)$fatal(1,"completion hold");end
        done_ready=1;@(negedge clk);done_ready=0;completed++;
      end
    join
  endtask
  task automatic prepare_q;
    logic [15:0][31:0] a,b;real angle,cs,sn,x,y;
    for(int group=0;group<8;group++)for(int r=0;r<ROWS;r++)begin
      for(int i=0;i<TILE;i++)begin
        x=aint(r)*bint(OP_Q_PROJ,2*group,i,0);y=aint(r)*bint(OP_Q_PROJ,2*group+1,i,0);
        angle=(7+r)*(10000.0**(-2.0*(group*TILE+i)/256.0));cs=real32(bits($cos(angle)));sn=real32(bits($sin(angle)));
        a[i]=bits(x*cs-y*sn);b[i]=bits(y*cs+x*sn);
      end
      qgold[group][r]=quant(a);qgold[group+8][r]=quant(b);
    end
    @(negedge clk);ext_qoz_region='0;ext_qoz_region.header='{job_id:16'd30,epoch:4'd3,head:3'd1,op:OP_Q_PROJ};
    ext_qoz_region.owner=QOZ_Q;ext_qoz_region.tiles=16;ext_qoz_region_valid=1;
    do @(posedge clk);while(!ext_qoz_region_ready);@(negedge clk);ext_qoz_region_valid=0;
    for(int t=0;t<16;t++)for(int p=0;p<PAIRS;p++)begin
      ext_qoz_wr='0;ext_qoz_wr.header=ext_qoz_region.header;ext_qoz_wr.n=6'(t);
      ext_qoz_wr.pair_data.tile_idx=6'(t);ext_qoz_wr.pair_data.pair_idx=PAIR_BITS'(p);ext_qoz_wr.pair_data.row_valid=row_mask(p);
      ext_qoz_wr.pair_data.row[0]=qgold[t][2*p];if(p<25)ext_qoz_wr.pair_data.row[1]=qgold[t][2*p+1];ext_qoz_wr.last=p==PAIRS-1;
      ext_qoz_wr_valid=1;do @(posedge clk);while(!ext_qoz_wr_ready);@(negedge clk);ext_qoz_wr_valid=0;
    end
  endtask
  initial begin
    job='0;vector_done='0;function_done='0;vector_result='0;function_result='0;xbc_entry='0;hbm_entry='0;kv_entry='0;acc_wr='0;
    ext_qoz_region='0;ext_qoz_wr='0;
    for(int i=0;i<7;i++)begin issues[i]=0;sent[i]=0;commands[i]=0;outputs[i]=0;end
    for(int r=0;r<ROWS;r++)begin m[r]=32'hff800000;lsum[r]=0;end
    repeat(35)@(negedge clk);reset=0;
    if($test$plusargs("ATTENTION_ONLY"))begin
      prepare_q();run_job(OP_ATTENTION,4,45760);
      if(!qoz_complete||qoz_region.owner!=QOZ_O||matrix_jobs!=110)$fatal(1,"Attention-only count");
      $display("tb_v3_pcore_control_v3 PASS attention_only=1 attention_jobs=110 real_softmax=1 workspace=1 O_commit=1");$finish;
    end
    if($test$plusargs("GU_ONLY"))begin
      run_job(OP_GU,6,106496);run_job(OP_DOWN_PROJ,7,53248);
      $display("tb_v3_pcore_control_v3 PASS gu_down_only=1 real_gelu=1 Z_chain=1");$finish;
    end
    run_job(OP_K_PROJ,1,3328);
    run_job(OP_V_PROJ,2,3328);
    run_job(OP_Q_PROJ,3,26624);
    if(!qoz_complete||qoz_region.owner!=QOZ_Q)$fatal(1,"Q not committed");
    run_job(OP_ATTENTION,4,45760);
    if(!qoz_complete||qoz_region.owner!=QOZ_O||matrix_jobs!=110)$fatal(1,"Attention O/matrix count");
    run_job(OP_O_PROJ,5,26624);
    run_job(OP_GU,6,106496);
    run_job(OP_DOWN_PROJ,7,53248);
    if(sent[OP_K_PROJ]!=52||sent[OP_V_PROJ]!=64||sent[OP_O_PROJ]!=1664||sent[OP_DOWN_PROJ]!=1664)$fatal(1,"egress counts");
    $display("tb_v3_pcore_control_v3 PASS jobs=7 issues=265408 attention_jobs=110 real_rope=1 real_gelu=1 real_softmax=1 all_mask_row=1 q_o_z_chain=1 egress_backpressure=1");$finish;
  end
  initial begin #12000000;$fatal(1,"control watchdog op=%0d stage=%0d vec=%0d sfu=%0d",job.header.op,dut.post_service.state_q,dut.vheld_q.function_id,dut.fheld_q.function_id);end
endmodule
