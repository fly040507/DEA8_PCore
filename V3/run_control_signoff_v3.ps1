param(
  [string]$VivadoRoot='D:\Xilinx\Vivado\2022.2',
  [ValidateRange(1,64)][int]$StressSeeds=16,
  [ValidateRange(1,16)][int]$Workers=4,
  [switch]$ProtocolOnly,
  [string]$ResumeReport=''
)
$ErrorActionPreference='Stop'
$here=$PSScriptRoot
$stamp=Get-Date -Format 'yyyyMMdd_HHmmss'
$report=Join-Path $here "reports/control_signoff_$stamp"
if($ResumeReport) {
  $report=(Resolve-Path -LiteralPath $ResumeReport).Path
  if((Split-Path $report -Parent) -ne (Join-Path $here 'reports') -or
     (Split-Path $report -Leaf) -notmatch '^control_signoff_(\d{8}_\d{6})$') {
    throw 'ResumeReport must be a control signoff directory in V3/reports'
  }
  $stamp=$Matches[1]
  if($ProtocolOnly){throw 'ResumeReport cannot be combined with ProtocolOnly'}
}
$cache=Join-Path $here ".tmp/control_signoff_$stamp"
$xvlog=Join-Path $VivadoRoot 'bin/xvlog.bat'
$xelab=Join-Path $VivadoRoot 'bin/xelab.bat'
$xsim=Join-Path $VivadoRoot 'bin/xsim.bat'
$null=New-Item -ItemType Directory -Force $report,$cache
$summary=Join-Path $report 'summary.txt'
$pointer=Join-Path $here 'reports/control_v3_signoff_latest.txt'
@("RUNNING",$report) | Set-Content $pointer
if($ResumeReport){Copy-Item -LiteralPath $summary -Destination (Join-Path $report "summary_before_resume_$(Get-Date -Format yyyyMMdd_HHmmss).txt")}
'RUNNING' | Set-Content $summary
$records=[Collections.Generic.List[object]]::new()
$sources=@(Get-ChildItem (Join-Path $here rtl),(Join-Path $here tb) -File -Filter *.sv)
$sources+=Get-Item (Join-Path $here v3_all.f),(Join-Path $here run_control_v3.ps1),(Join-Path $here run_control_signoff_v3.ps1)
function SourceHashes {
  $sources | Sort-Object FullName | Get-FileHash -Algorithm SHA256 |
    ForEach-Object { "$($_.Hash),$($_.Path.Substring($here.Length+1))" }
}
function VerifyRun([string]$name,[string]$top,[string]$log,[int]$code,[string]$output) {
  $text=if(Test-Path -LiteralPath $log){Get-Content -LiteralPath $log -Raw}else{''}
  if($code -ne 0 -or "$text`n$output" -match '(?im)^\s*(Fatal|Error|ERROR)(:|\s+\[)' -or
     $text -notmatch [regex]::Escape("$top PASS")) {throw "FAILED $name (exit=$code): $log"}
  $records.Add([pscustomobject]@{Test=$name;Status='PASS';Log=$log.Substring($here.Length+1)})
  $records | Export-Csv (Join-Path $report 'results.csv') -NoTypeInformation -Encoding UTF8
  "PASS $name"
}
function BuildSnapshot([string]$top) {
  $snapshot="${top}_signoff_$stamp"
  $out=& $xelab $top glbl -s $snapshot --O2 --debug typical --mt off -timescale 1ns/1ps -L unisims_ver -log (Join-Path $report "${top}_elab.log") 2>&1
  if($LASTEXITCODE -ne 0 -or ($out -join "`n") -match '(?im)^\s*(ERROR|Error)(:|\s+\[)'){throw "elaboration failed: $top"}
  return $snapshot
}
function RunSnapshot([string]$name,[string]$top,[string]$snapshot) {
  $log=Join-Path $report "$name.log"
  $out=& $xsim $snapshot -runall -wdb (Join-Path $cache "$name.wdb") -log $log 2>&1
  $code=$LASTEXITCODE
  VerifyRun $name $top $log $code ($out -join "`n")
}
$running=@()
Push-Location $here
try {
  $before=@(SourceHashes)
  if($ResumeReport) {
    $old=@(Get-Content -LiteralPath (Join-Path $report 'sources_sha256.csv'))
    $designPattern=',(rtl\\|tb\\|v3_all\.f$)'
    if(Compare-Object @($old | Where-Object {$_ -match $designPattern}) @($before | Where-Object {$_ -match $designPattern})) {
      throw 'RTL, TB or compile list changed; cannot reuse previous simulation evidence'
    }
    $prior=@(Import-Csv -LiteralPath (Join-Path $report 'results.csv'))
    foreach($name in @('baseline','protocol','faults','cancel')) {
      if(!($prior | Where-Object {$_.Test -eq $name -and $_.Status -eq 'PASS'})){throw "missing prior PASS: $name"}
    }
    $before | Set-Content (Join-Path $report 'sources_sha256_resume.csv') -Encoding UTF8
  } else {
    $before | Set-Content (Join-Path $report 'sources_sha256.csv') -Encoding UTF8
    $out=& $xvlog -sv -f v3_all.f (Join-Path $VivadoRoot 'data/verilog/src/glbl.v') -log (Join-Path $report 'compile.log') 2>&1
    if($LASTEXITCODE -ne 0 -or ($out -join "`n") -match '(?im)^\s*ERROR:'){throw 'compilation failed'}
  }
  $numerical=''
  if(!$ProtocolOnly) {
    if($ResumeReport) {
      $numerical="tb_v3_pcore_control_v3_signoff_$stamp"
      if(!(Test-Path -LiteralPath (Join-Path $here "xsim.dir/$numerical/xsimk.exe"))){throw 'missing numerical snapshot'}
      VerifyRun 'baseline' 'tb_v3_pcore_control_v3' (Join-Path $report 'baseline.log') 0 ''
    } else {
      $numerical=BuildSnapshot 'tb_v3_pcore_control_v3'
      RunSnapshot 'baseline' 'tb_v3_pcore_control_v3' $numerical
    }
  }
  $top='tb_v3_pcore_control_protocol'
  if($ResumeReport){VerifyRun 'protocol' $top (Join-Path $report 'protocol.log') 0 ''}
  else {RunSnapshot 'protocol' $top (BuildSnapshot $top)}
  if(!$ProtocolOnly) {
    foreach($item in @(@('faults','tb_v3_pcore_control_faults'),@('cancel','tb_v3_pcore_control_cancel'))) {
      if($ResumeReport){VerifyRun $item[0] $item[1] (Join-Path $report "$($item[0]).log") 0 ''}
      else {RunSnapshot $item[0] $item[1] (BuildSnapshot $item[1])}
    }
    # Isolate kernel logs, journal and elaborated image for every worker.
    $next=1
    while($next -le $StressSeeds -or $running.Count) {
      while($next -le $StressSeeds -and $running.Count -lt $Workers) {
        $seed=$next++
        $work=Join-Path $cache "seed_$seed"
        $null=New-Item -ItemType Directory -Force (Join-Path $work 'xsim.dir')
        Copy-Item -LiteralPath (Join-Path $here "xsim.dir/$numerical") -Destination (Join-Path $work 'xsim.dir') -Recurse -Force
        $log=Join-Path $report "stress_seed_$seed.log"
        # An options file avoids Windows PowerShell 5.1 splitting SEED=n at '='.
        @('-runall','-testplusarg STRESS','-testplusarg CORNERS',"-testplusarg SEED=$seed", "-wdb stress_$seed.wdb") |
          Set-Content (Join-Path $work 'stress.options') -Encoding ASCII
        $running+=Start-Job -Name "control_seed_$seed" -ArgumentList $work,$xsim,$numerical,$log,$seed -ScriptBlock {
          param($work,$xsim,$snapshot,$log,$seed)
          Set-Location $work
          $out=& $xsim $snapshot -f stress.options -log $log 2>&1
          $out | Set-Content (Join-Path $work 'launcher.log')
          [pscustomobject]@{Seed=$seed;Code=$LASTEXITCODE;Log=$log;Output=($out -join "`n")}
        }
        "START stress seed=$seed"
      }
      $finished=Wait-Job -Job $running -Any
      $r=Receive-Job -Job $finished -ErrorAction Stop
      if(!$r -or $finished.State -ne 'Completed'){throw "stress worker failed: $($finished.Name)"}
      VerifyRun "stress_seed_$($r.Seed)" 'tb_v3_pcore_control_v3' $r.Log $r.Code $r.Output
      $running=@($running | Where-Object Id -ne $finished.Id)
      Remove-Job -Job $finished
    }
  }
  foreach($top in @('tb_v3_qoz_manager','tb_v3_qoz_shared','tb_v3_pcore_job_dispatch','tb_v3_attention_scheduler','tb_v3_acc_overlap')) {
    RunSnapshot $top $top (BuildSnapshot $top)
  }
  $after=@(SourceHashes)
  $after | Set-Content (Join-Path $report 'sources_sha256_after.csv') -Encoding UTF8
  if(Compare-Object $before $after){throw 'source changed during regression; results are not a single-source signoff'}
  Get-ChildItem -LiteralPath $report -Filter '*.log' | ForEach-Object {
    Select-String -LiteralPath $_.FullName -Pattern 'CONTROL_(COVER|LIFECYCLE|FAULT_PASS|CANCEL_PASS|RECOVERY_PASS|ACC_CREDIT_PASS)| PASS'
  } | ForEach-Object { "$([IO.Path]::GetFileName($_.Path)):$($_.Line)" } |
    Set-Content (Join-Path $report 'coverage_summary.txt') -Encoding UTF8
  $status=if($ProtocolOnly){'PASS PROTOCOL_ONLY (not full signoff)'}else{"PASS baseline + protocol + faults + cancel + $StressSeeds stress seeds + adjacent regression; simulation only"}
  $status | Set-Content $summary
  @($status,$report) | Set-Content $pointer
  $status
} catch {
  # Preserve independent runs and do not leave required simulations running.
  if($running.Count){$null=Wait-Job -Job $running; $running | Receive-Job | Out-Null; $running | Remove-Job}
  "FAILED: $_" | Set-Content $summary
  @('FAILED',$report) | Set-Content $pointer
  throw
} finally {Pop-Location}
