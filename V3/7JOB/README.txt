V3/7JOB 修正版
================

把本目录中的两个文件直接覆盖到：

C:\Users\fly04\Desktop\VLA\V3\7JOB\

覆盖：
- make_perf_tb.ps1
- run_perf_7job.ps1

正确版 make_perf_tb.ps1 开头应该包含：

$V3Root = Split-Path -Parent $SevenJobRoot
$srcPath = Join-Path $V3Root 'tb\tb_v3_pcore_control_v3.sv'

先检查：
Test-Path ..\tb\tb_v3_pcore_control_v3.sv

返回 True 后运行：
powershell -ExecutionPolicy Bypass -File .\run_perf_7job.ps1 -AttentionOnly
