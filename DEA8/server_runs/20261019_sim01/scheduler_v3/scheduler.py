"""Simulation-only restart with one external TB wait-sensitivity correction.

Original source tree, RTL, arithmetic, fixtures and acceptance checks are frozen.
The three aborted P2 attempts remain archived; all fourteen P2/P3 cases rerun.
"""
from pathlib import Path
from concurrent.futures import ThreadPoolExecutor, as_completed
import difflib
import fcntl
import hashlib
import importlib.util
import json
import os
import signal
import threading
import traceback

BASE=Path('/home/zhaofei/eda_runs/DEA8_panda/20261019_sim01')
RUN=Path(__file__).resolve().parent
spec=importlib.util.spec_from_file_location('previous_scheduler',str(BASE/'scheduler_v2/scheduler.py'))
previous=importlib.util.module_from_spec(spec);spec.loader.exec_module(previous)
m=previous.m
m.RUN=RUN
m.MAX_CONCURRENCY=4
m.SEQUENCE=64
ORIGINAL_MANIFEST_SHA=hashlib.sha256((BASE/'compile_manifest.json').read_bytes()).hexdigest()
raw_status=m.status


def status():
    with m.LOCK:
        raw_status()
        value=json.loads((RUN/'status.json').read_text())
        value.update(historical_tb_aborted_attempts=3,
            historical_attempts=str(BASE/'diagnosis_live_20261019/stopped_attempts.json'),
            original_compile_manifest_sha256=ORIGINAL_MANIFEST_SHA,
            current_compile_manifest_sha256=m.MANIFEST_SHA,
            tb_overlay_only=True,source_tree_modified=False,
            synthesis_permitted=False)
        m.write_json(RUN/'status.json',value)


m.status=status


def prepare():
    assert not json.loads((BASE/'scheduler_v2/driver_exit.json').read_text())['success']
    stopped=json.loads((BASE/'scheduler_v2/status.json').read_text())
    assert not stopped['running'] and stopped['pass']==36 and stopped['fail']==3
    original=json.loads((BASE/'compile_manifest.json').read_text())
    changed=[p for p,h in original.items() if not Path(p).is_file() or hashlib.sha256(Path(p).read_bytes()).hexdigest()!=h]
    if changed:raise RuntimeError('Original inputs changed: '+str(changed))
    m.MATRIX=json.loads((BASE/'test_matrix.json').read_text())['cases']
    assert len(m.MATRIX)==50
    for key,result in stopped['results'].items():
        if result['status']!='PASS':continue
        assert result['stage']=='P1' and result['compile_manifest_sha256']==ORIGINAL_MANIFEST_SHA
        directory=Path(result.get('evidence_directory',str(BASE/'cases'/key)))
        log=directory/'xsim.console.log';data=log.read_bytes();text=data.decode(errors='replace')
        if hashlib.sha256(data).hexdigest()!=result['log_sha256']:
            raise RuntimeError('Inherited PASS log checksum mismatch: '+key)
        if m.ERROR.search(text) or m.LICENSE.search(text) or result['top']+' PASS' not in text:
            raise RuntimeError('Inherited PASS evidence mismatch: '+key)
        value=dict(result,evidence_directory=str(directory),inherited_P1_without_rerun=True)
        m.RESULTS[key]=value
        dest=RUN/'cases'/key;dest.mkdir(parents=True)
        m.write_json(dest/'result.json',value)
    assert len(m.RESULTS)==36
    source=Path('/home/zhaofei/DEA8/tb/tb_dea8_layers_native.sv')
    overlay=RUN/'overrides/tb_dea8_layers_native.sv'
    old=source.read_text();new=overlay.read_text()
    old_wait='    wait(all_pc_done(id));if(wait_gcore)wait(gc_complete[id]);'
    new_wait='''    // XSim wait sensitivity does not include globals read inside all_pc_done.
    // Identical completion condition, made explicit; no checks are bypassed.
    wait(pc_complete[0][id]&&pc_complete[1][id]&&pc_complete[2][id]&&pc_complete[3][id]&&
      pc_complete[4][id]&&pc_complete[5][id]&&pc_complete[6][id]&&pc_complete[7][id]);
    if(wait_gcore)wait(gc_complete[id]);'''
    assert old.count(old_wait)==1 and new==old.replace(old_wait,new_wait)
    (RUN/'tb_override.diff').write_text(''.join(difflib.unified_diff(old.splitlines(True),new.splitlines(True),fromfile=str(source),tofile=str(overlay))))
    m.write_json(RUN/'source_overlay.json',{'created':m.now(),'original_manifest_sha256':ORIGINAL_MANIFEST_SHA,
        'original_tb':str(source),'original_tb_sha256':original[str(source)],
        'compiled_tb':str(overlay),'compiled_tb_sha256':hashlib.sha256(overlay.read_bytes()).hexdigest(),
        'change':'Only unfold all_pc_done(id) into identical eight completion bits in wait expression',
        'truth_table_equivalent':True,'load_reduced':False,'checks_relaxed':False,
        'rtl_modified':False,'source_tree_modified':False,'synthesis_permitted':False,
        'diagnosis':str(BASE/'diagnosis_live_20261019/DIAGNOSIS.md')})
    build=RUN/'build';build.mkdir();(build/'tmp').mkdir()
    sources=(BASE/'build/sources.f').read_text()
    assert sources.count('"'+str(source)+'"')==1
    sources=sources.replace('"'+str(source)+'"','"'+str(overlay)+'"')
    (build/'sources.f').write_text(sources)
    m.write_json(RUN/'test_matrix.json',json.loads((BASE/'test_matrix.json').read_text()))
    baseline=dict(original)
    for p in [overlay,Path(__file__).resolve(),RUN/'launch.sh',RUN/'at_job.sh',RUN/'exec_tool.py',
            RUN/'source_overlay.json',RUN/'tb_override.diff',build/'sources.f',
            BASE/'scheduler_v2/scheduler.py',BASE/'scheduler_v2/execution_manifest.json']:
        baseline[str(p)]=hashlib.sha256(p.read_bytes()).hexdigest()
    m.BASELINE=baseline;m.write_json(RUN/'compile_manifest.json',baseline)
    m.MANIFEST_SHA=hashlib.sha256((RUN/'compile_manifest.json').read_bytes()).hexdigest()
    m.write_json(RUN/'execution_manifest.json',{'created':m.now(),'manifest_sha256':m.MANIFEST_SHA,
        'original_manifest_sha256':ORIGINAL_MANIFEST_SHA,'sources':sources.splitlines(),
        'source_count':len(sources.splitlines()),'manifest_entries':len(baseline),
        'inherited_P1_pass':36,'historical_tb_aborted_attempts':3,'native_cases_to_rerun':14,
        'max_concurrency':4,'synthesis_permitted':False})
    m.verify_inputs()
    m.write_json(BASE/'SCHEDULER_CURRENT.json',{'time':m.now(),'status':str(RUN/'status.json'),
        'scheduler_pid':os.getpid(),'p0_p1_default':12,'p0_p1_conditional_max':16,'real_eight_core_max':4,
        'synthesis_permitted':False,'historical_tb_aborted_attempts':3,
        'tb_overlay':str(RUN/'source_overlay.json')})
    m.event('RESTART_AFTER_TB_WAIT_FIX',inherited_P1_pass=36,prior_aborted_attempts=3,
        compile_manifest_sha256=m.MANIFEST_SHA,source_tree_unchanged=True)
    return build


def main():
    lock=(RUN/'driver.lock').open('a');fcntl.flock(lock,fcntl.LOCK_EX|fcntl.LOCK_NB)
    (RUN/'driver.pid').write_text(str(os.getpid())+'\n')
    for sig in [signal.SIGTERM,signal.SIGINT,signal.SIGHUP]:signal.signal(sig,m.stop_signal)
    success=False;monitor=None
    try:
        build=prepare();m.PHASE='P0_RECOMPILE_TB_FIX';status()
        monitor=threading.Thread(target=previous.monitor,daemon=True);monitor.start()
        m.command('P0_full_compile_TB_fix','xvlog',['-sv','-f',build/'sources.f'],build,timeout_hours=1)
        m.verify_inputs()
        m.write_json(RUN/'P0_compile_PASS.json',{'time':m.now(),'compile_manifest_sha256':m.MANIFEST_SHA,
            'all_production_sources_recompiled':True,'tb_overlay_only':True})
        m.event('P0_PASS',compile_manifest_sha256=m.MANIFEST_SHA)
        for stage in ['P2','P3']:
            m.PHASE=stage;m.MAX_CONCURRENCY=4;m.verify_inputs();status()
            m.event('NATIVE_EIGHT_CORE_CONCURRENCY_CAP',stage=stage,limit=4)
            with ThreadPoolExecutor(max_workers=4) as pool:
                futures=[pool.submit(m.run_case,c) for c in m.MATRIX if c['stage']==stage]
                for future in as_completed(futures):future.result()
            if m.STOP.is_set() or any(r['status']!='PASS' for r in m.RESULTS.values()):return
            m.event('STAGE_PASS',stage=stage,completed=len(m.RESULTS),total=50)
        m.verify_inputs();success=True
    except Exception as error:
        m.event('DRIVER_FAILURE',reason=str(error),traceback=traceback.format_exc())
    finally:
        m.STOP.set()
        if monitor:monitor.join(timeout=8)
        m.PHASE='ALL_SIMULATIONS_PASS' if success else 'STOPPED_REQUIRES_REVIEW';status()
        m.write_json(RUN/'driver_exit.json',{'time':m.now(),'success':success,'completed':len(m.RESULTS),
            'pass':sum(v['status']=='PASS' for v in m.RESULTS.values()),'total':50,
            'historical_tb_aborted_attempts':3,'synthesis_started':False,
            'source_tree_modified':False,'pending':[c['id'] for c in m.MATRIX if c['id'] not in m.RESULTS]})
        m.event('DRIVER_EXIT',success=success,completed=len(m.RESULTS),total=50)


if __name__=='__main__':main()
