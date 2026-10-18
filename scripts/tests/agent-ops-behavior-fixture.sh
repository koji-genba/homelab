#!/bin/sh
# Run rendered helper functions with all external operations replaced locally.
set -eu
python3 <<'PY'
import json
import os
from pathlib import Path
import subprocess
import tarfile
import tempfile

import jinja2
from jinja2 import meta
import yaml

role = Path('files/infrastructure/ansible/agent/roles/agent_ops/templates')
defaults = yaml.safe_load((role.parent / 'defaults/main.yml').read_text())
env = jinja2.Environment()
env.filters['to_json'] = json.dumps
env.filters['bool'] = bool
with tempfile.TemporaryDirectory() as directory:
    root = Path(directory)
    def render(name):
        source = (role / f'homelab-agent-{name}.sh.j2').read_text()
        keys = meta.find_undeclared_variables(env.parse(source))
        values = {key: str(root / key) for key in keys}
        values.update(agent_ops_uid=os.getuid(), agent_ops_gid=os.getgid(),
                      agent_ops_health_services=['hermes'], agent_ops_backup_age_recipients=[],
                      agent_ops_runner_excludes=defaults['agent_ops_runner_excludes'],
                      agent_ops_export_encrypt=False,
                      agent_ops_health_pending_ops_threshold=10,
                      agent_ops_health_renotify_seconds=21600, agent_stack_timezone='Asia/Tokyo',
                      agent_ops_backup_daily_keep=14, agent_ops_backup_weekly_keep=8,
                      agent_ops_backup_weekly_dow=7)
        return env.from_string(source).render(values)

    def run(name, body, success=True):
        source = render(name)
        # Never reach main's real docker/SSH/HTTP operations. Every test invokes
        # only the functions below, with external commands replaced explicitly.
        source = source[:source.rfind('\nmain "$@"')]
        path = root / f'{name}.sh'
        path.write_text(source + '\n' + body)
        result = subprocess.run(['bash', str(path)], text=True, capture_output=True)
        assert (result.returncode == 0) == success, (name, result.returncode, result.stdout, result.stderr)
        return result

    # Execute the rendered backup's actual Runner streaming step with SSH
    # replaced by a local tar invocation. No host, key or network is accessed.
    backup = render('backup')
    stream = backup[backup.index("    log 'streaming the Runner work tree over SSH'"):
                    backup.index('    collect_metadata "$tmp/METADATA.txt"')]
    workspace = root / 'runner-work'
    recovery = workspace / 'lost+found'
    recovery.mkdir(parents=True)
    (recovery / 'recovered-file').write_text('filesystem recovery data')
    nested = workspace / 'project/lost+found'
    nested.mkdir(parents=True)
    (nested / 'keep.txt').write_text('user data')
    (workspace / 'work.txt').write_text('runner data')
    arguments = root / 'runner-tar-arguments'
    setup = f'''
RUNNER_WORKSPACE={json.dumps(str(workspace))}
tmp={json.dumps(str(root))}
notify_operator() {{ :; }}
ssh() {{
    while [ "$1" != tar ]; do shift; done
    printf '%s\\n' "$@" > {json.dumps(str(arguments))}
    command "$@"
}}
'''
    recovery.chmod(0)
    try:
        run('backup', setup + stream)
        with tarfile.open(root / 'runner-work.tar.gz') as archive:
            members = archive.getnames()
        assert './lost+found' not in members
        assert not any(name.startswith('./lost+found/') for name in members)
        assert './project/lost+found/keep.txt' in members
        assert './work.txt' in members
        # Also covers root-run fixtures, where chmod cannot cause a read error:
        # the rendered EXCLUDES must reach tar with no error-suppression flags.
        assert arguments.read_text().splitlines() == [
            'tar', '-C', str(workspace),
            *('--exclude=' + pattern for pattern in defaults['agent_ops_runner_excludes']),
            '-czf', '-', '.',
        ]
        if os.geteuid() != 0:
            # Neither unrelated unreadable paths nor a nested lost+found may be
            # silently omitted. Both must reach the backup helper's fail path.
            for unreadable in (workspace / 'private', nested):
                unreadable.mkdir(exist_ok=True)
                unreadable.chmod(0)
                try:
                    out = run('backup', setup + stream, success=False)
                    assert 'Permission denied' in out.stderr, out.stderr
                    assert 'could not stream' in out.stderr, out.stderr
                finally:
                    unreadable.chmod(0o700)
            print('Runner archive permission checks: ok (unprivileged tar; root lost+found excluded, other read errors fail)')
        else:
            print('Runner archive permission checks: rendered tar arguments only (UID 0 bypasses permissions)')
    finally:
        recovery.chmod(0o700)

    # API failure/malformed JSON must be a failed stats check, and an unhealthy
    # running container must not be counted as healthy.
    run('healthcheck', '''
compose() { return 1; }
check_hindsight_stats
[ "${FAILURES[hindsight-stats]}" = 'stats API unavailable or invalid' ]
FAILURES=()
compose() { printf '%s' '{"Service":"hermes","State":"running","Health":"unhealthy"}'; }
check_containers
[ "${FAILURES[container:hermes]}" = state=unhealthy ]
FAILURES=()
compose() { printf '%s' 'invalid json'; }
check_containers
[ "${FAILURES[container:hermes]}" = state=invalid ]
''')

    # Exercise notification state over 12 hours; after a 6h re-notification,
    # the next 5min tick stays silent. Restore's no-notify retries alter no state.
    state = root / 'health-state'
    notices = root / 'notices'
    common = f'''
STATE_DIR={json.dumps(str(root))}
STATE_FILE={json.dumps(str(state))}
notify_operator() {{ printf '%s\\n' "$*" >> {json.dumps(str(notices))}; }}
deadman_ping() {{ :; }}
load_env_file() {{ :; }}
id() {{ printf '0'; }}
date() {{ printf '%s' "$FIXTURE_NOW"; }}
check_containers() {{ record_failure container:hermes fixture; }}
check_hindsight_ready() {{ :; }}
check_tei() {{ :; }}
check_inference() {{ :; }}
check_runner() {{ :; }}
check_cdp() {{ :; }}
check_gateway() {{ :; }}
check_cron() {{ :; }}
check_hindsight_stats() {{ :; }}
'''
    for now, count in [(100000,1),(100300,1),(121600,2),(121900,2),(143200,3)]:
        run('healthcheck', common + f'FIXTURE_NOW={now}\nmain\n', success=False)
        assert len(notices.read_text().splitlines()) == count
    before = state.read_bytes()
    run('healthcheck', common + 'FIXTURE_NOW=200000\nmain --no-notify\n', success=False)
    assert state.read_bytes() == before
    assert len(notices.read_text().splitlines()) == 3

    # Explicit fail (not just set -e) must notify and remove private work.
    for name in ('backup', 'restore', 'export', 'rebuild-memory'):
        private = root / f'private-{name}'
        private.mkdir()
        if name == 'backup':
            setup = f'BACKUP_WORK_DIR={json.dumps(str(private))}'
        elif name == 'restore':
            setup = f'RESTORE_WORK_DIR={json.dumps(str(private))}'
        elif name == 'rebuild-memory':
            private.rmdir()
            private.write_text('fixture conversation')
            setup = f'REBUILD_STAGED={json.dumps(str(private))}'
        else:
            setup = ': '
        out = run(name, setup + '''
notify_operator() { printf 'notified\n'; }
fail 'injected failure'
''', success=False)
        assert out.stdout == 'notified\n', (name, out)
        if name != 'export':
            assert not private.exists(), name

    # A failed Compose shutdown must not delete the data under a still-running
    # scratch database. Decrypted working copies are independently cleaned.
    scratch = root / 'scratch-data'
    scratch.mkdir()
    override = root / 'scratch-override.yaml'
    override.touch()
    work = root / 'restore-work'
    work.mkdir()
    run('restore', f'''
SCRATCH_PROJECT=fixture
SCRATCH_OVERRIDE={json.dumps(str(override))}
SCRATCH_DATA_DIR={json.dumps(str(scratch))}
RESTORE_WORK_DIR={json.dumps(str(work))}
scratch_compose() {{ return 1; }}
cleanup
SCRATCH_PROJECT=''
''', success=False)
    assert scratch.exists() and override.exists()
    assert not work.exists()

    # Safety snapshot: tar warning exit 1 must stop before any DB destruction.
    for tar_rc in (1, 2):
        marker = root / f'destructive-{tar_rc}'
        out = run('restore', f'''
notify_operator() {{ :; }}
ASSUME_YES=1
SAFETY_DIR={json.dumps(str(root / ("safety-" + str(tar_rc))))}
compose() {{
    case "$*" in
        *DROP*) touch {json.dumps(str(marker))} ;;
    esac
}}
tar() {{ return {tar_rc}; }}
restore_production {json.dumps(str(root))}
''', success=False)
        assert not marker.exists()
        assert 'safety Hermes snapshot failed' in out.stderr

    # Portable export preserves the API's real event-date fields. A failed raw
    # document fetch must fail the export rather than publish a null-text success.
    import contextlib
    import io
    import re
    from unittest.mock import patch
    source = (role / 'homelab-agent-export.sh.j2').read_text()
    snippets = re.findall(r"<<'PY'[^\n]*\n(.*?)\nPY", source, re.S)
    snippets = [block.split("\n", 1)[1] if block.lstrip().startswith("|| fail") else block for block in snippets]
    memory = {"id":"m1", "text":"架空の事実", "fact_type":"world",
              "occurred_start":"2026-03-05T00:30:00+09:00",
              "occurred_end":"2026-03-05T01:30:00+09:00", "mentioned_at":"2026-03-05T00:31:00+09:00"}
    def response(payload):
        return io.BytesIO(json.dumps(payload).encode())
    output = io.StringIO()
    with patch('sys.argv', ['export', 'fixture']), patch('urllib.request.urlopen', return_value=response({"items":[memory], "total":1})), contextlib.redirect_stdout(output):
        exec(snippets[0], {})
    exported = json.loads(output.getvalue())
    assert all(exported[key] == memory[key] for key in ('occurred_start','occurred_end','mentioned_at'))
    def documents(url, **kwargs):
        if url.endswith('/documents?limit=100&offset=0'):
            return response({"items":[{"id":"doc1"}], "total":1})
        raise OSError('injected raw-document fetch failure')
    with patch('sys.argv', ['export', 'fixture']), patch('urllib.request.urlopen', side_effect=documents):
        try:
            exec(snippets[1], {})
        except OSError:
            pass
        else:
            raise AssertionError('raw document retrieval failure ignored')

    # The public wrapper must apply the managed policy to a new bank before
    # retain; --dry-run neither changes the bank nor discards its checkpoint.
    input_file = root / 'sessions.jsonl'
    input_file.write_text('{"id":"fixture","messages":[]}\n')
    helper = root / 'worker.py'
    helper.touch()
    policy = root / 'policy.py'
    policy.write_text('# synthetic bank policy')
    events = root / 'rebuild-events'
    setup = f'''
HELPER={json.dumps(str(helper))}
BANK_HELPER={json.dumps(str(policy))}
REBUILD_DIR={json.dumps(str(root / 'rebuild'))}
id() {{ printf 0; }}
notify_operator() {{ :; }}
compose() {{
    case "$*" in
        'exec -T hindsight id -u') printf '{os.getuid()}' ;;
        'exec -T hindsight id -g') printf '{os.getgid()}' ;;
        'exec -T hindsight python3 - new-bank') printf 'policy\\n' >> {json.dumps(str(events))}; cat >/dev/null ;;
        run*) printf 'worker\\n' >> {json.dumps(str(events))} ;;
        *) return 88 ;;
    esac
}}
'''
    run('rebuild-memory', setup + f'main --from {json.dumps(str(input_file))} --bank new-bank\n')
    assert events.read_text().splitlines() == ['policy', 'worker']
    import hashlib
    progress = root / 'rebuild' / ('new-bank-' + hashlib.sha256(input_file.read_bytes()).hexdigest()[:16])
    checkpoint = progress / 'progress.json'
    checkpoint.write_text('{"fixture":"must remain unchanged"}')
    events.unlink()
    run('rebuild-memory', setup + f'main --from {json.dumps(str(input_file))} --bank new-bank --dry-run --fresh\n')
    assert events.read_text().splitlines() == ['worker']
    assert checkpoint.read_text() == '{"fixture":"must remain unchanged"}'
    assert not (progress / 'input.jsonl').exists()

    # Render all shell templates, syntax-check and shellcheck the actual output.
    paths = []
    for name in ('backup','restore','export','rebuild-memory','healthcheck'):
        path = root / f'rendered-{name}.sh'
        path.write_text(render(name))
        subprocess.run(['bash','-n',str(path)], check=True)
        paths.append(path)
    # shellcheck is provided by the normal make target/toolbox, not assumed on
    # the management host. Syntax above also covers Python heredoc placement.
print('Agent ops behavioral fixture: ok')
PY
