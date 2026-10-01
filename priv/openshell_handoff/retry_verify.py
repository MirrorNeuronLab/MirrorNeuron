"""Read-only checkpoint artifact and handoff replay verification for Core."""
import json
import hashlib
import sys
from pathlib import Path
from files import VERSION, digest, regular, verify, read, safe
from store import resolve


def inspect(request):
    trusted = Path(request['trusted_root']).absolute()
    submission = Path(request['submission_path']).absolute()
    if not submission.is_relative_to(trusted) or submission.parent.name != 'submissions':
        raise ValueError('invalid retained submission path')
    def confined(path):
        path = path.absolute()
        if not path.is_relative_to(trusted):
            raise ValueError('artifact escapes retained storage')
        for part in [path, *path.parents]:
            if part == trusted:
                break
            if part.is_symlink():
                raise ValueError('unsupported retained storage symlink')
        return path
    confined(submission)
    run_roots = {run: submission / 'outputs' / 'runs' / run for run in request['run_ids']}
    if any(not isinstance(run, str) or safe(run) != run or '/' in run for run in run_roots):
        raise ValueError('invalid retained run identity')
    for root in run_roots.values():
        confined(root / '.handoff')
    inventory = request.get('artifacts', {}).get('inventory', [])
    for entry in inventory:
        verify(confined(run_roots[entry['run_id']]), entry)
    captured = {(entry['run_id'], entry['path']): entry for entry in inventory}
    total_bytes = sum(entry['size_bytes'] for entry in inventory)
    def remember(root, path, run):
        nonlocal total_bytes
        relative = path.relative_to(root).as_posix()
        path = regular(confined(root), relative)
        if (run, relative) in captured:
            return
        size = path.stat().st_size
        total_bytes += size
        if len(captured) >= 10000 or total_bytes > 1000000000:
            raise ValueError('checkpoint artifact inventory exceeds its bound')
        sha = hashlib.sha256()
        with path.open('rb') as stream:
            for chunk in iter(lambda: stream.read(1024 * 1024), b''):
                sha.update(chunk)
        captured[(run, relative)] = {'run_id': run, 'path': relative, 'sha256': sha.hexdigest(), 'size_bytes': size}

    def references(value):
        if isinstance(value, dict):
            if value.get('version') == VERSION:
                run = value['producer']['run_id']
                if run not in run_roots:
                    raise ValueError('cross-run artifact reference')
                resolve(run_roots[run] / '.handoff', value)
            elif set(value) == {'path', 'sha256'} or (isinstance(value.get('kind'), str) and isinstance(value.get('path'), str)
                    and set(value) <= {'kind', 'path', 'sha256', 'size_bytes', 'type', 'version', 'media_type'}):
                matched = False
                for run, root in run_roots.items():
                    candidate = confined(root / safe(value['path']))
                    if not candidate.resolve().is_relative_to(root.resolve()):
                        raise ValueError('checkpoint artifact escapes run directory')
                    if candidate.is_file() or candidate.is_dir():
                        files = [candidate] if candidate.is_file() else sorted(candidate.rglob('*'))
                        for path in files:
                            confined(path)
                            if path.is_dir():
                                continue
                            if request.get('mode') == 'capture':
                                remember(root, path, run)
                            elif 'sha256' not in value and (run, path.relative_to(root).as_posix()) not in captured:
                                raise ValueError('artifact has no retained integrity inventory')
                        if 'sha256' in value:
                            verify(root, {**value, 'size_bytes': value.get('size_bytes', candidate.stat().st_size)})
                        matched = True
                        break
                if not matched:
                    raise ValueError('checkpoint artifact is missing')
            else:
                for child in value.values():
                    references(child)
        elif isinstance(value, list):
            for child in value:
                references(child)

    references(request['workflow'])
    safe_steps = []
    for step in request['handoff_steps']:
        root = run_roots[request['workflow_run_id']] / '.handoff'
        folder = root / 'transactions' / digest({'run_id': request['workflow_run_id'], 'step_instance': step})
        state_path = folder / 'state.json'
        if not state_path.exists():
            continue
        state = read(regular(confined(folder), 'state.json'))
        if state['producer']['run_id'] != request['workflow_run_id'] or state['producer']['step_instance'] != step:
            raise ValueError('handoff producer identity mismatch')
        if not state['request_hash'].startswith('mn.logical_request/v1:'):
            raise ValueError('handoff logical replay contract is unsupported')
        if state['phase'] == 'prepared':
            safe_steps.append(step)
        else:
            receipt_path = confined(root / 'commits' / safe(state['commit_id']) / 'receipt.json')
            if receipt_path.exists():
                receipt = read(regular(receipt_path.parent, 'receipt.json'))
                if receipt['producer'] != state['producer'] or receipt['request_hash'] != state['request_hash']:
                    raise ValueError('handoff receipt identity mismatch')
                if receipt['execution']['exit_code'] == 0:
                    for ref in receipt['references']:
                        resolve(root, ref)
                    safe_steps.append(step)
    return {'safe_handoff_steps': safe_steps, 'inventory': list(captured.values())}


if __name__ == '__main__':
    try:
        print(json.dumps({'ok': inspect(json.loads(Path(sys.argv[1]).read_text()))}))
    except Exception:
        # Do not expose source paths or file contents through retry diagnostics.
        print(json.dumps({'error': 'Checkpoint artifacts or replay receipts are missing or invalid.'}))
        sys.exit(1)
