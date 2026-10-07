param([string]$VivadoRoot='D:\Xilinx\Vivado\2022.2',[switch]$ProtocolOnly)
$ErrorActionPreference='Stop'
$here=$PSScriptRoot
$report=Join-Path $here 'reports'
$xvlog=Join-Path $VivadoRoot 'bin\xvlog.bat'
$xelab=Join-Path $VivadoRoot 'bin\xelab.bat'
$xsim=Join-Path $VivadoRoot 'bin\xsim.bat'
Push-Location $here
try {
  Get-ChildItem rtl,tb -File -Filter *.sv | Sort-Object FullName | Get-FileHash -Algorithm SHA256 |
    ForEach-Object { "$($_.Hash),$($_.Path.Substring($here.Length+1))" } |
    Set-Content (Join-Path $report 'control_v3_sources_sha256.csv') -Encoding UTF8
  'RUNNING' | Set-Content (Join-Path $report 'control_v3_summary.txt')
  & $xvlog -sv -f v3_all.f (Join-Path $VivadoRoot 'data\verilog\src\glbl.v') |
    Tee-Object (Join-Path $report 'control_v3_compile.log')
  if($LASTEXITCODE){throw 'control compilation failed'}
  $tops=@('tb_v3_pcore_control_protocol','tb_v3_qoz_manager','tb_v3_qoz_shared','tb_v3_pcore_job_dispatch','tb_v3_attention_scheduler','tb_v3_acc_overlap')
  if(!$ProtocolOnly){$tops+='tb_v3_pcore_control_v3'}
  foreach($top in $tops) {
    # XSIM 2022.2 needs debug metadata to avoid its packed-array LLVM crash.
    & $xelab $top glbl -s "${top}_control" --O2 --debug typical --mt off -timescale 1ns/1ps -L unisims_ver |
      Tee-Object (Join-Path $report "${top}_control_elab.log")
    if($LASTEXITCODE){throw "control elaboration failed: $top"}
    $out=& $xsim "${top}_control" -runall --log (Join-Path $report "${top}_control.log") 2>&1
    $code=$LASTEXITCODE
    $out | Write-Output
    $text=$out -join "`n"
    if($code -ne 0 -or $text -match '(?im)^\s*(Fatal|Error):' -or $text -notmatch [regex]::Escape("$top PASS")) {
      throw "control simulation failed: $top"
    }
  }
  $summary=if($ProtocolOnly){'PASS: protocol, QOZ, dispatch, scheduler and accumulator mapping. Seven-job numerical run not included.'}
    else{'PASS: current-source control protocol, QOZ, dispatch, scheduler, accumulator mapping and seven complete jobs. Simulation only.'}
  $summary | Set-Content (Join-Path $report 'control_v3_summary.txt')
} catch {
  "FAILED: $_" | Set-Content (Join-Path $report 'control_v3_summary.txt')
  throw
} finally {Pop-Location}
