# Freeze only after both fresh simulation and final physical closure evidence.
param([switch]$VerifyOnly)
$ErrorActionPreference='Stop'
$here=$PSScriptRoot
$manifest=Join-Path $here 'V3_FROZEN.sha256.csv'
if($VerifyOnly -or (Test-Path -LiteralPath $manifest)){
  if(!(Test-Path -LiteralPath $manifest)){throw 'No V3 freeze manifest'}
  foreach($entry in (Import-Csv $manifest)){
    if((Get-FileHash -LiteralPath (Join-Path $here $entry.file) -Algorithm SHA256).Hash -ne $entry.sha256){throw "Frozen V3 changed: $($entry.file)"}
  }
  'V3_FROZEN_VERIFY_PASS';exit 0
}
$report=Join-Path $here 'reports'
$sim=Join-Path $report 'v3_simulation'
$physical=Join-Path $report 'v3_postroute'
if(!(Test-Path -LiteralPath $sim) -or !(Test-Path -LiteralPath $physical)){throw 'Missing V3 closure evidence'}
foreach($top in @('tb_deqacc_v1_arithmetic','tb_deqacc_v1_stream','tb_deqacc_v1_dynamic_matrix','tb_matrix')){
  $text=[IO.File]::ReadAllText((Join-Path $sim "$top.log"))
  if($text -match '(?im)^\s*(Fatal|ERROR|Error):' -or $text -notmatch [regex]::Escape("$top PASS")){throw "Simulation evidence invalid: $top"}
}
foreach($test in @('BAD_RAW','BAD_RAW_2','BAD_RAW_3')){
  $text=[IO.File]::ReadAllText((Join-Path $sim "$test.log"))
  if([regex]::Matches($text,'(?im)^\s*Fatal:').Count -ne 1 -or $text -notmatch 'Fatal: V1 accumulator RAW: dependent input interval below four cycles'){throw 'Negative RAW evidence invalid'}
}
$exact=[IO.File]::ReadAllText((Join-Path $physical 'margin_exact.txt'))
if($exact -notmatch 'Margin_0p5_pass=1' -or $exact -notmatch 'Clock_period_ns=4.000'){throw 'V3 physical margin not passed'}
foreach($row in (Import-Csv (Join-Path $physical 'source_sha256.csv'))){
  if($row.file -like 'rtl/*' -or $row.file -eq 'core_clock.xdc'){
    if((Get-FileHash -LiteralPath (Join-Path $here $row.file)).Hash -ne $row.sha256){throw 'Routed functional source differs'}
  }
}
foreach($row in (Import-Csv (Join-Path $sim 'sources_sha256.csv'))){
  if((Get-FileHash -LiteralPath (Join-Path $here $row.file)).Hash -ne $row.sha256){throw 'Simulated source differs'}
}
$route=[IO.File]::ReadAllText((Join-Path $physical 'route_status.rpt'))
if($route -notmatch 'nets with routing errors\.+\s*:\s*0'){throw 'Routing error evidence invalid'}
$sta=[IO.File]::ReadAllText((Join-Path $physical 'timing_summary_postroute.rpt'))
$match=[regex]::Match($sta,'(?m)^\s+([-\d.]+)\s+([-\d.]+)\s+(\d+)\s+(\d+)\s+([-\d.]+)\s+([-\d.]+)\s+(\d+)\s+(\d+)\s+([-\d.]+)\s+([-\d.]+)\s+(\d+)\s+(\d+)\s*$')
if(!$match.Success -or [double]$match.Groups[1].Value -lt .5 -or [double]$match.Groups[2].Value -ne 0 -or [int]$match.Groups[3].Value -ne 0 -or [double]$match.Groups[5].Value -lt 0 -or [int]$match.Groups[7].Value -ne 0){throw 'STA closure failed'}
# Generated scratch output may be removed after evidence is secured.
foreach($name in @('xsim.dir','.Xil')){
  $path=Join-Path $here $name
  if(Test-Path -LiteralPath $path){Remove-Item -LiteralPath $path -Recurse -Force}
}
foreach($item in (Get-ChildItem -LiteralPath $here -File)){
  if($item.Extension -in @('.wdb','.pb','.jou','.log') -or $item.Name -eq 'tight_setup_hold_pins.txt'){
    Remove-Item -LiteralPath $item.FullName -Force
  }
}
$rows=@('file,sha256')
$extensions=@('.sv','.f','.ps1','.tcl','.xdc')
# Entire DEQACC source copy is frozen, including simulation reference and the
# surrounding modules. Paths are relative to Pcore; sibling code uses ../.
$root=[IO.Path]::GetFullPath((Join-Path $here '..'))
foreach($file in (Get-ChildItem -LiteralPath $root -Recurse -File|Sort-Object FullName)){
  if($file.Extension -notin $extensions -or $file.FullName -match '\\(reports|history|xsim.dir|\.Xil)\\'){continue}
  $relative=if($file.FullName.StartsWith($here+'\')){$file.FullName.Substring($here.Length+1).Replace('\','/')}else{'../'+$file.FullName.Substring($root.Length+1).Replace('\','/')}
  $rows+="$relative,$((Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash)"
}
[IO.File]::WriteAllLines($manifest,$rows,[Text.Encoding]::UTF8)
$artifacts=@('file,sha256')
foreach($file in (Get-ChildItem -LiteralPath $physical -File|Sort-Object Name)){
  if($file.Name -eq 'artifacts_sha256.csv'){continue}
  $artifacts+="$($file.Name),$((Get-FileHash -LiteralPath $file.FullName).Hash)"
}
[IO.File]::WriteAllLines((Join-Path $physical 'artifacts_sha256.csv'),$artifacts,[Text.Encoding]::UTF8)
$closure=@('DEQACC V3 FROZEN 2026-10-14','Fresh short simulation: PASS','Seven stages, II=1, dependent interval>=4 cycles',
  '250MHz OOC post-route: WNS=+0.544ns TNS=0 WHS=+0.001ns THS=0',
  'Core LUT=49586 FF=20743 RAMB36=14 RAMB18=2',
  'Initial close-out WNS=+0.494ns; one existing-DCP refinement produced +0.544ns. RTL unchanged.',
  'Full seven jobs and eight-core/board integration are not new V3 closure evidence.',
  'No changes to DEA8; no GitHub push. Freeze uses V3_FROZEN.sha256.csv.')
[IO.File]::WriteAllLines((Join-Path $report 'v3_closure.txt'),$closure,[Text.Encoding]::UTF8)
"V3_FROZEN_PASS source_files=$($rows.Count-1)"
