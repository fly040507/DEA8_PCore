param(
  [Parameter(Mandatory=$true)][string]$Wav,
  [Parameter(Mandatory=$true)][string]$Out
)

$source = @"
using System;
using System.Globalization;
using System.IO;
using System.Speech.Recognition;
using System.Text;
using System.Threading;

public static class CnSpeech {
  public static void Run(string wav, string output) {
    var done = new ManualResetEvent(false);
    var sb = new StringBuilder();
    using (var engine = new SpeechRecognitionEngine(new CultureInfo("zh-CN"))) {
      engine.LoadGrammar(new DictationGrammar());
      engine.SpeechRecognized += (sender, e) => {
        if (e.Result != null && e.Result.Confidence >= 0.05f && !String.IsNullOrWhiteSpace(e.Result.Text)) {
          lock(sb) { sb.AppendLine(e.Result.Text); }
        }
      };
      engine.RecognizeCompleted += (sender, e) => done.Set();
      engine.SetInputToWaveFile(wav);
      engine.RecognizeAsync(RecognizeMode.Multiple);
      done.WaitOne();
    }
    File.WriteAllText(output, sb.ToString(), new UTF8Encoding(false));
  }
}
"@
Add-Type -AssemblyName System.Speech
$speechAssembly = [System.Speech.Recognition.SpeechRecognitionEngine].Assembly.Location
Add-Type -TypeDefinition $source -ReferencedAssemblies $speechAssembly
[CnSpeech]::Run((Resolve-Path -LiteralPath $Wav).Path, (Join-Path (Get-Location) $Out))
Get-Content -LiteralPath $Out -Encoding UTF8
