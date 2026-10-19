# RoPE 修复前的单核综合记录

2026-10-19首轮 `dea8_pcore_top` OOC综合：104642 LUT、102358 FF、500 DSP、110 RAMB36E2 + 11 RAMB18E2（115.5 BRAM36等效）、51 URAM。

该轮**不作为完整 PCore 面积结论**：RoPE系数初始化的数组搬运被Vivado忽略，`coefficients`无驱动，RoPE ROM被裁掉。独立复现见 `../rope_before.log`，包括 `Synth 8-311` 和无BRAM的失败检查。

首轮输入manifest SHA256：`2e22dce76f0a66b632d8087939506ea3c235b80f2753d15b6faabdf3e0bc6cf3`。本目录后续原始报告将由修复后同口径综合更新；修复前数值仅供比较缺失存储的影响。
