param(
  [Parameter(Mandatory=$true)][string]$Wav,
  [Parameter(Mandatory=$true)][string]$Out
)

Add-Type -AssemblyName System.Speech
$engine = New-Object System.Speech.Recognition.SpeechRecognitionEngine('MS-2052-80-DESK')
$engine.LoadGrammar((New-Object System.Speech.Recognition.DictationGrammar))
$records = New-Object System.Collections.Generic.List[string]
$done = New-Object System.Threading.ManualResetEvent($false)
$engine.add_SpeechRecognized({
  param($sender, $e)
  if ($null -ne $e.Result -and $e.Result.Confidence -ge 0.08 -and -not [String]::IsNullOrWhiteSpace($e.Result.Text)) {
    $records.Add(('{0:F2}`t{1:F2}`t{2}' -f $e.Result.Audio.AudioPosition.TotalSeconds, $e.Result.Confidence, $e.Result.Text))
  }
})
$engine.add_RecognizeCompleted({ $done.Set() | Out-Null })
$engine.SetInputToWaveFile((Resolve-Path -LiteralPath $Wav).Path)
$engine.RecognizeAsync([System.Speech.Recognition.RecognizeMode]::Multiple)
$done.WaitOne()
$engine.Dispose()
$records | Set-Content -LiteralPath $Out -Encoding UTF8
Get-Content -LiteralPath $Out -Encoding UTF8
