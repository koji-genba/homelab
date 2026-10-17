#!/bin/sh
# Exercise completion-marker semantics without network, credentials or a model.
set -eu
python3 <<'PY'
import pathlib
import re
import runpy
import sys
import tempfile
import types

import yaml

role = pathlib.Path('files/infrastructure/ansible/agent/roles/agent_stack')
script = role / 'files/fetch-model.py'
revision = 'a' * 40
with tempfile.TemporaryDirectory() as directory:
    snapshot = pathlib.Path(directory) / revision
    snapshot.mkdir()
    calls = []

    def interrupted(**kwargs):
        calls.append(kwargs)
        raise OSError('interrupted download')

    hub = types.ModuleType('huggingface_hub')
    hub.snapshot_download = interrupted
    sys.modules['huggingface_hub'] = hub
    sys.argv = [str(script), 'example/model', revision]
    try:
        runpy.run_path(str(script), run_name='__main__')
    except OSError:
        pass
    else:
        raise AssertionError('download failure was hidden')
    assert not (snapshot / '.homelab-complete').exists()

    def complete(**kwargs):
        calls.append(kwargs)
        return str(snapshot)

    hub.snapshot_download = complete
    runpy.run_path(str(script), run_name='__main__')
    assert (snapshot / '.homelab-complete').read_text() == revision + '\n'
    assert calls[-1]['revision'] == revision
    assert calls[-1]['max_workers'] == 2
    assert not (snapshot / '.homelab-complete.tmp').exists()
    sys.argv[-1] = 'main'
    try:
        runpy.run_path(str(script), run_name='__main__')
    except ValueError:
        pass
    else:
        raise AssertionError('mutable revision accepted')

# Catch the OOM regression at the provisioning boundary, not in the mock above.
fetch = (role / 'tasks/fetch_model.yml').read_text()
assert '--memory' in fetch and '--memory-swap' in fetch
assert 'agent_stack_tei_image' not in fetch and '/health' not in fetch
cache = (role / 'tasks/models.yml').read_text()
assert '/.homelab-complete' in cache
limits = yaml.safe_load((role / 'defaults/main.yml').read_text())
assert limits['agent_stack_model_fetch_memory'] == '1g'
assert '@sha256:' in limits['agent_stack_model_fetch_image']
assert '--require-hashes -r /requirements.txt' in fetch
assert '--only-binary=:all:' in fetch
assert 'homelab-agent-model-fetch-requirements.txt:/requirements.txt:ro' in fetch
assert 'src: model-fetch-requirements.txt' in cache
requirements = (role / 'files/model-fetch-requirements.txt').read_text()
entries = [line for line in requirements.splitlines() if line and not line.startswith('#')]
names = {line.split('==')[0].lower().replace('_', '-') for line in entries}
# Closure resolved for hub 0.36.0 on the pinned Python 3.13 amd64 image.
assert names == {'certifi', 'charset-normalizer', 'filelock', 'fsspec', 'hf-xet',
                 'huggingface-hub', 'idna', 'packaging', 'pyyaml', 'requests',
                 'tqdm', 'typing-extensions', 'urllib3'}
for line in entries:
    assert re.fullmatch(r'[A-Za-z0-9_.-]+==[A-Za-z0-9_.+-]+ --hash=sha256:[0-9a-f]{64}', line), line
assert any(line.startswith('huggingface-hub==0.36.0 ') for line in entries)
assert 'os.umask(0o022)' in script.read_text()

# A CPU quota alone did not bound the inference pools in WS7c. Check that
# role defaults reach all runtime knobs, without lowering the input-length or
# recall-candidate budgets to make the performance check look better.
compose = yaml.safe_load(pathlib.Path('files/services/agent/stack/compose.yaml').read_text())
reranker = compose['services']['reranker']
env_template = (role / 'templates/compose.env.j2').read_text()
validator = pathlib.Path('scripts/agent-compose-config.sh').read_text()
for suffix in ('cpus', 'threads', 'tokenization_workers', 'max_batch_requests'):
    key = 'agent_stack_reranker_' + suffix
    variable = 'TEI_RERANKER_' + suffix.upper()
    assert limits[key] > 0
    assert variable + '={{ ' + key + ' }}' in env_template
    assert variable + '=' + str(limits[key]) in validator
assert limits['agent_stack_reranker_threads'] <= limits['agent_stack_reranker_cpus']
# WS12: the two CPU-heavy models must leave capacity on the 8-vCPU VM even
# when background retain embeds documents during a foreground rerank.
assert limits['agent_stack_reranker_cpus'] == 6
assert limits['agent_stack_reranker_threads'] == 6
assert limits['agent_stack_reranker_tokenization_workers'] == 6
assert compose['services']['embedding']['cpus'] == 1
assert limits['agent_stack_reranker_cpus'] + compose['services']['embedding']['cpus'] <= 7
assert reranker['cpus'] == '${TEI_RERANKER_CPUS:?set TEI_RERANKER_CPUS}'
for key in ('RAYON_NUM_THREADS', 'OMP_NUM_THREADS', 'MKL_NUM_THREADS'):
    assert reranker['environment'][key] == '${TEI_RERANKER_THREADS:?set TEI_RERANKER_THREADS}'
argv = reranker['command']
assert argv[argv.index('--max-batch-tokens') + 1] == '2048'
assert argv[argv.index('--max-batch-requests') + 1].startswith('${TEI_RERANKER_MAX_BATCH_REQUESTS:')
assert argv[argv.index('--tokenization-workers') + 1].startswith('${TEI_RERANKER_TOKENIZATION_WORKERS:')
assert limits['agent_stack_reranker_max_candidates_mid'] == 20
assert limits['agent_stack_reranker_max_candidates_high'] == 30
PY
printf '%s\n' 'Agent download-only model fetch fixture: ok'
