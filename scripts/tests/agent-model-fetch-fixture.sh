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
from decimal import Decimal

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
for suffix in ('cpus', 'threads', 'tokenization_workers'):
    key = 'agent_stack_reranker_' + suffix
    variable = 'TEI_RERANKER_' + suffix.upper()
    assert limits[key] > 0
    assert variable + '={{ ' + key + ' }}' in env_template
    assert variable + '=' + str(limits[key]) in validator
assert limits['agent_stack_reranker_threads'] <= limits['agent_stack_reranker_cpus']
# WS14: the two CPU-heavy models must leave capacity on the 12-vCPU VM even
# when background retain embeds documents during a foreground rerank.
assert limits['agent_stack_reranker_cpus'] == 6
assert limits['agent_stack_reranker_threads'] == 6
assert limits['agent_stack_reranker_tokenization_workers'] == 6
embedding = compose['services']['embedding']
assert limits['agent_stack_embedding_cpus'] == 4
assert embedding['cpus'] == '${TEI_EMBEDDING_CPUS:?set TEI_EMBEDDING_CPUS}'
assert 'TEI_EMBEDDING_CPUS={{ agent_stack_embedding_cpus }}' in env_template
assert 'TEI_EMBEDDING_CPUS=4' in validator
# Tie resource accounting to the actual VM defaults, including the example.
tf_root = pathlib.Path('files/infrastructure/terraform/agent-vm')
tf_variables = (tf_root / 'variables.tf').read_text()
def vm_default(name):
    block = re.search(r'variable "' + name + r'" \{(.*?)\n\}', tf_variables, re.S).group(1)
    return int(re.search(r'default\s*=\s*(\d+)', block).group(1))
vm_cpus, vm_memory_mb = vm_default('cpu_cores'), vm_default('memory_mb')
assert (vm_cpus, vm_memory_mb) == (12, 24576)
example = (tf_root / 'terraform.tfvars.example').read_text()
for name, value in [('cpu_cores', vm_cpus), ('memory_mb', vm_memory_mb)]:
    assert re.search(r'^' + name + r'\s*=\s*' + str(value) + r'$', example, re.M)
assert limits['agent_stack_reranker_cpus'] + limits['agent_stack_embedding_cpus'] <= vm_cpus - 2
assert embedding['mem_limit'] == '8g'
assert reranker['mem_limit'] == '4g'
def memory_mib(value):
    match = re.fullmatch(r'([0-9.]+)([gm])', value)
    return Decimal(match[1]) * (1024 if match[2] == 'g' else 1)
memory_total_mb = sum(memory_mib(service['mem_limit']) for service in compose['services'].values())
# Include every service, and retain at least 6 GiB for OS/Docker and page cache.
assert memory_total_mb + 6 * 1024 <= vm_memory_mb
embedding_argv = embedding['command']
assert embedding_argv[embedding_argv.index('--max-batch-tokens') + 1] == '${HINDSIGHT_EMBEDDINGS_MAX_INPUT_TOKENS:?set HINDSIGHT_EMBEDDINGS_MAX_INPUT_TOKENS}'
assert limits['agent_stack_embeddings_max_input_tokens'] == 4096
assert reranker['cpus'] == '${TEI_RERANKER_CPUS:?set TEI_RERANKER_CPUS}'
for key in ('RAYON_NUM_THREADS', 'OMP_NUM_THREADS', 'MKL_NUM_THREADS'):
    assert reranker['environment'][key] == '${TEI_RERANKER_THREADS:?set TEI_RERANKER_THREADS}'
argv = reranker['command']
assert argv[argv.index('--max-batch-tokens') + 1] == '2048'
assert '--max-batch-requests' not in argv
assert argv[argv.index('--tokenization-workers') + 1].startswith('${TEI_RERANKER_TOKENIZATION_WORKERS:')
assert limits['agent_stack_reranker_max_candidates_mid'] == 20
assert limits['agent_stack_reranker_max_candidates_high'] == 30
# WS16: the image and per-input permits must agree with the Hindsight fan-out.
assert embedding['image'] == limits['agent_stack_tei_image']
assert embedding['image'].endswith('@sha256:2538ea1c9640d3763b15af668039d24172d063b42337b0c27796fc2be180c78d')
# WS18: only embedding is fetched on the VM. ORT is selected by an image-
# bundled ONNX graph; no cache mount or mutable model/revision argument remains.
assert [m['name'] for m in limits['agent_stack_pinned_models']] == ['embedding']
image_repository = 'ghcr.io/koji-genba/homelab-tei-reranker-onnx'
assert re.fullmatch(re.escape(image_repository) + r'@sha256:[0-9a-f]{64}', reranker['image'])
assert argv[argv.index('--model-id') + 1] == '/model'
assert '--revision' not in argv and 'volumes' not in reranker
assert reranker['memswap_limit'] == '4g'
assert reranker['read_only'] is True and reranker['cap_drop'] == ['ALL']
assert 'TEI_RERANKER_MODEL=' not in env_template + validator
assert 'TEI_RERANKER_REVISION=' not in env_template + validator

# Run the rendered production gate with just this image left at zero. A fake
# docker binary records accidental pass-through, without contacting any daemon.
import os
import subprocess
import jinja2
with tempfile.TemporaryDirectory() as directory:
    root = pathlib.Path(directory)
    env_file = root / 'compose.env'
    secret_file = root / 'memory-db.env'
    env_file.touch()
    secret_file.touch()
    source = pathlib.Path('files/services/agent/stack/compose.yaml').read_text()
    source = re.sub(r'@sha256:[0-9a-f]{64}', '@sha256:' + 'a' * 64, source)
    source = source.replace(image_repository + '@sha256:' + 'a' * 64,
                            image_repository + '@sha256:' + '0' * 64)
    compose_file = root / 'compose.yaml'
    compose_file.write_text(source)
    template = (role / 'templates/homelab-agent-compose-up.sh.j2').read_text()
    helper = root / 'up.sh'
    helper.write_text(jinja2.Template(template).render(
        agent_stack_project_dir=str(root), agent_stack_project_name='fixture',
        agent_stack_env_file=str(env_file), agent_stack_secrets_dir=str(root),
        agent_stack_compose_wait_timeout=600))
    marker = root / 'docker-called'
    docker = root / 'docker'
    docker.write_text('#!/bin/sh\ntouch "' + str(marker) + '"\n')
    docker.chmod(0o755)
    environment = dict(os.environ, PATH=str(root) + ':' + os.environ['PATH'])
    result = subprocess.run(['sh', str(helper)], env=environment, capture_output=True, text=True)
    assert result.returncode != 0 and 'ALL-ZERO placeholder' in result.stderr
    assert not marker.exists()
    compose_file.write_text(source.replace('@sha256:' + '0' * 64, '@sha256:' + 'b' * 64))
    result = subprocess.run(['sh', str(helper), 'config'], env=environment, capture_output=True, text=True)
    assert result.returncode == 0 and marker.exists(), result.stderr

image_dir = pathlib.Path('files/services/images/tei-reranker-onnx')
# Keep the existing backup provenance accurate without executing the exporter.
import ast
export_constants = {
    node.targets[0].id: ast.literal_eval(node.value)
    for node in ast.parse((image_dir / 'export_model.py').read_text()).body
    if isinstance(node, ast.Assign) and isinstance(node.targets[0], ast.Name)
    and node.targets[0].id in {'MODEL', 'REVISION'}
}
assert limits['agent_stack_reranker_model'] == export_constants['MODEL']
assert limits['agent_stack_reranker_revision'] == export_constants['REVISION']
dockerfile = (image_dir / 'Dockerfile').read_text()
assert dockerfile.count('@' + limits['agent_stack_tei_image'].split('@')[1]) == 2
assert 'AS candle-reference' in dockerfile and 'AS runtime' in dockerfile
assert '--require-hashes' in dockerfile and '--only-binary=:all:' in dockerfile
assert '/files/services/images/tei-reranker-onnx' in pathlib.Path('.github/dependabot.yml').read_text()
export_requirements = (image_dir / 'requirements.txt').read_text().splitlines()
for line in export_requirements:
    if not line or line.startswith(('#', '--')):
        continue
    assert re.fullmatch(r'[A-Za-z0-9_.-]+==[A-Za-z0-9_.+-]+ --hash=sha256:[0-9a-f]{64}', line), line
workflow = yaml.safe_load(pathlib.Path('.github/workflows/tei-reranker-onnx-image.yml').read_text())
for job in workflow['jobs'].values():
    for step in job['steps']:
        if 'uses' in step:
            assert re.fullmatch(r'[^@]+@[0-9a-f]{40}', step['uses'])

hindsight_env = compose['services']['hindsight']['environment']
assert hindsight_env['HINDSIGHT_API_WORKERS'] == '1'
embed_batch = int(hindsight_env['HINDSIGHT_API_EMBEDDINGS_TEI_BATCH_SIZE'])
embed_parallel = int(hindsight_env['HINDSIGHT_API_EMBEDDINGS_MAX_CONCURRENT_REQUESTS'])
assert (embed_batch, embed_parallel) == (32, 2)
assert int(embedding_argv[embedding_argv.index('--max-concurrent-requests') + 1]) == 128
assert 128 >= embed_batch * embed_parallel + 32
assert hindsight_env['HINDSIGHT_API_RERANKER_TEI_MAX_CONCURRENT'] == '1'
assert hindsight_env['HINDSIGHT_API_RERANKER_TEI_BATCH_SIZE'] == '32'
assert int(argv[argv.index('--max-concurrent-requests') + 1]) == 64
assert 64 >= int(hindsight_env['HINDSIGHT_API_RERANKER_TEI_BATCH_SIZE']) * int(hindsight_env['HINDSIGHT_API_RERANKER_TEI_MAX_CONCURRENT']) + 32
assert '--max-batch-requests' not in embedding_argv
assert limits['agent_stack_embedding_threads'] == 4
assert 'TEI_EMBEDDING_THREADS={{ agent_stack_embedding_threads }}' in env_template
assert 'TEI_EMBEDDING_THREADS=4' in validator
for key in ('RAYON_NUM_THREADS', 'OMP_NUM_THREADS', 'MKL_NUM_THREADS'):
    assert embedding['environment'][key] == '${TEI_EMBEDDING_THREADS:?set TEI_EMBEDDING_THREADS}'
PY
printf '%s\n' 'Agent download-only model fetch fixture: ok'
