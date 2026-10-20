"""User-authorized cleanup: retain only three completed native layer cases.

Plan first, then apply that exact plan. Never follow symlinks when deleting.
No simulator, synthesis tool, or source-tree writer is invoked.
"""
from pathlib import Path
import datetime
import hashlib
import json
import os
import shutil
import stat
import sys

ROOT = Path('/home/zhaofei/eda_runs/DEA8_panda')
BASE = ROOT / '20261019_sim01'
RUN = BASE / 'scheduler_v3'
OUT = ROOT / 'cleanup_20261020'
LAYERS = (1, 9, 18)
IDS = ['tb_dea8_layers_native__LAYER_' + str(n) for n in LAYERS]


def now():
    return datetime.datetime.now().astimezone().isoformat()


def sha(path):
    h = hashlib.sha256()
    with path.open('rb') as f:
        for chunk in iter(lambda: f.read(1024 * 1024), b''):
            h.update(chunk)
    return h.hexdigest()


def write(path, value):
    path.write_text(json.dumps(value, ensure_ascii=False, indent=2) + '\n')


def active_processes():
    active = []
    for p in Path('/proc').glob('[0-9]*'):
        try:
            if p.stat().st_uid != os.getuid():
                continue
            fields = (p / 'stat').read_text().rsplit(')', 1)[1].split()
            cwd = (p / 'cwd').resolve()
            if fields[0] != 'Z' and (cwd == ROOT or ROOT in cwd.parents):
                active.append(int(p.name))
        except (OSError, ValueError):
            pass
    return active


def verify_inputs():
    manifest = json.loads((RUN / 'compile_manifest.json').read_text())
    bad = [p for p, h in manifest.items()
           if not Path(p).is_file() or sha(Path(p)) != h]
    if bad:
        raise RuntimeError('Manifest inputs missing or changed: ' + str(bad))
    return manifest


def verify_cases():
    manifest_hash = sha(RUN / 'compile_manifest.json')
    rows = []
    for case_id in IDS:
        d = RUN / 'cases' / case_id
        result = json.loads((d / 'result.json').read_text())
        execution = json.loads((d / 'xsim.result.json').read_text())
        text = (d / 'xsim.console.log').read_text(errors='replace')
        assert result['status'] == 'PASS', case_id
        assert result['compile_manifest_sha256'] == manifest_hash, case_id
        assert execution['returncode'] == 0, case_id
        assert not execution['errors'] and not execution['license_failure'], case_id
        assert result['top'] + ' PASS' in text, case_id
        assert sha(d / 'xsim.console.log') == result['log_sha256'], case_id
        rows.append({'id': case_id, 'status': 'PASS', 'returncode': 0,
                     'log_sha256': result['log_sha256'],
                     'manifest_sha256': manifest_hash})
    return rows


def keep_paths(manifest):
    keep = set()

    def add(path):
        assert path.is_file() and not path.is_symlink(), str(path)
        keep.add(path)

    # Keep all manifest-referenced runner inputs at their original paths.
    for value in manifest:
        p = Path(value)
        if ROOT in p.parents:
            add(p)
    for relative in [
        'compile_manifest.json', 'environment.json', 'vendor_library_check.json',
        'build/sources.f', 'build/xvlog.console.log', 'build/xvlog.result.json',
        'scheduler_v3/compile_manifest.json',
        'scheduler_v3/execution_manifest.json',
        'scheduler_v3/P0_compile_PASS.json',
        'scheduler_v3/build/xvlog.console.log',
        'scheduler_v3/build/xvlog.result.json',
        'scheduler_v3/progress/layer9_o_exposed_latency.json',
        'scheduler_v3/progress/live_layout.json',
        'scheduler_v3/elaborations/tb_dea8_layers_native/snapshot_manifest.json',
        'scheduler_v3/elaborations/tb_dea8_layers_native/xelab.console.log',
        'scheduler_v3/elaborations/tb_dea8_layers_native/xelab.result.json',
        'diagnosis_live_20261019/DIAGNOSIS.md',
        'diagnosis_live_20261019/wait_sensitivity_repro.sv',
    ]:
        add(BASE / relative)
    for case_id in IDS:
        for name in ['result.json', 'xsim.result.json', 'xsim.console.log', 'xsim.jou']:
            add(RUN / 'cases' / case_id / name)
    audit = ROOT / '20261019_gu_readonly_audit'
    for name in [
        'down_completion_layer1.json', 'down_completion_layer18.json',
        'full_job_boundaries_layer1.json', 'full_job_boundaries_layer18.json',
        'job_status_20261019_234950.json',
        'gu_audit_20261019_215057.json', 'gu_audit_20261019_215257.json',
        'Layer1_nine_stage_measured.md', 'Layer9_job_cycles_summary.md',
        'Layer9_nine_stage_no_initial_norm.md',
    ]:
        add(audit / name)
    # These files are prepared before planning; they contain only retained-case data.
    for p in OUT.iterdir():
        if p.is_file():
            add(p)
    add(ROOT / 'README.md')
    return keep


def inventory():
    rows = []
    for parent, dirs, files in os.walk(str(ROOT), followlinks=False):
        for name in sorted(dirs + files):
            p = Path(parent) / name
            s = p.lstat()
            kind = 'symlink' if stat.S_ISLNK(s.st_mode) else (
                'directory' if stat.S_ISDIR(s.st_mode) else 'file')
            if kind == 'directory' and os.path.ismount(str(p)):
                raise RuntimeError('Nested mount; refusing cleanup: ' + str(p))
            row = {'path': str(p.relative_to(ROOT)), 'kind': kind,
                   'size': s.st_size, 'allocated_bytes': s.st_blocks * 512,
                   'inode': s.st_ino, 'device': s.st_dev,
                   'mtime_ns': s.st_mtime_ns}
            if kind == 'symlink':
                row['target'] = os.readlink(str(p))
            rows.append(row)
    return rows


def deletion_roots(keep):
    ancestors = {ROOT}
    for p in keep:
        ancestors.update(p.parents)
    delete = []

    def walk(d):
        for p in sorted(d.iterdir()):
            if p in keep:
                continue
            if p in ancestors and p.is_dir() and not p.is_symlink():
                walk(p)
            else:
                delete.append(p)
    walk(ROOT)
    return delete


def prepare():
    assert ROOT.resolve() == ROOT and not ROOT.is_symlink()
    assert not active_processes(), 'Active process inside cleanup scope'
    manifest = verify_inputs()
    cases = verify_cases()
    old_status_path = BASE / 'SCHEDULER_CURRENT.json'
    pointer = json.loads(old_status_path.read_text())
    state = json.loads(Path(pointer['status']).read_text())
    assert not state['running'] and not state.get('automatic_resume_permitted', False)
    write(OUT / 'historical_summary.json', {
        'recorded_at': now(), 'pass_before_cleanup': state['pass'],
        'formal_fail_before_cleanup': state['fail'],
        'user_cancelled_before_cleanup': state['cancelled'],
        'historical_tb_aborted_attempts': state['historical_tb_aborted_attempts'],
        'note': 'Only the three independent P2 layer result sets are retained. '
                'Other simulation evidence was deleted at user request.'})
    write(OUT / 'status.json', {
        'time': now(), 'phase': 'ARCHIVED_THREE_LAYERS_ONLY',
        'scope': 'GCore + 8 real PCore independent Layer1, Layer9, Layer18',
        'total_scenarios': 3, 'completed': 3, 'pass': 3, 'fail': 0,
        'running': [], 'automatic_resume_permitted': False,
        'synthesis_started': False, 'synthesis_permitted': False,
        'results': {x: json.loads((RUN / 'cases' / x / 'result.json').read_text())
                    for x in IDS}})
    # Retain original P2 observation lines; discard all P3 observation lines.
    source = RUN / 'progress/samples.jsonl'
    with (OUT / 'P2_progress_samples.jsonl').open('w') as dest:
        for line in source.open():
            record = json.loads(line)
            rows = record.get('cases', [])
            if rows and all(x['id'] in IDS for x in rows):
                dest.write(line)
    keep = keep_paths(manifest)
    keep.add(old_status_path)
    # Preserve source pointer bytes in the plan; update it only after successful deletion.
    write(OUT / 'pointer_before_cleanup.json', pointer)
    keep.add(OUT / 'pointer_before_cleanup.json')
    items = inventory()
    delete = deletion_roots(keep)
    known_files = {str(p.relative_to(ROOT)): sha(p) for p in sorted(keep)}
    plan = {'time': now(), 'root': str(ROOT),
            'user_request': 'Clean eda_runs; retain only GCore + 8 PCore '
                            'Layer1/9/18 simulations and essential evidence.',
            'allocated_bytes_before': ROOT.lstat().st_blocks * 512 + sum(
                x['allocated_bytes'] for x in items),
            'manifest_entries': len(manifest), 'verified_cases': cases,
            'kept_file_sha256': known_files,
            'delete_roots': [str(p.relative_to(ROOT)) for p in delete]}
    write(OUT / 'inventory_before.json', items)
    write(OUT / 'plan.json', plan)
    print(json.dumps({'delete_roots': plan['delete_roots'],
                      'retained_files': len(keep),
                      'allocated_bytes_before': plan['allocated_bytes_before'],
                      'retained_file_bytes': sum(p.stat().st_size for p in keep)},
                     ensure_ascii=False, indent=2))


def apply():
    assert ROOT.resolve() == ROOT and not ROOT.is_symlink()
    assert not active_processes(), 'Active process inside cleanup scope'
    plan = json.loads((OUT / 'plan.json').read_text())
    assert plan['root'] == str(ROOT)
    keep = {ROOT / x for x in plan['kept_file_sha256']}
    # Cleanup bookkeeping created by prepare() is not itself a deletion target.
    expected = plan['delete_roots']
    for relative, h in plan['kept_file_sha256'].items():
        p = ROOT / relative
        assert p.is_file() and not p.is_symlink() and sha(p) == h, relative
    verify_inputs()
    verify_cases()
    # Validate every deletion target and every nested entry before deleting anything.
    old = {x['path']: x for x in json.loads((OUT / 'inventory_before.json').read_text())}
    for relative in expected:
        p = ROOT / relative
        assert ROOT in p.parents and p != ROOT and '..' not in p.parts
        assert not any(p == k or p in k.parents for k in keep), relative
        assert p.parent.resolve() == p.parent, relative
        candidates = [p]
        if p.is_dir() and not p.is_symlink():
            for parent, dirs, files in os.walk(str(p), followlinks=False):
                candidates.extend(Path(parent) / n for n in dirs + files)
        for item in candidates:
            rel = str(item.relative_to(ROOT))
            s = item.lstat()
            before = old[rel]
            assert (s.st_ino, s.st_dev, s.st_size, s.st_mtime_ns) == (
                before['inode'], before['device'], before['size'], before['mtime_ns']), rel
            if item.is_dir() and not item.is_symlink():
                assert not os.path.ismount(str(item)), rel
    deleted = []
    with (OUT / 'deleted_roots.jsonl').open('w') as journal:
        for relative in expected:
            p = ROOT / relative
            if p.is_symlink() or not p.is_dir():
                p.unlink()
            else:
                shutil.rmtree(str(p))
            deleted.append(relative)
            journal.write(json.dumps({'time': now(), 'deleted': relative}) + '\n')
            journal.flush()
    manifest = verify_inputs()
    cases = verify_cases()
    # All original evidence bytes must remain unchanged.
    for relative, h in plan['kept_file_sha256'].items():
        assert sha(ROOT / relative) == h, relative
    pointer = json.loads((BASE / 'SCHEDULER_CURRENT.json').read_text())
    pointer.update(time=now(), status=str(OUT / 'status.json'),
                   scheduler_active=False, scheduler_state='ARCHIVED_THREE_LAYERS_ONLY',
                   automatic_resume_permitted=False,
                   scope='Only completed independent GCore + 8 PCore Layer1/9/18 retained',
                   cleanup_report=str(OUT / 'report.json'))
    for key in ['previous_scheduler_status', 'stop_record', 'job_progress',
                'job_notifications', 'active_resource_samples']:
        pointer.pop(key, None)
    write(BASE / 'SCHEDULER_CURRENT.json', pointer)
    after = inventory()
    allocated = ROOT.lstat().st_blocks * 512 + sum(x['allocated_bytes'] for x in after)
    report = {'time': now(), 'deleted_root_count': len(deleted),
              'allocated_bytes_before': plan['allocated_bytes_before'],
              'allocated_bytes_after_before_report': allocated,
              'estimated_freed_bytes': plan['allocated_bytes_before'] - allocated,
              'manifest_entries_verified_after': len(manifest),
              'changed_manifest_inputs': [], 'retained_cases': cases,
              'retained_case_names': sorted(p.name for p in (RUN / 'cases').iterdir()),
              'active_processes_inside_cleanup_root': active_processes(),
              'source_tree_modified': False, 'simulation_started': False,
              'synthesis_started': False,
              'waveforms_and_compiled_snapshots_removed': True,
              'note': 'Sizes include retained audit bookkeeping; disk usage can '
                      'vary slightly with filesystem block accounting.'}
    assert report['retained_case_names'] == sorted(IDS)
    assert not report['active_processes_inside_cleanup_root']
    write(OUT / 'report.json', report)
    print(json.dumps(report, ensure_ascii=False, indent=2))


if __name__ == '__main__':
    if sys.argv[1:] == ['--plan']:
        prepare()
    elif sys.argv[1:] == ['--apply']:
        apply()
    else:
        raise SystemExit('Use --plan or --apply; plan must precede apply.')
