# DEA8 PCore

本目录是当前 DEA8 单核 PCore 设计，保留投影、Attention、G-U 三类矩阵路径，并由 `dea8_pcore_control` 统一接收和执行七种矩阵 Job。旧版单 INT8 设计仍在根目录 `pcore`，与本目录互不覆盖。

## 结构

- `rtl/`：PCore 控制中心、Job adapter、矩阵数据通路、MXU、DEQACC、QOZ、K/V 外发。
- `tb/`：矩阵、Attention、G-U、QOZ、协议和七 Job 仿真。
- `docs/`：PCore 控制和输出接口说明。
- `reports/`：保留的当前验证证据；仿真缓存不作为工程文件。

PCore 不实现 SFU/VPU 内部算术、DEA8 总控、真实 HBM 控制器和八核 Reduce。SFU/VPU 通过 command/data/done 接口接入，Reduce 接收 PCore 的 FP32 输出，K/V 通过 PCore 内部 Tile sender 直接外发。

## 七种 Job

```text
K projection -> V projection -> Q projection -> Attention
-> O projection -> G-U -> Down projection
```

三类矩阵实现共享 `dea8_matrix`：

- Projection：XBC/HBM 提供 A/B，结果进入相应后处理或外发路径。
- Attention：QOZ/KVB 提供 A/B，控制中心负责 55 个 QK 与 55 个 PV block 的调度。
- G-U：XBC/HBM 提供 Gate/Up 的矩阵输入，SFU/VPU 后处理接口由 PCore 保留。

## 仿真

在本目录执行：

```powershell
Set-Location C:\Users\fly04\Desktop\VLA\DEA8\Pcore
.\run_pcore_xsim.ps1
```

脚本使用 Vivado 2022.2，并同时检查编译/展开返回码、Fatal/Error 文本和每个 TB 的 `PASS` 标记。当前只代表行为级仿真，不代表综合、布局布线或 250 MHz 时序签核。
