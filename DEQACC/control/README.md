# DEA8 Control

这里放置 DEA8 总控。总控负责十步去噪、18 层执行、各核 Job 分发、跨核完成汇总以及与服务器侧 pi0 的边界协议。

PCore 内部控制位于 `DEA8\Pcore`，本目录只保留 DEA8 级控制边界，不与 PCore 内部控制混用。
