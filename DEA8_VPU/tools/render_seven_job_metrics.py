"""Render a measured seven-Job table only from a hash-matched native PASS."""
from pathlib import Path
import argparse
import csv
import hashlib
import json
import re
from PIL import Image,ImageDraw,ImageFont

ROOT=Path(__file__).resolve().parents[1]
EXPECTED={"K":3328,"V":3328,"Q":26624,"Attention":45760,"O":26624,"G-U":106496,"Down":53248}


def main():
    parser=argparse.ArgumentParser()
    parser.add_argument("--report",type=Path,default=ROOT/"Pcore/reports/compute")
    parser.add_argument("--out",type=Path,default=ROOT/"reports/seven_job_native")
    args=parser.parse_args()
    report=args.report.resolve()
    log_path=report/"tb_pcore_seven_native_simulate.log"
    text=log_path.read_text(encoding="utf-8",errors="replace")
    marker="tb_pcore_seven_native PASS jobs=7 QK=55 PV=55 internal_tb_models=0 synthesis=0"
    if marker not in text or re.search(r"^\s*(Fatal:|Error:|ERROR:)",text,re.M):
        raise RuntimeError("A complete seven-Job native PASS is required")
    passed=json.loads((report/"tb_pcore_seven_native_PASS.json").read_text())
    manifest_path=report/"compile_sha256.json"
    if passed["compile_manifest_sha256"]!=hashlib.sha256(manifest_path.read_bytes()).hexdigest():
        raise RuntimeError("PASS and compile manifest differ")
    for name,expected in json.loads(manifest_path.read_text()).items():
        path=Path(name)
        if not path.is_absolute():path=ROOT/"Pcore"/path
        if not path.exists() or hashlib.sha256(path.read_bytes()).hexdigest()!=expected:
            raise RuntimeError("Inputs changed after verification: "+name)
    rows=[]
    for name,cycles,issues in re.findall(r"JOB_PERF name=(\S+) op=\d+ cycles=(\d+) matrix_issues=(\d+)",text):
        cycles,issues=int(cycles),int(issues)
        if EXPECTED.get(name)!=issues or cycles<issues:raise RuntimeError("Invalid Job accounting")
        rows.append(dict(job=name,cycles=cycles,simulation_us=cycles/250,matrix_issues=issues,occupancy=issues/cycles))
    if [r["job"] for r in rows]!=list(EXPECTED):raise RuntimeError("Missing, repeated or unordered Jobs")
    total=sum(r["cycles"] for r in rows)
    match=re.search(r"TOTAL cycles=(\d+) matrix_issues=(\d+) checked_q=(\d+) checked_fp=(\d+)",text)
    if not match or int(match[1])!=total or int(match[2])!=265408:raise RuntimeError("Total does not match Job rows")
    rows.append(dict(job="合计",cycles=total,simulation_us=total/250,matrix_issues=265408,occupancy=265408/total))
    args.out.mkdir(parents=True,exist_ok=True)
    with (args.out/"metrics.csv").open("w",newline="",encoding="utf-8-sig") as handle:
        writer=csv.DictWriter(handle,fieldnames=list(rows[0]));writer.writeheader();writer.writerows(rows)
    (args.out/"metrics.json").write_text(json.dumps(dict(rows=rows,clock_period_ns=4,
        time_kind="simulation_not_board_measurement",pass_time=passed["time"],
        compile_manifest_sha256=passed["compile_manifest_sha256"],
        log_sha256=hashlib.sha256(log_path.read_bytes()).hexdigest(),
        checked_quant=int(match[3]),checked_fp=int(match[4]),internal_tb_models=False,synthesis=False),indent=2,ensure_ascii=False),encoding="utf-8")
    def font(size,mono=False):
        candidates=([Path("C:/Windows/Fonts/consola.ttf")] if mono else [])+[
            Path("C:/Windows/Fonts/msyh.ttc"),Path("/usr/share/fonts/opentype/noto/NotoSansCJK-Regular.ttc"),
            Path("/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf")]
        for path in candidates:
            if path.exists():return ImageFont.truetype(str(path),size)
        raise RuntimeError("No suitable font available")
    image=Image.new("RGB",(1320,850),(12,14,17));draw=ImageDraw.Draw(image)
    title,header,body,number,small=font(32),font(26),font(27),font(29,True),font(21)
    draw.text((28,20),"单核真实 RTL：七 Job 串行验证",font=title,fill="#eeeeee")
    edges=[28,224,444,726,992,1292];top=84;rh=70
    for x in edges:draw.line((x,top,x,top+9*rh),fill="#72767e",width=2)
    for y in range(10):draw.line((edges[0],top+y*rh,edges[-1],top+y*rh),fill="#72767e",width=2)
    labels=["Job","总周期","仿真用时 / μs","矩阵 issue 周期","全 Job 矩阵占比"]
    for i,label in enumerate(labels):draw.text((edges[i]+14,top+18),label,font=header,fill="#b29ae6")
    for index,row in enumerate(rows):
        values=[row["job"],f'{row["cycles"]:,}',f'{row["simulation_us"]:,.3f}',f'{row["matrix_issues"]:,}',f'{100*row["occupancy"]:.2f}%']
        for i,value in enumerate(values):
            color="#ffba55" if index==7 or i==4 else "#eeeeee"
            draw.text((edges[i]+14,top+(index+1)*rh+18),value,font=body if i==0 else number,fill=color)
    draw.text((28,736),"DUT 内无 TB 算术模型；TB 仅提供单核外部数据、命令与接收。",font=small,fill="#b8bec7")
    draw.text((28,772),"4 ns/拍仅用于仿真时间换算；不是 250 MHz 板上实测或时序签核。",font=small,fill="#b8bec7")
    draw.text((28,808),f'证据：{passed["compile_manifest_sha256"][:20]}  |  {passed["time"][:19]}',font=small,fill="#9099a8")
    image.save(args.out/"seven_job_native.png")
    print(f"METRICS_READY cycles={total} matrix=265408 occupancy={265408/total:.4%} out={args.out}")


if __name__=="__main__":main()
