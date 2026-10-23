# 仿真与综合复现

更新：2026-10-23。无代价优化后单PCore七Job通过，285942拍；[原始证据](../Pcore/reports/compute/nocost_final7/Summary.md)。八核联合仍待服务器验收。

## 环境与重建

- Vivado **2022.2**，器件 `xcu50-fsvh2104-2-e`；设置`VIVADO_ROOT`
- Python3.10+、NumPy；生成图片另需Pillow
- Windows先加载`settings64.bat`；Linux使用安装目录的等效环境
- 同一工作目录的编译/IP生成须串行；下文`python`指实际解释器
- 发布包保留XCI、小型IP仿真封装、ROM、gold和测试源码。完整IP产品、快照和波形已清理，先生成IP再运行仿真

在`DEA8_VPU`：

```text
python run_dea8.py ip
```

核对生成配置：ADD/SUB11拍、MUL8拍，各2DSP；EXP21、RECIP29、RSQRT32。不能用不同IP延迟复用已验收计时。

输入已随工程提供。需要重新生成时，在`DEA8_VPU/Pcore`：

```text
python tools/prepare_compute_vectors.py --position 816
python tools/prepare_seven_job.py
```

层级输入在`DEA8_VPU`用`python run_dea8.py vectors`生成。默认profile为有效prefix816、suffix51、pi05=False、position816；改变Mask有效数时同步系数和top配置。官方AST对照依赖外层`openpi`源码，`official_mask_cases=0`不能解释为再次完成官方对照。

gold由独立NumPy模型生成，不注入DUT中间结果。RESID/prefix仅按TB允许方式预置；RoPE通过公开预载握手，在Job计时前完成。HBM普通RMSNorm参数导出为实际乘数`gamma=1+checkpoint.scale`，GCore不再加1、不将γ折叠权重。

## 单核与定向回归

在`DEA8_VPU/Pcore`，使用新tag保留发布证据：

```text
python run_compute.py test --top tb_pcore_seven_native --report-tag review7
python run_compute.py test --top tb_compute_sfu_shared --report-tag review_sfu
python run_compute.py test --top tb_gu_m2v --report-tag review_gu
python run_compute.py test --top tb_oacc_pages --report-tag review_oacc
python run_compute.py test --top tb_p_stream_shared --report-tag review_p_stream
python run_compute.py test --top tb_p_history_shared --report-tag review_history
python run_compute.py test --top tb_rope_rom_native --report-tag review_rope
python run_compute.py test --top tb_qk_max_order --report-tag review_qk_order
python run_compute.py test --top tb_deq_format_nocost --report-tag review_deq_format
```

在`DEA8_VPU`：

```text
python run_dea8.py test --top tb_pcore_cancel_native
python run_dea8.py test --top tb_attention_history --arg HIDING_AUDIT
python run_dea8.py test --top tb_mask_profile
python run_dea8.py test --top tb_qk_special_rows
python run_dea8.py test --top tb_gcore_norm_native
python run_dea8.py simulate --top tb_gcore_norm_native --arg IMPORT_FIRST
```

标准七Job不等于额外STRESS验收。TB只提供本核外部数据、命令、commit和接收。显式PASS、数值/协议检查满足、输入哈希绑定一致才通过；退出码0不足。源码、runner、IP、ROM或gold变更后重编译/展开，不复用旧snapshot。默认O3、mt off；工具问题才考虑`--opt 0`。

新增定向检查：QK256pair，独立shortreal比较oracle，覆盖signed-zero/subnormal/非法数/mask/背压；DEQACC384pair、12288lane检查，独立整数商/余数RNE oracle，核对INT20全范围边界、subnormal/溢出/bad scale及16拍延迟。当前12项定向/邻接PASS见[证据索引](../reports/README.md)。

## 八核服务器验收

在`DEA8_VPU`执行。八核完整展开属于server-heavy任务，本地未运行通过：

```text
python run_dea8.py test --top tb_dea8_layers_native --server-heavy --arg LAYER=1
python run_dea8.py simulate --top tb_dea8_layers_native --server-heavy --arg LAYER=9
python run_dea8.py simulate --top tb_dea8_layers_native --server-heavy --arg LAYER=9 --arg STRESS
python run_dea8.py simulate --top tb_dea8_layers_native --server-heavy --arg LAYER=18
python run_dea8.py simulate --top tb_dea8_layers_native --server-heavy --arg LAYER=18 --arg STRESS
python run_dea8.py simulate --top tb_dea8_layers_native --server-heavy --arg LAYER=1 --arg CANCEL_AT=Attention
python run_dea8.py simulate --top tb_dea8_layers_native --server-heavy --arg LAYER=1 --arg CANCEL_AT=GU
python run_dea8.py simulate --top tb_dea8_layers_native --server-heavy --arg LAYER=1 --arg CANCEL_AT=O
python run_dea8.py simulate --top tb_dea8_layers_native --server-heavy --arg LAYER=1 --arg CANCEL_AT=O --arg RECOVER
```

- 每核：7完成、265408矩阵issue、55QK/55PV、43264 XBC、14080 KVB、13418 tx256；Q/O/Z pair写1664、P pair写1430
- 共享：32 KV commit、128 FP Tile退休、6528 BF16残差写回；第18层final3264向量，不请求第19层参数
- 每核输入/权重须不同；检查Score/P、Q/O/Z、K/V坐标、量化轴、FP包、XHAT/Residual/final，不能只查计数
- RECOVER撤销旧供数，重新配置generation3、PCore epoch4、transfer epoch10，正式`GC_IMPORT_RESID`重装3264残差向量后重跑七Job
- 其他取消点支持K/Q/SCALE/Down及末层Final，不替代上述必需场景

第9/18层为独立checkpoint，不表示连续运行了前面的层。真实HBM/PCIe、连续18层/10步、动态M和板级测试仍未完成。

## 单模块资源测量

当前[资源预览](Resources.md)另行完成，不表示八核仿真准入通过。需要新预览时使用新tag：

```text
python run_dea8.py synth --target pcore --resource-preview --report-tag review_area
python run_dea8.py synth --target gcore --resource-preview --report-tag review_area
```

正式`--server-heavy`综合会核对10份当前输入绑定的PASS：默认目录的单核七Job，加上述9个八核场景。已发布单核证据在命名tag目录，正式准入前须按runner默认目录约定重新运行，不能复制旧PASS绕过准入。

```text
python run_dea8.py synth --target gcore --server-heavy
python run_dea8.py synth --target pcore --server-heavy
```

仅执行完整模块的`synth_design -mode out_of_context`，检查blackbox=0。4ns只作约束，不进行opt/place/route或频率签核，不综合八核。保留资源总表、层次表、RAM表、原语计数、输入哈希、PASS及日志；DCP/`ip_work`可重建。

不要用裸Matrix、旧DEQACC叶级脚本或历史GCore检查脚本替代完整模块资源。失败保留首个core/job/tile/row/lane、actual/gold、token及信用/队列状态；不删除检查或放宽gold获得PASS。
