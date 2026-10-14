param([string]$VivadoRoot='D:\Xilinx\Vivado\2022.2',[switch]$SevenJobs)
$ErrorActionPreference='Stop'
$here=$PSScriptRoot
$report=Join-Path $here 'reports/v3_simulation'
if(!(Test-Path -LiteralPath (Join-Path $here 'reports'))){throw 'Expected reports parent'}
if(!(Test-Path -LiteralPath (Join-Path $VivadoRoot 'settings64.bat'))){throw 'Missing settings64.bat'}
if(Test-Path -LiteralPath (Join-Path $here 'V3_FROZEN.sha256.csv')){
  foreach($entry in (Import-Csv (Join-Path $here 'V3_FROZEN.sha256.csv'))){
    if((Get-FileHash -LiteralPath (Join-Path $here $entry.file) -Algorithm SHA256).Hash -ne $entry.sha256){throw "Frozen V3 changed: $($entry.file)"}
  }
}
if(Test-Path -LiteralPath $report){throw 'V3 simulation evidence already exists; archive intentionally before rerunning'}
[void][IO.Directory]::CreateDirectory($report)
function Tool([string]$Name,[string]$Arguments,[switch]$Negative){
  $command='call "{0}\settings64.bat" && call "{0}\bin\{1}.bat" {2}' -f $VivadoRoot,$Name,$Arguments
  $output=& $env:ComSpec /d /c $command 2>&1
  $code=$LASTEXITCODE;$text=$output -join "`n"
  if(!$Negative -and ($code -ne 0 -or $text -match '(?im)^\s*(ERROR|Error):')){throw "$Name failed; inspect reports/v3_simulation"}
  return $text
}
Push-Location $here
try {
  $summary=[Collections.Generic.List[string]]::new()
  Tool xvlog '-sv -work v3_suite -f pcore_v1_sim.f -log reports/v3_simulation/compile.log' | Out-Null
  Tool xvlog ('-work v3_suite "{0}\data\verilog\src\glbl.v" -log reports/v3_simulation/glbl_compile.log' -f $VivadoRoot) | Out-Null
  $tops=@('tb_deqacc_v1_arithmetic','tb_deqacc_v1_stream','tb_deqacc_v1_dynamic_matrix','tb_matrix')
  if($SevenJobs){$tops+='tb_pcore_control'}
  foreach($top in $tops){
    "V3 小项开始：$top"
    Tool xelab "v3_suite.$top v3_suite.glbl -s v3_$top --O2 --debug typical --mt off -timescale 1ns/1ps -L unisims_ver -log reports/v3_simulation/${top}_elab.log" | Out-Null
    $text=Tool xsim "v3_$top -runall -log reports/v3_simulation/$top.log"
    if($text -match '(?im)^\s*(Fatal|ERROR|Error):' -or $text -notmatch [regex]::Escape("$top PASS")){throw "V3 verification failed: $top"}
    foreach($line in [regex]::Matches($text,'(?m)^tb_.* PASS.*$')){$summary.Add($line.Value);$line.Value}
  }
  foreach($test in @('BAD_RAW','BAD_RAW_2','BAD_RAW_3')){
    $text=Tool xsim "v3_tb_deqacc_v1_stream -runall -testplusarg $test -log reports/v3_simulation/$test.log" -Negative
    if([regex]::Matches($text,'(?im)^\s*Fatal:').Count -ne 1 -or
      $text -notmatch 'Fatal: V1 accumulator RAW: dependent input interval below four cycles' -or
      $text -match '(?im)^\s*(ERROR|Error):' -or $text -match 'tb_deqacc_v1_stream PASS'){throw "Unexpected negative result: $test"}
    $line="$test PASS expected RAW rejection";$summary.Add($line);$line
  }
  $summary.Add('V3 short closure: arithmetic, seven-stage stream, dynamic M, Matrix and three RAW negatives. Full seven jobs run only with -SevenJobs.')
  $summary.Add('Physical timing is a separate post-route result, not inferred from simulation.')
  [IO.File]::WriteAllLines((Join-Path $report 'summary.txt'),$summary,[Text.Encoding]::UTF8)
  $hashes=@('file,sha256')
  foreach($file in (@(Get-ChildItem -LiteralPath (Join-Path $here 'rtl') -File -Filter '*.sv')+
      @(Get-ChildItem -LiteralPath (Join-Path $here 'tb') -File -Filter '*.sv'))){
    $rel=$file.FullName.Substring($here.Length+1).Replace('\','/')
    $hashes+="$rel,$((Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash)"
  }
  [IO.File]::WriteAllLines((Join-Path $report 'sources_sha256.csv'),$hashes,[Text.Encoding]::UTF8)
} finally {Pop-Location}
