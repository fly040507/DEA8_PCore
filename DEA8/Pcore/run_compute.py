"""Portable Vivado runner. No implicit synthesis and no behavioral unit models."""
from pathlib import Path
import argparse
import ctypes
import hashlib
import json
import os
import re
import shutil
import subprocess
import sys
import datetime

ROOT = Path(__file__).resolve().parent
LIBRARIES = ["xbip_utils_v3_0_10", "axi_utils_v2_0_6", "xbip_pipe_v3_0_6",
             "xbip_dsp48_wrapper_v3_0_4", "xbip_dsp48_addsub_v3_0_6",
             "xbip_dsp48_multadd_v3_0_6", "xbip_bram18k_v3_0_6", "mult_gen_v12_0_18",
             "floating_point_v7_1_15", "unisims_ver", "unimacro_ver", "secureip", "xpm"]


def run(vivado, tool, options, log, cwd=ROOT):
    exe = vivado / "bin" / (tool + (".bat" if os.name == "nt" else ""))
    command = [str(exe), *map(str, options)]
    print("START", tool, log.name, flush=True)
    with log.open("w", encoding="utf-8") as f:
        result = subprocess.run(command, cwd=cwd, stdout=f, stderr=subprocess.STDOUT)
    content = log.read_text(encoding="utf-8", errors="replace")
    if result.returncode or re.search(r"^\s*(?:Fatal:|Error:|ERROR:)", content, re.M):
        print("\n".join(content.splitlines()[-24:]), flush=True)
        raise RuntimeError(f"{tool} failed; {log}")
    print("DONE", tool, flush=True)
    return content


def main():
    if os.name == "nt":
        ctypes.windll.kernel32.SetErrorMode(0x0001 | 0x0002 | 0x8000)
    parser = argparse.ArgumentParser()
    parser.add_argument("stage", choices=["ip", "compile", "elaborate", "simulate", "test"])
    parser.add_argument("--vivado", type=Path, default=Path(os.environ.get("VIVADO_ROOT", "D:/Xilinx/Vivado/2022.2")))
    parser.add_argument("--top", default="tb_compute_math")
    parser.add_argument("--opt", default="3", choices=["0", "1", "2", "3"])
    parser.add_argument("--arg", action="append", default=[])
    parser.add_argument("--report-tag", help="Save an independent run under reports/compute/<tag>")
    args = parser.parse_args()
    report = ROOT / "reports/compute"
    if args.report_tag:
        if not re.fullmatch(r"[A-Za-z0-9_-]+", args.report_tag):
            parser.error("--report-tag must contain only letters, numbers, underscores or hyphens")
        report = report / args.report_tag
    report.mkdir(parents=True, exist_ok=True)
    if args.stage == "ip":
        run(args.vivado, "vivado", ["-mode", "batch", "-nojournal", "-nolog", "-source", ROOT / "ip/generate_compute_ip.tcl", "-tclargs", ROOT], report / "ip.log")
        return
    if args.stage in ("compile", "test"):
        models = [ROOT / f"ip/generated/{n}/sim/{n}.v" for n in
                  ["pcore_fpadd_ip", "dea8_fpadd_ip", "dea8_fpmul_ip", "dea8_fpexp_ip", "dea8_fprecip_ip"]]
        if not all(p.exists() for p in models):
            raise RuntimeError("Run stage ip first; official models are required")
        sources = [ROOT / line for line in (ROOT / "pcore_rtl.f").read_text().splitlines() if line.strip()]
        sources += models + [args.vivado / "data/ip/xpm/xpm_memory/hdl/xpm_memory.sv",
                             args.vivado / "data/verilog/src/glbl.v"]
        sources += sorted((ROOT / "tb/compute").glob("*.sv"))
        sources += [ROOT / "tb/tb_packet_decode.sv"]
        filelist = ROOT / "output/compute_sources.f"
        filelist.parent.mkdir(parents=True, exist_ok=True)
        filelist.write_text("".join(f'"{p.as_posix()}"\n' for p in sources), encoding="utf-8")
        run(args.vivado, "xvlog", ["-sv", "-f", filelist], report / "compile.log")
        inputs = sources + sorted((ROOT / "units/rom").glob("*.mem")) + sorted((ROOT / "tb/data").rglob("*.mem"))
        inputs += [ROOT / "pcore_rtl.f", ROOT / "ip/generate_compute_ip.tcl", ROOT / "ip/compute_ip_config.txt"]
        manifest = {str(p.relative_to(ROOT)) if p.is_relative_to(ROOT) else str(p): hashlib.sha256(p.read_bytes()).hexdigest() for p in inputs}
        (report / "compile_sha256.json").write_text(json.dumps(manifest, indent=2), encoding="utf-8")
    manifest_path = report / "compile_sha256.json"
    if not manifest_path.exists():
        raise RuntimeError("Compile first; no source/configuration manifest exists")
    frozen = json.loads(manifest_path.read_text(encoding="utf-8"))
    def check_inputs():
        for name, expected in frozen.items():
            p = Path(name)
            if not p.is_absolute(): p = ROOT / p
            if not p.exists() or hashlib.sha256(p.read_bytes()).hexdigest() != expected:
                raise RuntimeError("Input changed since compile: " + name)
    check_inputs()
    manifest_hash = hashlib.sha256(manifest_path.read_bytes()).hexdigest()
    snapshot = args.top + "_native"
    snapshot_manifest = report / (args.top + "_snapshot.json")
    if args.stage in ("elaborate", "test"):
        run(args.vivado, "xelab", [args.top, "glbl", "-s", snapshot, "--O" + args.opt,
            "--debug", "typical", "--mt", "off", "-timescale", "1ns/1ps",
            *[s for lib in LIBRARIES for s in ("-L", lib)]], report / (args.top + "_elaborate.log"))
        snapshot_manifest.write_text(json.dumps({"compile_sha256": manifest_hash, "optimization": args.opt}), encoding="utf-8")
    if args.stage in ("simulate", "test"):
        if not snapshot_manifest.exists() or json.loads(snapshot_manifest.read_text())["compile_sha256"] != manifest_hash:
            raise RuntimeError("Snapshot does not match current compilation; elaborate again")
        options = [snapshot, "-runall"]
        for value in args.arg:
            options += ["-testplusarg", value]
        suffix = "_" + re.sub(r"[^A-Za-z0-9_-]", "_", "_".join(args.arg)) if args.arg else ""
        text = run(args.vivado, "xsim", options, report / (args.top + suffix + "_simulate.log"))
        marker = args.top + " PASS"
        if marker not in text:
            raise RuntimeError("Missing acceptance marker: " + marker)
        check_inputs()
        (report / (args.top + suffix + "_PASS.json")).write_text(json.dumps({"marker": marker,
            "time": datetime.datetime.now().astimezone().isoformat(), "args": args.arg,
            "compile_manifest_sha256": manifest_hash,
            "internal_tb_models": False, "synthesis": False}, indent=2), encoding="utf-8")
        print("\n".join(line for line in text.splitlines() if any(s in line for s in [" PASS", "PERF ", "TOTAL ", "HIDING ", "ACTIVITY_"])), flush=True)


if __name__ == "__main__":
    main()
