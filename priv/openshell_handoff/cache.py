"""Job-scoped disposable sandbox cache. Hash every hit; copy into each attempt."""
import hashlib
import os
import shutil
from pathlib import Path
from files import read, verify


def hydrate(spec):
    index = read(Path(spec['workspace']) / '.inputs/index.json')
    cache = Path(spec['cache_root'])
    cache.mkdir(parents=True, exist_ok=True)
    for entry in index.values():
        ref = entry['reference']
        target = Path(spec['workspace']) / '.inputs' / entry['file']
        cached_ref = {**ref, 'path': ref['sha256']}
        if not target.exists():
            source = verify(cache, cached_ref)
            target.parent.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(source, target)
        verify(target.parent, {**ref, 'path': target.name})
        target.chmod(0o444)
        cached = cache / ref['sha256']
        # A cache entry is expendable, so corruption is repaired from verified input.
        try:
            verify(cache, cached_ref)
        except (OSError, ValueError):
            temp = cached.with_name(cached.name + '.' + str(os.getpid()))
            shutil.copyfile(target, temp)
            temp.chmod(0o444)
            os.replace(temp, cached)
