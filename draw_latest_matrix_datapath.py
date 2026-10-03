from pathlib import Path
from PIL import Image, ImageDraw, ImageFont


ROOT = Path(r"C:\Users\fly04\Desktop\VLA")
OUT = ROOT / "最新矩阵运算物理数据通路框图.png"

W, H = 2400, 1380
BG = "#F8FAFB"
GRID = "#DCE3E8"
INK = "#18232E"
MUTED = "#5E6B75"
BLACK = "#111820"
WHITE = "#FFFFFF"
RED = "#C7352E"
BLUE = "#1D6EAA"
PURPLE = "#7B4EA3"
GREEN = "#3E7A57"
AMBER = "#A76800"
ORANGE = "#A75B2B"
TEAL = "#2F8792"
LIGHT_BLUE = "#EAF3F8"
LIGHT_GREEN = "#EAF5EE"
LIGHT_PURPLE = "#F2EBF8"
LIGHT_AMBER = "#FFF5E3"
LIGHT_RED = "#FCEDEC"
LIGHT_GRAY = "#F0F4F6"
STROKE = "#91A4AF"


def font(size, bold=False):
    path = r"C:\Windows\Fonts\msyhbd.ttc" if bold else r"C:\Windows\Fonts\msyh.ttc"
    return ImageFont.truetype(path, size=size, index=0)


F_TITLE = font(44, True)
F_SECTION = font(27, True)
F_HEAD = font(23, True)
F_BODY = font(20)
F_BODY_B = font(20, True)
F_SMALL = font(17)
F_SMALL_B = font(17, True)
F_TINY = font(14)


img = Image.new("RGB", (W, H), BG)
draw = ImageDraw.Draw(img)


def text_center(x, y, w, h, s, f=F_BODY, fill=INK, spacing=4):
    box = draw.multiline_textbbox((0, 0), s, font=f, spacing=spacing, align="center")
    tw, th = box[2] - box[0], box[3] - box[1]
    draw.multiline_text((x + (w - tw) / 2, y + (h - th) / 2), s, font=f,
                        fill=fill, spacing=spacing, align="center")


def text_left(x, y, w, h, s, f=F_BODY, fill=INK, spacing=4):
    box = draw.multiline_textbbox((0, 0), s, font=f, spacing=spacing)
    tw, th = box[2] - box[0], box[3] - box[1]
    draw.multiline_text((x, y + max(0, (h - th) / 2)), s, font=f, fill=fill, spacing=spacing)


def box(x, y, w, h, fill=WHITE, outline=STROKE, radius=16, width=3, title=None, title_fill=None):
    draw.rounded_rectangle((x, y, x + w, y + h), radius=radius, fill=fill, outline=outline, width=width)
    if title:
        title_fill = title_fill or outline
        draw.rounded_rectangle((x, y, x + w, y + 48), radius=radius, fill=title_fill, outline=title_fill, width=1)
        draw.rectangle((x, y + 30, x + w, y + 48), fill=title_fill)
        text_center(x + 6, y + 2, w - 12, 42, title, F_HEAD, WHITE)


def subbox(x, y, w, h, s, fill=LIGHT_BLUE, outline=STROKE, f=F_SMALL, color=INK):
    draw.rounded_rectangle((x, y, x + w, y + h), radius=10, fill=fill, outline=outline, width=2)
    text_center(x + 5, y + 4, w - 10, h - 8, s, f, color)


def line(points, fill=RED, width=5, dashed=False):
    if not dashed:
        draw.line(points, fill=fill, width=width, joint="curve")
        return
    for p1, p2 in zip(points, points[1:]):
        x1, y1 = p1
        x2, y2 = p2
        dx, dy = x2 - x1, y2 - y1
        dist = max(1, (dx * dx + dy * dy) ** 0.5)
        ux, uy = dx / dist, dy / dist
        step = 24
        gap = 14
        pos = 0
        while pos < dist:
            end = min(pos + step, dist)
            draw.line((x1 + ux * pos, y1 + uy * pos, x1 + ux * end, y1 + uy * end), fill=fill, width=width)
            pos += step + gap


def arrow(points, fill=RED, width=5, dashed=False, head=18):
    line(points, fill, width, dashed)
    x1, y1 = points[-2]
    x2, y2 = points[-1]
    dx, dy = x2 - x1, y2 - y1
    dist = max(1, (dx * dx + dy * dy) ** 0.5)
    ux, uy = dx / dist, dy / dist
    px, py = -uy, ux
    bx, by = x2 - ux * head, y2 - uy * head
    pts = [(x2, y2), (bx + px * head * 0.55, by + py * head * 0.55),
           (bx - px * head * 0.55, by - py * head * 0.55)]
    draw.polygon(pts, fill=fill)


def label(x, y, s, f=F_SMALL, fill=MUTED):
    draw.text((x, y), s, font=f, fill=fill)


# Background grid, similar to the reference drawing.
for x in range(0, W, 40):
    draw.line((x, 0, x, H), fill=GRID, width=1)
for y in range(0, H, 40):
    draw.line((0, y, W, y), fill=GRID, width=1)

# Header.
text_center(40, 22, W - 80, 70, "最新矩阵运算物理数据通路框图", F_TITLE, NAVY if False else "#17324D")
text_center(40, 88, W - 80, 38,
           "TILE=16 · MXU_KIND=0 · 16x16 INT8 MAC · 16 lane DEQACC · FP32 read-modify-write",
           F_SMALL, MUTED)

# Top transport path.
box(70, 150, 300, 176, fill="#8C522F", outline="#6C3E24", title="HBM")
text_center(92, 205, 256, 105, "权重持久存储\n256 bit AXI = 32 B/beat\n一个 tile: 272 B = 9 beat", F_BODY, WHITE)

box(430, 140, 560, 210, fill=LIGHT_GRAY, outline=STROKE, title="MCU - 私有权重补给")
subbox(450, 205, 120, 100, "AXI\nRead\nEngine", LIGHT_AMBER, "#C69550", F_SMALL_B)
subbox(585, 205, 120, 100, "CDC /\nBeat FIFO", LIGHT_BLUE, "#8BB4C9", F_SMALL_B)
subbox(720, 205, 120, 100, "Tile\nAssembly\n272 B", LIGHT_GREEN, "#91B89E", F_SMALL_B)
subbox(855, 205, 115, 100, "Payload /\nScale\nSplit", LIGHT_PURPLE, "#AE8BC7", F_SMALL_B)
arrow([(370, 238), (430, 238)], RED, 6)
label(372, 205, "AXI read", F_SMALL_B, RED)

box(1050, 150, 365, 176, fill="#4D7651", outline="#355A39", title="WFIFO")
text_center(1070, 205, 325, 110, "W_DATA: 128 bit x 512\n8 KiB · INT8 payload\nW_E: E_stat[15:0] 旁带", F_BODY, WHITE)
arrow([(990, 245), (1050, 245)], RED, 6)
label(978, 205, "tile stream", F_SMALL_B, RED)

box(1480, 150, 350, 176, fill=LIGHT_GRAY, outline=STROKE, title="Weight Loader")
text_center(1500, 205, 310, 105, "16 entry/tile\n128 bit/cycle\n写入 inactive Bank\nScale 同步写入", F_BODY, INK)
arrow([(1415, 245), (1480, 245)], RED, 6)

# Activation source, kept separate from weight path.
box(70, 365, 360, 150, fill="#4D7651", outline="#355A39", title="Activation Source")
text_center(92, 420, 316, 78, "QOZ-BUF / XBC / XFIFO\nINT8 data + E_qoz / E_stream\nQOZ-BUF 本体不存 Scale", F_BODY, WHITE)
arrow([(250, 515), (250, 590)], BLUE, 5)

# Main MXU.
box(470, 390, 1300, 760, fill="#F2F5F7", outline="#6A7A83", title="MXU - 16x16 Weight-Stationary Array")

# Physical weight banks inside MXU.
label(510, 455, "物理实现：W_BANK_A/B = PE 内部两组权重寄存器，不是额外复制的 SRAM", F_SMALL_B, AMBER)
subbox(510, 495, 300, 115, "W_BANK_A\nPE bank0: 256 x 8 bit\nE_stat_A: 16 x 8 bit", LIGHT_AMBER, "#C69550", F_BODY_B)
subbox(830, 495, 300, 115, "W_BANK_B\nPE bank1: 256 x 8 bit\nE_stat_B: 16 x 8 bit", LIGHT_AMBER, "#C69550", F_BODY_B)
subbox(1160, 510, 205, 85, "active_bank\nMUX", LIGHT_BLUE, "#6C9CB4", F_BODY_B)
arrow([(1130, 552), (1160, 552)], RED, 5)
arrow([(1365, 552), (1455, 552)], RED, 5)

# Activation input and local broadcast.
subbox(510, 675, 275, 100, "Activation Input Reg\n128 bit = 16 x INT8\nE_stream: 8 bit", LIGHT_GREEN, "#77A888", F_BODY_B)
subbox(820, 690, 260, 70, "16-way local broadcast\na[k] -> PE[k][0:15]", LIGHT_GREEN, "#77A888", F_SMALL_B)
arrow([(250, 590), (250, 725), (510, 725)], BLUE, 5)
arrow([(785, 725), (820, 725)], BLUE, 5)

# PE array with 4x4 representative drawing.
subbox(1130, 650, 385, 245, "PE Array\n16 output groups x 16 PE\n= 256 physical PE", LIGHT_BLUE, "#6C9CB4", F_BODY_B)
cell_x, cell_y, cell_w, cell_h = 1160, 725, 72, 42
for r in range(4):
    for c in range(4):
        draw.rectangle((cell_x + c * 82, cell_y + r * 48,
                        cell_x + c * 82 + cell_w, cell_y + r * 48 + cell_h),
                       fill="#DDECF6", outline="#6C9CB4", width=2)
        text_center(cell_x + c * 82, cell_y + r * 48, cell_w, cell_h, "PE", F_SMALL_B, INK)
text_center(1150, 925, 345, 52, "每个 PE: w_bank0 / w_bank1 + bank MUX + INT8乘法器 + product寄存器", F_TINY, MUTED)
arrow([(1080, 725), (1130, 725)], BLUE, 5)
arrow([(1455, 595), (1455, 650)], RED, 5)

# Adder tree and PSUM output.
subbox(1515, 470, 220, 125, "E_stat sideband\n随 active Bank\n不进入 PE", LIGHT_PURPLE, "#AE8BC7", F_SMALL_B)
arrow([(1365, 552), (1515, 532)], PURPLE, 4, dashed=True)
subbox(1550, 650, 185, 245, "4-level\nbalanced\nadder tree\n\n16 INT16\n-> 1 INT32\nper output group", LIGHT_AMBER, "#C69550", F_SMALL_B)
arrow([(1515, 775), (1550, 775)], RED, 5)
subbox(1510, 950, 225, 105, "PSUM OUT REG\n16 x INT32 = 512 bit\n不是 16x16 PSUM Buffer", LIGHT_RED, "#C77D77", F_BODY_B)
arrow([(1640, 895), (1640, 950)], RED, 5)

# Control/tag lane on MXU top.
subbox(510, 950, 390, 100, "TSQ / CNT_EX / CNT_WB\npipe_tag: row, tile_n, tile_k, final_k, acc_sel, addr", LIGHT_PURPLE, "#AE8BC7", F_SMALL_B)
arrow([(900, 1000), (1450, 1000)], PURPLE, 4, dashed=True)
label(1050, 970, "Tag sideband - same delay as PSUM", F_SMALL_B, PURPLE)

# Right side: DEQACC and accumulator path.
box(1840, 390, 490, 760, fill="#F2F5F7", outline="#6A7A83", title="DEQACC + FP32 Accumulator")
subbox(1870, 470, 430, 205, "DEQACC - 16 lane\nL0: LZC(32)\nL1: Barrel Shift -> mantissa / exponent\nL2: exp = E_stream + E_stat[n] - 266 + EXP_FOLD\nL3: FP32 add\nL4: writeback", LIGHT_PURPLE, "#8D6BA5", F_BODY_B)
arrow([(1735, 1000), (1810, 1000), (1810, 570), (1870, 570)], RED, 6)
label(1745, 945, "PSUM[15:0]", F_SMALL_B, RED)
arrow([(1735, 532), (1810, 532), (1870, 610)], PURPLE, 4, dashed=True)
label(1748, 505, "E_stream + E_stat[15:0]", F_SMALL_B, PURPLE)
arrow([(1735, 1000), (1810, 1000), (1810, 650), (1870, 650)], PURPLE, 4, dashed=True)
label(1715, 1025, "pipe_tag", F_SMALL_B, PURPLE)

subbox(1870, 730, 205, 150, "16 lane FP32\nAccumulator Add\n\nold + partial", LIGHT_AMBER, "#C69550", F_BODY_B)
subbox(2100, 705, 190, 100, "FACC\nFP32 512b x 51 x 2\n6.38 KiB", LIGHT_BLUE, "#6C9CB4", F_SMALL_B)
subbox(2100, 825, 190, 100, "OACC\nFP32 512b x 816\n51 KiB", LIGHT_GREEN, "#77A888", F_SMALL_B)
subbox(2100, 945, 190, 100, "SBUF\nFP32 512b x 51 x 2\nQK score tile", LIGHT_RED, "#C77D77", F_SMALL_B)
arrow([(2080, 805), (2100, 755)], RED, 4)
arrow([(2080, 805), (2100, 875)], RED, 4)
arrow([(2080, 805), (2100, 995)], RED, 4)
label(1875, 895, "acc_sel selects target", F_TINY, MUTED)

# VPU / SFU post-processing block.
box(1840, 1175, 490, 150, fill="#A46032", outline="#7A4324", title="VPU / SFU")
text_center(1865, 1230, 440, 75, "OACC_SCALE: alpha x OACC\nA_FIN: OACC / l -> output\nQK: mask + rowmax -> SBUF", F_BODY_B, WHITE)
arrow([(2195, 925), (2195, 1175)], PURPLE, 4, dashed=True)
label(2208, 1060, "OACC read", F_SMALL_B, PURPLE)

# Output / final quant path to QOZ.
arrow([(1840, 1280), (1660, 1280), (1660, 1215), (250, 1215), (250, 515)], GREEN, 4, dashed=True)
label(680, 1230, "A_FIN / quant -> QOZ-BUF (O) + E_o", F_SMALL_B, GREEN)

# Legend.
legend_y = 1338
draw.line((70, legend_y, 145, legend_y), fill=RED, width=5)
label(155, legend_y - 13, "主数据: INT8 / INT32 / FP32", F_TINY, RED)
line([(520, legend_y), (595, legend_y)], PURPLE, 4, True)
label(605, legend_y - 13, "旁带: Scale / Tag / valid", F_TINY, PURPLE)
draw.line((1040, legend_y, 1115, legend_y), fill=BLUE, width=5)
label(1125, legend_y - 13, "激活路径", F_TINY, BLUE)
label(1740, legend_y - 13, "物理存储与流水单元视图，非 RTL 端口级图", F_TINY, MUTED)

img.save(OUT, "PNG", optimize=True)
print(OUT)
