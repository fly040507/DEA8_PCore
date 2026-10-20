"""Live scheduler migration: retain in-flight XSim PIDs and frozen source inputs.

The original coordinator is paused, not its simulations. Their exact Linux exit
statuses remain readable while they are its unreaped children. Once all have
finished, the original coordinator is retired and the same compiled baseline is
used for the remaining tests. No RTL, TB, fixtures or original runner are edited.
"""
from pathlib import Path
from concurrent.futures import ThreadPoolExecutor, as_completed
import datetime
import fcntl
import hashlib
import importlib.util
import json
import os
import shutil
import signal
import subprocess
import threading
import time
import traceback

OLD=Path('/home/zhaofei/eda_runs/DEA8_panda/20261019_sim01')
RUN=Path(__file__).resolve().parent
spec=importlib.util.spec_from_file_location('frozen_runner',str(OLD/'run_simulations.py'))
m=importlib.util.module_from_spec(spec);spec.loader.exec_module(m)
m.RUN=RUN
m.MAX_CONCURRENCY=12
m.SEQUENCE=64
original_pid=int((OLD/'driver.pid').read_text())
original_start=None
paused=False
retired=False
adopted={}


def proc(pid):
    p=Path('/proc',str(pid))
    try:
        fields=(p/'stat').read_text().rsplit(')',1)[1].split()
        return {'pid':pid,'uid':p.stat().st_uid,'state':fields[0],
            'ppid':int(fields[1]),'pgrp':int(fields[2]),'start':fields[19],
            'raw_exit_status':int(fields[49]) if len(fields)>49 else None}
    except (OSError,ValueError,IndexError):return None


def same_original():
    p=proc(original_pid)
    return bool(p and p['uid']==os.getuid() and p['start']==original_start)


def freeze_and_import():
    global original_start,paused
    p=proc(original_pid)
    if not p or p['uid']!=os.getuid():raise RuntimeError('Original coordinator not found under this UID')
    if str(OLD/'run_simulations.py').encode() not in Path('/proc',str(original_pid),'cmdline').read_bytes():
        raise RuntimeError('Original coordinator identity mismatch')
    original_start=p['start']
    os.kill(original_pid,signal.SIGSTOP);paused=True
    for _ in range(100):
        if proc(original_pid)['state'] in ['T','t']:break
        time.sleep(.01)
    else:raise RuntimeError('Could not freeze original coordinator')
    old_status=json.loads((OLD/'status.json').read_text())
    if old_status['phase']!='P1':raise RuntimeError('Migration requires P1; original stage='+old_status['phase'])
    m.MATRIX=json.loads((OLD/'test_matrix.json').read_text())['cases']
    m.BASELINE=json.loads((OLD/'compile_manifest.json').read_text())
    m.MANIFEST_SHA=hashlib.sha256((OLD/'compile_manifest.json').read_bytes()).hexdigest()
    m.verify_inputs()
    for case in m.MATRIX:
        p=OLD/'cases'/case['id']/'result.json'
        if p.is_file():
            result=json.loads(p.read_text())
            if result['status']!='PASS':raise RuntimeError('Existing failure needs review: '+case['id'])
            log=p.parent/'xsim.console.log'
            if hashlib.sha256(log.read_bytes()).hexdigest()!=result['log_sha256']:
                raise RuntimeError('Existing result log checksum mismatch: '+case['id'])
            result['evidence_directory']=str(p.parent)
            m.RESULTS[case['id']]=result
    events=[json.loads(s) for s in (OLD/'events.jsonl').read_text().splitlines() if s.strip()]
    starts={e['pid']:e for e in events if e['event']=='TOOL_START'}
    children=set()
    for task in Path('/proc',str(original_pid),'task').iterdir():
        try:children.update(map(int,(task/'children').read_text().split()))
        except OSError:pass
    cases={c['id']:c for c in m.MATRIX}
    for pid in children:
        info=proc(pid);e=starts.get(pid)
        if not info:continue
        if not e or e['tool']!='xsim' or e['id'] not in cases:
            raise RuntimeError('Unexpected live child during migration: '+str(pid))
        if e['id'] in m.RESULTS:continue
        if info['pgrp']!=pid or info['uid']!=os.getuid():raise RuntimeError('Child process group/UID mismatch')
        adopted[e['id']]={'case':cases[e['id']],'process':info,'event':e}
        m.JOBS[e['id']]={'pid':pid,'cpu':e['cpu'],'tool':'xsim','paused':False,'started':e['time']}
    missing={c['id'] for c in m.MATRIX if c['stage']=='P1'}-set(m.RESULTS)-set(adopted)
    if missing:raise RuntimeError('Cannot account for P1 queue without restart: '+str(sorted(missing)))
    for p in (OLD/'elaborations').iterdir():
        if (p/'snapshot_manifest.json').is_file():m.ELAB_RESULTS[p.name]=p
    build=RUN/'build';build.mkdir()
    subprocess.run(['/bin/cp','--reflink=auto','-a',str(OLD/'build/xsim.dir'),str(build/'xsim.dir')],check=True)
    if (OLD/'build/xsim.ini').is_file():shutil.copy2(str(OLD/'build/xsim.ini'),str(build/'xsim.ini'))
    shutil.copy2(str(OLD/'exec_tool.py'),str(RUN/'exec_tool.py'))
    shutil.copy2(str(OLD/'compile_manifest.json'),str(RUN/'compile_manifest.json'))
    shutil.copy2(str(OLD/'test_matrix.json'),str(RUN/'test_matrix.json'))
    shutil.copy2(str(OLD/'P0_compile_PASS.json'),str(RUN/'P0_compile_PASS.json'))
    m.write_json(RUN/'migration.json',{'time':m.now(),'old_driver_pid':original_pid,
        'old_driver_start':original_start,'retained_xsim_pids':{k:v['process']['pid'] for k,v in adopted.items()},
        'completed_imported':len(m.RESULTS),'compile_manifest_sha256':m.MANIFEST_SHA,
        'no_simulation_restarted':True,'source_baseline_unchanged':True})
    m.write_json(OLD/'SCHEDULER_CURRENT.json',{'time':m.now(),'status':str(RUN/'status.json'),
        'scheduler_pid':os.getpid(),'p0_p1_default':12,'p0_p1_conditional_max':16,'real_eight_core_max':4,
        'synthesis_permitted':False})
    m.event('LIVE_MIGRATION_READY',retained=len(adopted),completed=len(m.RESULTS),total=len(m.MATRIX))


def collect_existing(key):
    entry=adopted[key];case=entry['case'];pid=entry['process']['pid']
    result=dict(case,started=entry['event']['time'],compile_manifest_sha256=m.MANIFEST_SHA,
        status='FAIL',adopted_without_restart=True,evidence_directory=str(OLD/'cases'/key))
    try:
        while not m.STOP.wait(1):
            info=proc(pid)
            if not info or info['start']!=entry['process']['start']:
                raise RuntimeError('Cannot recover exact exit status of adopted PID '+str(pid))
            if info['state']=='Z':break
        else:raise RuntimeError('Scheduler interrupted while adopting simulation')
        raw=info['raw_exit_status']
        if raw is None:raise RuntimeError('Kernel did not expose exact exit status')
        rc=-(raw&127) if raw&127 else (raw>>8)&255
        log=OLD/'cases'/key/'xsim.console.log';data=log.read_bytes();text=data.decode(errors='replace')
        errors=[s for s in text.splitlines() if m.ERROR.match(s)]
        result.update(returncode=rc,raw_wait_status=raw,signal=-rc if rc<0 else None)
        if m.LICENSE.search(text):m.STOP.set();raise RuntimeError('License failure; stop without bypass')
        if rc or errors:raise RuntimeError('returncode='+str(rc)+' '+str(errors[:5]))
        marker=case['top']+' PASS'
        if marker not in text:raise RuntimeError('Missing explicit PASS')
        if case['top']=='tb_pcore_seven_native' and 'PASS jobs=7 QK=55 PV=55 internal_tb_models=0' not in text:
            raise RuntimeError('Incomplete seven-Job workload')
        m.verify_inputs()
        result.update(status='PASS',pass_lines=[s for s in text.splitlines() if marker in s],
            metrics=[s for s in text.splitlines() if any(x in s for x in ['JOB_PERF ','TOTAL ','HIDING '])],
            log_sha256=hashlib.sha256(data).hexdigest(),internal_tb_arithmetic_substitutions=False)
    except Exception as e:result.update(reason=str(e),classification='UNCLASSIFIED_PENDING_REVIEW')
    result['finished']=m.now()
    with m.LOCK:
        m.JOBS.pop(key,None);m.RESULTS[key]=result
    directory=RUN/'cases'/key;directory.mkdir(parents=True,exist_ok=True)
    m.write_json(directory/'result.json',result)
    m.event('CASE_'+result['status'],id=key,completed=len(m.RESULTS),total=len(m.MATRIX),reason=result.get('reason'))
    m.status()
    return result


def monitor():
    previous=m.cpu_sample();swap=m.swap_sample();healthy=0;high_idle=0
    while not m.STOP.wait(5):
        current=m.cpu_sample();total=max(1,current[0]-previous[0])
        idle=100*(current[1]-previous[1])/total;iowait=100*(current[2]-previous[2])/total;previous=current
        mem={s.split(':')[0]:int(s.split()[1])*1024 for s in Path('/proc/meminfo').read_text().splitlines()}
        new_swap=m.swap_sample();paging=sum(new_swap[k]-swap[k] for k in swap);swap=new_swap
        with m.LOCK:groups={v['pid'] for v in m.JOBS.values()}
        rss=0
        for p in Path('/proc').iterdir():
            if not p.name.isdigit():continue
            try:
                if p.stat().st_uid!=os.getuid():continue
                fields=(p/'stat').read_text().rsplit(')',1)[1].split()
                if int(fields[2]) in groups:rss+=max(0,int(fields[21]))*os.sysconf('SC_PAGE_SIZE')
            except (OSError,ValueError,IndexError):pass
        reasons=[]
        if idle<60:reasons.append('CPU_IDLE_BELOW_60')
        if mem['MemAvailable']<max(64*1024**3,mem['MemTotal']*.20):reasons.append('MEMORY_PRESSURE')
        if paging>0:reasons.append('SWAP_ACTIVITY')
        if iowait>5:reasons.append('IOWAIT_ABOVE_5')
        if rss>64*1024**3:reasons.append('DEA8_RSS_ABOVE_64GIB')
        native=m.PHASE in ['P2','P3']
        ceiling=4 if native else 16
        with m.LOCK:
            if reasons:
                m.MAX_CONCURRENCY=max(1,min(ceiling,m.MAX_CONCURRENCY//2));healthy=0;high_idle=0
            else:
                healthy+=1
                high_idle=high_idle+1 if idle>80 and paging==0 and iowait<2 else 0
                if healthy>=6:
                    m.MAX_CONCURRENCY=min(4 if native else 12,m.MAX_CONCURRENCY+1) if m.MAX_CONCURRENCY<(4 if native else 12) else min(ceiling,m.MAX_CONCURRENCY)
                    healthy=0
                if not native and high_idle>=6:m.MAX_CONCURRENCY=16
                m.MAX_CONCURRENCY=min(ceiling,m.MAX_CONCURRENCY)
            for i,(key,value) in enumerate(list(m.JOBS.items())):
                pause=i>=m.MAX_CONCURRENCY
                if pause!=value['paused']:
                    try:os.killpg(value['pid'],signal.SIGSTOP if pause else signal.SIGCONT)
                    except ProcessLookupError:continue
                    value['paused']=pause;m.event('RESOURCE_PAUSE' if pause else 'RESOURCE_RESUME',id=key)
        record={'time':m.now(),'phase':m.PHASE,'idle_pct':round(idle,2),'iowait_pct':round(iowait,2),
            'available_gib':round(mem['MemAvailable']/1024**3,2),'swap_used_gib':round((mem['SwapTotal']-mem['SwapFree'])/1024**3,3),
            'swap_page_delta':paging,'dea8_rss_gib':round(rss/1024**3,2),'concurrency_limit':m.MAX_CONCURRENCY,
            'high_idle_consecutive_samples':high_idle,'reasons':reasons}
        with (RUN/'resources.jsonl').open('a') as f:f.write(json.dumps(record)+'\n')
        if reasons:m.event('RESOURCE_THROTTLE',**record)
        if mem['MemAvailable']<16*1024**3 or rss>80*1024**3:
            m.event('RESOURCE_SAFETY_STOP',**record);m.STOP.set()
        m.status()


def retire_original():
    global paused,retired
    if same_original():
        # All retained simulations have exited and have exact recorded statuses.
        # SIGTERM prevents the old queue from advancing to P2; SIGCONT lets its
        # Python signal handler and wait() calls retire normally.
        os.kill(original_pid,signal.SIGTERM);os.kill(original_pid,signal.SIGCONT)
    paused=False;retired=True
    m.event('ORIGINAL_COORDINATOR_RETIRED',pid=original_pid)


def main():
    lock=(RUN/'driver.lock').open('a');fcntl.flock(lock,fcntl.LOCK_EX|fcntl.LOCK_NB)
    (RUN/'driver.pid').write_text(str(os.getpid())+'\n')
    for sig in [signal.SIGTERM,signal.SIGINT,signal.SIGHUP]:signal.signal(sig,m.stop_signal)
    worker=None;success=False
    try:
        freeze_and_import();m.PHASE='P1';m.status()
        worker=threading.Thread(target=monitor,daemon=True);worker.start()
        with ThreadPoolExecutor(max_workers=16) as pool:
            futures=[pool.submit(collect_existing,key) for key in adopted]
            for f in as_completed(futures):f.result()
        if m.STOP.is_set():return
        retire_original()
        if any(v['status']!='PASS' for v in m.RESULTS.values()):return
        m.event('STAGE_PASS',stage='P1',completed=len(m.RESULTS),total=len(m.MATRIX))
        for stage in ['P2','P3']:
            m.PHASE=stage;m.MAX_CONCURRENCY=4;m.verify_inputs();m.status()
            m.event('NATIVE_EIGHT_CORE_CONCURRENCY_CAP',stage=stage,limit=4)
            with ThreadPoolExecutor(max_workers=4) as pool:
                futures=[pool.submit(m.run_case,c) for c in m.MATRIX if c['stage']==stage]
                for f in as_completed(futures):f.result()
            if m.STOP.is_set() or any(v['status']!='PASS' for v in m.RESULTS.values()):return
            m.event('STAGE_PASS',stage=stage,completed=len(m.RESULTS),total=len(m.MATRIX))
        m.verify_inputs();success=True
    except Exception as e:m.event('SCHEDULER_FAILURE',reason=str(e),traceback=traceback.format_exc())
    finally:
        m.STOP.set()
        if worker:worker.join(timeout=8)
        if paused and same_original():
            for entry in adopted.values():
                p=proc(entry['process']['pid'])
                if p and p['start']==entry['process']['start']:
                    try:os.killpg(p['pgrp'],signal.SIGCONT)
                    except ProcessLookupError:pass
            os.kill(original_pid,signal.SIGCONT)
            m.event('SAFE_HAND_BACK_TO_ORIGINAL',pid=original_pid)
        m.PHASE='ALL_SIMULATIONS_PASS' if success else 'STOPPED_REQUIRES_REVIEW';m.status()
        m.write_json(RUN/'driver_exit.json',{'time':m.now(),'success':success,'completed':len(m.RESULTS),
            'pass':sum(v['status']=='PASS' for v in m.RESULTS.values()),'total':len(m.MATRIX),
            'synthesis_started':False,'pending':[c['id'] for c in m.MATRIX if c['id'] not in m.RESULTS]})
        m.event('DRIVER_EXIT',success=success,completed=len(m.RESULTS),total=len(m.MATRIX))


if __name__=='__main__':main()
