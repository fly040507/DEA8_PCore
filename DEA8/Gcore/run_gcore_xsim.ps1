param(
  [string]$VivadoRoot='D:\Xilinx\Vivado\2022.2',
  [ValidateSet('all','types','stores','xbc','control','arithmetic','kv','rsqrt','frontend','packet','pcore_link','integrated')][string]$Test='all',
  [string]$Python='C:\Users\fly04\.cache\codex-runtimes\codex-primary-runtime\dependencies\python\python.exe'
)
$ErrorActionPreference='Stop'
$here=$PSScriptRoot
$report=Join-Path $here 'reports'
New-Item -ItemType Directory -Force $report | Out-Null
$tops=if($Test -eq 'all'){@('tb_gcore_types','tb_gcore_stores','tb_gcore_xbc','tb_gcore_control','tb_gcore_arithmetic','tb_gcore_kv','tb_gcore_rsqrt','tb_gcore_frontend','tb_gcore_packet','tb_gcore_pcore_link','tb_gcore_integrated')}else{@("tb_gcore_$Test")}
$library='gcore_direct'

function Invoke-VivadoTool([string]$Name,[string]$Arguments,[string]$LogName) {
  $command='call "{0}\settings64.bat" && call "{0}\bin\{1}.bat" {2}' -f $VivadoRoot,$Name,$Arguments
  $lines=& $env:ComSpec /d /c $command 2>&1
  $code=$LASTEXITCODE
  $lines | Set-Content -LiteralPath (Join-Path $report $LogName) -Encoding UTF8
  if($code -ne 0){throw "$Name failed ($code); see $LogName"}
  $result=$lines -join "`n"
  if($result -match '(?im)^\s*(Fatal|Error|ERROR)(:|\s+\[)'){throw "$Name reported an error; see $LogName"}
  return $result
}

function Get-SourceHashes {
  $sources=@('gcore.f','gcore_rtl.f','run_gcore_xsim.ps1','check_dsp_budget.tcl','check_gcore_synth.tcl',
    '../Pcore/rtl/pcore_pkg.sv','../Pcore/rtl/dea8_tile_link_pkg.sv',
    '../Pcore/rtl/dea8_fp32_pkg.sv','../Pcore/rtl/pcore_control_pkg.sv','../Pcore/rtl/dea8_kv_tile_sender.sv',
    '../Pcore/rtl/dea8_pcore_output.sv','../Pcore/rtl/dea8_pcore_control.sv',
    'tb/generate_numeric_vectors.py','tb/generate_rework_vectors.py')
  $sources+=@(Get-ChildItem rtl,tb -Filter *.sv -File | ForEach-Object {$_.FullName})
  $sources+=@(Get-ChildItem tb/data -File | ForEach-Object {$_.FullName})
  $sources+=@('ip/create_rsqrt.tcl','ip/rsqrt_config.txt',
    'ip/generated/gcore_rsqrt_ip/gcore_rsqrt_ip.xci',
    'ip/generated/gcore_rsqrt_ip/sim/gcore_rsqrt_ip.v')
  foreach($source in $sources) {
    $hash=Get-FileHash -LiteralPath $source -Algorithm SHA256
    $name=if([IO.Path]::IsPathRooted($source)){$source.Substring($here.Length+1)}else{$source}
    "$($hash.Hash),$name"
  }
}

Push-Location $here
try {
  'RUNNING' | Set-Content (Join-Path $report 'summary.txt') -Encoding UTF8
  if(!(Test-Path 'ip/generated/gcore_rsqrt_ip/sim/gcore_rsqrt_ip.v')) {
    $null=Invoke-VivadoTool 'vivado' '-mode batch -nojournal -source ip/create_rsqrt.tcl' 'rsqrt_generate.log'
  }
  & $Python tb/generate_rework_vectors.py
  if($LASTEXITCODE){throw 'numeric reference generation failed'}
  $sourceHashes=@(Get-SourceHashes)
  $null=Invoke-VivadoTool 'xvlog' "-sv -work $library -f gcore.f" 'compile.log'
  foreach($top in $tops) {
    $snapshot="${top}_direct"
    $null=Invoke-VivadoTool 'xvlog' "`"$VivadoRoot/data/verilog/src/glbl.v`" -work $library" 'glbl_compile.log'
    $null=Invoke-VivadoTool 'xelab' "$library.$top $library.glbl -L unisims_ver -L xpm -L floating_point_v7_1_15 -s $snapshot --mt off --O2 -timescale 1ns/1ps" "$top`_elaborate.log"
    $result=Invoke-VivadoTool 'xsim' "$snapshot -runall" "$top.txt"
    $marker="$top PASS"
    if($result -notmatch [regex]::Escape($marker)){throw "$top has no PASS marker"}
    $result -split "`n" | Where-Object {$_ -match ' PASS|CHECKS|METRICS'} | Write-Output
    if($top -eq 'tb_gcore_integrated') {
      foreach($case in @('STRESS','BAD_HEADER','BAD_PACKET','CANCEL_ACTIVE')) {
        $result=Invoke-VivadoTool 'xsim' "$snapshot -runall -testplusarg $case" "${top}_$case.txt"
        if($result -notmatch [regex]::Escape($marker)){throw "$top $case has no PASS marker"}
        $result -split "`n" | Where-Object {$_ -match ' PASS|CHECKS|METRICS'} | Write-Output
      }
    }
  }
  $after=@(Get-SourceHashes)
  if(Compare-Object $sourceHashes $after){throw 'Sources changed during simulation; rerun required'}
  $sourceHashes | Set-Content (Join-Path $report 'sources_sha256.csv') -Encoding UTF8
  $scope=if($tops -contains 'tb_gcore_integrated'){
    'Includes STRESS/BAD_HEADER/BAD_PACKET/CANCEL_ACTIVE. Native single rsqrt and internal 4-lane reduce; X/prefix preloaded. Eight PCore streams and DEA8 commands are TB.'
  }else{'Selected unit tests only; integrated GCore not run by this invocation.'}
  "PASS: $($tops -join ', ') at $(Get-Date -Format o). $scope No standalone Reduce dependency. No full-chip inference or timing signoff." |
    Set-Content (Join-Path $report 'summary.txt') -Encoding UTF8
} catch {
  "FAILED at $(Get-Date -Format o): $_" | Set-Content (Join-Path $report 'summary.txt') -Encoding UTF8
  throw
} finally {Pop-Location}
