param(
  [string]$VivadoRoot='D:\Xilinx\Vivado\2022.2',
  [ValidateSet('all','types','stores','xbc','control','arithmetic','kv','rsqrt','frontend','packet','pcore_link','integrated','layers','gamma_fetch')][string]$Test='all',
  [string]$Python='C:\Users\fly04\.cache\codex-runtimes\codex-primary-runtime\dependencies\python\python.exe'
)
$ErrorActionPreference='Stop'
$here=$PSScriptRoot
$report=Join-Path $here 'reports'
New-Item -ItemType Directory -Force $report | Out-Null
$tops=if($Test -eq 'all'){@('tb_gcore_types','tb_gcore_stores','tb_gcore_xbc','tb_gcore_control','tb_gcore_arithmetic','tb_gcore_kv','tb_gcore_rsqrt','tb_gcore_frontend','tb_gcore_packet','tb_gcore_pcore_link','tb_gcore_gamma_fetch','tb_gcore_integrated','tb_gcore_layers')}else{@("tb_gcore_$Test")}
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
    'tb/generate_numeric_vectors.py','tb/generate_rework_vectors.py','tb/generate_native_fp_vectors.py',
    '../Pcore/rtl/pcore_ip_config_pkg.sv','../Pcore/rtl/dea8_compute_config_pkg.sv',
    '../Pcore/rtl/dea8_sdp_ram.sv','../Pcore/rtl/dea8_ram_fifo.sv',
    '../Pcore/ip/generate_compute_ip.tcl','../Pcore/ip/compute_ip_config.txt')
  $sources+=@(Get-ChildItem rtl,tb -Filter *.sv -File | ForEach-Object {$_.FullName})
  $sources+=@(Get-ChildItem tb/data -File | ForEach-Object {$_.FullName})
  $sources+=@('ip/create_rsqrt.tcl','ip/rsqrt_config.txt',
    'ip/generated/gcore_rsqrt_ip/gcore_rsqrt_ip.xci',
    'ip/generated/gcore_rsqrt_ip/sim/gcore_rsqrt_ip.v')
  foreach($ip in @('dea8_fpadd_ip','dea8_fpmul_ip')) {
    $sources+="../Pcore/ip/generated/$ip/$ip.xci"
    $sources+="../Pcore/ip/generated/$ip/sim/$ip.v"
  }
  $sources=$sources | Select-Object -Unique
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
  if(!(Test-Path '../Pcore/ip/generated/dea8_fpadd_ip/sim/dea8_fpadd_ip.v')) {
    $null=Invoke-VivadoTool 'vivado' '-mode batch -nojournal -nolog -source ../Pcore/ip/generate_compute_ip.tcl' 'compute_generate.log'
  }
  & $Python tb/generate_rework_vectors.py
  if($LASTEXITCODE){throw 'numeric reference generation failed'}
  & $Python tb/generate_native_fp_vectors.py
  if($LASTEXITCODE){throw 'native FP reference generation failed'}
  $sourceHashes=@(Get-SourceHashes)
  $null=Invoke-VivadoTool 'xvlog' "-sv -work $library -f gcore.f" 'compile.log'
  $null=Invoke-VivadoTool 'xvlog' "-sv -work $library `"$VivadoRoot/data/ip/xpm/xpm_memory/hdl/xpm_memory.sv`"" 'xpm_compile.log'
  foreach($top in $tops) {
    $snapshot="${top}_direct"
    $null=Invoke-VivadoTool 'xvlog' "`"$VivadoRoot/data/verilog/src/glbl.v`" -work $library" 'glbl_compile.log'
    $ipLibraries='-L xbip_utils_v3_0_10 -L axi_utils_v2_0_6 -L xbip_pipe_v3_0_6 -L xbip_dsp48_wrapper_v3_0_4 -L xbip_dsp48_addsub_v3_0_6 -L xbip_dsp48_multadd_v3_0_6 -L xbip_bram18k_v3_0_6 -L mult_gen_v12_0_18 -L floating_point_v7_1_15'
    $null=Invoke-VivadoTool 'xelab' "$library.$top $library.glbl -L unisims_ver -L xpm $ipLibraries -s $snapshot --mt off --O3 -timescale 1ns/1ps" "$top`_elaborate.log"
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
    if($top -eq 'tb_gcore_layers') {
      foreach($case in @('LAYER9','LAYER18','LAYER9 -testplusarg STRESS','LAYER18 -testplusarg STRESS','CANCEL_START','GAMMA_FAULT_DOWN')) {
        $caseName=$case.Replace(' -testplusarg ','_').Replace('=','_')
        $result=Invoke-VivadoTool 'xsim' "$snapshot -runall -testplusarg $case" "${top}_$caseName.txt"
        if($result -notmatch [regex]::Escape($marker)){throw "$top $case has no PASS marker"}
        $result -split "`n" | Where-Object {$_ -match ' PASS|CHECKS|METRICS'} | Write-Output
      }
    }
  }
  $after=@(Get-SourceHashes)
  if(Compare-Object $sourceHashes $after){throw 'Sources changed during simulation; rerun required'}
  $sourceHashes | Set-Content (Join-Path $report 'sources_sha256.csv') -Encoding UTF8
  $scenarios=$tops.Count
  $scope=@()
  if($tops -contains 'tb_gcore_integrated'){$scope+='Service integration with STRESS/BAD_HEADER/BAD_PACKET/CANCEL_ACTIVE.';$scenarios+=4}
  if($tops -contains 'tb_gcore_layers'){$scope+='Layers 1/9/18, layer9/18 backpressure, macro cancel/restart, gamma failure during Down; FP32 final_norm. DEA8/HBM/eight PCore streams are TB; X/prefix preloaded. No skipped layers executed.';$scenarios+=6}
  if(!$scope.Count){$scope+='Selected unit tests only; integrated GCore not run by this invocation.'}
  "PASS: $scenarios scenarios; $($tops -join ', ') at $(Get-Date -Format o). $($scope -join ' ') No standalone Reduce dependency. No new synthesis, full-chip inference or timing signoff." |
    Set-Content (Join-Path $report 'summary.txt') -Encoding UTF8
} catch {
  "FAILED at $(Get-Date -Format o): $_" | Set-Content (Join-Path $report 'summary.txt') -Encoding UTF8
  throw
} finally {Pop-Location}
