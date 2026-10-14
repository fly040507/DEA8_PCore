param(
  [string]$VivadoRoot='D:\Xilinx\Vivado\2022.2',
  [string]$Baseline='v2_route_20261013',
  [string]$Tag='',
  [switch]$FourLane
)
$ErrorActionPreference='Stop'
if(!$Tag){$Tag=$(if($FourLane){'v2_hard8x4_'}else{'v2_nopblock_'})+(Get-Date -Format 'yyyyMMdd_HHmmss')}
foreach($value in @($Baseline,$Tag)) {if($value -notmatch '^[A-Za-z0-9_-]+$'){throw 'Use simple report tags'}}
if(!(Test-Path -LiteralPath (Join-Path $PSScriptRoot "reports/$Baseline/synthesized.dcp"))){throw 'Missing baseline checkpoint before Pblock application'}
if(!(Test-Path -LiteralPath (Join-Path $VivadoRoot 'settings64.bat'))){throw 'Missing Vivado environment launcher'}
Push-Location $PSScriptRoot
try {
  $root=$PSScriptRoot.Replace('\','/')
  $steps=@(
    @('implement_deqacc_v2_nopblock.tcl',"$Baseline $Tag $(if($FourLane){'fourlane'})",'implementation'),
    @('synth_deqacc_v2.tcl',"$Tag report_route",'reports'),
    @('report_deqacc_v2_census.tcl',"$Tag routed",'census'),
    @('compare_deqacc_v2_placement.tcl',"$Baseline $Tag",'comparison')
  )
  foreach($step in $steps){
    $command='call "{0}\settings64.bat" && call "{0}\bin\vivado.bat" -mode batch -source {1} -log reports/{2}_{3}.log -journal reports/{2}_{3}.jou -tclargs "{4}" {5}' -f $VivadoRoot,$step[0],$Tag,$step[2],$root,$step[1]
    & $env:ComSpec /d /c $command
    if($LASTEXITCODE -ne 0){throw "No-Pblock step failed: $($step[2])"}
  }
  "Controlled placement comparison reports: reports/$Tag FourLane=$FourLane"
  'Check final STA; successful implementation does not mean 4ns timing passed.'
} finally {Pop-Location}
