`timescale 1ns/1ps
// Diagnostic only. No DUT or acceptance test is replaced by this reproducer.
module wait_sensitivity_repro;
  bit clk=0;
  always #2 clk=~clk;
  bit pc_complete[8][16];
  bit original_resumed=0,clocked_resumed=0,explicit_resumed=0;
  function automatic bit all_pc_done(input int id);
    for(int c=0;c<8;c++)if(!pc_complete[c][id])return 0;
    return 1;
  endfunction
  task automatic original_wait(input int id);
    wait(all_pc_done(id));
    original_resumed=1;
    $display("DIAG_ORIGINAL_RESUMED t=%0t",$time);
  endtask
  task automatic clocked_wait(input int id);
    while(!all_pc_done(id))@(negedge clk);
    clocked_resumed=1;
    $display("DIAG_CLOCKED_RESUMED t=%0t",$time);
  endtask
  task automatic explicit_wait(input int id);
    wait(pc_complete[0][id]&&pc_complete[1][id]&&pc_complete[2][id]&&pc_complete[3][id]&&
      pc_complete[4][id]&&pc_complete[5][id]&&pc_complete[6][id]&&pc_complete[7][id]);
    explicit_resumed=1;
    $display("DIAG_EXPLICIT_RESUMED t=%0t",$time);
  endtask
  initial begin
    fork
      original_wait(2);
      clocked_wait(2);
      explicit_wait(2);
      begin
        #20;
        for(int c=0;c<8;c++)begin #4;pc_complete[c][2]=1;end
      end
    join_none
    #100;
    $display("DIAG_WAIT_RESULT all_done=%0d original_resumed=%0d clocked_resumed=%0d explicit_resumed=%0d",
      all_pc_done(2),original_resumed,clocked_resumed,explicit_resumed);
    if(!all_pc_done(2)||!clocked_resumed||!explicit_resumed)$fatal(1,"Diagnostic control did not work");
    $display("DIAGNOSTIC_COMPLETE_NOT_A_DEA8_ACCEPTANCE_PASS");
    $finish;
  end
endmodule
