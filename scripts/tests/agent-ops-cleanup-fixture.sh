#!/bin/sh
# Run the real EXIT cleanup functions after their caller's locals go out of
# scope. Docker is replaced with a recorder; all files are inside TemporaryDir.
set -eu
python3 <<'PY'
import pathlib
import subprocess
import tempfile

role = pathlib.Path('files/infrastructure/ansible/agent/roles/agent_ops/templates')
restore = (role / 'homelab-agent-restore.sh.j2').read_text()
backup = (role / 'homelab-agent-backup.sh.j2').read_text()
restore_cleanup = restore[restore.index('\ncleanup() {'):restore.index('\nmain() {')]
backup_cleanup = next(line.strip() for line in backup.splitlines() if line.strip().startswith('cleanup() {'))
for mode, cleanup in [('restore', restore_cleanup), ('backup', backup_cleanup)]:
    for exit_code in [0, 7]:
        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory)
            work, data, override, marker = [root / name for name in ['work', 'data', 'override', 'down-called']]
            work.mkdir()
            (work / 'decrypted-test-material').write_text('fixture only')
            data.mkdir()
            override.touch()
            script = '''set -eu
log() { :; }
scratch_compose() { printf '%s' "$*" > "$MARKER"; }
'''+cleanup+'''
main() {
    local work="$WORK" data_dir="$DATA" override="$OVERRIDE" project=fixture
    RESTORE_WORK_DIR="$work"
    BACKUP_WORK_DIR="$work"
    SCRATCH_PROJECT="$project"
    SCRATCH_DATA_DIR="$data_dir"
    SCRATCH_OVERRIDE="$override"
    trap cleanup EXIT
}
main
exit "$EXIT_CODE"
'''
            import os
            env = dict(os.environ, WORK=str(work), DATA=str(data), OVERRIDE=str(override), MARKER=str(marker), EXIT_CODE=str(exit_code))
            result = subprocess.run(['bash', '-c', script], env=env, text=True, capture_output=True)
            assert result.returncode == exit_code, (mode, result.stderr)
            assert not work.exists(), (mode, 'decrypted work leaked')
            if mode == 'restore':
                assert not data.exists() and not override.exists()
                assert marker.read_text() == 'fixture '+str(override)+' down -v --remove-orphans'
print('Agent ops EXIT cleanup fixture: ok')
PY
