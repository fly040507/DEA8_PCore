param(
  [string]$VivadoRoot='D:\Xilinx\Vivado\2022.2',
  [string]$Tag=('v2_synth_'+(Get-Date -Format 'yyyyMMdd_HHmmss'))
)
$ErrorActionPreference='Stop'
if($Tag -notmatch '^[A-Za-z0-9_-]+$'){throw 'Report tag must contain only letters, digits, underscores or hyphens'}
if(!(Test-Path -LiteralPath (Join-Path $PSScriptRoot 'reports'))){throw 'Expected reports directory'}
if(!(Test-Path -LiteralPath (Join-Path $VivadoRoot 'settings64.bat'))){throw 'Missing settings64.bat'}
Push-Location $PSScriptRoot
try {
  $root=$PSScriptRoot.Replace('\','/')
  $command='call "{0}\settings64.bat" && call "{0}\bin\vivado.bat" -mode batch -source synth_deqacc_v2.tcl -log reports/{1}.log -journal reports/{1}.jou -tclargs "{2}" {1}' -f $VivadoRoot,$Tag,$root
  & $env:ComSpec /d /c $command
  if($LASTEXITCODE -ne 0){throw 'V2 synthesis/report failed; inspect the run log'}
  $command='call "{0}\settings64.bat" && call "{0}\bin\vivado.bat" -mode batch -source report_deqacc_v2_census.tcl -log reports/{1}_census.log -journal reports/{1}_census.jou -tclargs "{2}" {1}' -f $VivadoRoot,$Tag,$root
  & $env:ComSpec /d /c $command
  if($LASTEXITCODE -ne 0){throw 'V2 resource census failed'}
  "V2 synthesis reports: reports/$Tag"
  'Synthesis estimates only. No placement/routing or physical timing signoff.'
} finally {Pop-Location}
