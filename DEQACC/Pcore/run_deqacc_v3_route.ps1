param([string]$VivadoRoot='D:\Xilinx\Vivado\2022.2',[string]$Tag='v3_postroute')
$ErrorActionPreference='Stop'
if($Tag -notmatch '^[A-Za-z0-9_-]+$'){throw 'Invalid report tag'}
if(!(Test-Path -LiteralPath (Join-Path $PSScriptRoot 'reports'))){throw 'Expected reports parent'}
if(!(Test-Path -LiteralPath (Join-Path $VivadoRoot 'settings64.bat'))){throw 'Missing settings64.bat'}
if(Test-Path -LiteralPath (Join-Path $PSScriptRoot 'V3_FROZEN.sha256.csv')){
  foreach($entry in (Import-Csv (Join-Path $PSScriptRoot 'V3_FROZEN.sha256.csv'))){
    if((Get-FileHash -LiteralPath (Join-Path $PSScriptRoot $entry.file) -Algorithm SHA256).Hash -ne $entry.sha256){throw "Frozen V3 changed: $($entry.file)"}
  }
}
Push-Location $PSScriptRoot
try {
  $command='call "{0}\settings64.bat" && call "{0}\bin\vivado.bat" -mode batch -source implement_deqacc_v3.tcl -log reports/{1}.log -journal reports/{1}.jou -tclargs "{2}" {1}' -f $VivadoRoot,$Tag,$PSScriptRoot.Replace('\','/')
  & $env:ComSpec /d /c $command
  if($LASTEXITCODE -ne 0){throw 'V3 synthesis/implementation failed'}
  $exact=[IO.File]::ReadAllText((Join-Path $PSScriptRoot "reports/$Tag/margin_exact.txt"))
  if($exact -notmatch 'Margin_0p5_pass=1'){throw 'Implementation completed but V3 0.5ns margin not reached'}
  "V3 post-route closure passed: reports/$Tag"
} finally {Pop-Location}
