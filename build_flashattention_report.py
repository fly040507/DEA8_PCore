from __future__ import annotations

from pathlib import Path
from typing import Iterable, Sequence

from pptx import Presentation
from pptx.dml.color import RGBColor
from pptx.enum.shapes import MSO_CONNECTOR, MSO_SHAPE
from pptx.enum.text import MSO_ANCHOR, PP_ALIGN
from pptx.util import Inches, Pt


OUT = Path("FlashAttention_FPGA_Architecture_Report_v8.pptx")

W = 13.333
H = 7.5

NAVY = "163A5F"
BLUE = "1E6A9E"
CYAN = "2F8FA8"
RED = "C23B32"
GREEN = "3D7A57"
AMBER = "B26A00"
INK = "17202A"
TEXT = "29343D"
MUTED = "66727C"
LIGHT = "F4F7F9"
PALE_BLUE = "EAF2F8"
PALE_RED = "FBEDEC"
PALE_GREEN = "EAF4EE"
GRID = "D8DEE3"
WHITE = "FFFFFF"
BLACK = "000000"

FONT_CN = "Microsoft YaHei"
FONT_MONO = "Consolas"


def rgb(hex_color: str) -> RGBColor:
    return RGBColor.from_string(hex_color)


def add_rect(slide, x, y, w, h, fill=WHITE, line=GRID, radius=False, width=1.0):
    shape_type = MSO_SHAPE.ROUNDED_RECTANGLE if radius else MSO_SHAPE.RECTANGLE
    sh = slide.shapes.add_shape(shape_type, Inches(x), Inches(y), Inches(w), Inches(h))
    sh.fill.solid()
    sh.fill.fore_color.rgb = rgb(fill)
    sh.line.color.rgb = rgb(line)
    sh.line.width = Pt(width)
    if radius:
        try:
            sh.adjustments[0] = 0.08
        except Exception:
            pass
    return sh


def add_line(slide, x1, y1, x2, y2, color=GRID, width=1.5, dash=None):
    # Keep connector extents strictly positive for older PowerPoint/WPS parsers.
    if x1 == x2:
        x2 += 0.001
    if y1 == y2:
        y2 += 0.001
    ln = slide.shapes.add_connector(
        MSO_CONNECTOR.STRAIGHT, Inches(x1), Inches(y1), Inches(x2), Inches(y2)
    )
    ln.line.color.rgb = rgb(color)
    ln.line.width = Pt(width)
    if dash:
        ln.line.dash_style = dash
    return ln


def add_arrow(slide, x1, y1, x2, y2, color=BLUE, width=2.0):
    ln = add_line(slide, x1, y1, x2, y2, color, width)
    ln.line.end_arrowhead = True
    return ln


def add_text(
    slide,
    text,
    x,
    y,
    w,
    h,
    size=18,
    color=TEXT,
    bold=False,
    font=FONT_CN,
    align=PP_ALIGN.LEFT,
    valign=MSO_ANCHOR.TOP,
    margin=0.04,
    fit=False,
):
    box = slide.shapes.add_textbox(Inches(x), Inches(y), Inches(w), Inches(h))
    tf = box.text_frame
    tf.clear()
    tf.margin_left = Inches(margin)
    tf.margin_right = Inches(margin)
    tf.margin_top = Inches(margin)
    tf.margin_bottom = Inches(margin)
    tf.vertical_anchor = valign
    tf.word_wrap = True
    p = tf.paragraphs[0]
    p.alignment = align
    p.space_after = Pt(0)
    p.space_before = Pt(0)
    p.line_spacing = 1.05
    run = p.add_run()
    run.text = text
    run.font.name = font
    run.font.size = Pt(size)
    run.font.bold = bold
    run.font.color.rgb = rgb(color)
    if fit:
        tf.fit_text(font_family=font, max_size=size)
    return box


def add_rich_text(slide, parts, x, y, w, h, size=18, align=PP_ALIGN.LEFT, valign=MSO_ANCHOR.TOP):
    box = slide.shapes.add_textbox(Inches(x), Inches(y), Inches(w), Inches(h))
    tf = box.text_frame
    tf.clear()
    tf.margin_left = tf.margin_right = Inches(0.04)
    tf.margin_top = tf.margin_bottom = Inches(0.03)
    tf.vertical_anchor = valign
    tf.word_wrap = True
    p = tf.paragraphs[0]
    p.alignment = align
    p.space_after = Pt(0)
    for item in parts:
        text, color, bold, font = item
        r = p.add_run()
        r.text = text
        r.font.name = font
        r.font.size = Pt(size)
        r.font.bold = bold
        r.font.color.rgb = rgb(color)
    return box


def add_bullets(slide, items: Sequence[str], x, y, w, h, size=16, color=TEXT, bullet_color=None):
    box = slide.shapes.add_textbox(Inches(x), Inches(y), Inches(w), Inches(h))
    tf = box.text_frame
    tf.clear()
    tf.margin_left = Inches(0.02)
    tf.margin_right = Inches(0.02)
    tf.margin_top = Inches(0.02)
    tf.margin_bottom = Inches(0.02)
    tf.word_wrap = True
    for i, item in enumerate(items):
        p = tf.paragraphs[0] if i == 0 else tf.add_paragraph()
        p.text = "•  " + item
        p.font.name = FONT_CN
        p.font.size = Pt(size)
        p.font.color.rgb = rgb(color)
        p.space_after = Pt(7)
        p.line_spacing = 1.08
    return box


def add_title(slide, number: str, title: str, subtitle: str | None = None):
    add_text(slide, number, 0.55, 0.32, 0.45, 0.36, 14, RED, True)
    add_text(slide, title, 1.02, 0.23, 11.7, 0.54, 25, INK, True)
    add_line(slide, 0.55, 0.83, 12.78, 0.83, NAVY, 1.1)
    if subtitle:
        add_text(slide, subtitle, 1.03, 0.88, 11.5, 0.3, 10.5, MUTED)


def add_footer(slide, page: int, source="VLA_Arch_Spec_v1 · FlashAttention architecture review"):
    add_text(slide, source, 0.58, 7.18, 10.8, 0.18, 8.5, MUTED)
    add_text(slide, f"{page:02d}", 12.15, 7.12, 0.55, 0.22, 9, NAVY, True, align=PP_ALIGN.RIGHT)


def add_section_tag(slide, text, x, y, w, color=NAVY):
    add_rect(slide, x, y, w, 0.28, color, color)
    add_text(slide, text, x + 0.08, y + 0.01, w - 0.16, 0.24, 10.5, WHITE, True, valign=MSO_ANCHOR.MIDDLE)


def add_metric(slide, value, label, x, y, w, accent=BLUE, note=None):
    add_rect(slide, x, y, w, 1.05, WHITE, GRID, radius=True)
    add_rect(slide, x, y, 0.08, 1.05, accent, accent)
    add_text(slide, value, x + 0.22, y + 0.12, w - 0.3, 0.4, 25, accent, True)
    add_text(slide, label, x + 0.22, y + 0.56, w - 0.3, 0.25, 11, MUTED)
    if note:
        add_text(slide, note, x + 0.22, y + 0.81, w - 0.3, 0.16, 8.5, MUTED)


def set_cell_text(cell, text, size=12, color=TEXT, bold=False, align=PP_ALIGN.LEFT, fill=None):
    if fill:
        cell.fill.solid()
        cell.fill.fore_color.rgb = rgb(fill)
    cell.margin_left = Inches(0.06)
    cell.margin_right = Inches(0.06)
    cell.margin_top = Inches(0.04)
    cell.margin_bottom = Inches(0.04)
    tf = cell.text_frame
    tf.clear()
    tf.vertical_anchor = MSO_ANCHOR.MIDDLE
    p = tf.paragraphs[0]
    p.alignment = align
    p.space_after = Pt(0)
    r = p.add_run()
    r.text = str(text)
    r.font.name = FONT_CN
    r.font.size = Pt(size)
    r.font.bold = bold
    r.font.color.rgb = rgb(color)


def add_table(slide, rows, cols, data, x, y, w, h, col_widths=None, header=True, font_size=11):
    table = slide.shapes.add_table(rows, cols, Inches(x), Inches(y), Inches(w), Inches(h)).table
    if col_widths:
        for i, cw in enumerate(col_widths):
            table.columns[i].width = Inches(cw)
    for r in range(rows):
        for c in range(cols):
            value = data[r][c]
            fill = NAVY if header and r == 0 else (LIGHT if r % 2 == 0 else WHITE)
            color = WHITE if header and r == 0 else TEXT
            set_cell_text(table.cell(r, c), value, font_size, color, header and r == 0, PP_ALIGN.CENTER if c > 0 else PP_ALIGN.LEFT, fill)
    return table


def new_slide(prs):
    slide = prs.slides.add_slide(prs.slide_layouts[6])
    slide.background.fill.solid()
    slide.background.fill.fore_color.rgb = rgb(WHITE)
    return slide


def title_slide(prs):
    s = new_slide(prs)
    add_rect(s, 0, 0, W, H, WHITE, WHITE)
    add_rect(s, 0, 0, 0.18, H, NAVY, NAVY)
    add_text(s, "VLA / PI0 ACTION EXPERT", 0.72, 0.58, 5.5, 0.35, 15, NAVY, True)
    add_text(s, "FlashAttention FPGA架构方案", 0.72, 1.38, 11.7, 0.72, 34, INK, True)
    add_text(s, "在线Softmax · 880物理序列 · Bkv=16 · MXINT8-B16 · 跨块流水", 0.75, 2.2, 11.5, 0.4, 16, MUTED)

    # Architecture motif
    add_section_tag(s, "ALGORITHM", 0.78, 3.25, 2.05, BLUE)
    add_section_tag(s, "MAPPING", 3.35, 3.25, 2.05, CYAN)
    add_section_tag(s, "PIPELINE", 5.92, 3.25, 2.05, GREEN)
    add_section_tag(s, "RESOURCES", 8.49, 3.25, 2.05, RED)
    add_section_tag(s, "CYCLES", 11.06, 3.25, 1.55, AMBER)
    for x1, x2 in [(2.83, 3.35), (5.40, 5.92), (7.97, 8.49), (10.54, 11.06)]:
        add_arrow(s, x1, 3.39, x2, 3.39, NAVY, 1.5)

    add_rect(s, 0.78, 4.08, 11.84, 1.56, LIGHT, GRID, radius=True)
    add_text(s, "目标", 1.02, 4.3, 0.7, 0.3, 14, RED, True)
    add_text(s, "在16×16 INT8矩阵核和有限片上存储条件下，确定可实现、可验证、周期可审计的FlashAttention数据通路。", 1.78, 4.24, 10.2, 0.62, 20, TEXT, True, valign=MSO_ANCHOR.MIDDLE)
    add_text(s, "第一版汇报方案", 0.78, 6.58, 2.8, 0.3, 12, NAVY, True)
    add_text(s, "2026.08", 11.25, 6.58, 1.35, 0.3, 12, MUTED, align=PP_ALIGN.RIGHT)


def overview_slide(prs, page):
    s = new_slide(prs)
    add_title(s, "01", "汇报主线与基线参数", "从数学等价到RTL资源映射，所有数字由固定模型形状推导")
    add_metric(s, "51", "Suffix queries", 0.65, 1.32, 2.2, BLUE, "1 state + 50 action")
    add_metric(s, "867 → 880", "Logical → physical keys", 3.05, 1.32, 2.45, CYAN, "16对齐，13 padding")
    add_metric(s, "8 : 1", "Query heads : KV head", 5.7, 1.32, 2.2, GREEN, "每PCore一个Q head")
    add_metric(s, "16 × 16", "INT8 MXU", 8.1, 1.32, 2.15, RED, "256 MAC/cycle/core")
    add_metric(s, "256", "Head dimension", 10.45, 1.32, 2.2, AMBER, "16 feature tiles")

    labels = [
        ("1", "在线Softmax", "μ / ℓ / α / OACC"),
        ("2", "880分块", "Bkv=16 vs 64"),
        ("3", "物理Mask", "AR block + padding"),
        ("4", "Scale链", "QK / PV / A_FIN"),
        ("5", "跨块流水", "QK / EXP / SCALE / PV"),
        ("6", "存储", "SBUF / PBUF / OACC"),
        ("7", "资源占用", "MXU / DEQACC / VPU / SFU"),
    ]
    for idx, (n, a, b) in enumerate(labels):
        col = idx % 4
        row = idx // 4
        x = 0.68 + col * 3.12
        y = 3.08 + row * 1.43
        add_rect(s, x, y, 2.82, 1.1, WHITE, GRID, radius=True)
        add_text(s, n, x + 0.16, y + 0.13, 0.37, 0.35, 16, RED, True, align=PP_ALIGN.CENTER)
        add_text(s, a, x + 0.62, y + 0.13, 1.95, 0.35, 16, INK, True)
        add_text(s, b, x + 0.62, y + 0.58, 1.95, 0.25, 10.5, MUTED)
    add_footer(s, page)


def problem_slide(prs, page):
    s = new_slide(prs)
    add_title(s, "02", "为什么必须采用FlashAttention", "完整S/P超出单PCore存储预算；分块后只保留一至两代中间结果")
    add_section_tag(s, "FULL ATTENTION", 0.65, 1.25, 2.1, RED)
    add_rect(s, 0.65, 1.67, 5.75, 4.65, WHITE, GRID, radius=True)
    add_text(s, "Q[51,256] × Kᵀ[256,880]", 0.95, 1.98, 4.9, 0.42, 19, INK, True, font=FONT_MONO, align=PP_ALIGN.CENTER)
    add_arrow(s, 3.52, 2.48, 3.52, 2.88, RED, 2)
    add_rect(s, 1.22, 2.95, 4.58, 1.02, PALE_RED, RED, radius=True)
    add_text(s, "S[51,880] FP32", 1.5, 3.15, 4.0, 0.28, 21, RED, True, font=FONT_MONO, align=PP_ALIGN.CENTER)
    add_text(s, "51 × 880 × 4 B = 179,520 B ≈ 175.3 KiB / core", 0.95, 4.25, 5.1, 0.42, 15, TEXT, True, font=FONT_MONO, align=PP_ALIGN.CENTER)
    add_text(s, "再保存P会继续增加约44.9 KiB；单核完整展开不可行。", 1.08, 5.08, 4.85, 0.5, 14, MUTED, align=PP_ALIGN.CENTER)

    add_section_tag(s, "FLASHATTENTION", 6.92, 1.25, 2.35, GREEN)
    add_rect(s, 6.92, 1.67, 5.75, 4.65, WHITE, GRID, radius=True)
    add_text(s, "一次只处理16个Key", 7.32, 1.98, 4.9, 0.4, 21, GREEN, True, align=PP_ALIGN.CENTER)
    y = 2.72
    blocks = [
        ("S_b", "[51,16] FP32", PALE_BLUE, BLUE),
        ("P_b", "[51,16] INT8 + E8M0", PALE_GREEN, GREEN),
        ("State", "μ / ℓ / α: 51×FP32", LIGHT, NAVY),
        ("OACC", "[51,256] FP32", PALE_RED, RED),
    ]
    for i, (name, shape, fill, accent) in enumerate(blocks):
        yy = y + i * 0.74
        add_rect(s, 7.35, yy, 4.88, 0.55, fill, accent, radius=True)
        add_text(s, name, 7.57, yy + 0.1, 0.9, 0.25, 13, accent, True, font=FONT_MONO)
        add_text(s, shape, 8.55, yy + 0.1, 3.35, 0.25, 12.5, TEXT, True, font=FONT_MONO)
    add_text(s, "存储从O(sequence)降为O(block)，输出仍与完整Softmax数学等价。", 7.35, 5.84, 4.9, 0.32, 13, GREEN, True, align=PP_ALIGN.CENTER)
    add_footer(s, page)


def online_softmax_slide(prs, page):
    s = new_slide(prs)
    add_title(s, "03", "在线Softmax：逐块状态更新", "每个Query行独立维护FP32的μ、ℓ和OACC")

    # Left flow
    add_section_tag(s, "BLOCK b INPUT", 0.62, 1.2, 2.0, BLUE)
    yvals = [1.68, 2.53, 3.38, 4.23, 5.08]
    labels = [
        ("① Score", "S_b = QK_bᵀ · 2⁻⁴"),
        ("② Mask", "invalid → −∞"),
        ("③ Row max", "ρ_b = max(S_b)"),
        ("④ Rebase", "μ_new = max(μ_old, ρ_b)"),
        ("⑤ Exponent", "P_b = exp(S_b − μ_new)"),
    ]
    for i, ((name, formula), y) in enumerate(zip(labels, yvals)):
        fill = PALE_RED if i == 1 else (PALE_GREEN if i == 4 else LIGHT)
        accent = RED if i == 1 else (GREEN if i == 4 else BLUE)
        add_rect(s, 0.62, y, 4.25, 0.62, fill, accent, radius=True)
        add_text(s, name, 0.85, y + 0.13, 1.15, 0.25, 12.5, accent, True)
        add_text(s, formula, 2.02, y + 0.12, 2.55, 0.28, 14, INK, True, font=FONT_MONO)
        if i < len(yvals) - 1:
            add_arrow(s, 2.74, y + 0.63, 2.74, yvals[i + 1] - 0.03, NAVY, 1.3)

    # Right equations
    add_section_tag(s, "ONLINE STATE UPDATE", 5.38, 1.2, 2.65, RED)
    add_rect(s, 5.38, 1.68, 7.28, 4.75, WHITE, GRID, radius=True)
    equations = [
        ("旧结果缩放", "α_b = exp(μ_old − μ_new)", RED),
        ("分母更新", "ℓ_new = α_b · ℓ_old + ΣP_b", BLUE),
        ("输出更新", "O_new = α_b · O_old + P_bV_b", GREEN),
        ("最终归一化", "Attention = OACC / ℓ", NAVY),
    ]
    for i, (lab, eq, accent) in enumerate(equations):
        y = 1.98 + i * 0.93
        add_text(s, lab, 5.75, y + 0.08, 1.35, 0.25, 11, accent, True)
        add_rect(s, 7.12, y, 4.93, 0.52, LIGHT, accent, radius=True)
        add_text(s, eq, 7.28, y + 0.1, 4.63, 0.27, 15, INK, True, font=FONT_MONO, align=PP_ALIGN.CENTER)

    add_rect(s, 5.78, 5.62, 6.48, 0.53, PALE_BLUE, BLUE, radius=True)
    add_text(s, "数值稳定性：S_b − μ_new ≤ 0，因此exp ∈ (0,1]，不会上溢", 5.97, 5.75, 6.1, 0.25, 12.5, BLUE, True, align=PP_ALIGN.CENTER)
    add_footer(s, page)


def online_dependency_slide(prs, page):
    s = new_slide(prs)
    add_title(s, "04", "单块依赖与硬件执行位置", "块内数学严格串行，块间通过独立资源交叠")
    stages = [
        ("QK(b)", "S_b", "MXU + DEQACC\nFACC / SBUF", BLUE),
        ("MASK + MAX", "ρ_b, μ_new", "VPU compare\nμ RF", RED),
        ("EXP(b)", "P_b, ℓ, α", "SFU + VPU\nPBUF / scalar RF", GREEN),
        ("SCALE(b)", "α_b·O_old", "VPU\nOACC RMW", AMBER),
        ("PV(b)", "P_bV_b", "MXU + DEQACC\nOACC RMW", NAVY),
    ]
    x0 = 0.58
    for i, (name, out, hw, accent) in enumerate(stages):
        x = x0 + i * 2.55
        add_rect(s, x, 1.7, 2.18, 2.12, WHITE, accent, radius=True)
        add_rect(s, x, 1.7, 2.18, 0.46, accent, accent)
        add_text(s, name, x + 0.08, 1.79, 2.02, 0.23, 14, WHITE, True, font=FONT_MONO, align=PP_ALIGN.CENTER)
        add_text(s, out, x + 0.12, 2.36, 1.94, 0.35, 15, accent, True, font=FONT_MONO, align=PP_ALIGN.CENTER)
        add_text(s, hw, x + 0.12, 2.86, 1.94, 0.62, 11, TEXT, True, align=PP_ALIGN.CENTER)
        if i < 4:
            add_arrow(s, x + 2.2, 2.75, x + 2.50, 2.75, NAVY, 1.5)

    add_rect(s, 0.72, 4.35, 5.78, 1.45, LIGHT, GRID, radius=True)
    add_text(s, "空Block规则", 0.98, 4.58, 1.4, 0.3, 15, RED, True)
    add_text(s, "若OR(valid[0:15])=0：保持μ、ℓ、OACC位相同；不发EXP，不写P，不执行PV。", 2.35, 4.48, 3.75, 0.74, 14, TEXT, True, valign=MSO_ANCHOR.MIDDLE)

    add_rect(s, 6.8, 4.35, 5.78, 1.45, PALE_GREEN, GREEN, radius=True)
    add_text(s, "核心并行机会", 7.08, 4.58, 1.65, 0.3, 15, GREEN, True)
    add_text(s, "QK(b+1)只依赖常驻Q和下一块K，与PV(b)结果无关，因此可以提前执行。", 8.68, 4.48, 3.48, 0.74, 14, TEXT, True, valign=MSO_ANCHOR.MIDDLE)
    add_footer(s, page)


def partition_slide(prs, page):
    s = new_slide(prs)
    add_title(s, "05", "880物理序列与Bkv=16排布", "Prefix天然16对齐；Suffix补齐后形成55个等长KV块")
    add_rich_text(s, [
        ("Tlogical = ", MUTED, False, FONT_MONO), ("816", NAVY, True, FONT_MONO),
        (" + ", MUTED, False, FONT_MONO), ("51", GREEN, True, FONT_MONO),
        (" = 867     Tphys = ceil(867/16)×16 = ", MUTED, False, FONT_MONO),
        ("880", RED, True, FONT_MONO),
    ], 0.75, 1.22, 11.8, 0.45, 18, align=PP_ALIGN.CENTER)

    x = 0.72
    y = 2.05
    total_w = 11.9
    prefix_w = total_w * 816 / 880
    suffix_valid_w = total_w * 51 / 880
    pad_w = total_w * 13 / 880
    add_rect(s, x, y, prefix_w, 0.84, PALE_BLUE, BLUE)
    add_rect(s, x + prefix_w, y, suffix_valid_w, 0.84, PALE_GREEN, GREEN)
    add_rect(s, x + prefix_w + suffix_valid_w, y, pad_w, 0.84, PALE_RED, RED)
    add_text(s, "Prefix 816 = 51 × 16", x + 0.2, y + 0.24, prefix_w - 0.4, 0.28, 16, BLUE, True, align=PP_ALIGN.CENTER)
    add_text(s, "Suffix\n51", x + prefix_w - 0.02, y + 0.12, max(suffix_valid_w + 0.12, 0.7), 0.5, 10.5, GREEN, True, align=PP_ALIGN.CENTER)
    add_text(s, "13\npad", x + prefix_w + suffix_valid_w - 0.02, y + 0.12, max(pad_w + 0.12, 0.55), 0.5, 9.5, RED, True, align=PP_ALIGN.CENTER)

    # Block strips
    add_text(s, "Block ID", 0.72, 3.28, 1.05, 0.28, 11, MUTED, True)
    bx = 1.72
    bw = 0.185
    for b in range(55):
        if b < 51:
            fill, line = PALE_BLUE, BLUE
        elif b < 54:
            fill, line = PALE_GREEN, GREEN
        else:
            fill, line = PALE_RED, RED
        add_rect(s, bx + b * bw, 3.24, bw - 0.012, 0.43, fill, line, width=0.4)
        if b in [0, 10, 20, 30, 40, 50, 51, 52, 53, 54]:
            add_text(s, str(b), bx + b * bw - 0.04, 3.73, 0.28, 0.2, 8, line, True, align=PP_ALIGN.CENTER)

    add_rect(s, 0.72, 4.38, 3.55, 1.45, LIGHT, GRID, radius=True)
    add_text(s, "统一粒度", 0.98, 4.62, 1.2, 0.28, 14, NAVY, True)
    add_text(s, "MXINT8块 = K-tile = 加法树输入 = KV块 = 16", 0.98, 5.04, 2.95, 0.55, 13, TEXT, True, font=FONT_MONO, align=PP_ALIGN.CENTER)
    add_rect(s, 4.57, 4.38, 3.55, 1.45, PALE_GREEN, GREEN, radius=True)
    add_text(s, "规则控制", 4.83, 4.62, 1.2, 0.28, 14, GREEN, True)
    add_text(s, "55个等长块；只有块54内13个padding lane需要Mask", 4.83, 5.04, 2.95, 0.55, 13, TEXT, True, align=PP_ALIGN.CENTER)
    add_rect(s, 8.42, 4.38, 4.2, 1.45, PALE_RED, RED, radius=True)
    add_text(s, "计算周期", 8.68, 4.62, 1.2, 0.28, 14, RED, True)
    add_text(s, "QK = PV = 55×51×16 = 44,880 cycles", 8.68, 5.04, 3.68, 0.55, 13, TEXT, True, font=FONT_MONO, align=PP_ALIGN.CENTER)
    add_footer(s, page)


def block_compare_slide(prs, page):
    s = new_slide(prs)
    add_title(s, "06", "Bkv=16与Bkv=64：计算量相同，结构代价不同", "最终选择B16是为了规整控制、缩小缓冲并对齐量化粒度")
    data = [
        ["维度", "Bkv=16（本设计）", "Bkv=64", "判断"],
        ["块数", "55，全等长", "14，末块48列", "B16规则"],
        ["Prefix 816", "51块，整除", "12整块+48列", "B16无ragged"],
        ["SBUF+PBUF+Ep", "8.07 KiB/core", "32.3 KiB/core", "B16省24.2 KiB"],
        ["P Scale索引", "Ep[m]", "Ep[m,ks]", "B16少一维"],
        ["PV Kt / FACC", "Kt=1 / 不参与", "Kt=4 / 参与", "B64端口更松"],
        ["OACC占用", "PV段100%", "PV段25%", "B64占优"],
        ["α事件", "55次", "14次", "B64占优"],
        ["QK/PV周期", "44,880 / 44,880", "44,880 / 44,880", "相同"],
    ]
    add_table(s, len(data), 4, data, 0.65, 1.28, 12.05, 4.7, [2.35, 3.05, 3.05, 3.6], True, 11.2)
    add_rect(s, 0.78, 6.2, 11.8, 0.62, PALE_BLUE, BLUE, radius=True)
    add_text(s, "结论：B16牺牲α事件数与OACC端口余量，换取与16×16 MXU/MXINT8完全一致的统一数据路径；这对FPGA RTL、验证和片上存储更重要。", 1.02, 6.32, 11.3, 0.34, 13, BLUE, True, align=PP_ALIGN.CENTER)
    add_footer(s, page)


def mask_slide(prs, page):
    s = new_slide(prs)
    add_title(s, "07", "Mask语义：AR block，而不是普通三角因果Mask", "Action token处于同一AR块，彼此双向可见；State不能看到Action")
    # Visibility matrix
    labels = ["Prefix", "State", "Action"]
    colors = [BLUE, AMBER, GREEN]
    add_text(s, "Query ↓ / Key →", 0.8, 1.35, 1.6, 0.28, 11, MUTED, True)
    for c, lab in enumerate(labels):
        add_text(s, lab, 2.55 + c * 1.34, 1.35, 1.15, 0.28, 11.5, colors[c], True, align=PP_ALIGN.CENTER)
    mat = [[1,0,0],[1,1,0],[1,1,1]]
    for r, lab in enumerate(labels):
        add_text(s, lab, 0.9, 1.87 + r * 0.84, 1.25, 0.3, 12, colors[r], True, align=PP_ALIGN.RIGHT)
        for c in range(3):
            visible = mat[r][c]
            fill = PALE_GREEN if visible else PALE_RED
            accent = GREEN if visible else RED
            add_rect(s, 2.5 + c * 1.34, 1.78 + r * 0.84, 1.15, 0.6, fill, accent, radius=True)
            add_text(s, "可见" if visible else "屏蔽", 2.55 + c * 1.34, 1.94 + r * 0.84, 1.05, 0.25, 12, accent, True, align=PP_ALIGN.CENTER)

    add_rect(s, 6.9, 1.32, 5.7, 3.24, WHITE, GRID, radius=True)
    add_section_tag(s, "PHYSICAL MASK", 7.18, 1.6, 2.2, RED)
    add_text(s, "jj = ((blk − 51) << 4) + n", 7.3, 2.15, 4.9, 0.38, 18, INK, True, font=FONT_MONO, align=PP_ALIGN.CENTER)
    add_text(s, "masked = (jj ≥ 51) OR (m = 0 AND jj ≥ 1)", 7.15, 2.82, 5.18, 0.42, 15.5, RED, True, font=FONT_MONO, align=PP_ALIGN.CENTER)
    add_arrow(s, 9.75, 3.35, 9.75, 3.7, RED, 1.6)
    add_text(s, "score_masked = masked ? −∞ : score", 7.3, 3.78, 4.9, 0.38, 15, BLUE, True, font=FONT_MONO, align=PP_ALIGN.CENTER)

    # Physical suffix blocks
    block_info = [
        ("blk51", "jj 0–15", "State仅jj=0", AMBER),
        ("blk52", "jj 16–31", "State全屏蔽", RED),
        ("blk53", "jj 32–47", "State全屏蔽", RED),
        ("blk54", "jj 48–63", "13 padding", NAVY),
    ]
    for i, (b, rng, rule, accent) in enumerate(block_info):
        x = 0.78 + i * 3.03
        add_rect(s, x, 5.04, 2.75, 1.04, WHITE, accent, radius=True)
        add_text(s, b, x + 0.15, 5.19, 0.72, 0.25, 12.5, accent, True, font=FONT_MONO)
        add_text(s, rng, x + 0.9, 5.19, 1.58, 0.25, 11, MUTED, font=FONT_MONO, align=PP_ALIGN.RIGHT)
        add_text(s, rule, x + 0.15, 5.6, 2.42, 0.25, 12, TEXT, True, align=PP_ALIGN.CENTER)
    add_rect(s, 1.12, 6.35, 11.1, 0.45, PALE_RED, RED, radius=True)
    add_text(s, "Mask必须位于rowmax之前；否则无效score会污染μ、ℓ和最终PV。", 1.32, 6.45, 10.7, 0.22, 12.5, RED, True, align=PP_ALIGN.CENTER)
    add_footer(s, page)


def scale_map_slide(prs, page):
    s = new_slide(prs)
    add_title(s, "08", "Attention中的Scale：三条数值链必须分开", "E8M0量化Scale、QK固定2⁻⁴、在线Softmax的FP32 α不是同一种Scale")

    # Dataflow rail
    nodes = [
        ("Q", "INT8 + Eq", BLUE),
        ("K", "INT8 + Ek", CYAN),
        ("S", "FP32", RED),
        ("P", "INT8 + Ep", GREEN),
        ("V", "INT8 + Ev", AMBER),
        ("OACC", "FP32", NAVY),
        ("Â", "INT8 + Eo", BLUE),
    ]
    xs = [0.55, 2.18, 4.02, 5.72, 7.36, 9.1, 11.08]
    for i, ((name, fmt, accent), x) in enumerate(zip(nodes, xs)):
        add_rect(s, x, 1.6, 1.42, 0.92, WHITE, accent, radius=True)
        add_text(s, name, x + 0.1, 1.72, 1.22, 0.28, 16, accent, True, font=FONT_MONO, align=PP_ALIGN.CENTER)
        add_text(s, fmt, x + 0.08, 2.08, 1.26, 0.2, 9.5, MUTED, True, font=FONT_MONO, align=PP_ALIGN.CENTER)
    add_arrow(s, 1.97, 2.06, 2.15, 2.06, NAVY, 1.3)
    add_arrow(s, 3.64, 2.06, 4.0, 2.06, NAVY, 1.3)
    add_arrow(s, 5.45, 2.06, 5.7, 2.06, NAVY, 1.3)
    add_arrow(s, 7.15, 2.06, 7.34, 2.06, NAVY, 1.3)
    add_arrow(s, 8.83, 2.06, 9.08, 2.06, NAVY, 1.3)
    add_arrow(s, 10.76, 2.06, 11.05, 2.06, NAVY, 1.3)

    sections = [
        ("QK反量化", "psum × 2^(Eq + Ek − 266 − 4)", "−4 = log₂(1/√256)", BLUE, 0.67),
        ("PV反量化", "psum × 2^(Ep + Ev − 266)", "P与V都沿key方向分块", GREEN, 4.5),
        ("在线重缩放", "OACC ← α_b · OACC", "α_b = exp(μold−μnew)，真FP32", RED, 8.33),
    ]
    for title, formula, note, accent, x in sections:
        add_rect(s, x, 3.15, 3.52, 1.45, WHITE, accent, radius=True)
        add_text(s, title, x + 0.2, 3.34, 1.2, 0.28, 13, accent, True)
        add_text(s, formula, x + 0.2, 3.79, 3.1, 0.3, 13.5, INK, True, font=FONT_MONO, align=PP_ALIGN.CENTER)
        add_text(s, note, x + 0.2, 4.24, 3.1, 0.22, 10.5, MUTED, align=PP_ALIGN.CENTER)

    add_rect(s, 0.67, 5.04, 11.18, 1.3, LIGHT, GRID, radius=True)
    add_text(s, "16个INT8共用一个E8M0 Scale", 0.95, 5.27, 2.85, 0.28, 14, NAVY, True)
    add_text(s, "Q/K：沿head_dim每16个元素；P/V：沿sequence/key每16个元素；Â：沿head_dim每16个元素。", 3.72, 5.21, 7.75, 0.52, 14, TEXT, True, valign=MSO_ANCHOR.MIDDLE)
    add_text(s, "禁止混用：α和1/ℓ是FP32算法状态，不是MXINT8的E8M0 Scale。", 0.98, 5.85, 10.6, 0.25, 12.5, RED, True, align=PP_ALIGN.CENTER)
    add_footer(s, page)


def quant_slide(prs, page):
    s = new_slide(prs)
    add_title(s, "09", "MXINT8-B16量化与反量化", "量化块、MXU归约tile和DEQACC的Scale粒度完全一致")

    add_section_tag(s, "ENCODE", 0.65, 1.2, 1.45, BLUE)
    add_rect(s, 0.65, 1.62, 5.9, 3.0, WHITE, GRID, radius=True)
    add_text(s, "每16个FP32/BF16值", 0.95, 1.94, 2.1, 0.32, 17, INK, True)
    add_arrow(s, 3.08, 2.09, 3.55, 2.09, BLUE, 1.8)
    add_text(s, "amax = max |v_i|", 3.72, 1.93, 2.35, 0.35, 16, BLUE, True, font=FONT_MONO, align=PP_ALIGN.CENTER)
    add_text(s, "E = clamp(floor(log₂amax)+127)", 1.0, 2.7, 5.15, 0.4, 17, RED, True, font=FONT_MONO, align=PP_ALIGN.CENTER)
    add_text(s, "q_i = sat₁₂₇(RNE(v_i · 2^(133−E)))", 1.0, 3.36, 5.15, 0.4, 17, GREEN, True, font=FONT_MONO, align=PP_ALIGN.CENTER)
    add_rect(s, 1.2, 4.02, 4.75, 0.42, PALE_BLUE, BLUE, radius=True)
    add_text(s, "16 B INT8 + 1 B E8M0 = 17 B/block", 1.35, 4.1, 4.45, 0.23, 12.5, BLUE, True, font=FONT_MONO, align=PP_ALIGN.CENTER)

    add_section_tag(s, "DOT + DEQUANT", 6.82, 1.2, 2.25, RED)
    add_rect(s, 6.82, 1.62, 5.85, 3.0, WHITE, GRID, radius=True)
    add_text(s, "MXU", 7.15, 1.94, 0.82, 0.3, 15, RED, True, font=FONT_MONO)
    add_text(s, "Σ(q_a · q_b) → INT32 psum", 8.03, 1.93, 4.15, 0.34, 16, INK, True, font=FONT_MONO)
    add_arrow(s, 9.72, 2.46, 9.72, 2.78, RED, 1.7)
    add_text(s, "DEQACC", 7.15, 2.91, 1.15, 0.3, 15, RED, True, font=FONT_MONO)
    add_text(s, "partial_fp = psum · 2^(Ea+Eb−266+fold)", 8.15, 2.86, 4.05, 0.46, 14, INK, True, font=FONT_MONO, align=PP_ALIGN.CENTER)
    add_text(s, "逐tile反量化后再做FP32跨tile累加", 7.25, 3.64, 4.95, 0.35, 15, GREEN, True, align=PP_ALIGN.CENTER)
    add_text(s, "不同tile的E不同，不能先合并INT32 psum再统一反量化", 7.25, 4.08, 4.95, 0.28, 11.5, MUTED, align=PP_ALIGN.CENTER)

    data = [
        ["通路", "Scale A", "Scale B", "fold", "FP32目的地"],
        ["QK", "Eq[m,t]", "Ek[j,t]", "−4", "FACC → SBUF"],
        ["PV", "Ep[m,b]", "Ev[b,t]", "0", "OACC"],
        ["O_Proj", "Eo[m,t]", "EwO[t,n]", "0", "FACC/CNET"],
    ]
    add_table(s, 4, 5, data, 1.0, 5.08, 11.3, 1.34, [1.55, 2.25, 2.25, 1.3, 3.95], True, 10.8)
    add_footer(s, page)


def cycle_slide(prs, page):
    s = new_slide(prs)
    add_title(s, "10", "QK与PV的816拍从哪里来", "816是阵列发射周期，不是单纯的MAC总数；每拍并行完成256 MAC")

    add_rect(s, 0.7, 1.32, 5.78, 4.75, WHITE, BLUE, radius=True)
    add_text(s, "QK(b+1)", 0.98, 1.58, 1.65, 0.36, 20, BLUE, True, font=FONT_MONO)
    add_text(s, "Q[51,256] × Kᵀ[256,16] → S[51,16]", 0.98, 2.1, 5.2, 0.38, 16, INK, True, font=FONT_MONO, align=PP_ALIGN.CENTER)
    add_text(s, "归约维256分成16个K-tile", 1.15, 2.9, 4.9, 0.34, 15, TEXT, True, align=PP_ALIGN.CENTER)
    add_text(s, "256 / 16 = 16", 1.15, 3.35, 4.9, 0.38, 21, BLUE, True, font=FONT_MONO, align=PP_ALIGN.CENTER)
    add_text(s, "每个K-tile连续处理51个Query行", 1.15, 4.08, 4.9, 0.34, 15, TEXT, True, align=PP_ALIGN.CENTER)
    add_rect(s, 1.25, 4.7, 4.7, 0.7, PALE_BLUE, BLUE, radius=True)
    add_text(s, "T_QK = 16 × 51 = 816 cycles", 1.42, 4.9, 4.35, 0.3, 19, BLUE, True, font=FONT_MONO, align=PP_ALIGN.CENTER)

    add_rect(s, 6.85, 1.32, 5.78, 4.75, WHITE, GREEN, radius=True)
    add_text(s, "PV(b)", 7.13, 1.58, 1.65, 0.36, 20, GREEN, True, font=FONT_MONO)
    add_text(s, "P[51,16] × V[16,256] → PV[51,256]", 7.13, 2.1, 5.2, 0.38, 16, INK, True, font=FONT_MONO, align=PP_ALIGN.CENTER)
    add_text(s, "输出维256分成16个N-tile", 7.3, 2.9, 4.9, 0.34, 15, TEXT, True, align=PP_ALIGN.CENTER)
    add_text(s, "256 / 16 = 16", 7.3, 3.35, 4.9, 0.38, 21, GREEN, True, font=FONT_MONO, align=PP_ALIGN.CENTER)
    add_text(s, "每个N-tile连续处理51个Query行", 7.3, 4.08, 4.9, 0.34, 15, TEXT, True, align=PP_ALIGN.CENTER)
    add_rect(s, 7.4, 4.7, 4.7, 0.7, PALE_GREEN, GREEN, radius=True)
    add_text(s, "T_PV = 16 × 51 = 816 cycles", 7.57, 4.9, 4.35, 0.3, 19, GREEN, True, font=FONT_MONO, align=PP_ALIGN.CENTER)

    add_text(s, "每块MAC数 = 51×16×256 = 208,896；MXU每拍256 MAC，所以208,896/256 = 816拍。", 1.18, 6.37, 11.0, 0.34, 13, RED, True, font=FONT_MONO, align=PP_ALIGN.CENTER)
    add_footer(s, page)


def pipeline_slide(prs, page):
    s = new_slide(prs)
    add_title(s, "11", "稳态1,632拍：五类资源任务与并行关系", "FACC是QK路径的FP32跨tile累加资源；前816拍 QK(b+1) || SCALE(α_b)，后816拍 PV(b) || EXP(b+1)")

    # The timeline and the resource table use the same two 816-cycle halves.
    add_text(s, "计算单元", 0.55, 1.31, 1.05, 0.22, 10.5, MUTED, True, align=PP_ALIGN.CENTER)
    add_rect(s, 1.78, 1.18, 4.85, 0.48, PALE_BLUE, BLUE, radius=True)
    add_rect(s, 6.78, 1.18, 4.85, 0.48, PALE_GREEN, GREEN, radius=True)
    add_text(s, "前816拍：QK(b+1) + SCALE(α_b)", 1.92, 1.31, 4.57, 0.22, 12, BLUE, True, font=FONT_MONO, align=PP_ALIGN.CENTER)
    add_text(s, "后816拍：PV(b) + EXP(b+1)", 6.92, 1.31, 4.57, 0.22, 12, GREEN, True, font=FONT_MONO, align=PP_ALIGN.CENTER)

    lanes = [("MXU", 1.86), ("DEQACC", 2.30), ("FACC", 2.74), ("SFU", 3.18), ("VPU", 3.62)]
    for name, y in lanes:
        add_text(s, name, 0.58, y + 0.17, 0.92, 0.23, 11.5, NAVY, True, font=FONT_MONO, align=PP_ALIGN.CENTER)
        add_line(s, 1.68, y + 0.52, 11.7, y + 0.52, GRID, 0.65)

    # MXU: the only matrix engine, time-multiplexed between QK and PV.
    add_rect(s, 1.84, 1.92, 4.73, 0.43, BLUE, BLUE, radius=True)
    add_text(s, "QK(b+1): Q[51,256]×Kᵀ[256,16] → S[51,16] · 816", 1.95, 2.02, 4.5, 0.22, 10.3, WHITE, True, font=FONT_MONO, align=PP_ALIGN.CENTER)
    add_rect(s, 6.84, 1.92, 4.73, 0.43, GREEN, GREEN, radius=True)
    add_text(s, "PV(b): P[51,16]×V[16,256] → PV[51,256] · 816", 6.95, 2.02, 4.5, 0.22, 10.3, WHITE, True, font=FONT_MONO, align=PP_ALIGN.CENTER)

    # DEQACC follows MXU by 11 cycles (6-cycle MXU latency + 5-cycle DEQACC latency)
    # while sustaining one 16-lane FP32 result per cycle.
    add_rect(s, 1.84, 2.44, 4.73, 0.43, RED, RED, radius=True)
    add_text(s, "QK反量化：Eq+Ek−266−4 → FACC · 816×16 lane，尾11", 1.95, 2.54, 4.5, 0.22, 9.2, WHITE, True, font=FONT_MONO, align=PP_ALIGN.CENTER)
    add_rect(s, 6.84, 2.44, 4.73, 0.43, RED, RED, radius=True)
    add_text(s, "PV反量化→PV_FP32；OACC_new=α_b·OACC_old+PV_FP32", 6.93, 2.54, 4.55, 0.22, 8.6, WHITE, True, font=FONT_MONO, align=PP_ALIGN.CENTER)

    # FACC is the QK-only FP32 cross-tile accumulator; PV uses OACC directly because Kt=1.
    add_rect(s, 1.84, 2.74, 4.73, 0.43, NAVY, NAVY, radius=True)
    add_text(s, "DEQACC L3：16路FP32加 → FACC；816拍输入，块末flush 51拍可重叠", 1.92, 2.85, 4.58, 0.22, 8.8, WHITE, True, font=FONT_MONO, align=PP_ALIGN.CENTER)
    add_rect(s, 6.84, 2.74, 4.73, 0.43, LIGHT, GRID, radius=True)
    add_text(s, "DEQACC L3：16路FP32加；PV_FP32+OACC_scaled→OACC", 6.98, 2.85, 4.42, 0.22, 8.8, MUTED, True, font=FONT_MONO, align=PP_ALIGN.CENTER)

    # SFU: P has 816 exp requests; alpha adds 51 more FP32 exponentials.
    add_rect(s, 1.84, 3.18, 4.73, 0.43, LIGHT, GRID, radius=True)
    add_text(s, "空闲（QK只产生S，不调用exp）", 2.0, 3.29, 4.4, 0.22, 10.5, MUTED, True, align=PP_ALIGN.CENTER)
    add_rect(s, 6.84, 3.18, 0.38, 0.43, RED, RED, radius=True)
    add_text(s, "α exp\n26", 6.845, 3.21, 0.37, 0.33, 7.2, WHITE, True, font=FONT_MONO, align=PP_ALIGN.CENTER)
    add_rect(s, 7.27, 3.18, 2.35, 0.43, GREEN, GREEN, radius=True)
    add_text(s, "P=exp(S−μ) · 816/2=408", 7.36, 3.29, 2.15, 0.22, 9.2, WHITE, True, font=FONT_MONO, align=PP_ALIGN.CENTER)
    add_text(s, "SFU合计：26 + 408 = 434拍", 9.83, 3.29, 1.65, 0.22, 8.4, GREEN, True, font=FONT_MONO, align=PP_ALIGN.CENTER)

    # VPU: scale in the first half; rowmax is placed in the PV half so a single-issue
    # VPU does not need to overlap its compare path with OACC_SCALE.
    add_rect(s, 1.84, 3.62, 4.73, 0.43, RED, RED, radius=True)
    add_text(s, "OACC_SCALE(α_b)：13,056 FP32 = 816×16 lane / 816拍", 1.88, 3.73, 4.64, 0.22, 10.2, WHITE, True, font=FONT_MONO, align=PP_ALIGN.CENTER)
    add_rect(s, 6.84, 3.57, 0.88, 0.53, PALE_RED, RED, radius=True)
    add_text(s, "MASK\n+ρ/μ · 51", 6.89, 3.63, 0.78, 0.38, 7.6, RED, True, font=FONT_MONO, align=PP_ALIGN.CENTER)
    add_rect(s, 7.86, 3.62, 1.22, 0.43, CYAN, CYAN, radius=True)
    add_text(s, "P量化", 7.94, 3.73, 1.06, 0.22, 10, WHITE, True, font=FONT_MONO, align=PP_ALIGN.CENTER)
    add_rect(s, 9.2, 3.62, 1.22, 0.43, CYAN, CYAN, radius=True)
    add_text(s, "ℓ更新", 9.28, 3.73, 1.06, 0.22, 10, WHITE, True, font=FONT_MONO, align=PP_ALIGN.CENTER)
    add_text(s, "PV(b)并行；EXP后各51行提交", 10.47, 3.73, 1.05, 0.22, 8.2, CYAN, True, font=FONT_MONO, align=PP_ALIGN.CENTER)

    # Exact task table for the three compute units.
    table_data = [
        ["单元", "QK阶段（前816拍）", "时间", "PV阶段（后816拍）", "时间", "完整窗口"],
        ["MXU", "QK矩阵乘：Q×Kᵀ→S", "816 / 100%", "PV矩阵乘：P×V", "816 / 100%", "100%"],
        ["DEQACC", "反量化+L3 FP32加→FACC", "816×16 lane；尾11", "反量化+L3 FP32加→OACC", "816×16 lane；尾11", "100%吞吐"],
        ["FACC", "16个K-tile累加；块末flush→SBUF", "816输入；flush51可重叠", "Kt=1，不参与", "0", "50%占用"],
        ["SFU", "无exp请求", "0", "P exp 408 + α exp 26", "434 / 53.2%", "26.6%≈27%"],
        ["VPU", "α×OACC 816", "816 / 100%", "MASK+ρ/μ 51 + P量化/ℓ 51", "102 / 12.5%", "56.25%"],
    ]
    add_table(s, 6, 6, table_data, 0.55, 4.18, 12.15, 1.92, [0.8, 3.2, 1.05, 3.05, 1.05, 1.9], True, 8.1)
    add_rect(s, 0.72, 6.2, 11.9, 0.48, PALE_BLUE, BLUE, radius=True)
    add_text(s, "位置说明：前816拍VPU完成OACC_scaled=α_b·OACC_old；后816拍DEQACC的L3用16路FP32加法器计算PV_FP32+OACC_scaled，L4在t+12以1R1W写回OACC_new。FACC的51拍块末flush由乒乓缓冲隐藏。", 0.78, 6.29, 11.78, 0.28, 8.7, BLUE, True, align=PP_ALIGN.CENTER)
    add_text(s, "单一VPU发射路径口径：PV半程VPU总计51拍Mask/rowmax + 51拍P量化/ℓ更新=102拍；DEQACC为16 lane、每阶段816个输入向量，尾部排空11拍。", 0.78, 6.78, 11.75, 0.22, 9.2, RED, True, align=PP_ALIGN.CENTER)
    add_footer(s, page)


def total_cycles_slide(prs, page):
    s = new_slide(prs)
    add_title(s, "12", "Attention总周期账目", "区分主计算、可隐藏后处理与唯一暴露的α54尾部")

    add_metric(s, "44,880", "55个QK blocks", 0.72, 1.35, 2.65, BLUE, "55×816")
    add_metric(s, "44,880", "55个PV blocks", 3.62, 1.35, 2.65, GREEN, "55×816")
    add_metric(s, "275", "全局保守余量", 6.52, 1.35, 2.65, AMBER, "不是每块额外51拍")
    add_metric(s, "816", "α54暴露尾", 9.42, 1.35, 2.65, RED, "无QK(55)可隐藏")

    add_rect(s, 0.72, 2.9, 11.98, 1.08, LIGHT, GRID, radius=True)
    parts = [
        ("89,760", NAVY, True, FONT_MONO),
        (" + ", MUTED, False, FONT_MONO),
        ("275", AMBER, True, FONT_MONO),
        (" + ", MUTED, False, FONT_MONO),
        ("816", RED, True, FONT_MONO),
        (" = ", MUTED, False, FONT_MONO),
        ("90,851 cycles/layer", GREEN, True, FONT_MONO),
    ]
    add_rich_text(s, parts, 1.05, 3.18, 11.3, 0.5, 24, align=PP_ALIGN.CENTER, valign=MSO_ANCHOR.MIDDLE)

    add_section_tag(s, "HIDDEN", 0.72, 4.42, 1.35, GREEN)
    add_bullets(s, [
        "EXP由2-lane SFU在408拍内完成，隐藏在816拍的QK/PV窗口。",
        "α₁…α₅₃的OACC_SCALE隐藏在QK(b+1)窗口。",
        "最后先求r=1/ℓ₅₄，再按行广播：A_FIN[m,:]=OACC[m,:]×r[m]；可与PV(54)尾随写回重叠。",
    ], 0.9, 4.86, 5.55, 1.6, 13)
    add_section_tag(s, "EXPOSED", 6.78, 4.42, 1.55, RED)
    add_bullets(s, [
        "α₅₄产生后已经没有合法QK(55)，因此必须单独遍历816个16-lane OACC向量组。",
        "90,851是设计文档的完整Attention口径；89,760仅代表QK+PV主阵列周期。",
    ], 6.95, 4.86, 5.55, 1.6, 13)
    add_rect(s, 6.78, 6.42, 5.55, 0.45, PALE_RED, RED, radius=True)
    add_text(s, "A_FIN重叠须DEQACC→VPU旁路；若重读OACC SRAM则+816拍", 6.9, 6.53, 5.3, 0.22, 9.5, RED, True, font=FONT_MONO, align=PP_ALIGN.CENTER)
    add_footer(s, page)


def storage_slide(prs, page):
    s = new_slide(prs)
    add_title(s, "13", "Attention存储与数据流", "乒乓条件由生产窗口和消费窗口是否重叠决定")
    # Compute modules
    mods = [
        ("MXU", 0.7, 1.5, BLUE),
        ("DEQACC", 2.45, 1.5, RED),
        ("FACC", 4.2, 1.5, NAVY),
        ("VPU", 8.95, 1.5, AMBER),
        ("SFU", 10.72, 1.5, GREEN),
    ]
    for name, x, y, accent in mods:
        add_rect(s, x, y, 1.45, 0.62, accent, accent, radius=True)
        add_text(s, name, x + 0.08, y + 0.15, 1.29, 0.25, 13, WHITE, True, font=FONT_MONO, align=PP_ALIGN.CENTER)

    memories = [
        ("Q-Memory (one)", "[51,256]\nMXINT8-B16", 0.7, 2.72, 1.75, BLUE),
        ("SBUF ping/pong", "2×[51,16]\nFP32", 3.0, 2.72, 2.0, RED),
        ("PBUF ping/pong", "2×[51,16]\nINT8+Ep", 5.47, 2.72, 2.0, GREEN),
        ("OACC", "[51,256]\nFP32", 7.94, 2.72, 1.75, NAVY),
        ("μ/ℓ/α RF", "3×51 FP32\nα two-gen", 10.2, 2.72, 1.85, AMBER),
    ]
    for name, shape, x, y, w, accent in memories:
        add_rect(s, x, y, w, 1.05, WHITE, accent, radius=True)
        add_text(s, name, x + 0.1, y + 0.15, w - 0.2, 0.26, 12, accent, True, font=FONT_MONO, align=PP_ALIGN.CENTER)
        add_text(s, shape, x + 0.1, y + 0.51, w - 0.2, 0.36, 10.5, TEXT, True, font=FONT_MONO, align=PP_ALIGN.CENTER)

    # Connections
    add_arrow(s, 1.55, 2.68, 1.45, 2.14, BLUE, 1.5)
    add_arrow(s, 2.15, 1.81, 2.43, 1.81, NAVY, 1.5)
    add_arrow(s, 3.9, 1.81, 4.18, 1.81, NAVY, 1.5)
    add_arrow(s, 3.2, 2.14, 3.72, 2.7, RED, 1.5)
    add_arrow(s, 4.92, 2.14, 4.3, 2.7, NAVY, 1.3)
    add_arrow(s, 4.7, 2.72, 9.25, 2.14, RED, 1.3)
    add_arrow(s, 10.7, 2.14, 6.65, 2.7, GREEN, 1.3)
    add_arrow(s, 7.45, 3.24, 7.92, 3.24, NAVY, 1.5)
    add_arrow(s, 9.3, 2.7, 9.6, 2.14, AMBER, 1.5)
    add_arrow(s, 10.22, 3.24, 9.72, 3.24, AMBER, 1.5)

    # Phases
    phase_data = [
        ["存储", "生产者", "消费者", "端口/代数", "设计原因"],
        ["SBUF", "QK写S", "EXP读S", "2代，各1RW", "跨块生产/消费重叠"],
        ["PBUF", "EXP写P", "PV读P", "2代，各1R1W", "同一PV窗口同时读写不同代"],
        ["OACC", "先做α×OACC_old", "再做OACC_scaled+PV_FP32；尾部供A_FIN", "单体512b 1R1W", "SCALE与PV严格分相"],
        ["Q-Memory（单体复用）", "写Q并供QK读取", "A_FIN写归一化O，供O-Project", "单体1RW", "Q、Attention读、A_FIN覆写三相互斥"],
    ]
    add_table(s, 5, 5, phase_data, 0.7, 4.34, 11.95, 2.0, [1.5, 2.0, 2.0, 2.15, 4.3], True, 10.2)
    add_footer(s, page)


def storage_table_slide(prs, page):
    s = new_slide(prs)
    add_title(s, "14", "Attention核心存储资源", "按规范图7-5：SBUF/PBUF/FACC/α状态需要乒乓；OACC与Q-Memory为单体复用")
    data = [
        ["存储", "格式 / 形状", "容量", "端口", "理由与时序"],
        ["SBUF乒乓", "2×[51,16] FP32", "512b×51×2 = 6.38 KiB", "各1RW", "QK填充的同时，较早块被EXP消费；双代避免生产/消费冲突"],
        ["PBUF乒乓", "2×[51,16] INT8 + E8M0", "1.59 + 0.10 = 1.69 KiB", "各1R1W", "EXP写一代的同时PV读另一代；P与E_p代号同步"],
        ["OACC", "[51,256] FP32", "512b×816 = 51.00 KiB", "512b 1R1W", "PV与OACC_SCALE都要全速率RMW，但两者永不重叠；单体足够"],
        ["μ / ℓ / α RF", "每状态51个FP32", "32b×51×4 = 0.80 KiB", "1R1W", "固定行序；μ、ℓ各一代，α保留两代，支撑在线递推"],
        ["Q-Memory（单体复用）", "[51,256] MXINT8-B16", "逻辑13.55 KiB；物理QOZ数据+Scale=27.09 KiB", "1RW", "先存Q并供55个QK读取；确认最后一次读后，A_FIN原地覆写为Attention输出"],
        ["FACC（补充）", "2×[51,16] FP32", "512b×51×2 = 6.38 KiB", "各1R1W", "QK跨16个K-tile累加；块末51拍冲刷与下一块首tile重叠；PV的Kt=1不参与"],
    ]
    add_table(s, len(data), 5, data, 0.42, 1.28, 12.48, 5.42, [1.55, 2.75, 2.45, 1.15, 4.58], True, 9.0)
    add_text(s, "Q-Memory只有一个物理实例：Q写入、Attention读取、A_FIN覆写三相互斥。FACC的816拍表示随QK被占用，不是额外再执行816拍。", 0.55, 6.86, 12.15, 0.27, 9.0, BLUE, True, align=PP_ALIGN.CENTER)
    add_footer(s, page)


def resource_slide(prs, page):
    s = new_slide(prs)
    add_title(s, "15", "稳态1,632拍窗口的资源占用", "与上一页统一：PV半程同时包含P的exp、α的exp、P量化和ℓ逐行更新")

    rows = [
        ("MXU", 100, 100, "QK / PV矩阵乘", BLUE),
        ("DEQACC", 100, 100, "QK→FACC / PV→OACC；尾11", RED),
        ("FACC", 100, 0, "PV Kt=1不参与", NAVY),
        ("OACC", 100, 100, "SCALE / PV RMW", AMBER),
        ("VPU", 100, 12.5, "SCALE816 / ρμ51+P量化ℓ51", CYAN),
        ("SFU", 0, 53.2, "P exp408+α exp26", GREEN),
        ("KVB", 33.3, 33.3, "K / V各272拍", BLUE),
        ("PBUF R", 0, 100, "PV重复读P", NAVY),
    ]
    add_text(s, "资源", 0.68, 1.25, 1.2, 0.25, 11, MUTED, True)
    add_text(s, "前816：QK + SCALE", 2.0, 1.25, 3.55, 0.25, 11, BLUE, True, align=PP_ALIGN.CENTER)
    add_text(s, "后816：PV + EXP", 5.85, 1.25, 3.55, 0.25, 11, GREEN, True, align=PP_ALIGN.CENTER)
    add_text(s, "完整窗口", 9.7, 1.25, 1.2, 0.25, 11, RED, True, align=PP_ALIGN.CENTER)
    add_text(s, "任务", 11.0, 1.25, 1.55, 0.25, 11, MUTED, True, align=PP_ALIGN.CENTER)
    y0 = 1.72
    barw = 3.25
    for i, (name, qk, pv, note, accent) in enumerate(rows):
        y = y0 + i * 0.62
        add_text(s, name, 0.68, y + 0.1, 1.1, 0.24, 11, accent, True, font=FONT_MONO, align=PP_ALIGN.RIGHT)
        add_rect(s, 2.0, y, barw, 0.42, LIGHT, GRID, radius=True)
        if qk > 0:
            add_rect(s, 2.0, y, barw*qk/100, 0.42, accent, accent, radius=True)
        add_text(s, f"{qk:g}%", 2.0, y + 0.08, barw, 0.22, 9.5, WHITE if qk>=35 else accent, True, font=FONT_MONO, align=PP_ALIGN.CENTER)
        add_rect(s, 5.85, y, barw, 0.42, LIGHT, GRID, radius=True)
        if pv > 0:
            add_rect(s, 5.85, y, barw*pv/100, 0.42, accent, accent, radius=True)
        add_text(s, f"{pv:g}%", 5.85, y + 0.08, barw, 0.22, 9.5, WHITE if pv>=35 else accent, True, font=FONT_MONO, align=PP_ALIGN.CENTER)
        avg = (qk + pv) / 2
        add_text(s, f"{avg:.1f}%", 9.68, y + 0.08, 1.25, 0.22, 10.5, RED if avg>=95 else TEXT, True, font=FONT_MONO, align=PP_ALIGN.CENTER)
        add_text(s, note, 10.98, y + 0.08, 1.6, 0.22, 9.5, MUTED, align=PP_ALIGN.CENTER)

    add_rect(s, 0.72, 6.76, 11.9, 0.38, PALE_RED, RED, radius=True)
    add_text(s, "瓶颈：MXU与DEQACC全窗口满载；OACC两个半程均满载但严格分相。VPU在PV半程为102/816=12.5%，SFU含P/α exp后为53.2%。", 0.95, 6.83, 11.45, 0.2, 10.8, RED, True, align=PP_ALIGN.CENTER)
    add_footer(s, page)


def closing_slide(prs, page):
    s = new_slide(prs)
    add_title(s, "16", "结论与下一步验证", "当前方案已经形成从算法、格式、存储到周期模型的一致闭环")
    decisions = [
        ("Bkv = 16", "统一MXINT8、MXU tile与FlashAttention块粒度", BLUE),
        ("FP32 state", "S、μ、ℓ、α、OACC保持高精度", RED),
        ("Physical Mask", "AR block与13个padding在rowmax前处理", GREEN),
        ("Cross-block pipeline", "QK(b+1)/SCALE与PV(b)/EXP成对调度", NAVY),
    ]
    for i, (head, body, accent) in enumerate(decisions):
        x = 0.72 + (i % 2) * 6.05
        y = 1.38 + (i // 2) * 1.42
        add_rect(s, x, y, 5.65, 1.08, WHITE, accent, radius=True)
        add_text(s, head, x + 0.22, y + 0.2, 1.85, 0.3, 15, accent, True, font=FONT_MONO)
        add_text(s, body, x + 2.0, y + 0.16, 3.35, 0.56, 13, TEXT, True, valign=MSO_ANCHOR.MIDDLE)

    add_section_tag(s, "NEXT", 0.72, 4.48, 1.0, RED)
    next_steps = [
        "位精确参考：MXINT8编码、QK fold=-4、P量化、α/ℓ FP32误差。",
        "事件周期模型：55块启动/稳态/收尾、11拍排空、全局pipe_en停顿。",
        "RTL断言：Mask可观测值、PBUF代匹配、OACC互斥、blk<55、A_FIN覆盖时序。",
        "综合核对：MXU/DEQACC 100%吞吐、OACC 512b 1R1W、VPU真FP32乘法资源。",
    ]
    add_bullets(s, next_steps, 0.9, 4.9, 11.7, 1.65, 13.5)
    add_rect(s, 1.25, 6.55, 10.85, 0.42, PALE_BLUE, BLUE, radius=True)
    add_text(s, "最终验收标准：软件张量、位精确数值库、事件周期模型与RTL四者一致。", 1.45, 6.63, 10.45, 0.22, 12.5, BLUE, True, align=PP_ALIGN.CENTER)
    add_footer(s, page)


def build():
    prs = Presentation()
    prs.slide_width = Inches(W)
    prs.slide_height = Inches(H)
    title_slide(prs)
    overview_slide(prs, 2)
    problem_slide(prs, 3)
    online_softmax_slide(prs, 4)
    online_dependency_slide(prs, 5)
    partition_slide(prs, 6)
    block_compare_slide(prs, 7)
    mask_slide(prs, 8)
    scale_map_slide(prs, 9)
    quant_slide(prs, 10)
    cycle_slide(prs, 11)
    pipeline_slide(prs, 12)
    total_cycles_slide(prs, 13)
    storage_slide(prs, 14)
    storage_table_slide(prs, 15)
    resource_slide(prs, 16)
    closing_slide(prs, 17)
    prs.core_properties.title = "FlashAttention FPGA Architecture Report v8"
    prs.core_properties.subject = "VLA / pi0 Action Expert FlashAttention"
    prs.core_properties.author = "VLA Architecture Team"
    prs.core_properties.keywords = "VLA, pi0, FlashAttention, FPGA, MXINT8"
    prs.save(OUT)
    print(f"saved: {OUT.resolve()} ({len(prs.slides)} slides)")


if __name__ == "__main__":
    build()
