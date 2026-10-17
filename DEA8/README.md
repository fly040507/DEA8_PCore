# DEA8：当前八核设计与接入入口

更新：2026-10-17。固定 `M=51`，目标U50。**VPU/SFU同学直接阅读 [PCore README](Pcore/README.md)**，字段以当前RTL package为准。

## 1. 当前拓扑

服务器承担pi0其余部分，FPGA目标为Action Expert的18层、10步去噪。DEA8总控理解层/步和八核屏障；PCore只执行外部七种Job，不自行循环18层/10步。

~~~text
                   DEA8 control（真实RTL待接入）
                GCore命令 / 八核Job / 阶段屏障
                              |
       GCore -- XBC/KVB --> PCore x8 <-- HBM适配
         ^                    |
         +-- 每核tx_data256 + valid/ready/last
         |
         +-- K/V按坐标写共享KV，返回KV commit
         +-- O/Down内部四lane八核归约 -> Residual
                     -> BF16写回/统计 -> 后续Norm
~~~

**旧独立reduce已废弃，不接入当前拓扑，也不在PCore外新增外发桥。** K/V是列分片落存，不做数值加法；O/Down才跨核求和。

## 2. 模块分工

| 模块 | 当前职责 | 尚未完成 |
|---|---|---|
| [PCore](Pcore/README.md) | 七Job、共享Matrix、双行MXU、11级DEQACC、Q/O/Z生命周期、VPU/SFU调度、内部外发 | 真实VPU/SFU算术接入 |
| [GCore](Gcore/README.md) | RESID/XHAT/KV、XBC/KVB、四lane归约/Residual、在线gamma Norm、单路真实rsqrt | prefix加载、步间算子、真实八核整层 |
| [control](control/README.md) | DEA8全局命令、层/步与八核同步 | 真实RTL待接入，目前TB发令 |
| [HBM](HBM/README.md) | 地址、权重布局、原始HBM到PCore入口适配 | 目前TB供给已打包数据 |
| [reduce](reduce/README.md) | 历史独立实现 | **废弃，不作为连接目标** |

矩阵顺序为 `K -> V -> Q -> Attention -> O -> G-U -> Down`。非矩阵由Tile提交、数据所有权、单元done触发，可与矩阵重叠，不是整层矩阵结束后统一执行。

## 3. VPU/SFU如何接入

1. 以 `Pcore/rtl/dea8_pcore_control.sv` 为顶层，不绕到Matrix或旧dea8_pcore_ctrl直接拼接。
2. 按pcore_control_pkg接两套独立command/data/done，以及ACC、workspace、RoPE系数接口。
3. `Pcore/tb/tb_pcore_control.sv` 的VPU/SFU并行服务是可执行示例；替换服务，不替换真实Matrix/QOZ/workspace。
4. 两单元各一条命令在途，彼此和Matrix可以并行；token、mask、last、写入可见、done及flush都要遵守。

具体触发、数据和权限见[PCore对接说明](Pcore/README.md)。**DEQACC仍为11级，本轮不做流水缩短。**

## 4. 相对旧GitHub

比较基线：本次推送前远端 `main=e12af5b`，已经逐文件核对，而不是依据旧README日期推断。

- PCore旧KV header/136-bit流与O/Down header/512-bit流，合并为一组256-bit带内header包
- 增加协议版本、payload长度、dtype、scale轴；K/V保留commit，O/Down不增加逐核反向commit
- GCore从占位升级为主体RTL，接收包并承担归约、Residual、Norm、KV与供数
- **未改**PCore的control_job/control_command、VPU/SFU端口、Matrix/MXU/11级DEQACC、Attention/G-U核心调度
- 旧独立Reduce报告不作为当前归约证据；精确PCore文件清单见[差异说明](Pcore/README.md#1-相对旧github的变化)

## 5. 证据与限制

| 证据 | 已确认 | 不代表 |
|---|---|---|
| [PCore七Job摘要](Pcore/reports/packet_7job_summary.txt)、[日志](Pcore/reports/packet_7job_baseline.log) | 新输出、265408矩阵issues、110个Attention子任务、真实Q/O/Z链 | 真实VPU/SFU、HBM或八核整层 |
| [GCore 23场景](Gcore/reports/summary.txt) | 第1/9/18层宏观链路、内部真实rsqrt、归约/Residual、Norm、KV；含真实PCore外发单元到GCore RX测试 | 完整18层循环、实例化八个完整PCore；DEA8总控/HBM和外部PCore运算仍由TB模型 |
| [GCore OOC](Gcore/reports/gcore_synth_summary.txt) | 109 DSP、48229 LUT、17502 FF、152.5 BRAM36、4 URAM，无黑盒 | 4ns布局布线或全芯片资源签核 |

旧25项PCore控制签核是历史证据，新接口以新七Job验收为准。冷Norm9936拍、热Norm6636拍、FP Tile最长314拍来自特定GCore TB，不是全层延迟。

## 6. 运行与依赖

- Vivado 2022.2；PCore需glbl/unisims_ver；[运行步骤](Pcore/README.md#10-运行与验收)
- GCore另需xpm、floating_point_v7_1_15、Python/NumPy；脚本首次生成冻结配置的rsqrt IP，[运行步骤](Gcore/README.md#仿真与证据)
- 使用pcore_all.f及gcore_rtl.f/gcore.f，不递归编译所有历史模块
- 尚无真实DEA8总控、HBM、八核完整单层验收；先替换单核TB算术服务，保留数值/背压/取消检查
