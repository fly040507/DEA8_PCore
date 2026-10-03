from reportlab.lib import colors
from reportlab.lib.pagesizes import A4
from reportlab.lib.styles import getSampleStyleSheet, ParagraphStyle
from reportlab.lib.units import mm
from reportlab.pdfbase import pdfmetrics
from reportlab.pdfbase.ttfonts import TTFont
from reportlab.platypus import SimpleDocTemplate, Paragraph, Spacer, Table, TableStyle, PageBreak, Preformatted
from pathlib import Path

OUT = Path("output/pdf/VLA_PCore_Attention_v4_方案.pdf")
pdfmetrics.registerFont(TTFont("SimHei", r"C:\\Windows\\Fonts\\simhei.ttf"))
s = getSampleStyleSheet()
s.add(ParagraphStyle(name="T", parent=s["Title"], fontName="SimHei", fontSize=21, leading=28, textColor=colors.HexColor("#16324F")))
s.add(ParagraphStyle(name="H", parent=s["Heading1"], fontName="SimHei", fontSize=15, leading=21, textColor=colors.HexColor("#126E82")))
s.add(ParagraphStyle(name="B", parent=s["BodyText"], fontName="SimHei", fontSize=9.2, leading=15, spaceAfter=6))
s.add(ParagraphStyle(name="C", parent=s["Code"], fontName="SimHei", fontSize=7.5, leading=11, backColor=colors.HexColor("#F1F5F7"), borderPadding=6))
def p(x, st="B"): return Paragraph(x.replace("\n","<br/>"), s[st])
def tbl(rows):
    t=Table([[p(str(c)) for c in row] for row in rows], colWidths=[48*mm,132*mm], repeatRows=1)
    t.setStyle(TableStyle([("BACKGROUND",(0,0),(-1,0),colors.HexColor("#D9EEF2")),("GRID",(0,0),(-1,-1),.35,colors.HexColor("#8AA7B0")),("VALIGN",(0,0),(-1,-1),"TOP"),("LEFTPADDING",(0,0),(-1,-1),5),("RIGHTPADDING",(0,0),(-1,-1),5)]))
    return t
def foot(c,d):
    c.saveState(); c.setFont("SimHei",7); c.setFillColor(colors.grey); c.drawString(18*mm,10*mm,"DEA-8 PCore + FlashAttention v4"); c.drawRightString(192*mm,10*mm,str(d.page)); c.restoreState()
S=[]
def page(title, body):
    S.extend([p(title,"H")])
    for x in body:
        S.append(x if not isinstance(x,str) else p(x))
    S.append(PageBreak())
S += [p("DEA-8 PCore + FlashAttention v4","T"), p("基于最新 FlashAttention / MXU 方案的架构与 RTL 实现规格"), Spacer(1,8*mm), p("本版本以最新 PPT 为主依据，以旧版 VLA_Arch_Spec_v1.pdf 作为结构和接口参考，并吸收标准录音 12 中对 Attention 的确认。文档描述 PCore 与 Attention 的实现边界，不把 VPU/SFU 的 FP32 算术 IP 伪装成已完成 RTL。"), tbl([["状态","结论"],["确定","MXU 16×16 INT8，权重驻留，四级加法树，L4 直接写 Psum_out_REG，MXU 延迟 6 拍。"],["确定","Attention 使用 55 个 KV block，每块 16 token，QK/PV 各 816 拍。"],["确定","Softmax 全部 FP32，P 在 FP32 exp 后重新量化为 INT8，再进入 PV。"],["待定","FP32 IP、HBM 物理 bank 映射、最终时钟和 SRAM 宏。"]]), PageBreak()]
page("1. 版本变更",["Attention 从附属后处理扩展为完整块流水：QK、Mask/RowMax、在线 Softmax、P 量化、PV、OACC 更新和最终归一化。","旧规格中的 alpha 乘法从 DEQACC 移出：alpha 由 SFU 计算，OACC 缩放由 VPU 完成。P 从 FP32 结果重新量化为 INT8，并携带 E_p 进入 PV。"])
page("2. PCore 总体数据路径",["HBM -> MCU/Weight Loader -> WFIFO_DATA + WFIFO_SCALE -> W_BANK_A/B -> 256 PE MXU -> Psum_out_REG + sideband -> DEQACC -> FACC/OACC/SBUF/PBUF。","Attention：Q/K -> QK MXU -> DEQACC/FACC -> VPU Mask/RowMax/Rebase -> SFU exp -> PBUF/E_p -> PV MXU -> DEQACC -> OACC。"])
page("3. MXU 与权重路径",["每个 tile 有 256 Byte INT8 权重和 16 Byte E8M0 scale，共 272 Byte。HBM 256 bit 每 beat 为 32 Byte，因此一个 tile 采用 8 个 payload beat 加 1 个 scale beat。Weight Loader 先消费 16 个 128 bit 数据 entry，再消费 1 个 128 bit scale word。",tbl([["单元","物理资源与作用"],["WFIFO_DATA","128 bit × 512，拆包后的权重数据，16 个 entry 对应一个 16×16 tile。"],["WFIFO_SCALE","128 bit × 32，每个 entry 是 16 个 scale。"],["W_BANK_A/B","两个权重驻留 bank，写非活动 bank，完成后切换。"],["PE","256 个 PE 各保存一个权重值，激活由 Q_ACT_REG 广播。"],["E_STAT","按 bank 存储，随 Psum 侧带传给 DEQACC。"]])])
page("4. MXU 时序与侧带",["t0 接收激活、E_stream 和 tag，同时从活动 W_BANK 取 E_stat 并锁存到 sideband_pipe[0]。t1 为 PE 乘法，t2/t3/t4 为前三层归约，t5 完成第四级加法并直接写入 Psum_out_REG。Psum_out_REG 是结果边界寄存器，不能省略。",Preformatted("pipe[0] input\npipe[1] PE product\npipe[2] adder L1\npipe[3] adder L2\npipe[4] adder L3\npipe[5] adder L4 + Psum_out_REG + sideband\nDEQACC: no alpha multiplier",s["C"])])
page("5. Attention 张量与分块",[tbl([["张量","形状/含义"],["Q","[51,256]"],["K/V","[880,256]，逻辑有效长度 867，55 个 block"],["S_b","[51,16]"],["P_b","[51,16]"],["OACC","[51,256] FP32"],["m/l","[51] FP32"]]),"QK = Q × K_b^T × 2^-4。PV = P_b × V_b，PV 折叠为 0。K 维 256 需要 16 个 16 维 tile，因此 QK、PV 各 816 拍。"])
page("6. 在线 Softmax 与精度",[Preformatted("rho_b = rowmax(S_b)\nm_new = max(m_old, rho_b)\nP_b = exp(S_b - m_new)\nalpha_b = exp(m_old - m_new)\nl_new = alpha_b*l_old + sum(P_b)\nO_new = alpha_b*O_old + P_b*V_b\nAttention = OACC / l",s["C"]),"Q、K、V、P 的矩阵乘输入采用 INT8，Score、m、l、alpha、exp、OACC 和最终除法使用 FP32。QK 反量化指数为 E_q + E_k - 266 - 4，PV 为 E_p + E_v - 266。"])
page("7. Mask 与可见性",["Mask RTL 只生成 lane mask，VPU 将无效 Score 替换为 NEG_INF_FP32。key_index 必须是全局物理 key 索引。","Prefix 只能看 Prefix。State 可看 Prefix 和当前 State。Action 可看 Prefix、State 以及不超过当前行的 Action。880 个物理槽位中尾部 13 个位置必须屏蔽。"])
page("8. Attention 存储",[tbl([["存储","内容与访问"],["FACC A/B","QK 跨 K-tile 的 FP32 累加，双 bank 交替读写。"],["SBUF A/B","Mask 后的 Score，供 VPU RowMax/exp。"],["PBUF A/B + E_p","P 的 INT8 数据及同地址 E_p，解耦 exp/量化和 PV。"],["OACC","[51,256] FP32 累加状态，PV 使用 RMW。"],["m/l/alpha","51 个 FP32 行状态，alpha 可流式或小型寄存器暂存。"]])])
page("9. Attention 并行调度",[Preformatted("启动：       QK(0)\n启动第二段： QK(1) || EXP(0)\n启动第三段： PV(0) || EXP(1)\n稳态：       QK(b+1) || OACC_SCALE(alpha_b)\n             PV(b)   || EXP(b+1)\n结尾：       OACC_SCALE(alpha_54)\n             PV(54)  || A_FIN",s["C"]),"OACC_SCALE 与 PV 的 OACC RMW 不能同时占用同一写端口，必须由 scoreboard 或双口存储仲裁。"])
page("10. VPU、SFU、DEQACC 边界",[tbl([["模块","负责内容"],["VPU","Mask、RowMax、m_new、P 量化、l 更新、OACC_SCALE、A_FIN。"],["SFU","exp(S-m_new)、exp(m_old-m_new)、reciprocal(l)。"],["DEQACC","反量化、INT32 到 FP32、FACC/OACC 加法，不放 alpha 乘法器。"],["Controller","block_id、ping-pong、命令和 ready/valid。"]])])
page("11. RTL 文件",[tbl([["文件","职责"],["dea8_attention_ctrl.sv","55 block 调度和 QK/EXP/PV/scale/afin 命令。"],["dea8_attention_mask.sv","全局 key_index 的 16 lane mask。"],["dea8_attention_storage.sv","SBUF/PBUF/E_p/FACC/OACC 物理存储。"],["dea8_mxu.sv","QK/PV 共用 16×16 INT8 MXU。"],["dea8_deqacc_lane.sv","16 lane 反量化和 FP32 IP 边界。"],["attention_reference.py","在线 Softmax、量化和尾块验证。"]])])
page("12. 验证与结论",["数值验证在线 Softmax、m/l/alpha/OACC 更新；精度验证 MXINT8-B16、RNE、QK -4 和 PV 0；时序验证 MXU 6 拍、DEQACC 5 拍、尾延迟 11 拍；存储验证双 bank、OACC RMW 冲突和尾部 mask。","结论：v4 将 PCore 的 16×16 权重驻留矩阵路径与 FlashAttention 的块级在线 Softmax 路径统一到同一套 MXU/DEQACC 边界。矩阵乘和反量化归 PCore，高精度向量运算归 VPU/SFU。"])
OUT.parent.mkdir(parents=True, exist_ok=True)
SimpleDocTemplate(str(OUT),pagesize=A4,rightMargin=18*mm,leftMargin=18*mm,topMargin=16*mm,bottomMargin=16*mm).build(S,onFirstPage=foot,onLaterPages=foot)
print(OUT)

