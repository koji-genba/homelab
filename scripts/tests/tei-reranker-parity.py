#!/usr/bin/env python3
"""Run offline TEI images sequentially on loopback; compare every rank and score.

Only named containers created by this process are removed. Python stdlib only.
Default: the 24 reviewed synthetic requests. --runs/--extra-input support the
longer local 20/30-candidate acceptance run without changing CI's input corpus.
"""
import argparse
import hashlib
import json
import math
from pathlib import Path
import re
import subprocess
import time
import urllib.error
import urllib.request
import uuid

FIXTURE = Path(__file__).resolve().parents[2] / 'files/services/images/tei-reranker-onnx/rerank20.json'
HTTP = urllib.request.build_opener(urllib.request.ProxyHandler({}))


def docker(*args):
    return subprocess.run(['docker', *args], check=True, text=True,
                          capture_output=True).stdout.strip()


def request(base, path, payload=None):
    req = urllib.request.Request(base + path,
        data=None if payload is None else json.dumps(payload).encode(),
        headers={'Content-Type': 'application/json'})
    start = time.perf_counter()
    with HTTP.open(req, timeout=180) as response:
        if response.status != 200:
            raise ValueError(f'Unexpected HTTP status {response.status}')
        body = response.read()
        return json.loads(body) if body else None, time.perf_counter() - start


def percentile(values, p):
    values = sorted(values)
    pos = (len(values) - 1) * p
    i = int(pos)
    return values[i] + (values[min(i + 1, len(values) - 1)] - values[i]) * (pos - i)


def check_response(response, size):
    if not isinstance(response, list) or len(response) != size:
        raise ValueError('Incomplete rerank response')
    if sorted(x['index'] for x in response) != list(range(size)):
        raise ValueError('Missing, repeated or invalid candidate index')
    if not all(isinstance(x['score'], (int, float)) and math.isfinite(x['score']) for x in response):
        raise ValueError('Non-finite/invalid score')
    if any(a['score'] < b['score'] for a, b in zip(response, response[1:])):
        raise ValueError('Scores are not sorted')


def run_image(label, image, corpora, args):
    name = 'ws18-parity-' + label + '-' + uuid.uuid4().hex[:12]
    result = dict(image=image, requests=[], warmup=[])
    created = False
    command = ['run', '-d', '--pull', 'never', '--name', name,
        '--cpus', str(args.cpus), '--memory', '4g', '--memory-swap', '4g',
        '--read-only', '--cap-drop', 'ALL', '--security-opt', 'no-new-privileges',
        '--tmpfs', '/tmp', '-p', '127.0.0.1::8080',
        '-e', 'PORT=8080', '-e', 'HF_HUB_OFFLINE=1',
        '-e', f'RAYON_NUM_THREADS={args.cpus}', '-e', f'OMP_NUM_THREADS={args.cpus}',
        '-e', f'MKL_NUM_THREADS={args.cpus}', image, '--model-id', '/model',
        '--max-concurrent-requests', '64', '--max-batch-tokens', '2048',
        '--tokenization-workers', str(args.cpus), '--auto-truncate']
    result['command'] = command
    try:
        docker(*command)
        created = True
        port = docker('port', name, '8080/tcp').rsplit(':', 1)[1]
        base = 'http://127.0.0.1:' + port
        for _ in range(300):
            state = json.loads(docker('inspect', '-f', '{{json .State}}', name))
            if not state['Running']:
                raise RuntimeError(f'{label} exited during startup: {state}')
            try:
                request(base, '/health')
                break
            except (urllib.error.URLError, TimeoutError, ConnectionError):
                time.sleep(1)
        else:
            raise RuntimeError(f'{label}: health deadline exceeded')
        result['info'] = request(base, '/info')[0]
        result['startup_peak_bytes'] = int(docker('exec', name, 'cat', '/sys/fs/cgroup/memory.peak'))
        result['cpu_max'] = docker('exec', name, 'cat', '/sys/fs/cgroup/cpu.max')
        if result['cpu_max'] != f'{args.cpus * 100000} 100000':
            raise ValueError('Unexpected cgroup CPU quota')
        for i in range(8):
            pool = corpora[i % len(corpora)][1][0]
            payload = dict(query=pool['query'], texts=pool['texts'], return_text=False)
            response, seconds = request(base, '/rerank', payload)
            check_response(response, len(pool['texts']))
            result['warmup'].append(seconds)
        result['warmup_peak_bytes'] = int(docker('exec', name, 'cat', '/sys/fs/cgroup/memory.peak'))
        for corpus, rows in corpora:
            for i in range(args.runs or len(rows)):
                row_index = i % len(rows)
                pool = rows[row_index]
                response, seconds = request(base, '/rerank', dict(
                    query=pool['query'], texts=pool['texts'], return_text=False))
                check_response(response, len(pool['texts']))
                result['requests'].append(dict(corpus=corpus, input_index=row_index,
                    response=response, seconds=seconds, status=200))
                print(label, corpus, i + 1, f'{seconds:.3f}s', flush=True)
        result['summary'] = {}
        for corpus, _ in corpora:
            seconds = [r['seconds'] for r in result['requests'] if r['corpus'] == corpus]
            result['summary'][corpus] = dict(n=len(seconds), p50=percentile(seconds, .5),
                                            p95=percentile(seconds, .95))
    finally:
        if created:
            logs = subprocess.run(['docker', 'logs', name], text=True, capture_output=True)
            log = logs.stdout + logs.stderr
            (args.output / f'{label}.log').write_text(log)
            result['state'] = json.loads(docker('inspect', '-f', '{{json .State}}', name))
            result['resources'] = json.loads(docker('inspect', '-f', '{{json .HostConfig}}', name))
            result['image_id'] = docker('inspect', '-f', '{{.Image}}', name)
            try:
                result['peak_bytes'] = int(docker('exec', name, 'cat', '/sys/fs/cgroup/memory.peak'))
                result['memory_events'] = docker('exec', name, 'cat', '/sys/fs/cgroup/memory.events')
            finally:
                docker('rm', '-f', name)
                (args.output / f'{label}.json').write_text(json.dumps(result, indent=2) + '\n')
    state = result['state']
    if not state['Running'] or state['OOMKilled'] or state['ExitCode']:
        raise RuntimeError(f'{label}: unhealthy final state: {state}')
    if re.search(r'panicked|panic|Full\(|overload', log, re.I):
        raise RuntimeError(f'{label}: panic/overload in logs')
    expected_batch = 8 if label == 'ort' else 4
    if f'max_batch_requests={expected_batch}' not in log:
        raise RuntimeError(f'{label}: expected backend batch {expected_batch} not found')
    events = dict(line.split() for line in result['memory_events'].splitlines())
    if any(int(events[key]) for key in ('max', 'oom', 'oom_kill')):
        raise RuntimeError(f'{label}: cgroup memory limit event')
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--ort-image', required=True)
    parser.add_argument('--candle-image', required=True)
    parser.add_argument('--cpus', type=int, default=6)
    parser.add_argument('--runs', type=int, default=0, help='Requests per corpus (0: every row once)')
    parser.add_argument('--extra-input', type=Path)
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    if args.cpus < 1 or args.runs < 0:
        parser.error('cpus must be positive and runs nonnegative')
    args.output.mkdir(parents=True, exist_ok=True)
    paths = [FIXTURE] + ([args.extra_input] if args.extra_input else [])
    corpora = [(p.stem, json.loads(p.read_text())) for p in paths]
    for _, rows in corpora:
        if not rows:
            raise ValueError('Empty corpus')
    baseline = run_image('candle', args.candle_image, corpora, args)
    ort = run_image('ort', args.ort_image, corpora, args)
    differences = []
    if len(baseline['requests']) != len(ort['requests']):
        raise ValueError('Different request counts')
    for a, b in zip(baseline['requests'], ort['requests']):
        if (a['corpus'], a['input_index']) != (b['corpus'], b['input_index']):
            raise ValueError('Different inputs')
        if [x['index'] for x in a['response']] != [x['index'] for x in b['response']]:
            raise ValueError(f"Rank mismatch: {a['corpus']} index {a['input_index']}")
        differences.extend(abs(x['score'] - y['score']) for x, y in zip(a['response'], b['response']))
    maximum = max(differences)
    summary = dict(full_rank_matches=len(ort['requests']), score_comparisons=len(differences),
                   max_abs_score_difference=maximum, threshold=1e-4,
                   inputs={p.name: hashlib.sha256(p.read_bytes()).hexdigest() for p in paths},
                   latency={label: r['summary'] for label, r in [('candle', baseline), ('ort', ort)]})
    (args.output / 'comparison.json').write_text(json.dumps(summary, indent=2) + '\n')
    if maximum > 1e-4:
        raise ValueError(f'Score difference {maximum} exceeds 1e-4')
    print('PASS', json.dumps(summary), flush=True)


if __name__ == '__main__':
    main()
