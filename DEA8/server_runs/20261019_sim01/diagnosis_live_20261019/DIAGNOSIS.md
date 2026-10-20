# P2三项阻塞：TB函数等待敏感性

2026-10-19，Vivado/XSim 2023.1。该诊断不是正式场景PASS。

- Layer1、9、18均已完成初始Norm和K计算；实时读取各进程显示量化向量3264、KV提交16，PCore/GCore busy均0。
- 八个`pc_complete[c][2]`及`gc_complete[2]`全部为1，无X，但`phase`仍为2，无首个`LAYER_PERF`。
- 运行内存只读核验见`live_completion_scoreboards.json`，未调用模拟器函数或修改内存。之前的GDB取栈曾短暂暂停Layer1，随后已detach。
- 当前TB第185行`wait(all_pc_done(id))`调用读取全局完成数组的函数；XSim生成代码的动态等待仅注册不变化的任务参数id，未注册完成数组。
- `wait_repro/xelab.console.log`有XSIM 43-4328警告。`wait_repro/xsim.console.log`证明数组已全部完成但函数等待仍未唤醒；时钟轮询对照能唤醒。后续`wait_repro_explicit/xsim.console.log`也证明显式八位合取等待能够在相同时间唤醒。
- 原正式展开日志同样有第185行对应的43-4328警告。

分类：TB等待敏感性/仿真器兼容性导致的验证阻塞，不是已证实的RTL算术失败。原三次运行没有PASS，必须重跑，不能续接为有效结果。

修复范围：仅在独立运行目录内复制TB，将函数包装的等待展开为八个相同完成位的显式合取；等待的逻辑条件完全相同。不修改工程源码或RTL，不修改负载、算术、数值标准、超时或检查。

重跑使用新编译manifest，记录原manifest及唯一TB覆盖关系。P1的36个PASS保留其原始manifest和日志；P2/P3重新展开和完整执行。综合禁止。
