"""Publish or clear run completion under a durable, monotonically fenced file lock."""
import fcntl
import json
import os
import sys
from pathlib import Path
from files import sync_dir


def update(request):
    root = Path(request['trusted_root']).absolute()
    directory = Path(request['run_directory']).absolute()
    if not directory.is_relative_to(root):
        raise ValueError('invalid run directory')
    for part in [directory, *directory.parents]:
        if part == root:
            break
        if part.is_symlink():
            raise ValueError('unsupported run directory symlink')
    directory.mkdir(parents=True, exist_ok=True)
    epoch = request['epoch']
    if type(epoch) is not int or epoch < 0:
        raise ValueError('invalid attempt epoch')
    fence = directory / '.mn_completion_fence.json'
    completion = directory / '.mn_completion.json'
    lock = directory / '.mn_completion.lock'
    for path in (fence, completion, lock):
        if path.is_symlink():
            raise ValueError('unsupported completion symlink')
    with lock.open('a+') as stream:
        fcntl.flock(stream, fcntl.LOCK_EX)
        current = json.loads(fence.read_text())['epoch'] if fence.exists() else 0
        if epoch < current:
            raise ValueError('stale completion epoch')
        if request['action'] == 'activate':
            atomic(fence, {'epoch': epoch})
            completion.unlink(missing_ok=True)
            sync_dir(directory)
        elif request['action'] == 'publish':
            atomic(fence, {'epoch': epoch})
            atomic(completion, {**request['receipt'], 'lease_epoch': epoch})
        else:
            raise ValueError('invalid completion operation')


def atomic(path, value):
    temporary = path.with_name(path.name + f'.{os.getpid()}.tmp')
    try:
        with temporary.open('x') as stream:
            json.dump(value, stream)
            stream.flush()
            os.fsync(stream.fileno())
        temporary.replace(path)
        sync_dir(path.parent)
    finally:
        temporary.unlink(missing_ok=True)


if __name__ == '__main__':
    try:
        update(json.loads(Path(sys.argv[1]).read_text()))
    except Exception:
        sys.exit(1)
