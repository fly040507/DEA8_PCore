"""Render the current Markdown baseline and implementation status as a PDF."""
from pathlib import Path
from xml.sax.saxutils import escape
from reportlab.pdfbase import pdfmetrics
from reportlab.pdfbase.ttfonts import TTFont
from reportlab.lib.styles import ParagraphStyle
from reportlab.lib import colors
from reportlab.platypus import SimpleDocTemplate, Paragraph, Table, TableStyle, PageBreak
from reportlab.lib.pagesizes import A4

ROOT = Path(__file__).resolve().parent.parent
pdfmetrics.registerFont(TTFont('CN', 'C:/Windows/Fonts/simhei.ttf'))
body = ParagraphStyle('body', fontName='CN', fontSize=10, leading=16, spaceAfter=7, wordWrap='CJK')
h1 = ParagraphStyle('h1', parent=body, fontSize=18, leading=25, spaceAfter=14)
h2 = ParagraphStyle('h2', parent=body, fontSize=13, leading=20, spaceBefore=12, keepWithNext=True)
cell = ParagraphStyle('cell', parent=body, fontSize=8.5, leading=13)

def para(text, style=body):
    return Paragraph(escape(text).replace('`',''), style)

def append_table(rows, story):
    if not rows:
        return
    widths = [120, 160, 231] if len(rows[0]) == 3 else [155,356]
    table = Table([[para(c, cell) for c in r] for r in rows], colWidths=widths, repeatRows=1)
    table.setStyle(TableStyle([
        ('BACKGROUND',(0,0),(-1,0),colors.HexColor('#deedf0')),
        ('GRID',(0,0),(-1,-1),0.4,colors.HexColor('#90a5a8')),
        ('VALIGN',(0,0),(-1,-1),'TOP'),
        ('TOPPADDING',(0,0),(-1,-1),6), ('BOTTOMPADDING',(0,0),(-1,-1),6)
    ]))
    story.append(table)

def footer(canvas, doc):
    canvas.setFont('CN',8)
    canvas.drawString(42,22,'DEA-8 / 2026-09-12 / README baseline')
    canvas.drawRightString(A4[0]-42,22,str(doc.page))

story=[]
for index, filename in enumerate(['冻结规格_2026-09-12.md','IMPLEMENTATION_STATUS.md']):
    if index:
        story.append(PageBreak())
    rows=[]
    for line in (ROOT/'pcore'/'docs'/filename).read_text(encoding='utf-8').splitlines():
        if line.startswith('|'):
            cells=[c.strip() for c in line.strip('|').split('|')]
            if not all(set(c)<=set('-: ') for c in cells):
                rows.append(cells)
            continue
        append_table(rows,story)
        rows=[]
        if not line.strip():
            continue
        if line.startswith('# '): story.append(para(line[2:],h1))
        elif line.startswith('## '): story.append(para(line[3:],h2))
        else: story.append(para(line))
    append_table(rows,story)
output=ROOT/'output'/'pdf'/'VLA_PCore_Attention_v5_20260912.pdf'
output.parent.mkdir(parents=True,exist_ok=True)
SimpleDocTemplate(str(output),pagesize=A4,leftMargin=42,rightMargin=42,
                  topMargin=38,bottomMargin=38).build(story,onFirstPage=footer,onLaterPages=footer)
print(output)
