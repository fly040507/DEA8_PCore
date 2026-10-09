param(
  [string]$VivadoRoot = '',
  [switch]$AttentionOnly
)

$ErrorActionPreference='Stop'
$SevenJobRoot=$PSScriptRoot
$V3Root=Split-Path -Parent $SevenJobRoot

if(!$VivadoRoot){
  $candidates=@(
    'D:\Xilinx\Vivado\2022.2',
    'C:\Xilinx\Vivado\2022.2',
    'C:\Program Files\Xilinx\Vivado\2022.2'
  )
  $VivadoRoot=$candidates | Where-Object {Test-Path (Join-Path $_ 'bin\xvlog.bat')} | Select-Object -First 1
}
if(!$VivadoRoot -or !(Test-Path (Join-Path $VivadoRoot 'bin\xvlog.bat'))){
  throw '没有找到 Vivado 2022.2。请用 -VivadoRoot 指定，例如 -VivadoRoot D:\Xilinx\Vivado\2022.2'
}

$gen=Join-Path $SevenJobRoot 'make_perf_tb.ps1'
if(!(Test-Path $gen)){throw "缺少 $gen"}
& powershell -ExecutionPolicy Bypass -File $gen -SevenJobRoot $SevenJobRoot
if($LASTEXITCODE -ne 0){throw '生成 performance TB 失败'}

$report=Join-Path $SevenJobRoot 'reports'
New-Item -ItemType Directory -Force $report | Out-Null

$xvlog=Join-Path $VivadoRoot 'bin\xvlog.bat'
$xelab=Join-Path $VivadoRoot 'bin\xelab.bat'
$xsim =Join-Path $VivadoRoot 'bin\xsim.bat'
$glbl =Join-Path $VivadoRoot 'data\verilog\src\glbl.v'

Push-Location $V3Root
try {
  Write-Host '=== 1/3 编译 SystemVerilog ==='
  & $xvlog -sv -f v3_all.f (Join-Path $SevenJobRoot 'tb_v3_pcore_control_perf.sv') $glbl `
    -log (Join-Path $report 'perf32x4_compile.log')
  if($LASTEXITCODE -ne 0){throw 'xvlog 编译失败，请看 reports\perf32x4_compile.log'}

  Write-Host '=== 2/3 Elaborate ==='
  & $xelab tb_v3_pcore_control_perf glbl `
    -s tb_v3_pcore_control_perf_sim `
    --O2 --debug typical --mt off -timescale 1ns/1ps -L unisims_ver `
    -log (Join-Path $report 'perf32x4_elab.log')
  if($LASTEXITCODE -ne 0){throw 'xelab 失败，请看 reports\perf32x4_elab.log'}

  Write-Host '=== 3/3 运行 7 Job 性能仿真 ==='
  $args=@(
    'tb_v3_pcore_control_perf_sim',
    '-runall',
    '-wdb',(Join-Path $report 'control_v3_performance_32x4.wdb'),
    '-log',(Join-Path $report 'control_v3_performance_32x4.log')
  )
  if($AttentionOnly){$args += @('-testplusarg','ATTENTION_ONLY')}
  & $xsim @args
  if($LASTEXITCODE -ne 0){throw 'xsim 失败'}

  $log=Join-Path $report 'control_v3_performance_32x4.log'
  $text=Get-Content -LiteralPath $log -Raw
  if($text -notmatch 'tb_v3_pcore_control_perf PASS'){
    throw '仿真没有出现 PASS，请检查 log 中最早的 Fatal/Error。'
  }

  Write-Host ''
  Write-Host '=== PASS ==='
  Select-String -LiteralPath $log -Pattern 'JOB_PERF|ATTN_PERF|POST_PERF|tb_v3_pcore_control_perf PASS' |
    ForEach-Object {$_.Line}
  Write-Host ''
  Write-Host "完整日志: $log"
  Write-Host "波形文件: $(Join-Path $report 'control_v3_performance_32x4.wdb')"
}
finally {
  Pop-Location
}
