"""Panda-only, simulation-only runner. Never imports project runners or edits RTL.

Coverage follows run_compute.py, run_dea8.py and run_gcore_xsim.ps1.
Every mutable elaboration/simulation directory is private. Existing IP simulation
models are consumed unchanged with Vivado 2023.1; no IP upgrade/generation occurs.
"""
from pathlib import Path
from concurrent.futures import ThreadPoolExecutor, as_completed
from collections import Counter
import datetime
import fcntl
import hashlib
import json
import os
import re
import shutil
import signal
import subprocess
import sys
import threading
import time
import traceback

ROOT = Path('/home/zhaofei/DEA8')
RUN = Path(__file__).resolve().parent
VIVADO = Path('/opt/Vivado/Vivado/2023.1')
PYTHON = sys.executable
LIBRARIES = ['xbip_utils_v3_0_10', 'axi_utils_v2_0_6', 'xbip_pipe_v3_0_6',
    'xbip_dsp48_wrapper_v3_0_4', 'xbip_dsp48_addsub_v3_0_6',
    'xbip_dsp48_multadd_v3_0_6', 'xbip_bram18k_v3_0_6', 'mult_gen_v12_0_18',
    'floating_point_v7_1_15', 'unisims_ver', 'unimacro_ver', 'secureip', 'xpm']
ERROR = re.compile(r'^\s*(?:Fatal:|Error:|ERROR:|FATAL:|CRITICAL WARNING:)', re.M)
LICENSE = re.compile(r'(?:ERROR[^\n]*(?:license|licensing)|license[^\n]*(?:checkout failed|not available|denied))', re.I)
LOCK = threading.RLock()
HASH_LOCK = threading.Lock()
STOP = threading.Event()
JOBS = {}
RESULTS = {}
ELAB_LOCKS = {}
ELAB_RESULTS = {}
BASELINE = {}
MANIFEST_SHA = ''
CPUS = sorted(os.sched_getaffinity(0))
SEQUENCE = 0
MAX_CONCURRENCY = 8
PHASE = 'SETUP'
MATRIX = []


def now():
    return datetime.datetime.now().astimezone().isoformat()


def write_json(path, value):
    tmp = path.with_name(path.name + '.tmp.' + str(threading.get_ident()))
    tmp.write_text(json.dumps(value, ensure_ascii=False, indent=2), encoding='utf-8')
    tmp.replace(path)


def event(kind, **fields):
    value = dict(time=now(), event=kind)
    value.update(fields)
    with LOCK:
        with (RUN/'events.jsonl').open('a', encoding='utf-8') as f:
            f.write(json.dumps(value, ensure_ascii=False) + '\n')
    print(json.dumps(value, ensure_ascii=False), flush=True)


def status():
    with LOCK:
        counts = Counter(v['status'] for v in RESULTS.values())
        write_json(RUN/'status.json', {'time':now(), 'phase':PHASE,
            'total_scenarios':len(MATRIX), 'completed':sum(counts.values()),
            'pass':counts['PASS'], 'fail':counts['FAIL'],
            'max_concurrency':MAX_CONCURRENCY,
            'running':[dict(id=k, **{x:v[x] for x in ['pid','cpu','tool','paused','started']}) for k,v in JOBS.items()],
            'results':RESULTS, 'synthesis_started':False, 'rtl_modified_by_runner':False})


def add(stage, group, top, args=()):
    tag = top + ('__' + '__'.join(args) if args else '')
    tag = re.sub(r'[^A-Za-z0-9_-]', '_', tag)
    MATRIX.append({'id':tag, 'stage':stage, 'group':group, 'top':top, 'args':list(args)})


def matrix():
    for top in ['tb_compute_math','tb_compute_sfu']:
        add('P1','pcore',top)
    for top in ['tb_gcore_native_math','tb_mask_profile','tb_qk_special_rows',
                'tb_vpu_p_history','tb_gcore_norm_native','tb_attention_history','tb_pcore_cancel_native']:
        add('P1','layer',top)
    add('P1','layer','tb_gcore_norm_native',['IMPORT_FIRST'])
    add('P1','layer','tb_attention_history',['HIDING_AUDIT'])
    for suffix in ['types','stores','xbc','control','arithmetic','kv','rsqrt','frontend','packet','pcore_link','gamma_fetch']:
        add('P1','gcore','tb_gcore_'+suffix)
    add('P1','pcore','tb_pcore_seven_native')
    add('P1','pcore','tb_pcore_seven_native',['STRESS'])
    for args in [[],['STRESS'],['BAD_HEADER'],['BAD_PACKET'],['CANCEL_ACTIVE']]:
        add('P1','gcore','tb_gcore_integrated',args)
    for args in [[],['LAYER9'],['LAYER18'],['LAYER9','STRESS'],['LAYER18','STRESS'],['CANCEL_START'],['GAMMA_FAULT_DOWN']]:
        add('P1','gcore','tb_gcore_layers',args)
    for layer in [1,9,18]:
        add('P2','layer','tb_dea8_layers_native',['LAYER='+str(layer)])
    for layer in [9,18]:
        add('P3','layer','tb_dea8_layers_native',['LAYER='+str(layer),'STRESS'])
    for point in ['Attention','GU','O']:
        add('P3','layer','tb_dea8_layers_native',['LAYER=1','CANCEL_AT='+point])
    add('P3','layer','tb_dea8_layers_native',['LAYER=1','CANCEL_AT=O','RECOVER'])
    for point in ['K','Q','SCALE','Down']:
        add('P3','layer','tb_dea8_layers_native',['LAYER=1','CANCEL_AT='+point])
    add('P3','layer','tb_dea8_layers_native',['LAYER=18','CANCEL_AT=Final'])
    assert len(MATRIX)==50 and len({x['id'] for x in MATRIX})==50
    write_json(RUN/'test_matrix.json', {'created':now(),'cases':MATRIX,
        'basis':['Pcore/run_compute.py','run_dea8.py','Gcore/run_gcore_xsim.ps1','Server_Verification.md'],
        'p0':'Fresh compile of all production source lists, active TBs and Vivado 2023.1 XPM/glbl; private top elaborations.',
        'exclusions':{'tb_packet_decode':'Helper, no standalone PASS or stimulus',
            'legacy_compatibility':'reduce/, Pcore/legacy/, old control signoff and GCore TBs absent from gcore.f are not current production acceptance',
            'subset_flags':'K_ONLY/KVQ_ONLY/THROUGH_GU/NORM_ONLY are diagnostic subsets, not replacements for full workloads'},
        'permitted_scope':'Only independent layer1/9/18 checkpoints; no continuous 18-layer or denoising run',
        'synthesis':'Disabled in this runner, even after all simulation passes'})


def filelist(path):
    result=[]
    for raw in path.read_text().splitlines():
        s=raw.strip()
        if not s or s.startswith('#'):continue
        if s.startswith('-f '):result+=filelist(path.parent/s[3:].strip())
        else:result.append((path.parent/s).resolve())
    return result


def prepare():
    global BASELINE, MANIFEST_SHA
    sources=filelist(ROOT/'Pcore/pcore_rtl.f')+filelist(ROOT/'Gcore/gcore_rtl.f')
    sources+=sorted((ROOT/'control/rtl').glob('*.sv'))
    sources+=[ROOT/'Pcore/ip/generated'/n/'sim'/(n+'.v') for n in ['pcore_fpadd_ip','dea8_fpexp_ip','dea8_fprecip_ip']]
    sources+=sorted((ROOT/'Pcore/tb/compute').glob('*.sv'))+[ROOT/'Pcore/tb/tb_packet_decode.sv']
    sources+=sorted((ROOT/'tb').glob('*.sv'))
    sources+=filelist(ROOT/'Gcore/gcore.f')
    sources+=[VIVADO/'data/ip/xpm/xpm_memory/hdl/xpm_memory.sv', VIVADO/'data/verilog/src/glbl.v']
    sources=list(dict.fromkeys(sources))
    missing=[str(p) for p in sources if not p.is_file()]
    if missing:raise RuntimeError('Missing compilation inputs: '+str(missing))
    inputs=set(sources)
    for rel in ['Pcore/rtl','Pcore/units','Gcore/rtl','control/rtl','Pcore/tb/data','Gcore/tb/data','tb/data','Pcore/ip','Gcore/ip']:
        for p in (ROOT/rel).rglob('*'):
            if p.is_file() and p.suffix.lower() in ['.sv','.v','.vhd','.vhdl','.mem','.xci','.f','.tcl','.txt','.json']:
                inputs.add(p.resolve())
    for rel in ['run_dea8.py','Pcore/run_compute.py','Gcore/run_gcore_xsim.ps1',
                'Pcore/pcore_rtl.f','Gcore/gcore_rtl.f','Gcore/gcore.f',
                'tools/generate_layer_vectors.py','Pcore/tools/prepare_compute_vectors.py',
                'Pcore/tools/prepare_seven_job.py','HANDOFF.md','Server_Verification.md']:
        inputs.add(ROOT/rel)
    inputs.add(VIVADO/'data/xsim/xsim.ini')
    for p in [RUN/'run_simulations.py',RUN/'exec_tool.py',RUN/'launch.sh']:
        inputs.add(p)
    BASELINE={str(p):hashlib.sha256(p.read_bytes()).hexdigest() for p in sorted(inputs)}
    write_json(RUN/'compile_manifest.json',BASELINE)
    MANIFEST_SHA=hashlib.sha256((RUN/'compile_manifest.json').read_bytes()).hexdigest()
    write_json(RUN/'environment.json', {'time':now(),'pid':os.getpid(),'ppid':os.getppid(),
        'uid':os.getuid(),'python':PYTHON,'python_version':sys.version,'vivado':str(VIVADO),
        'settings_loaded':os.environ.get('XILINX_VIVADO'),
        'cgroup':Path('/proc/self/cgroup').read_text(),'affinity':CPUS,
        'max_parallel_heavy':8,'max_authorized_heavy':12,'single_tool_cpu_limit':1,
        'nice':10,'io_class':'idle','per_tool_virtual_memory_limit_gib':32,
        'aggregate_rss_safety_gib':64,'license_environment_present':bool(os.environ.get('LM_LICENSE_FILE') or os.environ.get('XILINXD_LICENSE_FILE')),
        'ip_policy':'Use existing official simulation models unchanged; never generate or upgrade IP',
        'source_count':len(sources),'manifest_entries':len(BASELINE)})
    # Vendor precompiled libraries are read-only installation inputs.
    config=(VIVADO/'data/xsim/xsim.ini').read_text()
    mapped=dict(re.findall(r'^(\w+)=(.+)$',config,re.M))
    checks={}
    for lib in LIBRARIES:
        if lib=='xpm':continue  # Explicitly compiled from the installed source.
        location=mapped.get(lib,'').replace('$RDI_DATADIR',str(VIVADO/'data'))
        checks[lib]={'path':location,'exists':bool(location) and Path(location).is_dir()}
    write_json(RUN/'vendor_library_check.json',checks)
    if not all(x['exists'] for x in checks.values()):raise RuntimeError('Missing vendor libraries')
    build=RUN/'build';build.mkdir()
    (build/'sources.f').write_text(''.join('"'+p.as_posix()+'"\n' for p in sources))
    event('MATRIX_READY',total=len(MATRIX),source_files=len(sources),manifest_entries=len(BASELINE))
    return build


def verify_inputs():
    with HASH_LOCK:
        changed=[name for name,want in BASELINE.items() if not Path(name).is_file() or hashlib.sha256(Path(name).read_bytes()).hexdigest()!=want]
    if changed:
        STOP.set()
        raise RuntimeError('INPUT_CHANGED: '+str(changed[:12]))


def links(directory,group):
    directory.mkdir(parents=True,exist_ok=True)
    targets={'Pcore':ROOT/'Pcore','Gcore':ROOT/'Gcore','units':ROOT/'Pcore/units',
        'tb':ROOT/({'pcore':'Pcore/tb','gcore':'Gcore/tb','layer':'tb'}[group])}
    for name,target in targets.items():
        p=directory/name
        if not p.exists():p.symlink_to(target,target_is_directory=True)
    (directory/'tmp').mkdir(exist_ok=True)


def command(key,tool,args,cwd,timeout_hours=24):
    global SEQUENCE
    if STOP.is_set():raise RuntimeError('RUN_STOPPED')
    log=cwd/(tool+'.console.log')
    env=dict(os.environ,TMPDIR=str(cwd/'tmp'),TMP=str(cwd/'tmp'),TEMP=str(cwd/'tmp'),PYTHONDONTWRITEBYTECODE='1')
    started=time.monotonic()
    with log.open('w') as out:
        while True:
            if STOP.is_set():raise RuntimeError('RUN_STOPPED')
            with LOCK:
                if sum(not j['paused'] for j in JOBS.values())<MAX_CONCURRENCY:
                    SEQUENCE+=1;cpu=CPUS[(SEQUENCE-1)%len(CPUS)]
                    argv=[PYTHON,'-B',str(RUN/'exec_tool.py'),str(cpu),str(VIVADO/'bin'/tool)]+list(map(str,args))
                    p=subprocess.Popen(argv,cwd=str(cwd),stdout=out,stderr=subprocess.STDOUT,
                        env=env,start_new_session=True)
                    JOBS[key]={'pid':p.pid,'cpu':cpu,'tool':tool,'paused':False,'started':now(),'process':p}
                    break
            time.sleep(.5)
        event('TOOL_START',id=key,tool=tool,pid=p.pid,cpu=cpu,log=str(log))
        status()
        while p.poll() is None:
            if STOP.is_set() or time.monotonic()-started>timeout_hours*3600:
                try:os.killpg(p.pid,signal.SIGCONT);os.killpg(p.pid,signal.SIGTERM)
                except ProcessLookupError:pass
                try:p.wait(timeout=15)
                except subprocess.TimeoutExpired:
                    try:os.killpg(p.pid,signal.SIGKILL)
                    except ProcessLookupError:pass
                break
            time.sleep(1)
        rc=p.wait()
    with LOCK:JOBS.pop(key,None)
    text=log.read_text(errors='replace')
    errors=[s for s in text.splitlines() if ERROR.match(s)][:8]
    result={'tool':tool,'returncode':rc,'signal':-rc if rc<0 else None,
        'elapsed_seconds':round(time.monotonic()-started,3),'log':str(log),
        'errors':errors,'license_failure':bool(LICENSE.search(text))}
    write_json(cwd/(tool+'.result.json'),result)
    if result['license_failure']:STOP.set()
    event('TOOL_END',id=key,tool=tool,returncode=rc,errors=len(errors),elapsed=result['elapsed_seconds'])
    if rc!=0 or errors:raise RuntimeError(json.dumps(result))
    return text


def elaborate(case):
    top=case['top']
    with LOCK:lock=ELAB_LOCKS.setdefault(top,threading.Lock())
    with lock:
        if top in ELAB_RESULTS:
            value=ELAB_RESULTS[top]
            if isinstance(value,Exception):raise value
            return value
        directory=RUN/'elaborations'/top
        links(directory,case['group'])
        try:
            subprocess.run(['/bin/cp','--reflink=auto','-a',str(RUN/'build/xsim.dir'),str(directory/'xsim.dir')],check=True)
            ini=RUN/'build/xsim.ini'
            if ini.exists():shutil.copy2(str(ini),str(directory/'xsim.ini'))
            args=[top,'glbl','-s',top+'_panda','--O3','--debug','typical','--mt','off','-timescale','1ns/1ps']
            for lib in LIBRARIES:args+=['-L',lib]
            command('elab:'+top,'xelab',args,directory)
            verify_inputs()
            write_json(directory/'snapshot_manifest.json',{'compile_manifest_sha256':MANIFEST_SHA,'top':top,'optimization':3,'threads':'off'})
            ELAB_RESULTS[top]=directory
            return directory
        except Exception as e:
            ELAB_RESULTS[top]=e
            raise


def run_case(case):
    directory=RUN/'cases'/case['id']
    result=dict(case,started=now(),compile_manifest_sha256=MANIFEST_SHA,status='FAIL')
    try:
        verify_inputs()
        base=elaborate(case)
        links(directory,case['group'])
        subprocess.run(['/bin/cp','--reflink=auto','-a',str(base/'xsim.dir'),str(directory/'xsim.dir')],check=True)
        if (base/'xsim.ini').exists():shutil.copy2(str(base/'xsim.ini'),str(directory/'xsim.ini'))
        args=[case['top']+'_panda','-runall']
        for arg in case['args']:args+=['-testplusarg',arg]
        text=command(case['id'],'xsim',args,directory)
        marker=case['top']+' PASS'
        if marker not in text:raise RuntimeError('Missing explicit PASS: '+marker)
        if case['top']=='tb_pcore_seven_native' and 'PASS jobs=7 QK=55 PV=55 internal_tb_models=0' not in text:
            raise RuntimeError('Incomplete seven-Job workload')
        if case['top']=='tb_dea8_layers_native':
            if not any(a.startswith('CANCEL_AT=') for a in case['args']) or 'RECOVER' in case['args']:
                if 'cores=8 internal_tb_models=0 checkpoint_only=1' not in text:raise RuntimeError('Incomplete real-eight-core evidence')
            if 'RECOVER' in case['args'] and 'recovered=1' not in text:raise RuntimeError('Recovery did not complete rerun')
        verify_inputs()
        result.update(status='PASS',pass_lines=[s for s in text.splitlines() if marker in s],
            metrics=[s for s in text.splitlines() if any(x in s for x in ['JOB_PERF ','TOTAL ','LAYER_PERF ','LAYER_TOTAL ','HIDING '])],
            warnings=sum('Warning:' in s or 'WARNING:' in s for s in text.splitlines()),
            internal_tb_arithmetic_substitutions=False,log_sha256=hashlib.sha256((directory/'xsim.console.log').read_bytes()).hexdigest())
    except Exception as e:
        result.update(reason=str(e),classification='UNCLASSIFIED_PENDING_REVIEW')
    result['finished']=now()
    directory.mkdir(parents=True,exist_ok=True)
    write_json(directory/'result.json',result)
    with LOCK:RESULTS[case['id']]=result
    event('CASE_'+result['status'],id=case['id'],completed=len(RESULTS),total=len(MATRIX),reason=result.get('reason'))
    status()
    return result


def cpu_sample():
    p=Path('/proc/stat').read_text().splitlines()[0].split()[1:9]
    vals=list(map(int,p));return sum(vals),vals[3],vals[4]


def swap_sample():
    return {p[0]:int(p[1]) for s in Path('/proc/vmstat').read_text().splitlines() for p in [s.split()] if p[0] in ['pswpin','pswpout']}


def resource_monitor():
    global MAX_CONCURRENCY
    previous=cpu_sample();swap=swap_sample();healthy=0
    while not STOP.wait(5):
        current=cpu_sample();total=max(1,current[0]-previous[0])
        idle=100*(current[1]-previous[1])/total;iowait=100*(current[2]-previous[2])/total;previous=current
        mem={s.split(':')[0]:int(s.split()[1])*1024 for s in Path('/proc/meminfo').read_text().splitlines()}
        new_swap=swap_sample();paging=sum(new_swap[k]-swap[k] for k in swap);swap=new_swap
        with LOCK:groups={v['pid'] for v in JOBS.values()}
        rss=0
        for p in Path('/proc').iterdir():
            if not p.name.isdigit():continue
            try:
                if p.stat().st_uid!=os.getuid():continue
                fields=(p/'stat').read_text().rsplit(')',1)[1].split()
                if int(fields[2]) in groups:rss+=max(0,int(fields[21]))*os.sysconf('SC_PAGE_SIZE')
            except (OSError,ValueError,IndexError):continue
        reasons=[]
        if idle<60:reasons.append('CPU_IDLE_BELOW_60')
        if mem['MemAvailable']<max(64*1024**3,mem['MemTotal']*.20):reasons.append('MEMORY_PRESSURE')
        if paging>0:reasons.append('SWAP_ACTIVITY')
        if iowait>5:reasons.append('IOWAIT_ABOVE_5')
        if rss>64*1024**3:reasons.append('DEA8_RSS_ABOVE_64GIB')
        with LOCK:
            if reasons:MAX_CONCURRENCY=max(1,MAX_CONCURRENCY//2);healthy=0
            else:
                healthy+=1
                if healthy>=6:MAX_CONCURRENCY=min(8,MAX_CONCURRENCY+1);healthy=0
            jobs=list(JOBS.items())
            for index,(key,value) in enumerate(jobs):
                pause=index>=MAX_CONCURRENCY
                if pause!=value['paused']:
                    try:os.killpg(value['pid'],signal.SIGSTOP if pause else signal.SIGCONT)
                    except ProcessLookupError:continue
                    value['paused']=pause
                    event('RESOURCE_PAUSE' if pause else 'RESOURCE_RESUME',id=key)
        record={'time':now(),'idle_pct':round(idle,2),'iowait_pct':round(iowait,2),
            'available_gib':round(mem['MemAvailable']/1024**3,2),'swap_page_delta':paging,
            'dea8_rss_gib':round(rss/1024**3,2),'concurrency_limit':MAX_CONCURRENCY,'reasons':reasons}
        with (RUN/'resources.jsonl').open('a') as f:f.write(json.dumps(record)+'\n')
        if reasons:event('RESOURCE_THROTTLE',**record)
        if mem['MemAvailable']<16*1024**3 or rss>80*1024**3:
            event('RESOURCE_SAFETY_STOP',**record);STOP.set()
        status()


def stop_signal(signum,frame):
    event('DRIVER_SIGNAL',signal=signum);STOP.set()


def main():
    global PHASE
    lockfile=(RUN/'driver.lock').open('a')
    fcntl.flock(lockfile,fcntl.LOCK_EX|fcntl.LOCK_NB)
    for sig in [signal.SIGTERM,signal.SIGINT,signal.SIGHUP]:signal.signal(sig,stop_signal)
    (RUN/'driver.pid').write_text(str(os.getpid())+'\n')
    matrix()
    monitor=None
    success=False
    try:
        build=prepare()
        PHASE='P0_COMPILE';status()
        (build/'tmp').mkdir()
        monitor=threading.Thread(target=resource_monitor,daemon=True);monitor.start()
        command('P0_full_compile','xvlog',['-sv','-f',build/'sources.f'],build,timeout_hours=1)
        verify_inputs()
        write_json(RUN/'P0_compile_PASS.json',{'time':now(),'compile_manifest_sha256':MANIFEST_SHA,'vendor_libraries_checked':True})
        event('P0_PASS')
        for stage in ['P1','P2','P3']:
            PHASE=stage;status();verify_inputs()
            cases=[c for c in MATRIX if c['stage']==stage]
            with ThreadPoolExecutor(max_workers=8) as pool:
                futures=[pool.submit(run_case,c) for c in cases]
                for f in as_completed(futures):f.result()
            if STOP.is_set() or any(v['status']!='PASS' for v in RESULTS.values()):
                event('STAGE_FAILED_STOP',stage=stage);return
            event('STAGE_PASS',stage=stage,completed=len(RESULTS),total=len(MATRIX))
        verify_inputs();success=True
    except Exception as e:
        event('DRIVER_FAILURE',reason=str(e),traceback=traceback.format_exc())
    finally:
        STOP.set()
        if monitor:monitor.join(timeout=8)
        PHASE='ALL_SIMULATIONS_PASS' if success else 'STOPPED_REQUIRES_REVIEW'
        status()
        write_json(RUN/'driver_exit.json',{'time':now(),'success':success,'completed':len(RESULTS),
            'total':len(MATRIX),'pass':sum(v['status']=='PASS' for v in RESULTS.values()),
            'synthesis_started':False,'source_inputs_unchanged':success,
            'pending':[c['id'] for c in MATRIX if c['id'] not in RESULTS]})
        event('DRIVER_EXIT',success=success,completed=len(RESULTS),total=len(MATRIX))


if __name__=='__main__':main()
