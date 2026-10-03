from pathlib import Path
import html
import re

from reportlab.lib import colors
from reportlab.lib.enums import TA_CENTER, TA_LEFT
from reportlab.lib.pagesizes import A4
from reportlab.lib.styles import ParagraphStyle, getSampleStyleSheet
from reportlab.lib.units import mm
from reportlab.pdfbase import pdfmetrics
from reportlab.pdfbase.ttfonts import TTFont
from reportlab.platypus import (
    BaseDocTemplate,
    Frame,
    PageTemplate,
    Paragraph,
    PageBreak,
    Spacer,
    Table,
    TableStyle,
    KeepTogether,
)


ROOT = Path(r"C:\Users\fly04\Desktop\VLA")
OUTPUT = ROOT / "output" / "pdf" / "VLA_PCore_MXU_v3_方案.pdf"
FONT = r"C:\Windows\Fonts\simhei.ttf"

pdfmetrics.registerFont(TTFont("SimHei", FONT))

NAVY = colors.HexColor("#163A5F")
BLUE = colors.HexColor("#1E6A9E")
CYAN = colors.HexColor("#2F8FA8")
GREEN = colors.HexColor("#3D7A57")
RED = colors.HexColor("#B63A32")
AMBER = colors.HexColor("#A56600")
INK = colors.HexColor("#18232E")
TEXT = colors.HexColor("#29343D")
MUTED = colors.HexColor("#65727D")
GRID = colors.HexColor("#D5DEE5")
LIGHT = colors.HexColor("#F5F8FA")
PALE_BLUE = colors.HexColor("#EAF3F8")
PALE_GREEN = colors.HexColor("#EAF5EE")
PALE_AMBER = colors.HexColor("#FFF6E5")
PALE_RED = colors.HexColor("#FCEDEC")
WHITE = colors.white


styles = getSampleStyleSheet()
styles.add(ParagraphStyle(
    name="BodyCN", fontName="SimHei", fontSize=9.5, leading=15.2,
    textColor=TEXT, spaceAfter=5, alignment=TA_LEFT,
))
styles.add(ParagraphStyle(
    name="BodySmall", parent=styles["BodyCN"], fontSize=8.25,
    leading=12.6, spaceAfter=2,
))
styles.add(ParagraphStyle(
    name="BodyTiny", parent=styles["BodyCN"], fontSize=7.2,
    leading=10.2, spaceAfter=1,
))
styles.add(ParagraphStyle(
    name="H1CN", fontName="SimHei", fontSize=17, leading=23,
    textColor=NAVY, spaceBefore=6, spaceAfter=9,
))
styles.add(ParagraphStyle(
    name="H2CN", fontName="SimHei", fontSize=12.5, leading=18,
    textColor=BLUE, spaceBefore=10, spaceAfter=6,
))
styles.add(ParagraphStyle(
    name="H3CN", fontName="SimHei", fontSize=10.3, leading=15,
    textColor=NAVY, spaceBefore=6, spaceAfter=3,
))
styles.add(ParagraphStyle(
    name="TableHead", fontName="SimHei", fontSize=7.7, leading=10.5,
    textColor=WHITE, alignment=TA_CENTER,
))
styles.add(ParagraphStyle(
    name="TableCell", fontName="SimHei", fontSize=7.5, leading=10.2,
    textColor=TEXT,
))
styles.add(ParagraphStyle(
    name="TableCellCenter", parent=styles["TableCell"], alignment=TA_CENTER,
))
styles.add(ParagraphStyle(
    name="CodeCN", fontName="SimHei", fontSize=7.8, leading=11.5,
    textColor=NAVY,
))
styles.add(ParagraphStyle(
    name="FlowNode", fontName="SimHei", fontSize=7.7, leading=10.4,
    textColor=INK, alignment=TA_CENTER,
))
styles.add(ParagraphStyle(
    name="FlowArrow", fontName="SimHei", fontSize=10, leading=12,
    textColor=BLUE, alignment=TA_CENTER,
))
styles.add(ParagraphStyle(
    name="CallTitle", fontName="SimHei", fontSize=9.2, leading=13,
    textColor=NAVY,
))
styles.add(ParagraphStyle(
    name="CoverTitle", fontName="SimHei", fontSize=25, leading=33,
    textColor=WHITE, alignment=TA_CENTER,
))
styles.add(ParagraphStyle(
    name="CoverSub", fontName="SimHei", fontSize=12, leading=19,
    textColor=colors.HexColor("#DDECF3"), alignment=TA_CENTER,
))
styles.add(ParagraphStyle(
    name="CoverMeta", fontName="SimHei", fontSize=9.4, leading=14,
    textColor=TEXT,
))


def rich(text: str) -> str:
    value = html.escape(str(text), quote=False).replace("\n", "<br/>")
    value = re.sub(r"`([^`]+)`", r'<font color="#1E6A9E"><b>\1</b></font>', value)
    return value


def P(text, style="BodyCN"):
    return Paragraph(rich(text), styles[style])


def table(headers, rows, widths, small=False, center_cols=None):
    center_cols = set(center_cols or [])
    head_style = styles["TableHead"]
    cell_style = styles["BodyTiny" if small else "TableCell"]
    data = [[Paragraph(rich(h), head_style) for h in headers]]
    for row in rows:
        cells = []
        for i, item in enumerate(row):
            style = styles["TableCellCenter"] if i in center_cols else cell_style
            cells.append(Paragraph(rich(item), style))
        data.append(cells)
    t = Table(data, colWidths=widths, repeatRows=1, hAlign="LEFT")
    t.setStyle(TableStyle([
        ("BACKGROUND", (0, 0), (-1, 0), NAVY),
        ("GRID", (0, 0), (-1, -1), 0.45, GRID),
        ("VALIGN", (0, 0), (-1, -1), "MIDDLE"),
        ("LEFTPADDING", (0, 0), (-1, -1), 5),
        ("RIGHTPADDING", (0, 0), (-1, -1), 5),
        ("TOPPADDING", (0, 0), (-1, -1), 4),
        ("BOTTOMPADDING", (0, 0), (-1, -1), 4),
        ("ROWBACKGROUNDS", (0, 1), (-1, -1), [WHITE, LIGHT]),
    ]))
    return t


def callout(title, body, fill=PALE_BLUE, stroke=colors.HexColor("#A9C9D7")):
    t = Table([
        [P(title, "CallTitle")],
        [P(body, "BodySmall")],
    ], colWidths=[166 * mm], hAlign="LEFT")
    t.setStyle(TableStyle([
        ("BACKGROUND", (0, 0), (-1, -1), fill),
        ("BOX", (0, 0), (-1, -1), 0.7, stroke),
        ("LEFTPADDING", (0, 0), (-1, -1), 8),
        ("RIGHTPADDING", (0, 0), (-1, -1), 8),
        ("TOPPADDING", (0, 0), (-1, -1), 5),
        ("BOTTOMPADDING", (0, 0), (-1, -1), 4),
    ]))
    return t


def code_box(lines, fill=PALE_BLUE):
    text = "<br/>".join(html.escape(str(x), quote=False) or "&nbsp;" for x in lines)
    t = Table([[Paragraph(text, styles["CodeCN"])]], colWidths=[166 * mm], hAlign="LEFT")
    t.setStyle(TableStyle([
        ("BACKGROUND", (0, 0), (-1, -1), fill),
        ("BOX", (0, 0), (-1, -1), 0.7, colors.HexColor("#A9C9D7")),
        ("LEFTPADDING", (0, 0), (-1, -1), 8),
        ("RIGHTPADDING", (0, 0), (-1, -1), 8),
        ("TOPPADDING", (0, 0), (-1, -1), 6),
        ("BOTTOMPADDING", (0, 0), (-1, -1), 6),
    ]))
    return t


def flow(nodes, widths=None, node_fill=PALE_BLUE):
    if widths is None:
        widths = [30 * mm if i % 2 == 0 else 7 * mm for i in range(len(nodes) * 2 - 1)]
    cells = []
    for i, node in enumerate(nodes):
        if i:
            cells.append(P("->", "FlowArrow"))
        cells.append(P(node, "FlowNode"))
    t = Table([cells], colWidths=widths, hAlign="LEFT")
    styles_list = [
        ("VALIGN", (0, 0), (-1, -1), "MIDDLE"),
        ("LEFTPADDING", (0, 0), (-1, -1), 3),
        ("RIGHTPADDING", (0, 0), (-1, -1), 3),
        ("TOPPADDING", (0, 0), (-1, -1), 6),
        ("BOTTOMPADDING", (0, 0), (-1, -1), 6),
    ]
    for i in range(0, len(nodes) * 2 - 1, 2):
        styles_list += [
            ("BACKGROUND", (i, 0), (i, 0), node_fill),
            ("BOX", (i, 0), (i, 0), 0.7, colors.HexColor("#9AB9C8")),
        ]
    t.setStyle(TableStyle(styles_list))
    return t


def two_col(left, right, left_w=81 * mm, right_w=81 * mm):
    t = Table([[left, right]], colWidths=[left_w, right_w], hAlign="LEFT")
    t.setStyle(TableStyle([
        ("VALIGN", (0, 0), (-1, -1), "TOP"),
        ("LEFTPADDING", (0, 0), (-1, -1), 0),
        ("RIGHTPADDING", (0, 0), (-1, -1), 7),
        ("TOPPADDING", (0, 0), (-1, -1), 0),
        ("BOTTOMPADDING", (0, 0), (-1, -1), 0),
    ]))
    return t


def bullets(items, style="BodyCN"):
    return [P("- " + item, style) for item in items]


def cover(story):
    banner = Table([
        [Spacer(1, 14 * mm)],
        [P("单个矩阵计算数据通路", "CoverTitle")],
        [P("从 HBM 传输到 PSUM、DEQACC 与 FP32 累加结束", "CoverSub")],
        [Spacer(1, 11 * mm)],
    ], colWidths=[166 * mm], hAlign="CENTER")
    banner.setStyle(TableStyle([
        ("BACKGROUND", (0, 0), (-1, -1), NAVY),
        ("LEFTPADDING", (0, 0), (-1, -1), 12),
        ("RIGHTPADDING", (0, 0), (-1, -1), 12),
        ("TOPPADDING", (0, 0), (-1, -1), 3),
        ("BOTTOMPADDING", (0, 0), (-1, -1), 3),
    ]))
    story.extend([Spacer(1, 18 * mm), banner, Spacer(1, 11 * mm)])
    meta = [
        [P("依据", "CoverMeta"), P("VLA_Arch_Spec_v1.pdf；TILE=16，MXU_KIND=0", "CoverMeta")],
        [P("范围", "CoverMeta"), P("一个 PCore 内的一次 16x16 INT8 tile 计算；覆盖 HBM、MCU、WFIFO、MXU、DEQACC、FACC/OACC/SBUF", "CoverMeta")],
        [P("核心结论", "CoverMeta"), P("PSUM 不是 16x16 INT32 矩阵缓存，而是 16xINT32、512 bit 的输出向量；直接进入 16 lane DEQACC", "CoverMeta")],
        [P("版本口径", "CoverMeta"), P("权重双 Bank；激活不放入 PE 长期保存；Scale 走与数据同延迟的旁带；反量化后逐 lane FP32 读改写", "CoverMeta")],
    ]
    mt = Table(meta, colWidths=[25 * mm, 141 * mm], hAlign="CENTER")
    mt.setStyle(TableStyle([
        ("BACKGROUND", (0, 0), (-1, -1), WHITE),
        ("BACKGROUND", (0, 0), (0, -1), PALE_BLUE),
        ("GRID", (0, 0), (-1, -1), 0.45, GRID),
        ("VALIGN", (0, 0), (-1, -1), "MIDDLE"),
        ("LEFTPADDING", (0, 0), (-1, -1), 7),
        ("RIGHTPADDING", (0, 0), (-1, -1), 7),
        ("TOPPADDING", (0, 0), (-1, -1), 7),
        ("BOTTOMPADDING", (0, 0), (-1, -1), 7),
    ]))
    story.append(mt)
    story.append(Spacer(1, 12 * mm))
    story.append(callout(
        "阅读方法",
        "先看第 2 页的总链路，再看第 5、6 页的 MXU/PE 与 Scale 对齐，最后重点看第 8、9 页的 PSUM -> DEQACC -> FACC/OACC 流程。表格中的“存储资源”与“流水寄存器”分开统计，避免把一个 512 bit 数据拍误认为一个 16x16 缓存。",
        fill=PALE_AMBER, stroke=colors.HexColor("#E5C277"),
    ))
    story.append(PageBreak())


def page_scope(story):
    story.append(P("1. 设计范围与冻结参数", "H1CN"))
    story.append(P("本说明只抽取一次矩阵 tile 的硬件数据通路。它不展开完整 VLA 层调度，但会说明该通路在普通 GEMM、QK 和 PV 三种场景下，DEQACC 后分别写到哪里。所有位宽、存储深度和流水延迟以 VLA_Arch_Spec_v1.pdf 为准。", "BodyCN"))
    story.append(table(
        ["参数", "冻结值", "含义"],
        [
            ["TILE", "16", "TILE_R=TILE_C=16；也是 MXINT8-B16 的块长度和 Attention 的 B_kv"],
            ["MXU_KIND", "0", "16x16 INT8 MAC 阵列 + 4 级平衡加法树，不是 systolic array"],
            ["M/K/N", "M=51；K/N 按算子切成 16 的 tile", "一次发射周期处理一个 M 行激活向量和一个 KxN 权重 tile"],
            ["MXU_LAT", "6 拍", "1 拍乘法 + 4 拍加法树 + 1 拍输出寄存"],
            ["DEQACC_LAT", "5 拍", "L0 LZC、L1 移位、L2 指数、L3 FP32 加、L4 写回"],
            ["PIPE_DRAIN", "11 拍", "MXU_LAT + DEQACC_LAT；用于 CNT_WB 与描述符边界"],
            ["AXI / 内部数据", "256 bit / 128 bit", "HBM 物理 beat 为 32 B；MXU stationary 与 activation 为 16 B/拍"],
            ["Scale", "E8M0，8 bit/块", "一个 16 元素块一个 E；元素真实值 q x 2^(E-133)"],
        ],
        [25 * mm, 31 * mm, 110 * mm],
    ))
    story.append(Spacer(1, 4))
    story.append(P("一次 tile 的数学对象", "H2CN"))
    story.append(code_box([
        "A[m, 0:15]  x  W[0:15, n]  ->  PSUM[n] = sum(k=0..15) qA[m,k] * qW[k,n]",
        "n = 0..15，因此一个激活向量产生 16 个输出通道；每个输出通道得到一个 INT32 PSUM",
        "真实值 partial[n] = PSUM[n] x 2^(E_stream + E_stat[n] - 266 + EXP_FOLD)",
    ]))
    story.append(Spacer(1, 4))
    story.append(callout(
        "最重要的边界",
        "归约维 K=16 已经在 MXU 的加法树中完成。DEQACC 的任务不是重新做 16 项 INT32 横向求和，而是把每个输出 lane 的 INT32 PSUM 恢复为 FP32 partial，再与目标累加器中同一 row、同一 output-lane 的旧值相加。",
        fill=PALE_GREEN, stroke=colors.HexColor("#A7CFB5"),
    ))
    story.append(PageBreak())


def page_overview(story):
    story.append(P("2. 从 HBM 到累加结束的总链路", "H1CN"))
    story.append(P("下面的路径表示一个权重 tile 的生命周期。激活路径从 GCore/XBC 或 PCore 本地存储进入；权重从对应 PCore 的 HBM AXI 主端口进入。两者在 MXU 的每一个发射周期汇合。", "BodyCN"))
    story.append(flow([
        "HBM\n权重 tile\n272 B",
        "MCU\nAXI 读 + 流式拆包",
        "CDC / Beat FIFO\n跨域解耦",
        "WFIFO_DATA + SCALE\n128 bit x 512 / 128 bit x 32",
        "MXU 双 Bank\n16x16 INT8\n当前/下一 tile",
        "PSUM OUT\n512 bit\n16xINT32",
        "DEQACC\n16 lane\nINT32 -> FP32",
        "FACC/OACC/SBUF\nFP32 读改写\n或最终写回",
    ], widths=[15*mm, 3*mm, 16*mm, 3*mm, 15*mm, 3*mm, 22*mm, 3*mm, 17*mm, 3*mm, 16*mm, 3*mm, 18*mm, 3*mm, 23*mm], node_fill=PALE_BLUE))
    story.append(Spacer(1, 4))
    story.append(P("同一发射周期的激活侧", "H2CN"))
    story.append(flow([
        "XHAT/Q/P/Z\n本地 SRAM 或 XBC/XFIFO",
        "128 bit\nactivation input reg",
        "16 路局部广播\n同一个 a[k] 给 16 个 PE",
        "PE[k][0:15]\nINT8 x INT8",
    ], widths=[36*mm, 8*mm, 34*mm, 8*mm, 36*mm, 8*mm, 38*mm], node_fill=PALE_GREEN))
    story.append(Spacer(1, 5))
    story.append(table(
        ["阶段", "输入", "输出", "必须保持的上下文"],
        [
            ["MCU", "HBM 256 bit AXI beat", "16 个 128-bit 权重字 + 1 个 128-bit Scale word", "tile_id、段地址、beat 计数、valid"],
            ["MXU", "16 个 INT8 激活 + 16x16 INT8 weight", "16 个 INT32 PSUM", "E_stream、E_stat[15:0]、pipe_tag"],
            ["DEQACC", "16xINT32 PSUM + 两类 Scale", "16xFP32 partial", "目标累加器选择、地址、final_k"],
            ["累加器", "旧 FP32 word + partial", "新 FP32 word", "固定 K-tile 顺序，逐 lane 对齐"],
        ],
        [22*mm, 46*mm, 48*mm, 50*mm],
        small=True,
    ))
    story.append(PageBreak())


def page_storage(story):
    story.append(P("3. 存储资源总表：到底有几处存权重、激活和 Scale", "H1CN"))
    story.append(P("“存放位置”分成三类：持久/片外存储、传输缓冲、计算阵列寄存器。前两类用于容量和解耦，最后一类用于当前 tile 的低延迟计算。一个 tile 在流水中可以同时出现在多个位置，这是预取和双缓冲的正常结果。", "BodyCN"))
    story.append(table(
        ["资源", "每个 PCore 的数量/组织", "存什么", "容量/位宽", "性质"],
        [
            ["HBM 权重段", "1 个对应 AXI 主端口；容量由 HBM 分配决定", "持久权重 tile，包含 256 B INT8 + 16 B E_stat", "256 bit AXI beat；一个 tile 需 ceil(272/32)=9 beat", "片外源，不属于 MXU 内部容量"],
            ["MCU Stream Unpack", "不设置独立 tile-sized buffer", "beat[0:7]流式拆成权重字，beat[8]提取Scale word", "9-beat计数与ready/valid状态", "流式拆包，避免重复缓存"],
            ["WFIFO_DATA", "1 个 FIFO，128 bit x 512", "16 个 INT8 weight/entry", "8 KiB；数据侧 16 entry/tile，约 32 个 payload tile", "MCU 到 MXU 的弹性缓冲"],
            ["WFIFO_SCALE", "1 个独立FIFO，128 bit x 32", "一个tile的E_stat[0:15]", "16 B/entry；共32个tile Scale word", "与数据FIFO物理分开，按tile顺序绑定"],
            ["MXU W_BANK_A/B", "2 个 Bank；每 Bank 16x16 INT8 + 16 个 Scale", "当前 tile / 下一 tile", "每 Bank 256 B weight + 16 B E_stat = 272 B", "双缓冲；1 拍 swap"],
            ["PE weight registers", "256 个 PE x 2 bank = 512 个 8 bit 寄存器", "每个 PE 的 A/B bank 权重", "512 B INT8 寄存器总量", "等价于两份 16x16 权重 tile"],
            ["激活 SRAM/FIFO", "QOZ-BUF 分时复用；XHAT 消费时可经 XFIFO", "Q/O/Z 或广播来的 16 元素 activation block", "QOZ-BUF: 128 bit x 1632；XFIFO: 256 bit x 128", "长期/解耦存储；不复制到每个 PE"],
            ["activation input register", "1 个 128 bit 向量寄存级；物理实现可复制扇出", "当前 16 个 INT8 激活 + valid/row/tag", "16 x 8 bit = 128 bit", "切断 SRAM/跨核组合路径"],
            ["E_stream register", "每个发射上下文 1 个 8 bit 共享寄存器", "当前 activation block 的 Scale", "8 bit；同一拍 16 个 lane 共用", "随 MXU/DEQACC pipeline 延迟"],
            ["E_stat register", "每个活动 Bank 16 个 8 bit；A/B 共 32 个", "16 个输出通道各自的权重 Scale", "16 B/Bank；32 B 两 Bank", "不进入 PE 乘法器，只进 DEQACC 指数路径"],
            ["PSUM output register", "每个 MXU 结果 1 个 512 bit 输出 word", "16 个输出通道的 INT32 PSUM", "16 x 32 bit = 512 bit", "直接送 DEQACC；不是 16x16 PSUM buffer"],
            ["FACC", "FP32 512 bit x 51 x 2", "普通 GEMM/QK 的跨 K-tile 累加值", "约 6.38 KiB；1R1W；乒乓", "每 word 16 个 FP32 lane"],
            ["OACC", "FP32 512 bit x 816", "PV 的跨 KV block 输出累加值", "约 51 KiB；1R1W", "每 word 16 个 FP32 lane；PV 不走 FACC"],
            ["SBUF/PBUF", "SBUF: 512 bit x 51 x 2；PBUF: 128 bit x 51 x 2", "QK 的 score tile；EXP 后的 P tile", "SBUF 6.38 KiB；PBUF+E_p 约 1.69 KiB", "Attention 专用块级暂存"],
        ],
        [27*mm, 39*mm, 43*mm, 30*mm, 27*mm],
        small=True,
    ))
    story.append(Spacer(1, 4))
    story.append(callout(
        "直接回答“有几个存权重”",
        "从硬件资源角度：持久权重在 HBM；传输中有 Beat FIFO、流式拆包状态和两条 WFIFO；计算阵列内有 2 个 16x16 weight Bank。若只问 MXU 内部，答案是 2 份 16x16 INT8 权重寄存器阵列，合计 512 个 8 bit PE 权重寄存器；每份 Bank 另有 16 个 E_stat 寄存器。",
        fill=PALE_AMBER, stroke=colors.HexColor("#E5C277"),
    ))
    story.append(PageBreak())


def page_mcu(story):
    story.append(P("4. MCU：从 HBM beat 到可计算 weight tile", "H1CN"))
    story.append(P("每个 PCore 配一个私有 MCU。MCU 不做乘法，也不参与 PSUM 归约；它通过流式拆包把 HBM 上的 9 个 beat 变成 16 个 128-bit 权重 FIFO entry 和 1 个 128-bit Scale FIFO entry，不设置独立的 tile-sized 中间缓存。", "BodyCN"))
    story.append(flow([
        "HBM AXI\n256 bit=32 B/beat",
        "AXI Read Engine\n地址/突发/ID/超时",
        "Beat FIFO / CDC\nHBM 域 -> core 域",
        "Stream Unpack\n8 payload + 1 scale",
        "WFIFO_DATA\n16 x 128 bit",
        "WFIFO_SCALE\n1 x 128 bit",
        "WFIFO + ready\n等待 MXU 消费",
    ], widths=[18*mm, 3*mm, 21*mm, 3*mm, 20*mm, 3*mm, 21*mm, 3*mm, 20*mm, 3*mm, 20*mm, 3*mm, 20*mm], node_fill=PALE_BLUE))
    story.append(P("4.1 一个权重 tile 的字节核算", "H2CN"))
    story.append(code_box([
        "INT8 payload: 16 x 16 = 256 B",
        "Stationary Scale: 16 个输出列 x 1 B = 16 B",
        "完整 tile: 256 + 16 = 272 B",
        "HBM AXI: 256 bit = 32 B/beat；ceil(272/32) = 9 beat",
        "内部 MXU 数据装载: 256 B / 16 B per cycle = 16 cycles",
    ]))
    story.append(P("4.2 9 个 HBM beat 如何对应两个 FIFO", "H2CN"))
    story.append(P("前 8 个 HBM beat 是 256 B INT8 payload，每拍 32 B，拆成两个 128-bit 权重字，因此形成 16 个 `WFIFO_DATA` entry。第 9 个 HBM beat 的低 128 bit 是 16 个 E8M0 Scale，形成一个 `WFIFO_SCALE` entry；高 128 bit 只作为填充忽略。于是 HBM 侧是 9 拍，WFIFO_DATA 侧产生 16 个 entry，WFIFO_SCALE 侧产生 1 个 entry；Loader 再按 16 个 data entry 后 1 个 scale word 的顺序装入 inactive Bank。", "BodyCN"))
    story.append(callout(
        "WFIFO_DATA 的物理入口",
        "架构容量仍写作 128 bit x 512，但为保持 HBM 每拍接收能力，数据 FIFO 的写入口必须支持两个 128-bit 并行写通道；也可以用等价的 256-bit 写入、128-bit 读取的非对称 FIFO。若采用普通单写 128-bit FIFO，就必须增加半拍缓存，不能宣称每个 HBM beat 都能立即拆分写入。",
        fill=PALE_AMBER, stroke=colors.HexColor("#E5C277"),
    ))
    story.append(table(
        ["MCU 子模块", "需要保存的状态", "功能"],
        [
            ["AXI Read Engine", "araddr、arlen、ID、beat_count、rlast", "发出不跨 4 KiB 的 INCR 突发；9 beat 组成一个 tile"],
            ["CDC/Beat FIFO", "AXI 数据、ID、last、错误响应", "HBM 时钟域到 core 时钟域的安全跨域；HBM 响应不受 pipe_en 阻塞"],
            ["Stream Unpack", "beat_count、payload/scale phase、tile_complete", "前 8 拍双写 WFIFO_DATA，第 9 拍单写 WFIFO_SCALE"],
            ["WFIFO 写入器", "data_write_ptr、scale_write_ptr、watermark", "分别写入 128 bit x 512 数据 FIFO 和 128 bit x 32 Scale FIFO"],
            ["补给控制", "level、retry、timeout、error sticky", "低水位拉低 pcore_ready；AXI 超时进入 ABORT"],
        ],
        [31*mm, 57*mm, 78*mm],
        small=True,
    ))
    story.append(PageBreak())


def page_mxu_pe(story):
    story.append(P("5. MXU 与 PE：256 个乘法器如何工作", "H1CN"))
    story.append(P("MXU_KIND=0 时，MXU 是 16 个输出组的并行归约阵列。第 n 个输出组负责输出通道 n；每组有 16 个 PE，分别对应 K=0..15。激活按 K 维广播，权重在 PE 侧 stationary。", "BodyCN"))
    story.append(code_box([
        "                 output lane n=0                 output lane n=15",
        "a[0] ->  PE[0][0] ... PE[0][15]  -> 16 项和 -> PSUM[0]",
        "a[1] ->  PE[1][0] ... PE[1][15]  -> 16 项和 -> PSUM[1]",
        "  ...                  ...                         ...",
        "a[15] -> PE[15][0] ... PE[15][15] -> 16 项和 -> PSUM[15]",
        "             16 个 output group x 16 PE = 256 个 INT8 MAC",
    ]))
    story.append(P("5.1 单个 PE 应该包含什么", "H2CN"))
    story.append(table(
        ["PE 内结构", "数量/位宽", "理由"],
        [
            ["w_bank0 / w_bank1", "2 x 8 bit/PE", "双 Bank 支持当前 tile 计算与下一 tile 装载并行；swap 时只切 active_bank"],
            ["active-bank mux", "1 个选择器", "选择当前参与乘法的权重，避免重新搬移 256 个 PE 的内容"],
            ["INT8 signed multiplier", "1 个/PE，共 256 个", "q_activation x q_weight -> INT16 product"],
            ["product pipeline register", "至少 1 个/PE", "切断乘法器到加法树的时序路径，保持 1 MAC/cycle"],
            ["激活长期寄存器", "不放在 PE 内", "激活是每拍变化的共享输入；放入 256 个 PE 会产生复制、更新和扇出成本"],
            ["Scale / Tag / FP32 单元", "不放在 PE 内", "PE 只做 INT8 乘法；Scale 在 DEQACC 指数路径处理，Tag 走旁带"],
        ],
        [43*mm, 38*mm, 85*mm],
        small=True,
    ))
    story.append(P("5.2 激活到底复制到哪里", "H2CN"))
    story.append(P("架构上定义一个 128 bit activation input register，保存当前 16 个 INT8 激活。随后分成 16 路局部广播：a[k] 只送给同一归约行的 16 个 PE，即 a[k] -> PE[k][0:15]。它不是把一个激活值广播到全部 256 个 PE。物理综合为了扇出和布线可以复制寄存器，但那是实现优化，不改变架构上的一个输入向量语义。", "BodyCN"))
    story.append(callout(
        "为什么不把激活放入 PE",
        "一个权重在同一 tile 内 stationary 16 或 51 个周期，而激活每个 M 行都变化。让激活停留在 PE 会要求每行向 256 个位置写入或复制；采用 128 bit 入口寄存器 + 16 路局部广播，只需按拍更新一个向量，权重保持不动，数据流更简单。",
        fill=PALE_GREEN, stroke=colors.HexColor("#A7CFB5"),
    ))
    story.append(PageBreak())


def page_scale(story):
    story.append(P("6. Scale 的完整路线：如何保证和 PSUM 一致", "H1CN"))
    story.append(P("MXINT8-B16 有两类 Scale，不能混淆：`E_stream` 是当前激活 16 元素块的 Scale；`E_stat[n]` 是输出通道 n 对应的 16 个权重的 Scale。一个输出 lane 的反量化必须同时拿到这两者。", "BodyCN"))
    story.append(P("6.1 权重 Scale E_stat[n] 的路线", "H2CN"))
    story.append(flow([
        "HBM tile\n16 B E_stat",
        "MCU Stream Unpack\n按 beat 流式拆分",
        "WFIFO_SCALE\n128 bit x 32",
        "W_BANK_A/B\n每 Bank 16 个 E_stat",
        "MXU OUT sideband\n锁存 E_stat[15:0]",
        "DEQACC L0-L4\n同数据延迟",
        "lane n\n指数加法",
    ], widths=[22*mm, 5*mm, 22*mm, 5*mm, 22*mm, 5*mm, 22*mm, 5*mm, 23*mm, 5*mm, 22*mm, 5*mm, 24*mm], node_fill=PALE_AMBER))
    story.append(P("6.2 激活 Scale E_stream 的路线", "H2CN"))
    story.append(flow([
        "GCore XHAT/E_a\n或本地 Q/P/Z + E",
        "activation input\n128 bit + 1x8 bit E",
        "MXU 发射寄存\nE_stream 保持",
        "MXU 输出 sideband\n与 PSUM 同一 tag",
        "DEQACC 16 lane\n共享 E_stream",
    ], widths=[31*mm, 5*mm, 29*mm, 5*mm, 29*mm, 5*mm, 29*mm, 5*mm, 32*mm], node_fill=PALE_GREEN))
    story.append(P("6.3 Scale 的寄存器数量口径", "H2CN"))
    story.append(table(
        ["位置", "建议/规格中的数量", "保存什么"],
        [
            ["活动权重 Bank", "A/B 两份；每份 16 个 8 bit = 16 B；总计 32 个 Scale 寄存器", "两个 tile 的 E_stat[0:15]"],
            ["激活入口", "1 个 8 bit E_stream 寄存器/发射上下文", "当前 16 个激活码共享的 E_a"],
            ["MXU 输出边界", "1 个 E_stream + 16 个 E_stat 的 sideband word", "对齐当前 512 bit PSUM"],
            ["DEQACC pipeline", "架构上与数据同样跨 5 级；每级保存 E_stream/E_stat 和 tag", "L0-L4 使用的 E_stream/E_stat 和 tag"],
            ["全局源存储", "GCore E_a: 8 bit x 3264；PCore E_qoz: 8 bit x 1632；E_p/E_z 按专用 buffer 配套", "不是每个 PE 的 Scale；是被消费张量的块 Scale"],
        ],
        [36*mm, 55*mm, 77*mm],
        small=True,
    ))
    story.append(callout(
        "对齐规则",
        "每次 MXU 发射必须形成一个不可拆开的上下文：activation[15:0]、E_stream、active_bank、E_stat[15:0]、valid、pipe_tag。数据走 MXU 和 DEQACC，Scale 与 Tag 走等长度旁带流水。只要 PSUM[n]、E_stat[n]、E_stream、写回地址同一拍到达 lane n，Psum 与 Scale 就不会错配。",
        fill=PALE_RED, stroke=colors.HexColor("#E0AAA5"),
    ))
    story.append(PageBreak())


def page_schedule(story):
    story.append(P("7. 填充、稳态与排空：权重加载如何和计算并行", "H1CN"))
    story.append(P("双 Bank 是并行的关键。当前计算使用 active Bank，MCU/WFIFO 把下一 tile 写入 inactive Bank。两者不能写同一 Bank；只有下一 tile 完整、校验通过且当前 tile 的发射边界到达，才能 1 拍切换 active_bank。", "BodyCN"))
    story.append(P("7.1 推荐时间线（每个 tile 处理 M=51 行）", "H2CN"))
    story.append(table(
        ["时间区间", "计算侧", "装载侧", "说明"],
        [
            ["Prolog t=0..15", "等待 tile 0 完整；不能使用未完成的 Bank", "把 tile 0 的 16 个 128 bit payload entry 写入 Bank A，并写入 16 个 E_stat", "若系统在描述符前已预取，16 拍可被隐藏；否则这是首 tile 预热"],
            ["首 tile t=16..66", "Bank A 处理 m=0..50，每拍一个 activation vector", "Bank B 可装载 tile 1；只需 16 个数据拍，余下时间等待/预取", "51 拍计算窗口覆盖 16 拍装载，下一 tile 可提前 ready"],
            ["Swap t=67", "停止发射一个边界事件，切 active_bank A->B", "检查 Bank B valid、tile 坐标、Scale 完整", "文档冻结为全局 1 拍 swap；不允许半 tile swap"],
            ["稳态 tile t+1", "Bank B 处理下一 tile 的 m=0..50", "Bank A 装载再下一 tile", "形成计算与权重加载重叠"],
            ["尾部", "最后一个 activation 输入后，MXU/DEQACC 仍有在途数据", "停止对已完成 Bank 的写入或准备下一 descriptor", "最后写回滞后 PIPE_DRAIN=11 拍；CNT_WB 负责正确地址"],
        ],
        [28*mm, 47*mm, 47*mm, 44*mm],
        small=True,
    ))
    story.append(P("7.2 为什么不“边装同一 Bank 边算同一 Bank”", "H2CN"))
    story.append(P("同一 Bank 的一部分权重尚未到达时，MXU 可能已经读到了另一部分权重，结果会把不同 tile 的数据混在一起。因此可以“边计算边装载”，但必须是计算 active Bank、装载 inactive Bank。用户提出的“第一个周期加载 n=0 同时 m=0 开始算”只有在 n=0..15 的当前 tile 已经预加载，或存在第二套完整 Bank 时才成立；不能在同一个尚未完整的 Bank 上直接启动。", "BodyCN"))
    story.append(P("7.3 地址和标签怎样不乱", "H2CN"))
    story.extend(bullets([
        "CNT_EX 在输入侧产生 m、k-tile、n-tile 地址；CNT_WB 延迟 PIPE_DRAIN 后产生写回地址。不能用同一组计数器直接驱动两端。",
        "Scale 和 tile_tag 随 inactive Bank 的 ready 状态提交；swap 时同时切换 weight data、E_stat、bank_id 和 tile 坐标。",
        "若 WFIFO 低于完整 tile 阈值，MCU 继续补给，PCore 拉低 ready，pipe_en 整体冻结；HBM 响应和 FIFO 指针更新属于 always-live 域。",
        "首 tile 和 descriptor 切换时可以用 11 拍排空；若采用文档中的 tag pipeline，则结果顺序连续时可不排空，但写回标签必须跨 11 拍跟随数据。",
    ], "BodySmall"))
    story.append(PageBreak())


def page_psum_deq(story):
    story.append(P("8. 重点：PSUM 之后到底发生什么", "H1CN"))
    story.append(callout(
        "结论先说",
        "不需要、也不应该额外建立一个 16x16 的 INT32 PSUM 寄存器矩阵。16x16 的乘法结果已经沿 K 维在 MXU 加法树中归约；MXU 的架构输出就是一个 512 bit word，包含 16 个 INT32 PSUM。该 word 直接进入 16 lane DEQACC。",
        fill=PALE_RED, stroke=colors.HexColor("#E0AAA5"),
    ))
    story.append(P("8.1 MXU 内部已有的寄存器与 PSUM 输出", "H2CN"))
    story.append(table(
        ["位置", "保存的数据", "数量", "是否是额外 PSUM buffer"],
        [
            ["PE 乘积寄存器", "INT8 x INT8 -> INT16", "16 个输出组 x 16 个 PE = 256 个 product register", "不是；是乘法流水寄存器"],
            ["加法树 L1", "局部部分和", "每组 8 个中间值", "不是；分布在每个输出组内"],
            ["加法树 L2", "局部部分和", "每组 4 个中间值", "不是"],
            ["加法树 L3", "局部部分和", "每组 2 个中间值", "不是"],
            ["加法树 L4/OUT", "每个输出通道的 INT32 归约结果", "16 个 INT32 = 512 bit", "这是 PSUM output register，不是 16x16"],
        ],
        [30*mm, 54*mm, 37*mm, 45*mm],
        small=True,
    ))
    story.append(P("8.2 DEQACC 五级流水", "H2CN"))
    story.append(table(
        ["拍", "级", "每个 lane 的动作", "全局数据"],
        [
            ["t+6", "MXU OUT", "Adder_L4结果写入Psum_out_REG；锁存E_stream、E_stat[n]、tag", "512 bit PSUM + Scale/Tag sideband"],
            ["t+7", "L0", "sign/abs/zero/LZC(32)，同时发出累加器读地址", "16 lane并行；输入保持INT32"],
            ["t+8", "L1", "barrel shift，形成FP32尾数与base exponent；锁存old_acc", "不做通用FP32乘法"],
            ["t+9", "L2", "scale_exp = E_stream + E_stat[n] - 266 + EXP_FOLD", "每lane一个扩展指数加法路径"],
            ["t+10", "L3", "partial_fp[n]与旧FP32累加值相加；first_k时BYPASS", "16个FP32 add；不含alpha乘法器"],
            ["t+11", "L4/WB", "按lane_mask、write_dst、acc_addr提交写回", "512 bit FP32 word，1R1W读改写"],
        ],
        [15*mm, 19*mm, 82*mm, 50*mm],
        small=True,
    ))
    story.append(P("8.3 反量化公式与位宽", "H2CN"))
    story.append(code_box([
        "decode(a) = q_a x 2^(E_stream - 133)",
        "decode(w[n]) = q_w[n] x 2^(E_stat[n] - 133)",
        "psum[n] = sum(k=0..15) q_a[k] x q_w[k,n]      (INT32)",
        "partial_fp[n] = FP32(psum[n]) x 2^(E_stream + E_stat[n] - 266 + EXP_FOLD)",
        "普通 GEMM/PV: EXP_FOLD=0；QK: EXP_FOLD=-4，表示 1/sqrt(256)=2^-4",
    ]))
    story.append(callout(
        "为什么 DEQACC 不放 alpha",
        "在线 Softmax 的 alpha 是跨 KV block 的 FP32 重缩放因子，规范已把它交给 VPU 的 VOP_OACC_SCALE。DEQACC 保持为 LZC、移位、指数加法、FP32 加法和写回，便于独立验证，也不需要在 16 lane 中增加 alpha 乘法器。",
        fill=PALE_GREEN, stroke=colors.HexColor("#A7CFB5"),
    ))
    story.append(PageBreak())


def page_accum(story):
    story.append(P("9. 反量化结束后的“归约”：不是横向归约，而是逐 lane 累加", "H1CN"))
    story.append(P("需要把两个概念分开：MXU 已完成一个 K-tile 内的横向归约；DEQACC 后的累加是跨 K-tile 或跨 Attention block 的纵向累加。每个 lane 只和目标存储器中同一地址的同一 lane 相加。", "BodyCN"))
    story.append(P("9.1 普通 GEMM 与 QK：FACC 读改写", "H2CN"))
    story.append(flow([
        "16xINT32 PSUM",
        "DEQACC\n16xFP32 partial",
        "FACC read\n16xFP32 old",
        "16 lane FP32 add\nold + partial",
        "FACC write\n16xFP32 new",
    ], widths=[27*mm, 7*mm, 30*mm, 7*mm, 28*mm, 7*mm, 29*mm, 7*mm, 30*mm], node_fill=PALE_BLUE))
    story.append(P("FACC 的一个 word 是 16 个 FP32 累加器，而不是 16 个 INT32 PSUM 的二次归约器。对同一输出 word 的 K-tile 依次执行：FACC_new[lane] = FACC_old[lane] + partial_fp[lane]。固定 K-tile 顺序保证确定性。", "BodyCN"))
    story.append(P("9.2 三种写回场景", "H2CN"))
    story.append(table(
        ["场景", "DEQACC 后目标", "是否跨 K-tile", "需要的 16 lane 状态"],
        [
            ["普通 q/k/v/o/gate/up/down GEMM", "FACC；final_k 时送最终目标", "通常需要；Kt=16/32/64 等", "FACC old[15:0]、partial[15:0]、new[15:0]"],
            ["QK^T", "FACC 先积累，最后冲刷到 SBUF/rowmax", "Kt=256/16=16", "16 个 FP32 score 累加 lane；最终 mask 在 rowmax 前施加"],
            ["P x V", "OACC 直接读改写", "Kt=1，不需要 FACC", "16 个 FP32 OACC lane；块间 alpha 由 VPU 先缩放 OACC"],
        ],
        [38*mm, 53*mm, 34*mm, 41*mm],
        small=True,
    ))
    story.append(P("9.3 反量化结束后到底需要多少寄存器", "H2CN"))
    story.append(table(
        ["寄存器/存储", "建议数量", "保存什么", "说明"],
        [
            ["DEQACC 输入寄存器", "16 x 32 bit", "当前 16 个 INT32 PSUM", "一拍一个 512 bit 输入 word；可与 MXU OUT 合并实现"],
            ["DEQACC 尾数/指数寄存器", "16 lane；每 lane 尾数 + 初始指数 + scale_exp", "FP32 规格化中间结果", "具体拆分位宽由认证 FP32/定点单元决定；架构逻辑为 16 lane"],
            ["DEQACC partial 寄存器", "16 x 32 bit FP32", "反量化后的 partial_fp[15:0]", "进入 L3 加法器"],
            ["累加器旧值寄存器", "16 x 32 bit FP32", "FACC/OACC SRAM 读出的 old[15:0]", "与 partial 同拍对齐"],
            ["累加器结果寄存器", "16 x 32 bit FP32", "new[15:0] = old + partial", "写回 512 bit word"],
            ["真正的长期累加存储", "FACC/OACC SRAM，不是寄存器", "跨 tile 存活的 FP32 累加值", "FACC 51x2 words；OACC 816 words"],
        ],
        [36*mm, 33*mm, 54*mm, 43*mm],
        small=True,
    ))
    story.append(callout(
        "所以“归约用多少寄存器”的准确回答",
        "没有一个新的 16 路归约器，也没有 16x16 PSUM 寄存器。横向 16 项归约已经由 MXU 的 16 组加法树完成；DEQACC 后只需 16 lane 的 FP32 partial、16 lane 的旧累加值和 16 lane 的新累加值流水寄存器，长期状态放在 FACC/OACC 的 512 bit SRAM word 中。",
        fill=PALE_AMBER, stroke=colors.HexColor("#E5C277"),
    ))
    story.append(PageBreak())


def page_qk_pv(story):
    story.append(P("10. QK 与 PV 中的具体去向", "H1CN"))
    story.append(P("同一套 MXU/DEQACC 因为 K-tile 数量不同，后面的累加器选择不同。理解这个分叉，就能解释为什么 FACC 对普通 GEMM/QK 很重要，而 PV 直接占用 OACC。", "BodyCN"))
    story.append(P("10.1 QK^T 路径", "H2CN"))
    story.append(flow([
        "Q tile + K tile\nMXU 16x16 INT8",
        "PSUM[15:0]\n16xINT32",
        "DEQACC\nEXP_FOLD=-4",
        "FACC\n累加 16 个 K-tile",
        "VOP_SMAX_ROWMX\n先 mask 后 rowmax",
        "SBUF\nFP32 S[51,16]",
    ], widths=[20*mm, 3*mm, 21*mm, 3*mm, 20*mm, 3*mm, 20*mm, 3*mm, 23*mm, 3*mm, 22*mm], node_fill=PALE_BLUE))
    story.append(P("QK 的 K=256，因此 Kt=256/16=16。每个 output lane 是一个 score。前 15 个 K-tile 的 DEQACC 结果进入 FACC；第 16 个完成后，FACC 冲刷出这个 score tile。对 suffix/padding 的非法 key，必须在 rowmax 前写成负无穷语义，不能先置零再修正。", "BodyCN"))
    story.append(P("10.2 PV 路径", "H2CN"))
    story.append(flow([
        "P tile + V tile\n16 key x 16 channel",
        "PSUM[15:0]\n16xINT32",
        "DEQACC\n16xFP32 partial",
        "OACC read-modify-write\nold + partial",
        "VPU OACC_SCALE\nalpha 在 PV 前执行",
        "A_FIN\nOACC / l -> O",
    ], widths=[20*mm, 3*mm, 18*mm, 3*mm, 20*mm, 3*mm, 24*mm, 3*mm, 23*mm, 3*mm, 22*mm], node_fill=PALE_GREEN))
    story.append(P("PV 的 K 是 key 维，一个 B_kv=16 的 P tile 恰好覆盖一次 K=16 归约，所以 Kt=1。结果直接对 OACC 做 FP32 读改写。下一个 KV block 到来前，先执行 OACC <- alpha_b x OACC，再把新的 PV partial 加进去；alpha 不在 DEQACC 中。", "BodyCN"))
    story.append(table(
        ["存储", "每个 word", "总组织", "为什么这样放"],
        [
            ["SBUF", "16 个 FP32 score", "512 bit x 51 x 2", "QK 一个 block 的 51 行、16 列 score；乒乓给 EXP 读写"],
            ["PBUF + E_p", "16 个 INT8 P + 1 个 E_p", "128 bit x 51 x 2 + Scale", "exp 结果量化后供 PV，沿 key 方向 Scale"],
            ["FACC", "16 个 FP32", "512 bit x 51 x 2", "QK 的 16 个 K-tile 或普通 GEMM 的跨 K-tile partial"],
            ["OACC", "16 个 FP32 输出通道", "512 bit x 816", "PV 跨 55 个 KV block 的 O 累加；还被 alpha/A_FIN 使用"],
        ],
        [26*mm, 35*mm, 45*mm, 60*mm],
        small=True,
    ))
    story.append(PageBreak())


def page_precision(story):
    story.append(P("11. 精度边界：哪些是 INT8、INT32、FP32", "H1CN"))
    story.append(table(
        ["数据/运算", "存储格式", "计算格式", "转换发生位置"],
        [
            ["HBM 权重 payload", "INT8；每 16 个码配 1 个 E8M0 E_stat", "MCU 只搬运/解包", "HBM -> Stream Unpack -> WFIFO"],
            ["激活输入 XHAT/Q/P/Z", "INT8 + E_stream", "MXU 输入 INT8", "GCore/PCore 量化后进入 SRAM/FIFO"],
            ["PE 乘法", "INT8 x INT8", "INT16 product", "MXU PE 内"],
            ["MXU K=16 归约", "中间整数", "INT32 PSUM 接口", "4 级平衡加法树；输出 512 bit"],
            ["反量化", "INT32 PSUM + E_stream/E_stat", "FP32 partial", "DEQACC L0-L2；E8M0 只需要指数/移位路径"],
            ["跨 tile 累加", "FACC/OACC FP32", "FP32 add", "DEQACC L3；固定 K-tile 顺序"],
            ["QK mask/rowmax", "FP32", "FP32 compare/选择", "VPU/SFU 冲刷 FACC 时，mask 在 rowmax 前"],
            ["alpha", "FP32 x 51", "FP32 multiply", "VPU OACC_SCALE；独占 OACC 端口，和 PV 不重叠"],
            ["A_FIN", "OACC FP32", "FP32 reciprocal + multiply", "VPU/SFU；最后量化为 MXINT8 O"],
            ["最终残差/CNET", "FP32 流，落盘 BF16", "FP32 add/tree", "CNET/GCore；只在存储边界舍入 BF16"],
        ],
        [36*mm, 40*mm, 42*mm, 48*mm],
        small=True,
    ))
    story.append(P("11.1 INT32 PSUM 为什么足够", "H2CN"))
    story.append(code_box([
        "|q_a| <= 127, |q_w| <= 127",
        "单项最大值 = 127 x 127 = 16,129",
        "16 项最大绝对和 <= 16 x 16,129 = 258,064",
        "258,064 远小于 signed INT32 上限 2,147,483,647",
        "因此 MXU 输出统一采用 16 个 INT32；不需要 16x16 的长期 PSUM 存储",
    ]))
    story.append(P("11.2 为什么跨 tile 不能直接 INT32 相加", "H2CN"))
    story.append(P("不同 K-tile 的激活块和权重块通常有不同 E。两个 tile 的整数 PSUM 代表的真实量纲不同，直接把 INT32 码值相加没有数学意义。必须先使用各自的 E_stream + E_stat 做反量化到 FP32，再在 FACC/OACC 中相加。", "BodyCN"))
    story.append(callout(
        "确定性要求",
        "Scale 指数方程、INT8 饱和、RNE、FP32 加法顺序和 CNET 固定树拓扑都属于架构可见行为。RTL 仿真应同时与位精确数值模型、周期模型和接口标签模型比对。",
        fill=PALE_GREEN, stroke=colors.HexColor("#A7CFB5"),
    ))
    story.append(PageBreak())


def page_interface(story):
    story.append(P("12. 建议冻结的 RTL 接口与实现检查表", "H1CN"))
    story.append(P("下面这些接口一旦冻结，MCU、MXU、DEQACC 和存储模块就可以并行开发，且不会在 Scale、地址或流水延迟上互相误解。", "BodyCN"))
    story.append(table(
        ["接口", "建议 payload", "关键约束"],
        [
            ["MCU -> WFIFO", "W_DATA[127:0]、W_SCALE[127:0]、tile_id、entry_idx、valid/ready", "W_SCALE一次携带16个output-column的E_stat，并与W_DATA按tile顺序绑定"],
            ["WFIFO -> MXU", "weight_entry[127:0]、E_stat[15:0]、bank_id、tile_id", "完整 tile 才能置 bank_valid；不能半 tile swap"],
            ["Activation -> MXU", "act[127:0]、E_stream[7:0]、row、valid", "E_stream 与 act 属于同一 16 元素 block"],
            ["MXU -> DEQACC", "psum[511:0]、E_stream、E_stat[127:0]、pipe_tag、valid", "psum[n] 对应 E_stat[n]；sideband 与数据跨同样级数"],
            ["DEQACC -> accumulator", "partial[511:0]、deq_tag、valid", "acc_sel=FACC/OACC/SBUF；acc_addr 和 tile_last 必须可靠"],
            ["FACC/OACC", "512 bit 1R1W", "同拍读旧 word、加法、写新 word；与 PV/OACC_SCALE 的端口占用互斥"],
            ["全局控制", "pipe_en、pcore_ready、bank_ready、fatal/abort", "计算通道受 pipe_en 冻结；HBM/FIFO 补给 always-live"],
        ],
        [32*mm, 65*mm, 69*mm],
        small=True,
    ))
    story.append(P("12.1 最小断言集合", "H2CN"))
    story.extend(bullets([
        "bank_valid=1 才允许 MXU 发射；active Bank 与 load Bank 不能相同。",
        "valid && !ready 时，weight、Scale、activation、tag 全部保持稳定。",
        "每个 psum lane n 使用同一拍的 E_stat[n]，不允许把一个 eb 广播给 16 个不同 weight Scale lane。",
        "final_k=0 只更新 FACC；final_k=1 根据 acc_sel 写最终目标；QK 的最后结果才触发 SBUF/rowmax 冲刷。",
        "DEQACC 不含 alpha 乘法器；alpha 只能由 VPU OACC_SCALE 完成。",
        "最后一个输入发射后至少等待/跟踪 PIPE_DRAIN=11 拍，除非完整 tag pipeline 已经证明相邻 descriptor 不冲突。",
    ], "BodySmall"))
    story.append(Spacer(1, 5))
    story.append(callout(
        "最终架构一句话",
        "HBM/MCU 负责把带 E_stat 的 16x16 INT8 权重 tile 送进双 Bank；激活以 128 bit 向量进入并局部广播到 256 个 PE；MXU 在 16 个输出组内完成 K=16 的 INT32 归约，输出 16xINT32 PSUM；DEQACC 用 E_stream 和逐 lane 的 E_stat 还原 16 个 FP32 partial；最后在 FACC、OACC 或 SBUF 对应地址逐 lane 读改写，长期累加状态不放在 PE，也不新增 16x16 PSUM 缓冲。",
        fill=PALE_AMBER, stroke=colors.HexColor("#E5C277"),
    ))
    story.append(Spacer(1, 8))
    story.append(P("参考规格页：第 24、29-35、41-44、50-58、74-83 页。", "BodySmall"))


def draw_page(canvas, doc):
    canvas.saveState()
    page = canvas.getPageNumber()
    width, height = A4
    if page > 1:
        canvas.setStrokeColor(GRID)
        canvas.setLineWidth(0.45)
        canvas.line(18 * mm, height - 12 * mm, width - 18 * mm, height - 12 * mm)
        canvas.setFont("SimHei", 7.4)
        canvas.setFillColor(MUTED)
        canvas.drawString(18 * mm, height - 9 * mm, "VLA · 单个矩阵计算数据通路")
        canvas.drawRightString(width - 18 * mm, 9 * mm, f"第 {page - 1} 页")
        canvas.line(18 * mm, 12 * mm, width - 18 * mm, 12 * mm)
    canvas.restoreState()


def main():
    doc = BaseDocTemplate(
        str(OUTPUT), pagesize=A4,
        leftMargin=18 * mm, rightMargin=18 * mm,
        topMargin=18 * mm, bottomMargin=17 * mm,
        title="单个矩阵计算数据通路规格说明",
        author="VLA DEA-8 Team",
        allowSplitting=1,
    )
    frame = Frame(doc.leftMargin, doc.bottomMargin, doc.width, doc.height, id="main")
    doc.addPageTemplates([PageTemplate(id="main", frames=[frame], onPage=draw_page)])
    story = []
    cover(story)
    page_scope(story)
    page_overview(story)
    page_storage(story)
    page_mcu(story)
    page_mxu_pe(story)
    page_scale(story)
    page_schedule(story)
    page_psum_deq(story)
    page_accum(story)
    page_qk_pv(story)
    page_precision(story)
    page_interface(story)
    doc.build(story)
    print(OUTPUT)


if __name__ == "__main__":
    main()
