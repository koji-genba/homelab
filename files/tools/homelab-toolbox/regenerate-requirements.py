#!/usr/bin/env python3
"""Refresh the complete linux/amd64 wheel closure using Python 3.13 / pip 25.1.1."""
import hashlib
import os
from pathlib import Path
import re
import subprocess
import sys
import tempfile
from zipfile import ZipFile
from email.parser import BytesParser

import pip

if sys.version_info[:2] != (3, 13) or pip.__version__ != '25.1.1':
    raise SystemExit('Use the documented Python 3.13 / pip 25.1.1 generator container')

requirements = Path(__file__).with_name('requirements.txt')
pins = re.findall(r'^([A-Za-z0-9_.-]+==[^\s\\]+)', requirements.read_text(), re.M)
if not pins:
    raise SystemExit('No version pins found')
with tempfile.TemporaryDirectory() as tmp:
    root = Path(tmp)
    (root / 'pins.txt').write_text('\n'.join(pins) + '\n')
    wheels = root / 'wheels'
    subprocess.run([
        sys.executable, '-m', 'pip', '--isolated', 'download',
        '--index-url', 'https://pypi.org/simple', '--only-binary=:all:',
        '--no-cache-dir', '--dest', str(wheels), '-r', str(root / 'pins.txt'),
    ], check=True, env={**os.environ, 'PIP_CONFIG_FILE': os.devnull})
    rows = []
    for wheel in sorted(wheels.glob('*.whl')):
        with ZipFile(wheel) as archive:
            metadata = BytesParser().parsebytes(archive.read(next(
                name for name in archive.namelist() if name.endswith('.dist-info/METADATA')
            )))
        rows.append((metadata['Name'], metadata['Version'], hashlib.sha256(wheel.read_bytes()).hexdigest()))
    header = ('# Linux amd64 / CPython 3.13; complete binary-wheel closure.\n'
              '# Generated with Python 3.13 / pip 25.1.1; see README.md.\n'
              '# Edit version pins here, then run regenerate-requirements.py.\n'
              '--index-url https://pypi.org/simple\n')
    requirements.write_text(header + ''.join(
        f'{name}=={version} --hash=sha256:{digest}\n'
        for name, version, digest in sorted(rows, key=lambda row: row[0].lower())
    ))
