# GCore 当前设计入口

更新：2026-10-19。原文中的外部Reduce、16-lane残差、双rsqrt、118DSP和旧自研FP加乘均已替代，已撤下这些旧接口说明，避免误接。当前完整规格见 [整体方案](GCore_Overall_Plan.md)、[接收/共享算术方案](GCore_Reduce_Plan.md)和[README](README.md)。

## 当前组成

- 顶层 `rtl/dea8_gcore.sv`，默认 `INTERNAL_RSQRT=1`；服务连接为 `dea8_gcore_services`。
- DEA8全局策略在外部，GCore局部控制接宏观Job，不发布PCore Job，不自行循环18层/10步。
- 八路256bit包直接来自PCore内部外发模块；K/V按列坐标落KV，O/Down在GCore内部归约。
- 八个256×4同步BRAM payload FIFO；header单独保持，没有八份FP32输入Tile或归约结果Tile。
- 四棵八输入FP32树分时处理归约/SUM8/SUM64；4lane残差相加，写回BF16 RNE。
- 16个FP32乘法器共享平方、均方、两次归一化乘法；γ在线加载并参与计算。
- 官方ADD11拍、MUL8拍，各2DSP；单官方rsqrt32拍。结构预算109DSP，尚无当前版本资源实测。
- Norm输出8-lane量化，完整16元素共享B16 scale，存XHAT并供XBC。
- KV RAM服务KVB；第18层Down后final norm输出3264个512bit FP32向量。

## 对象与完成

数据身份绑定context、generation、参数ID、layer及对象版本。残差、统计、XHAT和KV各有生命周期；完成不能只看最后一次读请求或最后payload入队。

K/V必须实际写入KV后commit。O/Down必须等当前Tile归约、残差写回及平方统计退休。Norm必须等所有输出实际写入或被接收；最终FP32流最后一次握手后才结束。

取消不回滚已经写入的残差；先真实排空并失效对象，再通过合法输入/正式import恢复。prefix本阶段预置，`GC_PREFIX_LOAD`尚未实现，不能把预置当DMA验收。

## 当前验证与资源入口

真实GCore官方IP算术、冷Norm/import及服务定向回归已通过；真实八个完整PCore联合第1/9/18层仍待服务器。日志范围和哈希见 [README](README.md)，不能以旧23场景代替新版本验收。

服务器先完成仿真，再通过 `../run_dea8.py synth --target gcore --server-heavy`测完整GCore资源；单PCore另外综合。当前不做八核综合或布局布线。输出 `../reports/resource_synth/gcore/`，不覆盖唯一历史综合检查点与报告。
