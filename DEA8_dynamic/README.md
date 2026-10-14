# DEA8 Dynamic

动态 M 重构工程。当前基线：compact row、三行 A 加载、512-bit B 输入与四拍驻留装载、双行 MXU、七级 DEQACC；保留七种外部 Job和三种矩阵模式。

所有修改仅在本目录。既有 `DEA8/` 和独立 `DEQACC/` 只读，不覆盖原设计。

## 当前进度

- 动态 MXU / PE / DEQACC及真实A/B加载基础已实现：Profile、row3 RAM、三槽A queue、双PC配对、八槽B queue接入计算链路。
- 2026-10-14新源码7项常规仿真与3项RAW负例通过；加载前端覆盖M=0..51、17424笔Psum/FP32提交。证据入口在PCore README。
- QOZ/PBUF管理、local loader、完整profile/owner生命周期、最终HBM/KVB协议适配仍待接入。
- 七Job、完整Attention/G-U、内部外发和动态Reduce仍待实现/联调；VPU/SFU只留接口，真实算术不属于本工程当前实现范围。
- 没有新综合或布局布线签核。仿真4ns时钟不证明250MHz物理时序。

旧动态尝试中的2-beat B加载、original row_id贯穿算术和相关foundation说明不再是当前基线；本目录现存源码/证据以PCore入口为准。

## 设计入口

| 文档 | 内容 |
|---|---|
| [PCore整体重构方案V1](C:/Users/fly04/Desktop/VLA/DEA8_dynamic/Pcore/PCore整体重构方案_V1.md) | 七Job/三mode、剩余模块、后处理触发、完成屏障、资源和接口 |
| [A侧加载V1](C:/Users/fly04/Desktop/VLA/DEA8_dynamic/Pcore/A侧矩阵加载方案_V1.md) | 三行输入、3-slot A queue、QOZ/PBUF三row bank |
| [B侧加载V1](C:/Users/fly04/Desktop/VLA/DEA8_dynamic/Pcore/B侧矩阵加载方案_V1.md) | HBM双PC、KVB512、8-slot B queue、四列/拍装载 |
| [Attention调度V1](C:/Users/fly04/Desktop/VLA/DEA8_dynamic/Pcore/Attention调度方案_V1.md) | 110子Job、动态Block间隔、SCALE隐藏和尾部 |
| [PCore实现与验证](C:/Users/fly04/Desktop/VLA/DEA8_dynamic/Pcore/README.md) | 现存RTL、计算合同、仿真证据和未完成事项 |
| [老设计复用分析](C:/Users/fly04/Desktop/VLA/DEA8_dynamic/Pcore/老设计复用方案_V1.md) | 旧DEA8模块调查；不等于逐文件复制要求 |

## 动态行语义

`A[M,16]×B[16,16]`，M=0..51。K/V projection固定51行，其余五种Job使用M。

算术、存储和传输使用 compact row `0..M-1`。原始行序只在profile控制上下文、RoPE/mask服务和接收端映射中解释；不随每个PE/流水结果携带原始row_id。

同一profile可以由DEA8跨18层复用，但PCore只处理外部Job，不理解层数和十步去噪循环。profile在相关存储/输出仍存活时不能改写。

完整系统目标与旧DEA8能力对齐，不把旧仿真日志当成dynamic验证结果。

