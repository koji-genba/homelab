"""pip download --only-binary=:all: の結果から amd64 用 lock を作る。"""
import hashlib
from pathlib import Path
import sys
import zipfile
from email.parser import BytesParser

print('# Ubuntu 24.04 / CPython 3.12 / linux/amd64; generated from requirements.in.')
for wheel in sorted(Path(sys.argv[1]).glob('*.whl')):
    with zipfile.ZipFile(wheel) as archive:
        metadata = next(p for p in archive.namelist() if p.endswith('.dist-info/METADATA'))
        package = BytesParser().parsebytes(archive.read(metadata))
    digest = hashlib.sha256(wheel.read_bytes()).hexdigest()
    print(f'{package["Name"]}=={package["Version"]} --hash=sha256:{digest}')
