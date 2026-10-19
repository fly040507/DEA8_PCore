"""Real-layer verification and single-module resource synthesis.

Resource preview is explicit; normal synthesis requires simulation evidence.
Eight-core synthesis and place/route are deferred in the current phase.
"""
from pathlib import Path
import argparse
import ctypes
import hashlib
import json
import os
import re
import subprocess
import sys
from datetime import datetime

ROOT=Path(__file__).resolve().parent
sys.path.insert(0,str(ROOT/"Pcore"))
from run_compute import LIBRARIES


def run(vivado,tool,args,log):
    command=[str(vivado/"bin"/(tool+(".bat" if os.name=="nt" else ""))),*map(str,args)]
    print("START",tool,log.name,flush=True)
    with log.open("w",encoding="utf-8") as f:
        p=subprocess.run(command,cwd=ROOT,stdout=f,stderr=subprocess.STDOUT)
    text=log.read_text(encoding="utf-8",errors="replace")
    if p.returncode or re.search(r"^\s*(?:Fatal:|Error:|ERROR:)",text,re.M):
        print("\n".join(text.splitlines()[-24:]),flush=True)
        raise RuntimeError(f"{tool} failed: {log}")
    print("DONE",tool,flush=True)
    return text


def source_list(component=None):
    result=[]
    lists={"pcore":(ROOT/"Pcore","pcore_rtl.f"),"gcore":(ROOT/"Gcore","gcore_rtl.f")}
    selected=list(lists.values()) if component is None else [lists[component]]
    for base,file in selected:
        for line in (base/file).read_text(encoding="utf-8").splitlines():
            if not line.strip() or line.startswith("#"):continue
            p=(base/line).resolve()
            if p not in result:result.append(p)
    if component is None:result += sorted((ROOT/"control/rtl").glob("*.sv"))
    return result


def digest(paths):
    return {str(p.relative_to(ROOT)) if p.is_relative_to(ROOT) else str(p):
        hashlib.sha256(p.read_bytes()).hexdigest() for p in paths}


def archive_manifest(path):
    if path.exists():
        checksum=hashlib.sha256(path.read_bytes()).hexdigest()
        directory=path.parent/"manifests";directory.mkdir(exist_ok=True)
        target=directory/(checksum+".json")
        if not target.exists():target.write_bytes(path.read_bytes())


def require_simulation_passes():
    """Require current-input evidence, not copied historical PASS files."""
    evidence=[]
    suites=[(ROOT/"Pcore/reports/compute",ROOT/"Pcore",[
        ("tb_pcore_seven_native_PASS.json","tb_pcore_seven_native_simulate.log","tb_pcore_seven_native",[])])]
    cases=[["LAYER=1"],["LAYER=9"],["LAYER=18"],["LAYER=9","STRESS"],
        ["LAYER=18","STRESS"],["LAYER=1","CANCEL_AT=Attention"],
        ["LAYER=1","CANCEL_AT=GU"],["LAYER=1","CANCEL_AT=O"],
        ["LAYER=1","CANCEL_AT=O","RECOVER"]]
    top="tb_dea8_layers_native"
    records=[]
    for args in cases:
        tag=top+"_"+re.sub(r"[^A-Za-z0-9_-]","_","_".join(args))
        records.append((tag+"_PASS.json",tag+".log",top,args))
    suites.append((ROOT/"reports/layer_native",ROOT,records))
    for report,base,records in suites:
        manifest=report/"compile_sha256.json"
        if not manifest.exists():raise RuntimeError(f"Simulation first: missing {manifest}")
        for name,expected in json.loads(manifest.read_text(encoding="utf-8")).items():
            path=Path(name)
            if not path.is_absolute():path=base/path
            if not path.is_file() or hashlib.sha256(path.read_bytes()).hexdigest()!=expected:
                raise RuntimeError(f"Simulation inputs changed; compile and rerun: {name}")
        checksum=hashlib.sha256(manifest.read_bytes()).hexdigest()
        evidence.append(manifest)
        for pass_name,log_name,top,args in records:
            passed,log=report/pass_name,report/log_name
            if not passed.is_file() or not log.is_file():
                raise RuntimeError(f"Simulation first: missing {passed}")
            record=json.loads(passed.read_text(encoding="utf-8"))
            content=log.read_text(encoding="utf-8",errors="replace")
            if (record.get("compile_manifest_sha256")!=checksum or
                record.get("internal_tb_models") is not False or record.get("args")!=args or
                top+" PASS" not in content or re.search(r"^\s*(?:Fatal:|Error:|ERROR:)",content,re.M)):
                raise RuntimeError(f"Invalid/stale simulation evidence: {passed}")
            if top=="tb_pcore_seven_native" and "PASS jobs=7 QK=55 PV=55 internal_tb_models=0" not in content:
                raise RuntimeError(f"Incomplete seven-Job evidence: {log}")
            evidence += [passed,log]
    return evidence


def main():
    if os.name=="nt":ctypes.windll.kernel32.SetErrorMode(0x0001|0x0002|0x8000)
    ap=argparse.ArgumentParser()
    ap.add_argument("stage",choices=["vectors","ip","compile","elaborate","simulate","test","synth","place-route"])
    ap.add_argument("--vivado",type=Path,default=Path(os.environ.get("VIVADO_ROOT","D:/Xilinx/Vivado/2022.2")))
    ap.add_argument("--top",default="tb_dea8_layers_native")
    ap.add_argument("--opt",choices=["0","1","2","3"],default="3")
    ap.add_argument("--arg",action="append",default=[])
    ap.add_argument("--server-heavy",action="store_true")
    ap.add_argument("--target",choices=["gcore","pcore"],help="Required for resource-only synthesis; no eight-core target")
    ap.add_argument("--resource-preview",action="store_true",
        help="Synthesis-only area preview without claiming the full simulation gate passed")
    ap.add_argument("--report-tag",help="Separate synthesis run name; preserves earlier area evidence")
    args=ap.parse_args()
    if args.stage=="place-route":ap.error("Place/route is deferred; this phase measures GCore and one PCore resources only")
    if args.stage=="synth" and (args.target is None or (not args.server_heavy and not args.resource_preview)):
        ap.error("Use synth --target gcore|pcore --server-heavy after completing server simulations")
    if args.target is not None and args.stage!="synth":ap.error("--target applies only to synth")
    if args.resource_preview and args.stage!="synth":ap.error("--resource-preview applies only to synth")
    if args.report_tag is not None and (args.stage!="synth" or not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9_-]*",args.report_tag)):
        ap.error("--report-tag applies only to synth and must be an alphanumeric/hyphen/underscore name")
    reports=ROOT/"reports/layer_native";reports.mkdir(parents=True,exist_ok=True)
    if args.stage=="vectors":
        subprocess.run([sys.executable,str(ROOT/"tools/generate_layer_vectors.py")],cwd=ROOT,check=True);return
    if args.stage=="ip":
        for file in ["Pcore/ip/generate_compute_ip.tcl","Gcore/ip/create_rsqrt.tcl"]:
            run(args.vivado,"vivado",["-mode","batch","-nojournal","-nolog","-source",file],reports/(Path(file).stem+".log"))
        return
    if args.stage=="synth":
        evidence=[] if args.resource_preview else require_simulation_passes()
        sources=[p for p in source_list(args.target) if "/ip/generated/" not in p.as_posix()]
        listing=ROOT/f"output/{args.target}_synth_sources.f";listing.parent.mkdir(parents=True,exist_ok=True)
        listing.write_text("\n".join(p.as_posix() for p in sources)+"\n",encoding="utf-8")
        script=ROOT/"tools/synth_resource.tcl"
        files=sources+[ROOT/"run_dea8.py",script,ROOT/"tools/dea8_4ns.xdc",listing,
            ROOT/"Pcore/pcore_rtl.f",ROOT/"Gcore/gcore_rtl.f",
            ROOT/"Pcore/ip/generate_compute_ip.tcl",ROOT/"Pcore/ip/compute_ip_config.txt",
            ROOT/"Gcore/ip/create_rsqrt.tcl",ROOT/"Gcore/ip/rsqrt_config.txt"]
        files+=sorted((ROOT/"Pcore/ip/generated").glob("*/*.xci"))+sorted((ROOT/"Gcore/ip/generated").glob("*/*.xci"))
        files+=sorted((ROOT/"Pcore/units/rom").glob("*.mem"))
        report_name=args.target+"_"+args.report_tag if args.report_tag else (args.target+"_preview" if args.resource_preview else args.target)
        report=ROOT/"reports/resource_synth"/report_name
        report.mkdir(parents=True,exist_ok=True)
        before=digest(files+evidence)
        (report/"inputs_sha256.json").write_text(json.dumps(before,indent=2),encoding="utf-8")
        # Do not leave an old success marker after a failed rerun.
        success=report/"PASS.json"
        success.unlink(missing_ok=True)
        content=run(args.vivado,"vivado",["-mode","batch","-nojournal","-nolog","-source",script,
            "-tclargs",args.target,listing,report],report/"synth.log")
        if f"DEA8_RESOURCE_SYNTH_DONE target={args.target} " not in content:
            raise RuntimeError("Missing resource-synthesis completion marker")
        if digest(files+evidence)!=before:raise RuntimeError("Inputs changed during synthesis")
        success.write_text(json.dumps({"time":datetime.now().astimezone().isoformat(),
            "target":args.target,"top":"dea8_gcore" if args.target=="gcore" else "dea8_pcore_top",
            "input_manifest_sha256":hashlib.sha256((report/"inputs_sha256.json").read_bytes()).hexdigest(),
            "simulation_gate_passed":not args.resource_preview,"resource_preview":args.resource_preview,
            "synthesis_only":True,"placement_routing":False,
            "eight_core_synthesis":False},indent=2),encoding="utf-8")
        return
    sources=source_list()
    for n in ["pcore_fpadd_ip","dea8_fpexp_ip","dea8_fprecip_ip"]:
        sources.append(ROOT/f"Pcore/ip/generated/{n}/sim/{n}.v")
    sources += [args.vivado/"data/ip/xpm/xpm_memory/hdl/xpm_memory.sv",args.vivado/"data/verilog/src/glbl.v"]
    sources += sorted((ROOT/"tb").glob("*.sv"))
    # Include official IP/config images and external oracle inputs in provenance.
    inputs=list(sources)+sorted((ROOT/"Pcore/units/rom").glob("*.mem"))+sorted((ROOT/"tb/data/layer_native").rglob("*.mem"))
    inputs += sorted((ROOT/"Pcore/tb/data").rglob("*.mem"))
    inputs += [ROOT/"run_dea8.py",ROOT/"Pcore/pcore_rtl.f",ROOT/"Gcore/gcore_rtl.f",
        ROOT/"Pcore/ip/generate_compute_ip.tcl",ROOT/"Pcore/ip/compute_ip_config.txt",
        ROOT/"Gcore/ip/create_rsqrt.tcl",ROOT/"Gcore/ip/rsqrt_config.txt",
        ROOT/"tools/generate_layer_vectors.py"]
    inputs += sorted((ROOT/"Pcore/ip/generated").glob("*/*.xci"))
    inputs += sorted((ROOT/"Gcore/ip/generated").glob("*/*.xci"))
    if any(not p.exists() for p in inputs):raise RuntimeError("Missing input; run vectors and ip stages first")
    manifest=reports/"compile_sha256.json"
    if args.stage in ("compile","test"):
        archive_manifest(manifest)
        listing=ROOT/"output/dea8_sim_sources.f";listing.parent.mkdir(parents=True,exist_ok=True)
        listing.write_text("".join(f'"{p.as_posix()}"\n' for p in sources),encoding="utf-8")
        run(args.vivado,"xvlog",["-sv","-f",listing],reports/"compile.log")
        manifest.write_text(json.dumps(digest(inputs),indent=2),encoding="utf-8")
        archive_manifest(manifest)
    elif not manifest.exists() or json.loads(manifest.read_text())!=digest(inputs):
        raise RuntimeError("Sources/configuration/oracle changed after compilation; compile again")
    manifest_hash=hashlib.sha256(manifest.read_bytes()).hexdigest()
    snapshot=args.top+"_native";report_tag=args.top+"_"+re.sub(r"[^A-Za-z0-9_-]","_","_".join(args.arg) or "default")
    snapshot_manifest=reports/(args.top+"_snapshot.json")
    if args.stage in ("elaborate","test"):
        if args.top=="tb_dea8_layers_native" and not args.server_heavy:
            ap.error("Eight complete PCores are a server-heavy elaboration; compile only locally")
        run(args.vivado,"xelab",[args.top,"glbl","-s",snapshot,"--O"+args.opt,"--debug","typical","--mt","off",
            "-timescale","1ns/1ps",*[s for lib in LIBRARIES for s in ("-L",lib)]],reports/(args.top+"_elaborate.log"))
        snapshot_manifest.write_text(json.dumps({"compile_sha256":manifest_hash,"optimization":args.opt}),encoding="utf-8")
    if args.stage in ("simulate","test"):
        if args.top=="tb_dea8_layers_native" and not args.server_heavy:ap.error("Use --server-heavy on the server for full layer simulation")
        if not snapshot_manifest.exists() or json.loads(snapshot_manifest.read_text())["compile_sha256"]!=manifest_hash:
            raise RuntimeError("Snapshot does not match current compilation; elaborate again")
        options=[snapshot,"-runall"]
        for value in args.arg:options += ["-testplusarg",value]
        text=run(args.vivado,"xsim",options,reports/(report_tag+".log"))
        if args.top+" PASS" not in text:raise RuntimeError("Missing explicit PASS marker")
        if json.loads(manifest.read_text())!=digest(inputs):raise RuntimeError("Inputs changed during verification")
        (reports/(report_tag+"_PASS.json")).write_text(json.dumps({"time":datetime.now().astimezone().isoformat(),
            "top":args.top,"args":args.arg,"compile_manifest_sha256":hashlib.sha256(manifest.read_bytes()).hexdigest(),
            "internal_tb_models":False,"input_fixture":args.top=="tb_attention_history",
            "scope":"eight_core_layer" if args.top=="tb_dea8_layers_native" else "targeted_test",
            "synthesis":False},indent=2),encoding="utf-8")
        print("\n".join(l for l in text.splitlines() if " PASS" in l or "PERF " in l or "TOTAL " in l),flush=True)


if __name__=="__main__":main()
