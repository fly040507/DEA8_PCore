# PCore无代价优化结果

日期：2026-10-23。**本轮已完成；当前RTL已通过完整七Job。**

## 1. 最终结果

按“下一步方案”及本轮补充要求执行：覆盖全部既定无代价候选，以不新增DSP/BRAM、保持流水/发射速率、总周期不明显增加为原则；不强求系统LUT降到70%。

| 指标 | 优化前基线 | 最终版本 | 变化 |
|---|---:|---:|---:|
| 单PCore LUT | 116270 | **104422** | **−11848，−10.19%** |
| FF | 142773 | 142551 | −222 |
| DSP | 398 | 398 | 0 |
| BRAM36等效 | 71.5 | 71.5 | 0 |
| URAM | 40 | 40 | 0 |
| 七Job总周期 | 285942 | **285942** | **0** |

不仅总周期相同，七个Job和记录的非矩阵命令最大时长也逐项相同。LUT收益来自全核综合，不是若干模块预算之和。

## 2. 各项处理情况

全部改动位于`DEA8_VPU/`；11个RTL文件、2个定向TB。生产filelist、runner、gold与官方IP配置保持。

| 候选 | 已完成的修改/判断 | 保留情况 |
|---|---|---|
| SFU固定切片 | packet双slot固定128bit目的写入；scalar固定32bit写入；4-lane/1-lane模式分开选择窄元素 | 保留；整核撤回消融确认有净收益 |
| VPU固定lane/chunk | hist/factor改奇偶pair银行；量化metadata固定目的槽；保留原chunk统计写回、AA51项和既有共享统计存储 | 保留；不新增缓存或端口等待 |
| 前台遗留路径清理 | 根据shared wrapper入口与状态转移，移除旧串行AREQ/CALC/AW/RESULT等路径；OACC_SCALE仍由独立后台执行 | 保留；错误排空、RoPE与GU路径保留 |
| 后台scale访问 | α按奇偶银行读取，pair计数器代替`mul_issued%26`，随乘法地址一同延迟row mask | 保留；新增内部对齐断言，scale命令仍970拍 |
| 控制/宽服务MUX | Matrix请求用共享owner译码；已路由的M2V写A/读B不再二次选择宽payload；写回flag使用统一行mask做重复检查和置位 | 保留；错误/身份检查完整，取消重启通过 |
| Workspace无BRAM版本 | object/chunk的20项窄译码共享到各lane，替代双读口反复动态访问FF对象；响应/valid/容量保持 | 保留；不实施TDP BRAM方案 |
| V转置静态FF窗口 | 保持16×16 FP32窗口，按列地址并行取双列，不再整个窗口右移64bit | 保留；V Job仍3731拍，token轴gold全通过 |
| QK MAX外围 | 浮点有序键在叶节点编码，树内比较键，出口解码；保留signed-zero、NaN/+Inf、−Inf、empty/initial策略及官方SUB | 保留；新增独立数值oracle与特殊行检查 |
| DEQACC/ACC外围 | INT20最高位改平衡priority tree；FACC/raw/scaled valid改固定目的位，保持页失效/写入/消费优先级 | 保留；精确RNE/16拍验证、OACC复用通过 |

复核后无需再改的部分：

- DEQACC现有`pack_partial`本来已经是有界guard/sticky移位，未把通用包中的未实例化函数误当成本；不改FP规则
- `updated_stat`的QK/P复用已存在，不把它重复记作本轮新收益；`saved_ram`继续复用M2V slots2/3，不再另造缓存
- 原ACC响应FIFO仅约40 LUT，保持4×1024bit与真实出口valid，不为了省FF改成BRAM
- Workspace/V转置BRAM版、48DSP整数树属于资源交换路线，不在本轮无代价实施范围

## 3. 实测收益如何判断

### 综合批次

| 批次 | LUT | 说明 |
|---|---:|---|
| 已有基线 | 116270 | `pcore_banked_20261023`，按用户要求直接沿用 |
| 首批候选r1 | 106308 | 无新增资源的结构修改 |
| **最终r2** | **104422** | 增加统一写回mask，较r1再降1886 |
| 仅撤回SFU候选 | 106415 | 较最终版增加1993，恢复并保留SFU修改 |
| 仅撤回ACC valid候选 | 104597 | 较最终版增加175，恢复并保留ACC修改 |

- 除SFU/ACC两组撤回消融外，其余候选按组合批次测量，未宣称每个局部修改有独立净收益数字
- 两份消融均未优于最终版；最终源码已恢复到原r2/七Job清单的完全相同字节，校验通过
- `pcore_nocost_baseline`是用户叫停的未完成尝试，无PASS；没有用它替换已有可信基线

### 为什么不能按层次下降量相加

| 顶层子树 | 基线LUT | 最终LUT | 差额 |
|---|---:|---:|---:|
| control | 69293 | 55761 | −13532 |
| vpu | 34517 | 34988 | +471 |
| sfu | 12307 | 13543 | +1236 |
| Mask＋顶层 | 153 | 130 | −23 |
| **全核** | **116270** | **104422** | **−11848** |

新综合网表确认`ctrl`下存在`capture_gate/bypass_q`等其他源模块的逻辑，SFU/VPU下也吸收workspace相关逻辑。`ctrl`9195→4494不是小FSM独立省4701；SFU子树变大，也不代表SFU修改负收益——撤回后全核反而多1993。唯一确定的总收益为11848 LUT。

## 4. 正确性与周期

### 完整七Job

| Job | 基线周期 | 当前周期 | 增量 |
|---|---:|---:|---:|
| K | 4268 | 4268 | 0 |
| V | 3731 | 3731 | 0 |
| Q | 27850 | 27850 | 0 |
| Attention | 54513 | 54513 | 0 |
| O | 28829 | 28829 | 0 |
| G-U | 111298 | 111298 | 0 |
| Down | 55453 | 55453 | 0 |
| **合计** | **285942** | **285942** | **0** |

- 55 QK/55 PV、265408 Matrix issues、6299量化、157743 FP检查均通过
- 命令最大时长保持：QK_POST91、ALPHA_EXP53、P_EXP295、P_POST360、OACC_SCALE970、RECIP99、AFIN1529、GELU2261拍
- 无DUT内部TB算术代算；gold/检查容差没有放宽；标准完整七Job不等于额外STRESS

### 12项定向/邻接回归

| 测试 | 关键覆盖 | 结果 |
|---|---|---|
| `tb_compute_sfu_shared` | 4命令、816 P＋816 GELU、真实workspace/背压、100个GU向量共享MUL并发 | PASS |
| `tb_qk_max_order`（新增） | 256pair，独立shortreal比较oracle；±0、subnormal、非法数、mask、背压、身份 | PASS |
| `tb_deq_format_nocost`（新增） | 384pair/12288lane，独立整数商余数RNE；INT20边界、subnormal/overflow/bad scale、gap、16拍 | PASS |
| `tb_p_history_shared` | 51row，old_l16、α0.5、sumP16→24 | PASS |
| `tb_p_stream_shared` | EXP group与P pair重叠、共享ADD | PASS |
| `tb_gu_m2v` | 51row、M2V读写、背压、row50 | PASS |
| `tb_oacc_pages` | raw双页、scaled单次消费、尾部、page复用 | PASS |
| `tb_shared16` | MUL/ADD/RoPE、gap、物理16lane共享 | PASS |
| `tb_rope_rom_native` | 408地址、13120系数、背压/flush/非法位置 | PASS |
| `tb_qk_special_rows` | empty/initial、signed MAX、masked NaN、row50 | PASS |
| `tb_mask_profile` | 165 block query、state/action规则、空/洞、flush | PASS |
| `tb_pcore_cancel_native` | 缺配置拒绝、RoPE在途取消、无旧写、重启K102项/3328issues | PASS |

## 5. 证据与源码绑定

- [完整七Job汇总](../DEA8_VPU/Pcore/reports/compute/nocost_final7/Summary.md)
- [完整PCore面积汇总](../DEA8_VPU/reports/resource_synth/pcore_nocost_r2/Summary.md)
- 9项模块原始记录：`DEA8_VPU/Pcore/reports/compute/nocost_r2_modules/`
- 3项邻接原始记录：`DEA8_VPU/reports/layer_native/`，对应测试名的`*_default.log`与PASS
- 综合89项输入清单SHA256：`1bcd4e1093bd185b963a2b59e1417de21e0afc6bf4982613c7fa997881b0b4bb`
- 七Job及9项模块共用118项清单SHA256：`46cdad3277ba164909010d91acc7adb683a45eb5f8d63ab7c8205fba0604e200`
- 原始基线报告/PASS未改写；最终清单逐项与当前RTL/IP/TB/gold一致；GCore生产清单37项字节未变
- 环境：指定`vla-perf`的Python3.10.20/NumPy2.2.6、Vivado2022.2、U50。验证采用现有真实runner/TB，无额外测试框架

## 6. 当前停点与下一步

- 当前RTL已冻结到104422 LUT/285942拍通过版本；工程README、资源口径、验证入口已更新
- 本轮既定无代价候选均已实施或完成上述复核；没有为70%而增加存储/算术资源、改精度或降低发射速率
- `GCore＋8核`沿用原GCore面积外推为865158 LUT，**99.2518%**，比之前少94784；BRAM48.4375%、DSP55.3259%、URAM53.75%
- 70%尚未达到，但不是本轮失败项；下一轮可据本结果重新评估资源交换是否值得，不沿用旧预算当实测
- 本轮没有布局布线/频率签核、八核联合/额外STRESS或板级验证；4ns仅为综合约束和周期折算
- 新生成DCP/IP/快照暂留供检查，未做新一轮发布清理，也未提交/推送Git
