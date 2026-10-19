# VPU/SFU来源与当前实现

导入来源：[kayuenhuang/DEA8_VPU](https://github.com/kayuenhuang/DEA8_VPU)，冻结commit `dfe54efcdd704c0afd6f891099fc40239e774a02`。本地只读审查记录见 `../reports/VPU_SFU_review_20261018.md`。

当前 `units/vpu`、`units/sfu` 是工程内生产源码，不依赖 `.review` 或联网克隆。保留上游文件中已有署名/来源信息。检查的上游快照未发现独立LICENSE，**不自行添加MIT/Apache授权，也不宣称已取得对外再许可**；对外发布需由项目确认授权。本轮未上传GitHub。

## 本轮主要改动

- FP32加/减/乘/exp/reciprocal改官方IP，latency统一由生成配置包派生
- VPU共享32MUL和32ADD；RoPE复用P行和树；QK采用压缩Mask及空block保护
- 宽Score只存一次URAM，不再随13级QK元数据复制；结果RAM同步预取、CE与tag对齐
- SFU连续读/发射/回收；exp4、交错GELU双链、单物理倒数共享
- SFU/VPU对齐payload及结果FIFO用BRAM；只保留必要小cache/valid/tag寄存器
- 正式Mask/RoPE配置、内部访存/命令、flush/错误由 `dea8_pcore_top` 连接，不由最终TB代答

生产文件由 `../pcore_rtl.f` 显式列出；目录中未列入清单的上游辅助文件不是生产算术实例。编译和快照hash见 `../reports/compute`。商业IP由Vivado2022.2 Tcl重新生成，不将生成产品视为上游开源代码。
