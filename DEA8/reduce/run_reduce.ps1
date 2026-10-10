param([string]$VivadoRoot='D:\Xilinx\Vivado\2022.2')
$ErrorActionPreference='Stop'; Push-Location $PSScriptRoot
try {
  New-Item -ItemType Directory -Force reports | Out-Null
  & "$VivadoRoot\bin\xvlog.bat" -sv -f reduce.f "$VivadoRoot\data\verilog\src\glbl.v" | Tee-Object reports/reduce_compile.log
  if($LASTEXITCODE){throw 'reduce compilation failed'}
  & "$VivadoRoot\bin\xelab.bat" tb_reduce glbl -s reduce_sim --O2 --debug typical --mt off -timescale 1ns/1ps | Tee-Object reports/reduce_elaborate.log
  if($LASTEXITCODE){throw 'reduce elaboration failed'}
  $out=& "$VivadoRoot\bin\xsim.bat" reduce_sim -runall --log reports/reduce_sim.log 2>&1
  $out | Write-Output; $text=$out -join "`n"
  if($LASTEXITCODE -ne 0 -or $text -match '(?im)^\s*(Fatal|Error):' -or $text -notmatch 'tb_reduce PASS'){throw 'reduce simulation failed or PASS missing'}
  'PASS' | Set-Content reports/reduce_summary.txt
} finally { Pop-Location }
