import pcore_pkg::*;import pcore_control_pkg::*;
// Scalars are register banks; only row-major Score occupies the shared M2V.
// AA storage is reused by final reciprocals after all alpha generations drain.
module dea8_pcore_workspace #(parameter bit EXTERNAL_VECTOR=0)(
 input logic clk,reset,clear,output vector_ram_port_t ram_a,ram_b,
 input logic [TILE-1:0][FP_BITS-1:0] ram_a_data,ram_b_data,
 input logic v_valid,output logic v_ready,input control_memory_req_t v_req,
 output logic v_out_valid,input logic v_out_ready,output control_memory_rsp_t v_out,
 input logic f_valid,output logic f_ready,input control_memory_req_t f_req,
 output logic f_out_valid,input logic f_out_ready,output control_memory_rsp_t f_out
);
 logic [50:0] initialized[6];logic [50:0] score_valid[2];
 control_memory_req_t req[2],read_req[2];control_memory_rsp_t held[2],scalar_response[2];
 logic [1:0] valid,ready,pending,full,advance,fire;
 logic [15:0] read_initialized[2];
 logic [511:0] data_a,data_b;
 function automatic int object_id(input control_memory_req_t r);
   case(r.buffer_id)WORK_M:return 0;WORK_AA:return 1;WORK_L:return 2;WORK_RECIP:return 3;default:return 4+int'(r.bank);endcase
 endfunction
 function automatic int physical_object(input control_memory_req_t r);
   case(r.buffer_id)WORK_M:return 0;WORK_AA,WORK_RECIP:return 1;WORK_L:return 2;default:return 3+int'(r.bank);endcase
 endfunction
 assign req[0]=v_req;assign req[1]=f_req;assign valid={f_valid,v_valid};assign fire=valid&ready;
 assign v_ready=ready[0];assign f_ready=ready[1];assign v_out=held[0];assign f_out=held[1];
  assign v_out_valid=full[0]&&!reset&&!clear;assign f_out_valid=full[1]&&!reset&&!clear;
  logic [2:0] physical_id[2],logical_id[2];
  logic [511:0] scalar_read[2];
  logic [19:0] scalar_select[2];
  for(genvar p=0;p<2;p++)begin: scalar_addresses
    assign physical_id[p]=3'(physical_object(req[p]));
    assign logical_id[p]=3'(object_id(req[p]));
    for(genvar obj=0;obj<5;obj++)for(genvar chunk=0;chunk<4;chunk++)begin: selects
      assign scalar_select[p][obj*4+chunk]=physical_id[p]==obj&&req[p].index[5:4]==chunk;
    end
  end
  // Each lane has its own fixed 32-bit input. A dynamic row write into one
  // monolithic array otherwise builds a 16-to-1 payload mux for EVERY word.
  for(genvar lane=0;lane<16;lane++)begin: scalar_lanes
    (* ram_style="registers" *) logic [31:0] words[5][4];
    for(genvar obj=0;obj<5;obj++)begin: objects
      wire from_f=fire[1]&&req[1].write&&req[1].buffer_id!=WORK_SCORE&&physical_id[1]==obj;
      wire from_v=fire[0]&&req[0].write&&req[0].buffer_id!=WORK_SCORE&&physical_id[0]==obj;
      wire [31:0] write_data=from_f?req[1].data[lane]:req[0].data[lane];
      wire [1:0] write_chunk=from_f?req[1].index[5:4]:req[0].index[5:4];
      wire write_enable=(from_f&&req[1].mask[lane])||(from_v&&req[0].mask[lane]);
      for(genvar chunk=0;chunk<4;chunk++)begin: chunks
        always_ff @(posedge clk)if(!reset&&!clear&&write_enable&&write_chunk==chunk&&chunk*16+lane<51)
          words[obj][chunk]<=write_data;
      end
    end
    for(genvar p=0;p<2;p++)begin: read_ports
      // Share a narrow object/chunk decoder across all 32-bit lane payloads.
      always_comb begin
        scalar_read[p][32*lane+:32]=0;
        for(int obj=0;obj<5;obj++)for(int chunk=0;chunk<4;chunk++)
          scalar_read[p][32*lane+:32]|=words[obj][chunk]&{32{scalar_select[p][obj*4+chunk]}};
      end
    end
  end
  for(genvar obj=0;obj<6;obj++)for(genvar row=0;row<51;row++)begin: scalar_valid
    always_ff @(posedge clk)begin
      if(reset||clear)initialized[obj][row]<=0;
      else if((fire[0]&&req[0].write&&req[0].buffer_id!=WORK_SCORE&&logical_id[0]==obj&&
               req[0].index[5:4]==row/16&&req[0].mask[row%16])||
              (fire[1]&&req[1].write&&req[1].buffer_id!=WORK_SCORE&&logical_id[1]==obj&&
               req[1].index[5:4]==row/16&&req[1].mask[row%16]))initialized[obj][row]<=1;
    end
  end
 if(EXTERNAL_VECTOR)begin assign data_a=ram_a_data;assign data_b=ram_b_data;end
 else begin: private_store
   dea8_vector_ram memory(.clk,.a(ram_a),.b(ram_b),.a_data(data_a),.b_data(data_b));
 end
 always_comb begin
   for(int p=0;p<2;p++)begin
     advance[p]=!full[p]||(p==0?v_out_ready:f_out_ready);
     ready[p]=!reset&&!clear&&(!pending[p]||advance[p]);
   end
    if(valid[0]&&valid[1]&&req[0].buffer_id==req[1].buffer_id&&req[0].bank==req[1].bank&&
       req[0].index==req[1].index&&(req[0].write||req[1].write))ready[1]=0;
    if(valid[0]&&valid[1]&&req[0].write&&req[1].write&&
       req[0].buffer_id!=WORK_SCORE&&req[1].buffer_id!=WORK_SCORE&&physical_id[0]==physical_id[1])ready[1]=0;
   ram_a='0;ram_b='0;
   for(int p=0;p<2;p++)if(fire[p]&&req[p].buffer_id==WORK_SCORE)begin
     for(int lane=0;lane<16;lane++)begin
       if(p==0)begin
         ram_a.en[lane]=1;ram_a.we[lane]=req[p].write;ram_a.addr[lane]={1'b1,req[p].bank,req[p].index};ram_a.data[lane]=req[p].data[lane];
       end else begin
         ram_b.en[lane]=1;ram_b.we[lane]=req[p].write;ram_b.addr[lane]={1'b1,req[p].bank,req[p].index};ram_b.data[lane]=req[p].data[lane];
       end
     end
   end
 end
 always_ff @(posedge clk)begin
   if(reset||clear)begin
     pending<=0;full<=0;
     for(int bank=0;bank<2;bank++)score_valid[bank]<=0;
   end else for(int p=0;p<2;p++)begin
     if(!pending[p]||advance[p])pending[p]<=fire[p]&&!req[p].write;
     if(full[p]&&(p==0?v_out_ready:f_out_ready))full[p]<=0;
     if(fire[p])begin
       if(req[p].write)begin
         if(req[p].buffer_id==WORK_SCORE)score_valid[req[p].bank][req[p].index]<=1;
       end else begin
         read_req[p]<=req[p];scalar_response[p]<='0;scalar_response[p].token<=req[p].token;
         for(int lane=0;lane<16;lane++)begin
           read_initialized[p][lane]<=req[p].buffer_id==WORK_SCORE?score_valid[req[p].bank][req[p].index]:1'b0;
            if(req[p].index[5:4]!=3||lane<3)begin
             scalar_response[p].mask[lane]<=1;
              scalar_response[p].data[lane]<=initialized[logical_id[p]][{req[p].index[5:4],4'(lane)}]?
                scalar_read[p][32*lane+:32]:
               (req[p].buffer_id==WORK_M?32'hff800000:32'b0);
           end
         end
       end
     end
     if(pending[p]&&advance[p])begin
       full[p]<=1;held[p]<=scalar_response[p];
       if(read_req[p].buffer_id==WORK_SCORE)begin
         held[p].mask<=read_initialized[p];held[p].token<=read_req[p].token;
         for(int lane=0;lane<16;lane++)held[p].data[lane]<=read_initialized[p][lane]?(p==0?data_a[32*lane+:32]:data_b[32*lane+:32]):32'b0;
       end
     end
   end
 end
 // synthesis translate_off
 always @(posedge clk)if(!reset&&!clear)for(int p=0;p<2;p++)
   if(fire[p]&&req[p].buffer_id!=WORK_SCORE&&req[p].index[3:0]!=0)$fatal(1,"Scalar access must be a 16-row aligned chunk");
 // synthesis translate_on
endmodule
