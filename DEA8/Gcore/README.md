# DEA8 GCore

更新：2026-10-17。固定 `M=51`、hidden=1024、8 PCore，目标 U50。

当前实现依据 [整体方案](GCore_Overall_Plan.md) 和 [接收/归约方案](GCore_Reduce_Plan.md)：**8类宏观Job、γ后台预取、内部4-lane归约/残差、Tile平方统计、单路真实rsqrt、8-lane B16量化及末层FP32输出**。每核一条256-bit包链路；独立Reduce不在当前GCore构建中。本轮未修改PCore。

本轮 **23个功能仿真场景全部通过**，运行前后源码/参考数据SHA256一致，见 [summary.txt](reports/summary.txt) 与 [源码清单](reports/sources_sha256.csv)。2026-10-16的U50 OOC为109 DSP、无黑盒，**不包含本轮新增宏观控制，不能作为当前源码的新综合结果**。未进行4ns布局布线时序签核。

## 数据路径

```text
8 × PCore.tx_data256 + valid/ready/last
  -> 每核带内header解析 + 共用256×4 FIFO
     K/V -> 按坐标写KV RAM -> KV commit
     O/Down -> 4路八输入FP32树 -> 4路残差加法
       -> BF16 RNE -> RESID RAM
       -> 本Tile 51行平方 -> SUM8 / SUM64 / SQ_ACC
       -> 当前Tile退休，允许下一header

NORM:
  无匹配统计时扫描RESID，否则复用SQ_ACC
  -> sq/1024+epsilon -> 单路rsqrt -> INV[51]
  -> RESID*inv -> H反馈FIFO -> H*gamma
  -> Y FIFO -> 8-lane量化（两半共用一个B16 scale）
  -> XHAT四bank -> XBC广播
  -> 第18层DOWN改为FP32向量流，不再量化/写下一层XHAT

共享KV RAM -> KVB -> 八核Attention供数（110子任务）
```

- 加法、乘法、统计均FP32；残差写回BF16时RNE一次
- 统计使用实际写入的BF16值；相邻四个N-Tile形成SUM64，再跨16组累加
- NORM执行两次FP32乘法，不再默认γ折叠进权重；FP32的Y直接量化，不额外做BF16输出舍入
- O/Down不缓存完整FP32结果Tile，不保存八核输入Tile副本
- 四棵SUM8树分时用于归约、平方和与SUM64；16个乘法器分时用于平方及归一化
- 每Tile先完成归约/残差写回，再扫描51行统计；不是边修改同址残差边扫描

## 顶层与文件入口

| 文件 | 职责 |
|---|---|
| [dea8_gcore.sv](rtl/dea8_gcore.sv) | 公开顶层；默认在GCore内部接入单路真实rsqrt |
| [dea8_gcore_services.sv](rtl/dea8_gcore_services.sv) | 局部控制、RAM、接收、计算、XBC和KVB的连接 |
| [gcore_pkg.sv](rtl/gcore_pkg.sv) | 命令192、完成128、γ加载92、rsqrt包110等类型 |
| [dea8_gcore_control.sv](rtl/dea8_gcore_control.sv) | 服务互斥、对象/版本、完成仲裁、KV引用和取消 |
| [dea8_gcore_jobs.sv](rtl/dea8_gcore_jobs.sv) | 8类宏观Job展开、O后台槽、XHAT用途/版本和换层承接 |
| [dea8_gcore_gamma_fetch.sv](rtl/dea8_gcore_gamma_fetch.sv) | 单HBM参数请求、两组串行加载、slot/index及长度检查 |
| [dea8_gcore_packet_rx.sv](rtl/dea8_gcore_packet_rx.sv) | 八路共线解析、每核256×4 FIFO、计数、背压与退休 |
| [dea8_gcore_compute.sv](rtl/dea8_gcore_compute.sv) | 四lane归约/残差、Tile统计、冷/热Norm及乘法复用调度 |
| [dea8_gcore_tree8.sv](rtl/dea8_gcore_tree8.sv) | 固定三级、七个FPADD的八输入树 |
| [dea8_gcore_gamma.sv](rtl/dea8_gcore_gamma.sv) | 2048×32参数RAM，两组γ的身份与完整性 |
| [dea8_gcore_quant8.sv](rtl/dea8_gcore_quant8.sv) | 全16元素MAX、共享scale、两拍8-lane量化、背压保持 |
| [dea8_gcore_rsqrt.sv](rtl/dea8_gcore_rsqrt.sv) | 单路真实FP32 IP、正规化、信用、响应FIFO |
| `dea8_gcore_residual_store/activation_store/stat_ram.sv` | RESID、XHAT、SQ_ACC/INV同步RAM |
| `dea8_gcore_kv_receive/kv_store/kvb.sv` | KV按坐标存储、写入确认和完整KVB重放 |
| [gcore_rtl.f](gcore_rtl.f) / [gcore.f](gcore.f) | 当前生产RTL清单 / 当前回归清单 |

旧 `vector/norm/shared_compute/reduce_sink` 源码及其旧TB暂作历史对照，不在这两份清单的当前功能链路中。旧16-lane量化模块只加入算术叶单测，不进入生产顶层。不要将旧TB直接套用到新接口。

## 接入约定

### DEA8命令与数据对象

DEA8总控理解层号、去噪步数和七种PCore Job；GCore不发布PCore Job，也不自行展开18层或10步。

DEA8到GCore优先使用宏观接口。初始化：预置RESID/prefix、`config`、`preloaded`、`layer`，每项等完成握手；首层`START`完成后再按K/V/Q/ATTENTION/O/GU/DOWN推进。

| Job | 内部展开与完成条件 |
|---|---|
| START | 加载本层两组γ → 初始Attention Norm → XHAT完整 |
| K / V | 先准备KV接收，再XBC；等待两者都完成 |
| Q | XBC全部被八核接受 |
| ATTENTION | 完整110子任务KVB全部被八核接受；仍保留KV lease |
| O | 归约/残差/统计 → FFN Norm → 下一组γ后台加载；γ事务完成才done |
| GU | FFN XHAT有效后即可XBC，不必等O后台γ完成 |
| DOWN | 归约/残差/统计 → 等γ → 下一层热Norm；末层改为final norm和FP32输出 |

`xhat_status`为带用途、层号和对象版本的持久状态。O的FFN XHAT先就绪，之后O和GU可以同时在途；完成通道有两个有界槽，独立保留身份。错误阶段的job明确拒绝，不越阶段启动。O启动前必须由DEA8确认Attention已结束并释放KV lease。

换层使用`layer`，只在上一层本地阶段结束后接受；保留RESID、SQ_ACC及XHAT，失效旧suffix K/V，登记调用方已经预置的新prefix。`context_id/generation`保持为同一数据代次；下一层γ ID必须对应上一层预取的两组ID。末层不请求第19层参数。

原服务级命令继续保留，供管理和兼容测试。宏观Job期间外部服务命令与原始γ加载不接受；取消时只接管宏观Job自己的完成，不吞掉旧服务级调用者的完成响应。

- 配置context后登记预置RESID/prefix对象；本阶段默认数据已在RAM中，没有prefix DMA/接收协议
- `GC_IMPORT_RESID`可重新导入3264个BF256字；`GC_PREFIX_LOAD`在实际顶层明确拒绝
- `GC_NORM`选择源RESID、目标XHAT、epsilon及`norm_param_id`
- `GC_XBC_RUN`选择K/V/Q/G-U重放；G-U的n>0仍等八核prefetch许可
- `GC_KV_RX`授权本次K或V接收；header必须匹配活动context的transfer身份和列映射
- `GC_KVB_RUN`输出完整55 QK+55 PV对应B流，结束后仍需DEA8显式释放KV lease
- `GC_RESIDUAL_APPLY`选择O或Down；源RESID版本完整、64个Tile归约/写回/统计结束后才发布新对象

服务可在资源不冲突时并行；NORM与RESIDUAL共用计算后端、互斥。完成保持到上层握手；服务局部done不等于上层已退休。

### 每核256-bit包

| 项目 | K | V | O/Down |
|---|---|---|---|
| header | 低128有效，高128为0 | 同左 | 同左 |
| payload数 | 51 | 64 | 102 |
| 有效载荷 | data128+scale8，高120为0 | 同左 | FP32×8 |
| 布局 | FEATURE_B16 | TOKEN_B16，尾组仅3 token有效 | 每行先低8列、再高8列 |
| 结束 | 最后payload的last=1 | 同左 | 第102个payload的last=1 |
| 退休屏障 | KV实际落RAM后的commit | 同左 | 本Tile归约、残差写回及统计完成 |

八条链路独立握手，不是八核争用一条256-bit线。FP32一个FIFO head分低/高128位发射两次，第二次接受后共同pop；K/V每word独立消费，不等八核齐到。每核只有一份活动header，不能与下一Tile混排。

完整字段及K/V列映射见方案第3节和 [dea8_tile_link_pkg.sv](../Pcore/rtl/dea8_tile_link_pkg.sv)。协议版本字段只是线协议标识，不是设计版本改名。

### 在线γ与rsqrt

`gamma_load_valid/ready`传输92-bit `gamma_load_t`：context16、generation16、param_id16、slot1、index10、FP32 value32、last1。每组按index=0..1023加载，最后一项才置有效并返回done；同context/generation中两个slot不允许重复param_id。

宏观Job不要求DEA8逐项生成上述元数据，而使用`gamma_fetch_valid/ready`请求和`gamma_data_valid/ready`返回。请求绑定token/context/generation/目标层/参数ID；HBM只需返回token+FP32值+整笔last。普通事务2048项、final事务1024项，GCore生成slot/index及每组last。O的FFN Norm结束后释放缓存有效位，不清RAM；加载可与GU XBC和Down归约重叠，不能覆盖正在Norm读取的γ。

接口字段、位宽及首层/中间层输入约定见 [整体方案第17节](GCore_Overall_Plan.md#17-宏观控制的实际接口)。`final_data`每拍16个FP32，按`index=n_tile*51+row`发送，lane i对应全局列`16*n_tile+i`；共3264拍有效负载。最后一拍实际握手才完成末层DOWN。

`norm_param_id`选择完整且匹配context/generation的参数组。参数变更使用新身份或重新加载；不得在Norm读取期间覆盖，归约/残差阶段不占用γ读端口。加载值是实际乘数，模型参数导出端负责生成γ，GCore不自动再加1。RAM每拍预取一个γ，当前/下一16列缓存供51行复用；H反馈同时保留对应γ，防止预取覆盖错配。

默认 `INTERNAL_RSQRT=1`：真实IP在GCore内，外部rsqrt输入忽略，request仅供观察。`INTERNAL_RSQRT=0`只用于外部服务/错误响应注入。110-bit包编码保留，但当前每行一个请求：mask=01、row0=0..50、row1=row0+1、高32数据为0。不是原双通道26包方案。

### 故障与取消

非法包、身份/长度错误、非有限值和统计错误不能静默通过。故障后禁止继续写RESID/XHAT并失效统计；局部结果不能发布为完整对象。取消必须等待本地及外部flush ack，清理在途valid和对象/context后才能重新配置。不能把部分已加过残差的RAM当成原版本直接重跑，需恢复/重新登记合法输入。

## 仿真与证据

### 从仓库重建依赖

仓库保留 `ip/create_rsqrt.tcl`、冻结的 `gcore_rsqrt_ip.xci` 和配置文本；不上传可生成的厂商HDL、仿真缓存、checkpoint或cmodel压缩包。首次运行下述脚本会生成IP。需要Python/NumPy；不使用本机默认Python路径时传 `-Python python` 或自己的解释器绝对路径。

直接使用 `gcore.f` 前，先在本目录运行Vivado 2022.2 batch脚本 `ip/create_rsqrt.tcl`。若复现OOC，还需先运行 `check_dsp_budget.tcl` 生成rsqrt DCP，再运行 `check_gcore_synth.tcl`；不要将缺失可生成DCP误判为设计黑盒已经验收。所有工具都先加载对应Vivado的 `settings64.bat`。

`reports/sources_sha256.csv`是原验证快照；IP生成产物的hash需在生成后核对，不能把全新机器的绝对路径和旧机器路径机械拼接。真实PCore接线和相对GitHub变化见[PCore README](../Pcore/README.md)。

```powershell
cd C:\Users\fly04\Desktop\VLA\DEA8\Gcore
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\run_gcore_xsim.ps1
# 单项：-Test integrated / packet / frontend / rsqrt 等
```

脚本使用Vivado 2022.2官方环境，检查工具退出码、Fatal/Error和PASS；运行前后核对源文件与golden的SHA256。新golden由 [generate_rework_vectors.py](tb/generate_rework_vectors.py) 使用NumPy生成，包含两组非平凡γ、正负八核贡献、BF16舍入及固定SUM8/SUM64顺序。

| 测试 | 覆盖 |
|---|---|
| types / stores / xbc / control | 位宽、完整RAM读写、K/V/Q/G-U重放、七服务路由、对象和取消 |
| arithmetic | 各4096 FPADD/FPMUL、2048 BF16、256量化golden及暂停 |
| kv | KV错包、最终写入屏障、存储边界、KVB信用及错误tag |
| rsqrt | 8192正FP32含非正规数、1ULP界、背压与在途flush |
| frontend | 新8-lane量化256向量、输出保持、γ完整/重复/乱序/NaN |
| packet | 深度4、稳定head、7种非法包、KV commit屏障 |
| pcore_link | 真实PCore外发→真实GCore RX：K/V各2Tile、O/Down各64Tile、13418个包beat、6528个FP32行，8537个TX停顿周期 |
| integrated | 真实内部rsqrt、3次Norm、O/Down各64Tile、9792量化块、6528残差字、32 KV commit、110 KVB子任务 |
| integrated附加 | 断供/背压、错header、错last、活动中取消、无迟到写入；错误清理后恢复输入并重新计算完整Norm |
| gamma_fetch | 实际γ缓存参与：双组/末组事务、请求/完成保持、错token/last、NaN、重复ID、部分加载取消及重载，12项检查 |
| layers | 第1/9/18层完整宏观链路；第9/18层独立背压；跨层热统计承接；START取消、Down期间γ故障及真实冷Norm重启 |

无人工断供时：冷Norm9936拍，热Norm6636拍；单个O/Down Tile从header到统计退休最多314拍，小于416拍参考矩阵窗口。不是将整个64Tile服务的总耗时认作314拍，也不是250MHz时序实测。

数值与周期以本次日志为准，不引用旧body日志代替。PCore边界流、DEA8命令、X/prefix预置仍由TB提供；不代表真实八核单层推理或模型精度已验收。

代表层为三个独立场景，不伪造跳过的模型层。中间/末层初始XHAT也由真实Norm计算，不从golden直接写入。所有RESID写回、量化块、XBC数据、八核KVB及rsqrt输入均与独立NumPy参考核对；末层52224个FP32按3ULP传播界核对，身份、索引和last严格相等。日志`total_macro_cycles`只表示该TB供数/背压条件下的GCore本地链路，不是八个真实PCore的模型层延迟。

后台γ故障场景刻意延迟HBM，让Down归约先开始，再注入错token。检查O/Down均不报成功、无迟到写回、统计失效；flush后恢复已部分覆盖的RESID，再通过START重新计算完整冷Norm。不是仅清error标志就复用混合新旧版本的残差。

2026-10-17代表层普通场景结果：

| 层场景 | GCore本地宏观链路拍数 | 宏观γ负载（不含输入准备） | 末层FP32向量 |
|---|---:|---:|---:|
| 第1层，含START | 161941 | 4096项，第1、2层各两组 | 0 |
| 第9层，不含输入准备Norm | 149945 | 2048项，第10层两组 | 0 |
| 第18层，不含输入准备Norm | 149939 | 1024项，final γ | 3264 |

这些拍数包含TB设置的O每Tile416拍、Down每Tile832拍及相应握手，不是完整真实PCore层延迟。首层FFN XHAT在周期75975就绪，GU在75977启动，O的γ事务在78230才完成，验证了提前供数和后台加载重叠。第1层另一次普通换层后，热Norm服务为6636拍，没有多出冷扫描。末层未请求第19层参数，也未生成下一层量化XHAT。

集成测试的三次Norm分别检查冷启动、O后统计复用、Down后统计复用；不是把单层定义为三次RMSNorm。配套[真实PCore七Job回归](../Pcore/reports/packet_7job_summary.txt)也已通过：265408 issues、110 Attention子任务、Q/O/Z链及外发检查；VPU/SFU/HBM和GCore返回仍是TB模型，不与本体八路数值测试混称为真实八核单层。

## 历史资源与下一步

2026-10-16，Vivado 2022.2、`xcu50-fsvh2104-2-e`，默认内部真实rsqrt、本体包含Reduce：

| 资源 | 2026-10-16修改前OOC | 占U50 |
|---|---:|---:|
| LUT | 48,229 | 5.53% |
| FF | 17,502 | 1.00% |
| DSP48E2 | 109 | 1.83% |
| BRAM36等效 | 152.5（152 RAMB36+1 RAMB18） | 11.35% |
| URAM | 4 | 0.63% |

109 DSP分配：四树56＋残差8＋行累加2＋epsilon2＋16乘法32＋单rsqrt9，实际综合吻合。大RAM：KV128 BRAM36、XHAT16、γ2、SQ/INV各1；SUM8前三个Tile共六项使用3 BRAM36，第四个Tile的两项流水旁路给SUM64，无需第四个物理bank；rsqrt响应队列1.5 BRAM36。RESID为4 URAM。浅FIFO及乘法反馈仍使用LUTRAM/寄存器，不声称全部存储都是BRAM。

证据：[综合摘要](reports/gcore_synth_summary.txt)、[资源总表](reports/gcore_utilization_summary.rpt)、[层次表](reports/gcore_utilization.rpt)、[综合源码hash](reports/gcore_synth_sources_sha256.csv)。0 error、0 critical warning，存在333条普通警告，含未用端口/位及常量传播；未声称无警告。这里是OOC资源结果，没有placement/routing，也没有250MHz时序通过结论。

### RX深度比较

单独对八路包接收前端做U50 OOC，见 [深度4](reports/rx_depth_4.rpt)、[深度8](reports/rx_depth_8.rpt)，脚本为 `check_rx_depth.tcl`。

| RX深度 | LUT总量 | 其中LUTRAM | FF | BRAM / DSP |
|---|---:|---:|---:|---:|
| 4 | 2791 | 1184 | 241 | 0 / 0 |
| 8 | 2815 | 1184 | 265 | 0 / 0 |

两个深度映射到相同粒度LUTRAM，因此容量翻倍不等于LUTRAM翻倍；深度8仍多出控制资源。默认保留已通过完整功能/隐藏验证的4深，未将单独RX的深度8综合当成完整GCore深度8验证。由于层次重建，RX数据RAM可能归入父层级，不能只读 `packet_receiver` 行就判断FIFO没有物理RAM。

109 DSP报告及 `.sim/gcore_synth.dcp`保留为修改前证据，综合hash独立保存；不能与本轮仿真hash混用。本阶段只仿真，不重新综合。下一步为真实DEA8控制/HBM适配、换层prefix装载、八核联调及新RTL的资源/4ns实现验证；action projection和步间更新不由本轮GCore宏观Job自动覆盖。
