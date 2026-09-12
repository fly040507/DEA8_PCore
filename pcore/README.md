# DEA-8 PCore / Attention

当前依据：用户2026-09-12版README，整理见 [冻结规格](docs/冻结规格_2026-09-12.md)。
本轮新版接口与QK执行链见 [QK Job接口与验证](docs/QK_Job接口与验证.md)：58bit Tag、13bit Dest、同步QOZ读取与最后commit屏障。
实现状态见 [状态清单](docs/IMPLEMENTATION_STATUS.md)。本工程不是完整Attention签核版本。

## 当前已实现并仿真的通路

HBM -> dea8_w_loader（Fetch、WFIFO、Bank Load与状态） -> dea8_mxu -> Psum + sideband[5]。

新增dea8_qk_engine：QK Sequencer驱动真实同步QOZ/E_QOZ，连接W_Loader、MXU、DEQACC及唯一一份累加存储。已不依赖测试台在MXU输出端生成Dest。当前仅支持QK Job，不代表完整Attention Top已经完成。
接线、时序和运行方式见 [DEQACC接入说明](docs/DEQACC_RTL接入说明.md)。

- 256bit HBM、8数据beat+1低128bit有效scale beat。
- 完整Tile预留后16拍装载，scale首拍同步写入。
- W_Loader独占四种bank状态；首Tile末加载沿激活，中间Tile末乘法沿切换。
- Q_ACT_REG / E_STREAM_REG / ACT_TAG_REG / ACT_VALID_REG输入边界。
- E_STAT_ACTIVE_REG只在激活bank时更新，每个乘法沿复制到pipe[1]。
- 六个逻辑阶段，旁带只保留[1:5]；Tile内51拍连续执行。
- block边界加载预算由外部sequencer控制；集成测试演示832拍窗口。

已删除旧dea8_weight_loader.sv和dea8_mcu_weight_path.sv，filelist已更新。
历史PDF v3/v4与旧PPT不再作为当前MXU接口依据。

## 验证

在VLA根目录：python -m unittest discover -s pcore/tests -v

Vivado默认路径D:/Xilinx/Vivado/2022.2：
powershell -ExecutionPolicy Bypass -File pcore/rtl/run_xsim.ps1 -Test all

脚本默认调用python生成DEQACC向量；使用其他Python路径时传 -PythonExecutable。生成的test_vectors目录不提交Git。

主MXU测试实际连接W_Loader、FIFO和PE；验证2个block、32个Tile、1632行和26112个输出lane，
包含负数/极值、逐lane scale、完整tag、首拍启动、READY保持、中间切换、block间16拍加载。
额外测试流式HBM及延迟scale、Tile内断流必须报错。

DEQACC已通过RTL数值仿真，尚未完成目标器件综合时序签核；Attention任务执行器和VPU/SFU仍未完整实现。控制器计数PASS不表示Attention数值与提交依赖验证通过。
