# 新版 README：QK Matrix Job 实现

本轮完整阅读 Desktop/README.docx 第1～25节，并以其更新后的第9、18～25节为接口依据。上传的建议用于安排实现顺序，不覆盖README。较早段落遗漏DEQ_DEST_REG时，以第9节明确列出的完整事务边界为准。

## 已落实的变更

pipe_tag_t固定58bit：row6、nt8、kt8、head3、lane_mask16、post_op5、exp_fold6、final_k1、last1、epoch4。删除bank与blk；BLOCK_BITS仍供Job Context及attn_cmd_t使用。MXU与QK Sequencer内有位宽静态检查。

deq_dest_t固定13bit：acc_sel2、acc_addr10、acc_clear1。由Sequencer在读取QOZ时生成，经读响应元数据寄存器、DEQ_DEST_REG、dest_q[1:5]、rsp_dest、DEQACC，直到commit_dest。输出端没有根据当前计数器或Block ID重新生成目的地址的逻辑。

一次MXU输入边界为128bit A、8bit E_stream、58bit Tag、13bit Dest和1bit Valid，共208bit。MXU输出为512bit Psum、128bit E_stat、8bit E_stream、58bit Tag、13bit Dest，共719bit有效载荷，另有1bit Valid。结构体不意味着新增合包RAM。

QK只支持[51,256]×[256,16]，顺序固定kt0～15，每个kt连续row0～50。每Job816事务。nt=0、exp_fold=-4；最后kt的51笔final_k=1，仅kt15,row50的last=1。post_op当前保留为0，后续VPU命令编码尚未定义。

## 本轮模块

| 模块 | 职责 |
| --- | --- |
| dea8_qoz_buffer | 独立QOZ_BUF与E_QOZ，同一写使能/地址成对写入，同一读使能/地址同步读取。 |
| dea8_qk_sequencer | 接受QK Job、保持Context、产生QOZ读地址及Tag/Dest、控制本Job的16次Bank Load、等待最后commit。 |
| dea8_mxu | 新增req_dest/rsp_dest、DEQ_DEST_REG、dest_q[1:5]；不修改PE、权重驻留和加法树算法。 |
| dea8_qk_engine | 连接Sequencer、QOZ、W_Loader、MXU、DEQACC和唯一一份Accumulator Storage。支持空闲时FACC读回。 |

DEQACC FP32算法、五级延迟、W_Loader的FIFO与Bank状态机保持上一轮实现。旧Attention Controller不接入本顶层，因为其命令接受/完成语义尚未改造，不能让它提前推进Job。

## Job 接口

输入job_valid/job_ready完成一次接受；job_block_id、job_head、job_epoch、job_facc_bank同沿锁存。resources_ready是上层对QOZ内容已准备、FACC目的bank已独占的承诺，不是内部自动检测所有数据都已初始化。

job_busy从接受后保持到最后commit被采样。job_done是job_busy && commit_valid && commit_tag.last，在L4提交后的周期有效；该周期current_block_id仍对应已完成Job。Sequencer在下一采样沿清busy，此后才能接受新Job。

输入job字段在busy期间可以变化或提出下一请求，但不会改写当前Context。QOZ不按job_head自动偏移：上层必须提前把当前head的Q放入缓冲。HBM输入也必须是当前Job按kt顺序的16个B Tile，允许再预取下个Job；本轮不新增HBM地址发生器或AXI读主机。

FACC选择是显式job_facc_bank，不从block_id奇偶推导。acc_addr=row，acc_clear只在kt0为1。该规则仅用于QK，不泛化到PV。

## QOZ 组织与时序

QOZ_BUF为51×32个128bit word，26112Byte；E_QOZ为51×32个8bit word，1632Byte。线性地址=row×32+tile_idx，11bit地址总线，合法0～1631。QK使用tile_idx=kt0～15；16～31也物理存在，但本QK Job不读取。

同步读：E_read沿RAM采样地址，同时Sequencer锁存该地址的Tag/Dest/Valid；沿后RAM输出A与E_stream。下一个沿E_read+1，五者一起锁存进MXU Stage0。因此并未新增第二个Q_ACT_REG。

首Tile：第15个Bank Load沿发出row0读请求，第16个加载沿同时把row0写入Q_ACT_REG、E_STREAM_REG、ACT_TAG_REG和DEQ_DEST_REG；下一沿开始PE乘法。没有额外Bank Switch或激活装载拍。

中间Tile：上一Tile最后一次QOZ读后，若下一B Tile已经READY，则继续读下一Tile row0。下一沿与旧Tile row50乘法/Bank Activate同沿进入MXU。若B Tile尚未准备，只在Tile边界等待；一旦首行进入，51行内部连续运行。

Sequencer计数Bank Load启动次数，到16后禁止继续Bank Load；不修改W_Loader的Bank所有权。HBM到WFIFO预取不受此限制。不同Job之间必须经过提交屏障，新Job仍独立经历首Tile16拍加载。

## 周期口径

供数充分：从首个Bank Load沿计至最后PE乘法沿，包含16个加载周期与816个乘法周期，共832周期。job_valid等待、首次HBM不足、Job Context建立、最后流水排空和下游读取不包含在832内。

MXU Stage0接受到DEQACC L4提交相隔10个沿间隔；11是逻辑阶段总数。QOZ读请求在Stage0前一沿，所以QOZ请求到L4相隔11个沿间隔。job_done只由实际最后commit产生，不靠倒计时猜完成。

## 所有权与当前边界

QK忙时禁止外部QOZ写与FACC读，RTL断言检测错误。空闲时可成对写QOZ或经facc_rd_en/bank/addr读回FACC；facc_rd_valid在同步响应周期给出。当前聚合1R1W前端在整个QK Job期间被DEQACC独占，尚不支持并行VPU消费者。

整个QK顶层只实例化dea8_accumulator_storage，不重复实例化旧Attention storage。reset取消当前Job、有效流水及在途提交；RAM内容不整块清零。取消后上层必须重新按Job边界装载/预取B流，不能把被中断的旧HBM包继续当作新Job开始。

## 验收

运行run_xsim.ps1 -Test qk，自动生成Python位精确golden并运行预填充、流式HBM、长时间断供、在途复位、QOZ写冲突五种测试。-Test all同时回归MXU、DEQACC及原Attention命令计数测试。

两个完整Job使用block_id=3和17，head/epoch不同，显式选择FACC_A/B，验证Block Context保持到最后commit，避免偶然依赖Block奇偶。每Job816输入/输出/提交，逐笔检查QOZ Data/Scale、Tag、Dest、fold=-4和结果；最后读回两个bank的全部51行，与Python最终FP32结果逐位比较。

长时间断供测试在第8个B Tile前停600拍，要求确实出现Tile边界等待，仍禁止Tile内部气泡。复位测试在已有事务在途时取消Job，不能误发done或恢复旧写回。QOZ写冲突是预期失败测试。

## 未完成

本轮交付的是QK-only Matrix Job执行链，不是完整FlashAttention：尚无PV/Linear Sequencer、QK完成后的VPU Mask/RowMax、EXP/P量化、alpha与OACC缩放、A_FIN，以及完成握手版Attention Controller。尚未进行目标器件综合、布局布线和时序签核；单周期L3为固定架构，变更须另立版本。
