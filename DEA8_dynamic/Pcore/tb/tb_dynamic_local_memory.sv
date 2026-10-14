`timescale 1ns/1ps
import pcore_pkg::*;
module tb_dynamic_local_memory;
  logic clk=0;always #2 clk=~clk;
  logic reset=1,clear=0;
  logic acquire_valid=0,acquire_ready,acquire_set=0;
  local_object_t acquire_object='0,bind_object='0;
  job_token_t producer_token=0,consumer_token=0;
  logic bind_valid=0,bind_ready,bind_set=0,release_valid=0,release_ready;
  local_release_t release_request='0;
  logic wr_valid=0,wr_ready,rd_valid=0,rd_ready,out_valid,out_ready=0;
  local_write_t wr='0;local_read_t rd='0;local_response_t out_response;
  logic qoz_active,qoz_complete,qoz_bound;
  logic [1:0] pbuf_active,pbuf_complete,pbuf_bound;
  local_object_t qoz_object,pbuf_object[0:1];
  logic protocol_error,empty;
  dea8_local_memory dut(.*);

  local_object_t objects[0:2];
  job_token_t writer[0:2],reader[0:2];
  local_response_t expected[0:3],held;
  int epush=0,epop=0,credits=0,reads=0,writes=0,objects_tested=0,negative_checks=0;
  int stalls=0,peak=0,seq=0,cycle=0,allow_release_blocks=0;
  bit allow_error=0,was_held=0,auto_ready=0;

  function automatic int index_for(input local_kind_e kind,input bit set_id);
    return kind==LOCAL_P?1+int'(set_id):0;
  endfunction
  function automatic logic [ROW_BITS-1:0] vector_ref(input local_object_t o,input int tile,row);
    logic [DATA_BITS-1:0] data;
    for(int k=0;k<TILE;k++)data[k*INT_BITS+:INT_BITS]=8'(int'(o.kind)*47+int'(o.content_version)*13+tile*29+row*17+k*11);
    return {data,8'(120+(int'(o.content_version)+tile+row)%16)};
  endfunction
  function automatic int tile_count(input local_kind_e kind);
    return kind==LOCAL_P?1:(kind==LOCAL_Z?QOZ_Z_TILES:QOZ_Q_TILES);
  endfunction
  always @(negedge clk)if(auto_ready)out_ready=cycle%7!=2&&cycle%7!=3&&cycle%7!=4;
  always @(posedge clk)begin
    local_response_t e;int idx,row;
    cycle++;
    if(reset||clear)begin credits=0;epush=0;epop=0;was_held=0;end
    else begin
      if(was_held&&out_response!==held)$fatal(1,"Local memory changed a held reply");
      if(was_held&&!out_valid&&!protocol_error)$fatal(1,"Local memory dropped held valid");
      if(rd_valid&&rd_ready)begin
        idx=index_for(rd.kind,rd.set_id);e='0;e.request=rd;
        e.mask=a_group_mask(objects[idx].m_rows,rd.group_idx);
        for(int i=0;i<A_INPUT_ROWS;i++)if(e.mask[i])begin
          row=int'(rd.group_idx)*A_INPUT_ROWS+i;e.entry[i]=vector_ref(objects[idx],rd.tile,row);
        end
        if(credits==2&&!(out_valid&&out_ready))$fatal(1,"Local memory accepted beyond response credits");
        expected[epush%4]=e;epush++;credits++;
      end
      if(out_valid&&out_ready)begin
        if(credits==0||out_response!==expected[epop%4])
          $fatal(1,"Local memory reply identity/mask/payload idx=%0d kind=%0d tile=%0d group=%0d",epop,out_response.request.kind,out_response.request.tile,out_response.request.group_idx);
        epop++;credits--;reads++;
      end
      if(credits>peak)peak=credits;
      if(wr_valid&&wr_ready)writes++;
      if(rd_valid&&!rd_ready)stalls++;
      was_held=out_valid&&!out_ready&&!protocol_error;held=out_response;
    end
    #1;if(protocol_error&&!allow_error)$fatal(1,"Local memory unexpected protocol fault cycle=%0d",cycle);
  end
  task automatic flush;
    @(negedge clk);clear=1;acquire_valid=0;bind_valid=0;release_valid=0;wr_valid=0;rd_valid=0;
    auto_ready=0;out_ready=0;
    @(negedge clk);clear=0;repeat(3)@(negedge clk);
    if(!empty||protocol_error||out_valid)$fatal(1,"Local memory clear failed");
  endtask
  task automatic acquire(input local_kind_e kind,input int m,version,input bit set_id);
    int idx;local_object_t o;
    idx=index_for(kind,set_id);o='0;o.kind=kind;o.m_rows=ROW_COUNT_BITS'(m);
    o.content_version=16'(version);o.data_context=16'(100+version);o.profile_id=7;
    o.profile_version=16'(version+3);o.head=2;o.block_id=6'(set_id?3:2);
    @(negedge clk);acquire_object=o;acquire_set=set_id;producer_token=32'h11110000+32'(version);acquire_valid=1;
    @(posedge clk);if(!acquire_ready)$fatal(1,"Local memory acquire refused");
    @(negedge clk);acquire_valid=0;objects[idx]=o;writer[idx]=producer_token;
    reader[idx]=32'h22220000+32'(version);objects_tested++;
  endtask
  task automatic fill(input local_kind_e kind,input bit set_id,input bit single_rows);
    int idx,m,count,step,row,lane;local_write_t w;
    idx=index_for(kind,set_id);m=objects[idx].m_rows;count=tile_count(kind);step=single_rows?1:A_INPUT_ROWS;
    for(int t=0;t<count;t++)for(int r=0;r<m;r+=step)begin
      w='0;w.kind=kind;w.set_id=set_id;w.token=writer[idx];w.content_version=objects[idx].content_version;w.tile=TILE_BITS'(t);
      for(int i=0;i<step;i++)if(r+i<m)begin
        row=r+i;lane=single_rows?row%A_INPUT_ROWS:(i+1)%A_INPUT_ROWS;
        w.mask[lane]=1;w.row[lane]=ROW_COUNT_BITS'(row);w.entry[lane]=vector_ref(objects[idx],t,row);
      end
      @(negedge clk);wr=w;wr_valid=1;
      @(posedge clk);if(!wr_ready)$fatal(1,"Local memory legal write refused");
    end
    @(negedge clk);wr_valid=0;
    if(kind==LOCAL_P?!pbuf_complete[set_id]:!qoz_complete)$fatal(1,"Local memory full-region completion missing");
  endtask
  task automatic bind_source(input local_kind_e kind,input bit set_id);
    int idx;idx=index_for(kind,set_id);
    @(negedge clk);bind_set=set_id;bind_object=objects[idx];consumer_token=reader[idx];bind_valid=1;
    @(posedge clk);if(!bind_ready)$fatal(1,"Local memory complete object bind refused");
    @(negedge clk);bind_valid=0;
  endtask
  task automatic request(input local_kind_e kind,input bit set_id,input int tile,group_idx);
    int idx;local_read_t r;
    idx=index_for(kind,set_id);r='0;r.kind=kind;r.set_id=set_id;r.token=reader[idx];
    r.content_version=objects[idx].content_version;r.request_seq=SEQ_BITS'(seq++);
    r.tile=TILE_BITS'(tile);r.group_idx=A_GROUP_BITS'(group_idx);
    @(negedge clk);rd=r;rd_valid=1;
    do @(posedge clk);while(!rd_ready);
    @(negedge clk);rd_valid=0;
  endtask
  task automatic read_all(input local_kind_e kind,input bit set_id);
    int idx;idx=index_for(kind,set_id);auto_ready=1;
    for(int t=0;t<tile_count(kind);t++)for(int g=0;g<(int'(objects[idx].m_rows)+A_INPUT_ROWS-1)/A_INPUT_ROWS;g++)
      request(kind,set_id,t,g);
    while(credits!=0)@(negedge clk);
    auto_ready=0;out_ready=0;
  endtask
  task automatic release_source(input local_kind_e kind,input bit set_id);
    int idx;idx=index_for(kind,set_id);
    @(negedge clk);release_request='0;release_request.kind=kind;release_request.set_id=set_id;
    release_request.token=reader[idx];release_request.content_version=objects[idx].content_version;release_valid=1;
    @(posedge clk);if(!release_ready)$fatal(1,"Local memory drained release refused");
    @(negedge clk);release_valid=0;
  endtask
  task automatic lifetime_tests;
    acquire(LOCAL_P,11,200,0);
    @(negedge clk);bind_object=objects[1];bind_set=0;consumer_token=reader[1];bind_valid=1;
    repeat(3)begin @(posedge clk);if(bind_ready||pbuf_bound[0])$fatal(1,"Partial PBUF was bound");end
    @(negedge clk);bind_valid=0;fill(LOCAL_P,0,0);bind_source(LOCAL_P,0);
    out_ready=0;request(LOCAL_P,0,0,0);request(LOCAL_P,0,0,1);
    repeat(3)@(negedge clk);
    if(!out_valid||credits!=2)$fatal(1,"Local memory two response credits not exercised");
    release_request='0;release_request.kind=LOCAL_P;release_request.token=reader[1];
    release_request.content_version=objects[1].content_version;release_valid=1;
    repeat(4)begin @(negedge clk);if(release_ready||!pbuf_active[0])$fatal(1,"Release with held read replies");end
    release_valid=0;allow_release_blocks++;
    // The other P generation may be written while the first has live replies.
    acquire(LOCAL_P,7,201,1);fill(LOCAL_P,1,1);bind_source(LOCAL_P,1);
    @(negedge clk);acquire_valid=1;acquire_set=0;acquire_object=objects[1];producer_token=writer[1];
    repeat(3)begin @(posedge clk);if(acquire_ready)$fatal(1,"Live P generation overwritten");end
    @(negedge clk);acquire_valid=0;out_ready=1;
    while(credits!=0)@(negedge clk);
    release_source(LOCAL_P,0);read_all(LOCAL_P,1);release_source(LOCAL_P,1);
    if(!empty)$fatal(1,"PBUF two-generation release incomplete");
    // Source changes wait for the older manager's accepted replies.
    acquire(LOCAL_Q,3,202,0);fill(LOCAL_Q,0,0);bind_source(LOCAL_Q,0);
    acquire(LOCAL_P,3,203,0);fill(LOCAL_P,0,0);bind_source(LOCAL_P,0);
    out_ready=0;request(LOCAL_Q,0,0,0);
    @(negedge clk);rd='0;rd.kind=LOCAL_P;rd.token=reader[1];rd.content_version=objects[1].content_version;rd_valid=1;
    repeat(3)begin @(posedge clk);if(rd_ready)$fatal(1,"Read source changed with live older reply");end
    @(negedge clk);rd_valid=0;out_ready=1;while(credits!=0)@(negedge clk);
    read_all(LOCAL_P,0);read_all(LOCAL_Q,0);release_source(LOCAL_P,0);release_source(LOCAL_Q,0);
  endtask
  task automatic negative_test(input int which);
    allow_error=1;
    acquire(LOCAL_P,3,300+which,0);
    case(which)
      0:begin
        wr='0;wr.kind=LOCAL_P;wr.token=writer[1];wr.content_version=objects[1].content_version;
        wr.mask=3'b001;wr_valid=1;
        @(posedge clk);if(!wr_ready)$fatal(1,"Negative fixture write");
        @(negedge clk); // Duplicate same row must not reach RAM.
      end
      1:begin wr='0;wr.kind=LOCAL_P;wr.token=writer[1];wr.content_version=objects[1].content_version;
        wr.mask=1;wr.row[0]=3;wr_valid=1;end
      2:begin wr='0;wr.kind=LOCAL_P;wr.token=writer[1]+1;wr.content_version=objects[1].content_version;wr.mask=1;wr_valid=1;end
      3:begin wr='0;wr.kind=LOCAL_P;wr.token=writer[1];wr.content_version=objects[1].content_version;
        wr.mask=3'b011;wr.row[0]=0;wr.row[1]=0;wr_valid=1;end
      4:begin fill(LOCAL_P,0,0);bind_object=objects[1];bind_object.profile_version++;
        bind_set=0;consumer_token=reader[1];bind_valid=1;end
      5,6:begin fill(LOCAL_P,0,0);bind_source(LOCAL_P,0);rd='0;rd.kind=LOCAL_P;rd.token=reader[1];
        rd.content_version=objects[1].content_version+(which==5?1:0);rd.group_idx=which==6?1:0;rd_valid=1;end
    endcase
    @(posedge clk);
    if((wr_valid&&wr_ready)||(bind_valid&&bind_ready)||(rd_valid&&rd_ready))$fatal(1,"Illegal local access accepted");
    #1;if(!protocol_error)$fatal(1,"Illegal local access not reported which=%0d",which);
    negative_checks++;flush();allow_error=0;
  endtask
  initial begin
    repeat(32)@(negedge clk);reset=0;
    for(int m=1;m<=ROWS;m++)begin
      acquire(local_kind_e'(LOCAL_Q+(m-1)%3),m,m,0);
      fill(objects[0].kind,0,m%11==0);bind_source(objects[0].kind,0);
      read_all(objects[0].kind,0);release_source(objects[0].kind,0);
      acquire(LOCAL_P,m,100+m,m[0]);fill(LOCAL_P,m[0],m%7==0);
      bind_source(LOCAL_P,m[0]);read_all(LOCAL_P,m[0]);release_source(LOCAL_P,m[0]);
    end
    lifetime_tests();
    // Clear cancels synchronous replies and validity without clearing payload RAM.
    acquire(LOCAL_Z,51,250,0);fill(LOCAL_Z,0,0);bind_source(LOCAL_Z,0);
    request(LOCAL_Z,0,31,16);flush();
    acquire(LOCAL_Q,1,251,0);fill(LOCAL_Q,0,0);bind_source(LOCAL_Q,0);read_all(LOCAL_Q,0);release_source(LOCAL_Q,0);
    for(int i=0;i<7;i++)negative_test(i);
    allow_error=1;acquire_object='0;acquire_object.kind=LOCAL_Q;acquire_valid=1;
    @(posedge clk);#1;if(acquire_ready||!protocol_error)$fatal(1,"Empty object acquired");negative_checks++;flush();allow_error=0;
    if(!empty||reads<1000||peak!=2||stalls==0||allow_release_blocks==0)$fatal(1,"Local memory coverage incomplete");
    $display("tb_dynamic_local_memory PASS all_M=1..51 objects=%0d writes=%0d replies=%0d credit_peak=%0d stalls=%0d negative_checks=%0d pending_release_checks=%0d",objects_tested,writes,reads,peak,stalls,negative_checks,allow_release_blocks);
    $finish;
  end
  initial begin #3000000;$fatal(1,"Local memory watchdog");end
endmodule
