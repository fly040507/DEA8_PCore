param([string]$Tag='v2_soft_single_lane_20261014')
$ErrorActionPreference='Stop'
$report=Join-Path $PSScriptRoot "reports/$Tag"
if(!(Test-Path -LiteralPath $report)){throw 'Missing Soft report directory'}
$culture=[Globalization.CultureInfo]::InvariantCulture
function Read-Text([string]$File){[IO.File]::ReadAllText($File)}
function Number($Value){[double]::Parse([string]$Value,$culture)}
function Statistics($Values){
  $v=@($Values|ForEach-Object {Number $_}|Sort-Object)
  if(!$v.Count){throw 'Empty statistic sample'}
  $m=$v|Measure-Object -Average -Minimum -Maximum
  [pscustomobject]@{mean=[math]::Round($m.Average,4);median=[math]::Round(($v[[int][math]::Floor(($v.Count-1)/2)]+$v[[int][math]::Floor($v.Count/2)])/2,4);min=$m.Minimum;max=$m.Maximum}
}
$variants=@('v2_route_20261013','v2_hard8x4_20261014','v2_nopblock_20261014',$Tag)
$incoming=[Collections.Generic.List[object]]::new()
$global=[Collections.Generic.List[object]]::new()
$stages=[Collections.Generic.List[object]]::new()
foreach($variant in $variants){
  $dir=Join-Path $PSScriptRoot "reports/$variant"
  $timing=Read-Text (Join-Path $dir 'timing_summary_postroute.rpt')
  $match=[regex]::Match($timing,'(?m)^\s+([-\d.]+)\s+([-\d.]+)\s+(\d+)\s+(\d+)\s+([-\d.]+)\s+([-\d.]+)\s+(\d+)\s+(\d+)\s+([-\d.]+)\s+([-\d.]+)\s+(\d+)\s+(\d+)\s*$')
  if(!$match.Success){throw "Missing timing table: $variant"}
  $util=Read-Text (Join-Path $dir 'utilization.rpt')
  $hier=Read-Text (Join-Path $dir 'utilization_hierarchical.rpt')
  $core=[regex]::Match($hier,'(?m)^\|\s+core\s+\|\s+DEQACC_V1\s+\|\s+(\d+)\s+\|\s+(\d+)\s+\|\s+(\d+)\s+\|\s+(\d+)\s+\|\s+(\d+)\s+\|\s+(\d+)\s+\|\s+(\d+)')
  if(!$core.Success){throw "Missing core utilization: $variant"}
  $clb=[regex]::Match($util,'(?m)^\| CLB\s+\|\s+(\d+)')
  $slr=[regex]::Match($util,'\| Total SLLs Used\s+\|\s+(\d+)')
  $densityFile=Join-Path $report "${variant}_clock_region_density.csv"
  if(!(Test-Path -LiteralPath $densityFile)){
    $densityFile=Join-Path $PSScriptRoot "reports/v2_nopblock_20261014/${variant}_clock_region_density.csv"
    if(!(Test-Path -LiteralPath $densityFile)){$densityFile=Join-Path $dir "${variant}_clock_region_density.csv"}
  }
  $density=Import-Csv $densityFile
  $route=Read-Text (Join-Path $dir 'route_status.rpt')
  $routeErrors=[regex]::Match($route,'nets with routing errors\.+\s*:\s*(\d+)').Groups[1].Value
  $global.Add([pscustomobject]@{
    variant=$variant;WNS=$match.Groups[1].Value;TNS=$match.Groups[2].Value;setup_failed=$match.Groups[3].Value
    WHS=$match.Groups[5].Value;THS=$match.Groups[6].Value;hold_failed=$match.Groups[7].Value
    routing_errors=$routeErrors;SLR_crossings=$slr.Groups[1].Value
    core_LUT=$core.Groups[1].Value;core_FF=$core.Groups[5].Value;used_CLB=$clb.Groups[1].Value
    max_clock_region_CLB_percent=(Statistics $density.CLB_percent).max
    RAMB36=$core.Groups[6].Value;RAMB18=$core.Groups[7].Value
  })
  $paths=Import-Csv (Join-Path $dir 'path_delays.csv')
  foreach($path in $paths){
    if($path.group -match '^lane([0-3])_([0-7])_(Q0|Q1|A0|A1|A2|A3|C)$'){
      $g=[int]$Matches[1];$lane=[int]$Matches[2];$s=$Matches[3]
      $incoming.Add([pscustomobject]@{
        variant=$variant;row=[int][math]::Floor($g/2);col=($g%2)*8+$lane;stage=$s
        logic_ns=$path.logic_ns;route_ns=$path.routed_net_ns;total_ns=$path.total_ns
        slack_ns=$path.slack_ns;logic_levels=$path.logic_levels;startpoint=$path.startpoint;endpoint=$path.endpoint
      })
    } elseif($path.group -in @('Q0','Q1','A0','A1','A2','A3','C')){
      $stages.Add([pscustomobject]@{variant=$variant;stage=$path.group;logic_ns=$path.logic_ns;route_ns=$path.routed_net_ns;total_ns=$path.total_ns;slack_ns=$path.slack_ns;logic_levels=$path.logic_levels;startpoint=$path.startpoint;endpoint=$path.endpoint})
    }
  }
}
$global|Export-Csv (Join-Path $report 'four_way_summary.csv') -NoTypeInformation -Encoding UTF8
$stages|Export-Csv (Join-Path $report 'seven_stage_timing.csv') -NoTypeInformation -Encoding UTF8
$incoming|Export-Csv (Join-Path $report 'lane_stage_timing.csv') -NoTypeInformation -Encoding UTF8
$internal=Import-Csv (Join-Path $report 'lane_internal_timing.csv')
$stats=[Collections.Generic.List[object]]::new()
foreach($mode in @('incoming','internal')){
  $records=if($mode -eq 'incoming'){$incoming}else{$internal}
  foreach($variant in ($records.variant|Sort-Object -Unique)){
    foreach($s in @('Q1','A0','A1','A2')){
      $sample=@($records|Where-Object {$_.variant -eq $variant -and $_.stage -eq $s})
      if($sample.Count -ne 32){throw "Incomplete $mode $variant $s"}
      $r=Statistics $sample.route_ns;$t=Statistics $sample.total_ns;$sl=Statistics $sample.slack_ns
      $stats.Add([pscustomobject]@{mode=$mode;variant=$variant;stage=$s;route_mean=$r.mean;route_median=$r.median;route_min=$r.min;route_max=$r.max;total_mean=$t.mean;total_median=$t.median;total_min=$t.min;total_max=$t.max;slack_mean=$sl.mean;slack_median=$sl.median;slack_min=$sl.min;slack_max=$sl.max;failing_lanes=@($sample|Where-Object {(Number $_.slack_ns) -lt 0}).Count})
    }
  }
}
$stats|Export-Csv (Join-Path $report 'lane_stage_statistics.csv') -NoTypeInformation -Encoding UTF8
$deltas=[Collections.Generic.List[object]]::new()
foreach($mode in @('incoming','internal')){
  $records=if($mode -eq 'incoming'){$incoming}else{$internal}
  $previous=@($records|Where-Object {$_.variant -eq 'v2_nopblock_20261014'})
  foreach($now in ($records|Where-Object {$_.variant -eq $Tag -and $_.stage -in @('Q1','A0','A1','A2')})){
    $old=@($previous|Where-Object {$_.row -eq $now.row -and $_.col -eq $now.col -and $_.stage -eq $now.stage})
    if($old.Count -ne 1){throw 'Nonunique lane comparison'}
    $deltas.Add([pscustomobject]@{mode=$mode;row=$now.row;col=$now.col;stage=$now.stage;no_route=$old[0].route_ns;soft_route=$now.route_ns;route_delta=[math]::Round((Number $now.route_ns)-(Number $old[0].route_ns),3);no_slack=$old[0].slack_ns;soft_slack=$now.slack_ns;slack_delta=[math]::Round((Number $now.slack_ns)-(Number $old[0].slack_ns),3)})
  }
}
$deltas|Export-Csv (Join-Path $report 'lane_stage_delta.csv') -NoTypeInformation -Encoding UTF8
$escape=[Collections.Generic.List[object]]::new()
$placements=Import-Csv (Join-Path $report 'soft_stage_inside_outside.csv')
foreach($s in @('Q0','Q1','A0','A1','A2','A3','C','COMB_LEAF')){
  $part=@($placements|Where-Object {$_.stage -eq $s})
  $in=($part|ForEach-Object {[int]$_.inside}|Measure-Object -Sum).Sum
  $out=($part|ForEach-Object {[int]$_.outside}|Measure-Object -Sum).Sum
  $escape.Add([pscustomobject]@{stage=$s;inside=$in;outside=$out;outside_percent=[math]::Round(100.0*$out/($in+$out),3)})
}
$escape|Export-Csv (Join-Path $report 'stage_escape_summary.csv') -NoTypeInformation -Encoding UTF8
$natural=Import-Csv (Join-Path $report 'natural_lane_stage_placement.csv')
$soft=Import-Csv (Join-Path $report 'soft_lane_stage_placement.csv')
$spread=[Collections.Generic.List[object]]::new()
foreach($prefix in @('natural','soft')){
  $rows=if($prefix -eq 'natural'){$natural}else{$soft}
  foreach($s in @('ALL','Q0','Q1','A0','A1','A2','A3','C')){
    $part=@($rows|Where-Object {$_.stage -eq $s});if($part.Count -ne 32){throw 'Incomplete placement stage coverage'}
    $x=Statistics $part.x_span;$y=Statistics $part.y_span
    $spread.Add([pscustomobject]@{variant=$prefix;stage=$s;x_span_mean=$x.mean;x_span_median=$x.median;x_span_max=$x.max;y_span_mean=$y.mean;y_span_median=$y.median;y_span_max=$y.max;cross_clock_region_lanes=@($part|Where-Object {$_.cross_region -eq 1}).Count})
  }
}
$spread|Export-Csv (Join-Path $report 'lane_placement_statistics.csv') -NoTypeInformation -Encoding UTF8
$actual=Import-Csv (Join-Path $report 'soft_pblock_actual.csv')
if($actual.Count -ne 32 -or @($actual|Where-Object {$_.IS_SOFT -ne 1 -or $_.CONTAIN_ROUTING -ne 0}).Count){throw 'Soft properties not verified'}
$totalIn=($actual|ForEach-Object {[int]$_.inside}|Measure-Object -Sum).Sum
$totalOut=($actual|ForEach-Object {[int]$_.outside}|Measure-Object -Sum).Sum
"SOFT_CENSUS cells=$($totalIn+$totalOut) outside=$totalOut outside_percent=$([math]::Round(100*$totalOut/($totalIn+$totalOut),3)) CLB_windows_over70=$(@($actual|Where-Object {(Number $_.actual_CLB_percent) -gt 70}).Count)"
$global|Format-Table variant,WNS,TNS,setup_failed,max_clock_region_CLB_percent
$stats|Where-Object {$_.variant -in @('v2_nopblock_20261014',$Tag)}|Format-Table mode,variant,stage,route_mean,failing_lanes
$hashes=@('file,sha256')
foreach($file in @('deqacc_v2_single_lane_soft.tcl','implement_deqacc_v2_single_lane_soft.tcl',
  'report_deqacc_v2_single_lane_soft.tcl','report_deqacc_v2_lane_internal.tcl',
  'run_deqacc_v2_single_lane_soft.ps1','summarize_deqacc_v2_single_lane_soft.ps1',
  'synth_deqacc_v2.tcl','compare_deqacc_v2_placement.tcl')) {
  $hashes+="$file,$((Get-FileHash -LiteralPath (Join-Path $PSScriptRoot $file) -Algorithm SHA256).Hash)"
}
[IO.File]::WriteAllLines((Join-Path $report 'final_report_scripts_sha256.csv'),$hashes,[Text.Encoding]::UTF8)
'SINGLE_LANE_SOFT_SUMMARY_COMPLETE'
