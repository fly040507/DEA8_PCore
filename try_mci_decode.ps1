$src = @"
using System;
using System.Runtime.InteropServices;
public static class Mci {
  [DllImport("winmm.dll", CharSet=CharSet.Unicode)]
  public static extern int mciSendString(string command, System.Text.StringBuilder ret, int retLen, IntPtr callback);
}
"@
Add-Type -TypeDefinition $src
$in = 'C:\Users\fly04\Desktop\VLA\.tmp\std12.mp3'
$out = 'C:\Users\fly04\Desktop\VLA\.tmp\std12.wav'
$sb = New-Object System.Text.StringBuilder 512
foreach($cmd in @(
  "open `"$in`" type mpegvideo alias song",
  "set song time format ms",
  "save song `"$out`"",
  "close song"
)) {
  $err=[Mci]::mciSendString($cmd,$sb,$sb.Capacity,[IntPtr]::Zero)
  Write-Output "$err $cmd $($sb.ToString())"
  $sb.Clear() | Out-Null
}
if(Test-Path -LiteralPath $out){ Get-Item -LiteralPath $out | Select-Object FullName,Length }
