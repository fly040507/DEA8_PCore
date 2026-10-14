param(
  [string]$VivadoRoot='D:\Xilinx\Vivado\2022.2',
  [string]$Baseline='v2_route_20261013',
  [string]$Natural='v2_nopblock_20261014',
  [string]$Tag=('v2_soft_single_lane_'+(Get-Date -Format 'yyyyMMdd_HHmmss')),
  [switch]$ReportOnly
)
$ErrorActionPreference='Stop'
foreach($value in @($Baseline,$Natural,$Tag)){if($value -notmatch '^[A-Za-z0-9_-]+$'){throw 'Use simple report tags'}}
if(!(Test-Path -LiteralPath (Join-Path $PSScriptRoot 'reports'))){throw 'Missing report parent'}
if(!(Test-Path -LiteralPath (Join-Path $VivadoRoot 'settings64.bat'))){throw 'Missing Vivado environment'}
Push-Location $PSScriptRoot
try {
  $root=$PSScriptRoot.Replace('\','/')
  $steps=@()
  if(!$ReportOnly){$steps+=,@('implement_deqacc_v2_single_lane_soft.tcl',"$Baseline $Natural $Tag",'implementation')}
  else {if(!(Test-Path -LiteralPath "reports/$Tag/routed.dcp")){throw 'ReportOnly needs completed routed DCP'}}
  $steps+=,@('synth_deqacc_v2.tcl',"$Tag report_route",'timing')
  $steps+=,@('report_deqacc_v2_single_lane_soft.tcl',$Tag,'placement_census')
  $steps+=,@('compare_deqacc_v2_placement.tcl',"$Natural $Tag",'comparison')
  $steps+=,@('report_deqacc_v2_lane_internal.tcl',$Tag,'lane_internal')
  foreach($step in $steps){
    $command='call "{0}\settings64.bat" && call "{0}\bin\vivado.bat" -mode batch -source {1} -log reports/{2}_{3}.log -journal reports/{2}_{3}.jou -tclargs "{4}" {5}' -f $VivadoRoot,$step[0],$Tag,$step[2],$root,$step[1]
    & $env:ComSpec /d /c $command
    if($LASTEXITCODE -ne 0){throw "Single-Lane Soft step failed: $($step[2])"}
  }
  & .\summarize_deqacc_v2_single_lane_soft.ps1 -Tag $Tag
  "Single-Lane Soft reports: reports/$Tag (check STA; flow completion is not timing PASS)"
} finally {Pop-Location}
