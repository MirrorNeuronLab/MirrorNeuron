#!/usr/bin/env python3
"""Filesystem sandbox/transport double; runs the real uploaded worker wrapper."""
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
args = sys.argv[1:]
root = Path(os.environ['FAKE_SANDBOX_ROOT'])
command = args[1]
if command == 'upload':
    source, destination = Path(args[3]), args[4]
    target = root / args[2] / destination.removeprefix('/sandbox/')
    if source.is_dir():
        target.mkdir(parents=True, exist_ok=True)
        shutil.copytree(source, target/source.name, dirs_exist_ok=True)
    else:
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(source, target)
elif command == 'download':
    source = root / args[2] / args[3].removeprefix('/sandbox/')
    if (root/'fail-transfer').exists() and '/outputs/' in str(source):
        sys.exit(9)
    shutil.copyfile(source, Path(args[4])/source.name)
elif command == 'exec':
    sandbox = root / args[args.index('--name')+1]
    cmd = args[args.index('--')+1:]
    def rewrite(text): return text.replace('/sandbox/', str(sandbox)+'/')
    if cmd[:2] == ['python3', '-c']:
        sys.exit(subprocess.run([rewrite(x) for x in cmd]).returncode)
    if cmd[0] == 'python3':
        if (root/'fail-exec').exists(): sys.exit(9)
        spec = Path(rewrite(cmd[2]))
        spec.write_text(rewrite(spec.read_text()))
        # Rewrite only fixture command references, never user data in real code.
        env = os.environ.copy()
        cmd = [rewrite(x) for x in cmd]
        result = subprocess.run(cmd, env=env)
        sys.exit(result.returncode)
    if cmd[:2] == ['rm','-rf']:
        if (root/'fail-cleanup').exists(): sys.exit(4)
        shutil.rmtree(rewrite(cmd[-1]), ignore_errors=True)
    else:
        sys.exit(2)
else:
    sys.exit(2)
