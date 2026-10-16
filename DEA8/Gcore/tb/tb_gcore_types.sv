`timescale 1ns/1ps
module tb_gcore_types;
  import gcore_pkg::*;
  gcore_cmd_t command;
  gcore_done_t completion;
  initial begin
    command='0; command.opcode=GC_IMPORT_RESID;
    command.command_id=16'habcd; command.generation=16'h1234;
    command.dst_object=16'h5678; command.dst_version=16'h9abc;
    completion=make_done(command,GC_OK,16'(VECTOR_WORDS));
    if(!same_completion(completion,command)||completion.completed_items!=VECTOR_WORDS||
        command_token(command)!=32'h1234abcd) $fatal(1,"packed command/completion mismatch");
    if($bits(gcore_cmd_t)!=192||$bits(gcore_done_t)!=128||$bits(residual_import_t)!=301||
        $bits(prefix_import_t)!=184||$bits(rsqrt_packet_t)!=110||
        $bits(pcore_pkg::xbc4_t)!=563||$bits(pcore_pkg::b2_t)!=288) $fatal(1,"type width mismatch");
    $display("tb_gcore_types PASS cmd=192 done=128 residual=301 prefix=184 rsqrt=110 xbc=563 kvb=288");
    $finish;
  end
endmodule
