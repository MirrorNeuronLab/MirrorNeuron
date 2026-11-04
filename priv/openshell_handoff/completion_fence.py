"""Publish or clear run completion under a durable, monotonically fenced file lock."""
import fcntl
import json
import os
import stat
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
            handoff_to_volume_owner(root, directory, request['receipt'].get('output_files', []))
            atomic(fence, {'epoch': epoch})
            atomic(completion, {**request['receipt'], 'lease_epoch': epoch})
        else:
            raise ValueError('invalid completion operation')


def handoff_to_volume_owner(root, run, files):
    """Give the host sync account access to the fenced output inventory only."""
    owner = root.stat()
    user = run.parent.parent / 'user'
    inventory = {}
    for entry in files:
        path = Path(entry['path'])
        if '..' in path.parts or not (path.is_relative_to(run) or path.is_relative_to(user)):
            raise ValueError('output outside the completed run or user directory')
        if path.is_relative_to(run / '.handoff'):
            continue  # Private execution journal, including receipts from earlier Core versions.
        branch = inventory
        parts = path.relative_to(root).parts
        for name in parts[:-1]:
            branch = branch.setdefault(name, {})
        branch[parts[-1]] = None

    def visit(parent_fd, parent, entries):
        for name, children in entries.items():
            path = parent / name
            if children is None:
                info = os.stat(name, dir_fd=parent_fd, follow_symlinks=False)
                if not stat.S_ISREG(info.st_mode):
                    raise ValueError('unexpected output file type')
                if accessible(info, owner, 4):
                    continue
            flags = os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK
            if children is not None:
                flags |= os.O_DIRECTORY
            fd = os.open(name, flags, dir_fd=parent_fd)
            try:
                if path.is_relative_to(run) or path.is_relative_to(user):
                    info = os.fstat(fd)
                    is_dir = children is not None
                    if not is_dir and not stat.S_ISREG(info.st_mode):
                        raise ValueError('unexpected output file type')
                    need = 5 if is_dir else 4
                    if not accessible(info, owner, need):
                        if (not is_dir and info.st_nlink != 1) or (info.st_mode >> 6) & need != need:
                            raise PermissionError('cannot transfer private output ownership')
                        os.fchown(fd, owner.st_uid, -1)
                if children is not None:
                    visit(fd, path, children)
            finally:
                os.close(fd)

    fd = os.open(root, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
    try:
        visit(fd, root, inventory)
    finally:
        os.close(fd)


def accessible(info, owner, need):
    shift = 6 if info.st_uid == owner.st_uid else 3 if info.st_gid == owner.st_gid else 0
    return ((info.st_mode >> shift) & need) == need


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
