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
SOURCE = ROOT / "FlashAttention_最终汇报稿_2026-08-25.md"
OUTPUT = ROOT / "FlashAttention_最终汇报稿_可直接汇报.pdf"
FONT = r"C:\Windows\Fonts\simhei.ttf"

pdfmetrics.registerFont(TTFont("SimHei", FONT))

NAVY = colors.HexColor("#17324D")
BLUE = colors.HexColor("#176B87")
CYAN = colors.HexColor("#2F8F9D")
INK = colors.HexColor("#1D2733")
MUTED = colors.HexColor("#5F6B76")
GRID = colors.HexColor("#D8E0E6")
PALE_BLUE = colors.HexColor("#EAF4F7")
PALE_GREEN = colors.HexColor("#EDF7F2")
PALE_AMBER = colors.HexColor("#FFF7E8")


styles = getSampleStyleSheet()
styles.add(ParagraphStyle(
    name="BodyCN", fontName="SimHei", fontSize=10.3, leading=18,
    textColor=INK, spaceAfter=7, alignment=TA_LEFT,
))
styles.add(ParagraphStyle(
    name="BodyTight", parent=styles["BodyCN"], fontSize=9.4,
    leading=15.5, spaceAfter=3,
))
styles.add(ParagraphStyle(
    name="H1CN", fontName="SimHei", fontSize=18, leading=25,
    textColor=NAVY, spaceBefore=10, spaceAfter=11,
))
styles.add(ParagraphStyle(
    name="H2CN", fontName="SimHei", fontSize=14, leading=21,
    textColor=BLUE, spaceBefore=16, spaceAfter=8,
))
styles.add(ParagraphStyle(
    name="H3CN", fontName="SimHei", fontSize=11.2, leading=17,
    textColor=NAVY, spaceBefore=9, spaceAfter=5,
))
styles.add(ParagraphStyle(
    name="CodeCN", fontName="SimHei", fontSize=9.0, leading=14,
    textColor=NAVY, leftIndent=0, rightIndent=0,
))
styles.add(ParagraphStyle(
    name="CoverTitle", fontName="SimHei", fontSize=27, leading=37,
    textColor=colors.white, alignment=TA_CENTER,
))
styles.add(ParagraphStyle(
    name="CoverSub", fontName="SimHei", fontSize=13, leading=21,
    textColor=colors.HexColor("#DDEDF2"), alignment=TA_CENTER,
))
styles.add(ParagraphStyle(
    name="CoverMeta", fontName="SimHei", fontSize=10.2, leading=17,
    textColor=INK, alignment=TA_LEFT,
))
styles.add(ParagraphStyle(
    name="SmallCN", fontName="SimHei", fontSize=8.2, leading=12,
    textColor=MUTED,
))


def inline(text: str) -> str:
    escaped = html.escape(text, quote=False)
    return re.sub(
        r"`([^`]+)`",
        r'<font color="#176B87"><b>\1</b></font>',
        escaped,
    )


def code_box(lines):
    content = "<br/>".join(html.escape(line, quote=False) or "&nbsp;" for line in lines)
    table = Table(
        [[Paragraph(content, styles["CodeCN"])]],
        colWidths=[166 * mm],
        hAlign="LEFT",
    )
    table.setStyle(TableStyle([
        ("BACKGROUND", (0, 0), (-1, -1), PALE_BLUE),
        ("BOX", (0, 0), (-1, -1), 0.7, colors.HexColor("#A7CBD5")),
        ("LEFTPADDING", (0, 0), (-1, -1), 9),
        ("RIGHTPADDING", (0, 0), (-1, -1), 9),
        ("TOPPADDING", (0, 0), (-1, -1), 7),
        ("BOTTOMPADDING", (0, 0), (-1, -1), 7),
    ]))
    return table


def note_box(title, body, fill=PALE_GREEN, stroke=colors.HexColor("#A8D4BE")):
    table = Table([
        [Paragraph(f"<b>{html.escape(title)}</b>", styles["BodyTight"])],
        [Paragraph(html.escape(body), styles["BodyTight"])],
    ], colWidths=[166 * mm], hAlign="LEFT")
    table.setStyle(TableStyle([
        ("BACKGROUND", (0, 0), (-1, -1), fill),
        ("BOX", (0, 0), (-1, -1), 0.7, stroke),
        ("LEFTPADDING", (0, 0), (-1, -1), 9),
        ("RIGHTPADDING", (0, 0), (-1, -1), 9),
        ("TOPPADDING", (0, 0), (-1, -1), 6),
        ("BOTTOMPADDING", (0, 0), (-1, -1), 6),
    ]))
    return table


def cover(story):
    banner = Table([
        [Spacer(1, 16 * mm)],
        [Paragraph("FlashAttention", styles["CoverTitle"])],
        [Paragraph("VLA 加速器硬件实现方案 · 组会汇报稿", styles["CoverSub"])],
        [Spacer(1, 14 * mm)],
    ], colWidths=[166 * mm], hAlign="CENTER")
    banner.setStyle(TableStyle([
        ("BACKGROUND", (0, 0), (-1, -1), NAVY),
        ("BOX", (0, 0), (-1, -1), 0, NAVY),
        ("LEFTPADDING", (0, 0), (-1, -1), 12),
        ("RIGHTPADDING", (0, 0), (-1, -1), 12),
        ("TOPPADDING", (0, 0), (-1, -1), 3),
        ("BOTTOMPADDING", (0, 0), (-1, -1), 3),
    ]))
    story.extend([Spacer(1, 19 * mm), banner, Spacer(1, 13 * mm)])
    meta = [
        [Paragraph("汇报主题", styles["CoverMeta"]), Paragraph("DEA-8 Private Core 中的 FlashAttention 架构、精度与流水实现", styles["CoverMeta"])],
        [Paragraph("核心参数", styles["CoverMeta"]), Paragraph("D_HEAD=256 · B_kv=16 · 55 个 KV Block · 16×16 MXU", styles["CoverMeta"])],
        [Paragraph("正文重点", styles["CoverMeta"]), Paragraph("在线 Softmax、Mask、MXINT8-B16、计算单元调度、片上存储与利用率", styles["CoverMeta"])],
        [Paragraph("汇报结尾", styles["CoverMeta"]), Paragraph("团队下一步计划：量化精度验证、VPU RTL、FP ACC 对接、模块集成与仿真验证", styles["CoverMeta"])],
    ]
    t = Table(meta, colWidths=[28 * mm, 138 * mm], hAlign="CENTER")
    t.setStyle(TableStyle([
        ("BACKGROUND", (0, 0), (-1, -1), colors.white),
        ("GRID", (0, 0), (-1, -1), 0.5, GRID),
        ("BACKGROUND", (0, 0), (0, -1), PALE_BLUE),
        ("VALIGN", (0, 0), (-1, -1), "MIDDLE"),
        ("LEFTPADDING", (0, 0), (-1, -1), 8),
        ("RIGHTPADDING", (0, 0), (-1, -1), 8),
        ("TOPPADDING", (0, 0), (-1, -1), 8),
        ("BOTTOMPADDING", (0, 0), (-1, -1), 8),
    ]))
    story.append(t)
    story.append(Spacer(1, 15 * mm))
    story.append(note_box(
        "汇报口径",
        "正文按新 PPT 的页面顺序组织；结尾采用团队视角，只说明下一阶段正在推进和计划开展的工作，不将任务表述为个人成果。",
        fill=PALE_AMBER,
        stroke=colors.HexColor("#E8C77A"),
    ))
    story.append(PageBreak())


def parse_markdown(path: Path):
    lines = path.read_text(encoding="utf-8").splitlines()
    story = []
    in_code = False
    code_lines = []
    paragraph = []

    def flush_paragraph():
        nonlocal paragraph
        if paragraph:
            text = " ".join(x.strip() for x in paragraph).strip()
            if text:
                story.append(Paragraph(inline(text), styles["BodyCN"]))
        paragraph = []

    for line in lines:
        if line.strip() == "```":
            flush_paragraph()
            if in_code:
                story.append(code_box(code_lines))
                story.append(Spacer(1, 4))
                code_lines = []
            in_code = not in_code
            continue
        if in_code:
            code_lines.append(line)
            continue
        if not line.strip():
            flush_paragraph()
            continue
        if line.startswith("# "):
            flush_paragraph()
            story.append(Paragraph(inline(line[2:].strip()), styles["H1CN"]))
        elif line.startswith("## "):
            flush_paragraph()
            if line.startswith("## 十二、汇报前建议修正 PPT 的地方"):
                break
            story.append(Paragraph(inline(line[3:].strip()), styles["H2CN"]))
        elif re.match(r"^\d+\.\s+", line):
            flush_paragraph()
            story.append(Paragraph("• " + inline(re.sub(r"^\d+\.\s+", "", line)), styles["BodyCN"]))
        elif line.startswith("适用文件：") or line.startswith("建议汇报时长："):
            flush_paragraph()
            story.append(Paragraph(inline(line), styles["SmallCN"]))
        else:
            paragraph.append(line)
    flush_paragraph()
    return story


def draw_page(canvas, doc):
    canvas.saveState()
    page = canvas.getPageNumber()
    width, height = A4
    if page > 1:
        canvas.setStrokeColor(GRID)
        canvas.setLineWidth(0.5)
        canvas.line(22 * mm, height - 14 * mm, width - 22 * mm, height - 14 * mm)
        canvas.setFont("SimHei", 8)
        canvas.setFillColor(MUTED)
        canvas.drawString(22 * mm, height - 10.5 * mm, "FlashAttention · VLA 加速器硬件实现方案")
        canvas.drawRightString(width - 22 * mm, 10 * mm, f"第 {page - 1} 页")
        canvas.setStrokeColor(GRID)
        canvas.line(22 * mm, 14 * mm, width - 22 * mm, 14 * mm)
    canvas.restoreState()


def main():
    doc = BaseDocTemplate(
        str(OUTPUT), pagesize=A4,
        leftMargin=22 * mm, rightMargin=22 * mm,
        topMargin=21 * mm, bottomMargin=20 * mm,
        title="FlashAttention 最终汇报稿",
        author="VLA DEA-8 Team",
    )
    frame = Frame(doc.leftMargin, doc.bottomMargin, doc.width, doc.height, id="normal")
    doc.addPageTemplates([PageTemplate(id="main", frames=[frame], onPage=draw_page)])
    story = []
    cover(story)
    story.extend(parse_markdown(SOURCE))
    doc.build(story)
    print(OUTPUT)


if __name__ == "__main__":
    main()
