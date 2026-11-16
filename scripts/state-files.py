#!/usr/bin/env python3
"""Shared state validation and toolbox-only sync; never print state contents."""
import datetime
import json
from pathlib import Path
import re
import subprocess
import sys


def invalid_constant(_):
    raise ValueError('invalid JSON constant')


def load(path, full=False):
    try:
        value = json.loads(Path(path).read_text(encoding='utf-8'),
                           parse_constant=invalid_constant)
    except (ValueError, OSError, UnicodeError):
        raise ValueError('invalid Terraform state JSON') from None
    if not isinstance(value, dict):
        raise ValueError('Terraform state must be a JSON object')
    if type(value.get('serial')) is not int or value['serial'] < 0:
        raise ValueError('Terraform state serial must be a nonnegative integer')
    if not isinstance(value.get('lineage'), str) or not value['lineage']:
        raise ValueError('Terraform state lineage must be a nonempty string')
    for key, kind in (('version', int), ('outputs', dict), ('resources', list)):
        if (full or key in value) and type(value.get(key)) is not kind:
            raise ValueError('Terraform state version/outputs/resources are invalid')
    return value


def same_content(left, right):
    # Python equality equates True with 1. Canonical JSON preserves that
    # distinction while allowing whitespace/key-order-only differences.
    return json.dumps(left, sort_keys=True) == json.dumps(right, sort_keys=True)


def destination(repo, source):
    match = re.fullmatch(r'terraform-state/(files/infrastructure/terraform/[A-Za-z0-9_-]+/terraform\.tfstate)\.age', source)
    if not match:
        raise ValueError('refusing unexpected state-backup path: ' + source)
    path = repo / match[1]
    for parent in [path, *path.parents]:
        if parent == repo:
            break
        if parent.is_symlink():
            raise ValueError('refusing symlink in state destination')
    if not path.parent.is_dir():
        raise ValueError('Terraform root directory is missing: ' + match[1])
    if path.exists() and (not path.is_file() or path.stat().st_mode & 0o777 != 0o600):
        raise ValueError('local Terraform state must be a regular mode 0600 file')
    return path


def sync(repo, temporary, identity):
    ref = 'refs/remotes/origin/state-backup'
    entries = subprocess.check_output(['git', '-C', str(repo), 'ls-tree', '-rz', ref, '--', 'terraform-state'])
    actions, present = [], set()
    for number, entry in enumerate(filter(None, entries.split(b'\0'))):
        metadata, name = entry.decode('utf-8').split('\t', 1)
        path = destination(repo, name)
        mode, kind, sha = metadata.split()
        if mode != '100644' or kind != 'blob':
            raise ValueError('state-backup entry must be a regular blob: ' + name)
        present.add(path)
        cipher = temporary / f'{number}.age'
        candidate = temporary / f'{number}.tfstate'
        with cipher.open('wb') as output:
            subprocess.run(['git', '-C', str(repo), 'cat-file', 'blob', sha], stdout=output, check=True)
        with candidate.open('wb') as output:
            subprocess.run(['age', '--decrypt', '--identity', identity, str(cipher)], stdout=output, check=True)
        backup = load(candidate)
        if path.exists():
            local = load(path)
            if local['lineage'] != backup['lineage']:
                raise ValueError('lineage mismatch: ' + path.parent.name)
            if local['serial'] > backup['serial']:
                raise ValueError('local state is newer; run make state-backup on this workstation: ' + path.parent.name)
            if local['serial'] == backup['serial']:
                if not same_content(local, backup):
                    raise ValueError('same serial with different contents: ' + path.parent.name)
                continue
        actions.append((path, candidate))
    if not present:
        raise ValueError('origin/state-backup contains no state-backup tree')
    for path in (repo / 'files/infrastructure/terraform').glob('*/terraform.tfstate'):
        if path not in present:
            print('WARNING: local root absent from backup: ' + path.parent.name, file=sys.stderr)
    # Validate every root before changing any destination. The temp directory is
    # on this filesystem; rename installs without exposing a partial JSON file.
    stamp = datetime.datetime.now(datetime.timezone.utc).strftime('%Y%m%dT%H%M%S%fZ')
    for path, candidate in actions:
        if path.exists():
            saved = path.with_name(path.name + '.pre-sync.' + stamp)
            if saved.exists():
                raise ValueError('pre-sync destination already exists')
            subprocess.run(['mv', '--', str(path), str(saved)], check=True)
            saved.chmod(0o600)
        candidate.chmod(0o600)
        subprocess.run(['mv', '--', str(candidate), str(path)], check=True)
        print('synced Terraform root: ' + path.parent.name)


if __name__ == '__main__':
    try:
        if sys.argv[1] == 'validate':
            load(sys.argv[2], full=True)
        elif sys.argv[1] == 'check':
            load(sys.argv[2])
        elif sys.argv[1] == 'publish-check':
            local, backup = load(sys.argv[2]), load(sys.argv[3])
            if local['lineage'] != backup['lineage']:
                raise ValueError('refusing backup: lineage mismatch')
            if local['serial'] < backup['serial']:
                raise ValueError('refusing backup: remote state is newer; run make state-sync')
            if local['serial'] == backup['serial'] and not same_content(local, backup):
                raise ValueError('refusing backup: same serial with different contents')
        elif sys.argv[1] == 'destination':
            destination(Path(sys.argv[2]).resolve(), sys.argv[3])
        else:
            sync(Path(sys.argv[2]).resolve(), Path(sys.argv[3]), sys.argv[4])
    except (ValueError, OSError, subprocess.SubprocessError) as error:
        # ValueError messages are ours; JSON decoder errors never include data.
        print(str(error) if isinstance(error, ValueError) else 'state file operation failed', file=sys.stderr)
        sys.exit(1)
