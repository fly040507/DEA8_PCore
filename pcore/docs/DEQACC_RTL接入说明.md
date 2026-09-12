# DEQACC RTL 接入与验证

DEQACC算术保持上一轮实现；新版接口删除tag.bank与tag.blk，Tag58bit、Dest13bit。MXU现有独立Dest流水，QK顶层接入正式Sequencer；详见QK_Job接口与验证.md。Attention调度器的完成信号、alpha代际和PBUF/SBUF端口问题尚未解决。

## 模块分工

| 文件 | 职责 |
| --- | --- |
| dea8_fp32_pkg.sv | 整数归一化后的FP32 RNE打包、FP32加法；支持subnormal、Infinity和canonical NaN。加法归一化用前导位检测和一次移位，不串联26个条件移位级。 |
| dea8_deqacc_lane.sv | L0整数绝对值/指数；L1归一化和无偏指数；L2反量化与旧值锁存；L3FP32加法。 |
| dea8_deqacc.sv | 16lane实例、目的描述符/tag流水、读写端口、L4 commit、RAW/越界断言。 |
| dea8_accumulator_storage.sv | FACC_A/B各51×512bit，OACC816×512bit，独立读写地址，16个32bit lane写使能。 |

FP32固定为IEEE binary32，E8M0固定8bit。TILE/地址/tag等沿用package参数；不能仅修改FP_BITS就声称支持其他浮点格式，lane启动断言会拒绝不支持配置。

## 外部接线

MXU现有psum、e_stat、rsp_e_stream、rsp_tag组成mxu_rsp_t，连req；rsp_valid连req_valid。不增加输出FIFO或Psum阵列。结构体只是总线组织方式，不自动增加寄存器。

QK Sequencer为每个事务提供deq_dest_t：acc_sel、acc_addr、acc_clear。该描述符经同步QOZ读旁带、DEQ_DEST_REG和dest_q[1:5]到rsp_dest，再直接进入DEQACC，不在输出端根据Tag重建。

mem_rd_en/sel/addr连接选中存储的一拍同步读端口，mem_rd_data返回512bit。mem_wr_en/sel/addr/lane_en/data连接同步写端口，写请求不可被丢弃或反压。L4即实际写入沿，commit_valid在该沿之后报告提交，不需要下游再额外寄存一次写请求。

dea8_accumulator_storage当前向调用方暴露一个聚合读口和一个聚合写口，每个物理bank内部独立。该测试接口还不是支持VPU多客户端同时访问不同bank的完整Attention存储交换逻辑。Top集成必须显式设计所有权、按bank并行端口与冲突检查。

不要在新Top里同时实例化旧dea8_attention_storage的FACC/OACC与新模块当作同一份存储。旧模块暂时保留，尚未接成完整Top。

## 时序契约

E0接受；E1存储采样读地址；E2同时得到FP32 partial和old；E3寄存FP32 sum；E4 RAM实际写入并产生commit。因此是五级，不是lane四级后再额外排五级。

lane的partial_fp是L2诊断输出，acc_fp/valid_out对应L3，abs_psum/scale_exp/psum_sign对应L0。顶层仅使用L3结果；不能拿valid_out去标记L2或L0诊断数据。

同bank同地址接受间距至少4拍。当前无前递网络，间距1～3均报错；断言是协议检查，不会替上游插入停顿。对于lane_mask全部为0的向量仍保留事务顺序和commit，只是没有lane被写入。

acc_clear只表示覆盖旧值。QK首kt设置，后续kt清除；PV0可按初始化策略设置，PV1以后要读取已经缩放的OACC。不能将kt==0硬编码成所有操作的清零条件。

## 验证覆盖

运行：python -m unittest discover -s pcore/tests -v。

Vivado：powershell -ExecutionPolicy Bypass -File pcore/rtl/run_xsim.ps1 -Test all -PythonExecutable <实际python.exe路径>。

脚本自动通过generate_deqacc_vectors.py生成test_vectors，随机种子固定20260912，目录被Git忽略。预期结果来自deqacc_bitexact.py的任意精度整数实现，不来自RTL自身的算术函数。

FP32加法100225组，反量化51568组，包含NaN/Infinity/有符号零、最小值、正常/非正规边界和随机位模式。DEQACC流水3433向量、54928个lane结果逐位比较，覆盖FACC_A/B、PV三轮、部分lane写入后再次读取、fold=-32/31、复位取消在途写入。

正向运行含连续流与输入空拍；DEQACC可接受MXU块间空拍，不表示MXU块内允许断流。负向运行覆盖同地址间距1和3、SBUF非法目标、FACC地址越界，必须触发指定断言。

tb_dea8_mxu增加实际DEQACC与累加存储连接：HBM输入两block、32Tile、1632行，直到FACC写回逐位比较Python预期，检查输入到提交10个沿间隔。原始832拍窗口和MXU输出检查继续保留。

## 尚未签核

XSim通过只能证明所测行为，不证明单周期FP32加法满足目标时钟。尚无本次目标器件的综合、布局布线、时序和资源报告。若L3需要增加物理流水，必须统一修改数据/tag、读响应对齐、commit与RAW间距，不能只更换算术IP。

尚未完成：PV/Linear Sequencer、Attention完成握手、VPU/SFU数值实现、OACC与VPU交接、alpha防覆盖和完整Attention端到端验证。QK-only Sequencer和同步QOZ已实现。
