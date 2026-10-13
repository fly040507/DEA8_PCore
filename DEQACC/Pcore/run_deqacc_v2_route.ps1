param(
  [string]$VivadoRoot='D:\Xilinx\Vivado\2022.2',
  [string]$Tag=('v2_route_'+(Get-Date -Format 'yyyyMMdd_HHmmss'))
)
$ErrorActionPreference='Stop'
if($Tag -notmatch '^[A-Za-z0-9_-]+$'){throw 'Use a simple unique report tag'}
if(!(Test-Path -LiteralPath (Join-Path $PSScriptRoot 'reports'))){throw 'Expected reports directory'}
if(!(Test-Path -LiteralPath (Join-Path $VivadoRoot 'settings64.bat'))){throw 'Missing settings64.bat'}
Push-Location $PSScriptRoot
try {
  $root=$PSScriptRoot.Replace('\','/')
  foreach($step in @(
    @('implement_deqacc_v2.tcl','implementation',''),
    @('synth_deqacc_v2.tcl','reports','report_route'),
    @('report_deqacc_v2_census.tcl','census','routed')
  )) {
    $command='call "{0}\settings64.bat" && call "{0}\bin\vivado.bat" -mode batch -source {1} -log reports/{2}_{3}.log -journal reports/{2}_{3}.jou -tclargs "{4}" {2} {5}' -f $VivadoRoot,$step[0],$Tag,$step[1],$root,$step[2]
    & $env:ComSpec /d /c $command
    if($LASTEXITCODE -ne 0){throw "V2 implementation/report step failed: $($step[1])"}
  }
  "Post-route reports: reports/$Tag"
  'Flow completion does not mean timing passed. Inspect WNS/TNS/WHS/THS and route status.'
} finally {Pop-Location}
