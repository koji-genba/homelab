"""Dagu の JSON パラメータを検証し、共有 AI 保存先へ直列で取得する。"""
import fcntl
from contextlib import ExitStack
import json
import os
from pathlib import Path
import re
import shlex
import signal
import stat
import subprocess
import sys
import time


class InvalidInput(ValueError):
    pass


def invalid(name, reason, value):
    received = repr(value)
    if len(received) > 200:
        received = received[:197] + '...'
    return InvalidInput(f'{name}: {reason}; got {received}')


def text(value, name, limit, strip=False):
    received = value
    if strip and isinstance(value, str):
        value = value.strip()
    if not isinstance(value, str) or len(value) > limit or any(ord(c) < 32 or ord(c) == 127 for c in value):
        raise invalid(name, 'invalid string', received)
    return value


def patterns(value, name):
    value = text(value, name, 4096)
    if not value.strip():
        return []
    result = [p.strip() for p in value.split(',')]
    if len(result) > 32:
        raise invalid(name, 'at most 32 patterns', value)
    for part in result:
        if not part or len(part) > 256 or part.startswith(('-', '/')) or '..' in part.split('/'):
            raise invalid(name, 'invalid pattern', value)
    return result


def validate(params):
    if not isinstance(params, dict) or set(params) - {'repo_id', 'repo_type', 'revision', 'include', 'exclude', 'max_workers'}:
        raise InvalidInput('unknown parameters')
    repo = text(params.get('repo_id', ''), 'repo_id', 193, strip=True)
    parts = repo.split('/')
    if len(parts) != 2 or any(not re.fullmatch(r'[A-Za-z0-9_][A-Za-z0-9_.-]{0,94}[A-Za-z0-9_]|[A-Za-z0-9_]', p)
                              or '--' in p or '..' in p or p.endswith('.git') for p in parts):
        raise invalid('repo_id', 'expected namespace/name (1..96 characters per component)', params.get('repo_id'))
    kind = params.get('repo_type', 'model')
    if kind not in ('model', 'dataset'):
        raise invalid('repo_type', 'expected model or dataset', params.get('repo_type'))
    revision = text(params.get('revision', 'main'), 'revision', 128, strip=True) or 'main'
    if not re.fullmatch(r'[A-Za-z0-9_./-]+', revision) or revision.startswith(('-', '/')) or revision.endswith('/') or '..' in revision or '//' in revision:
        raise invalid('revision', 'invalid revision', params.get('revision'))
    if '--' in revision:
        raise invalid('revision', 'branches containing -- must use a commit SHA instead', params.get('revision'))
    workers = params.get('max_workers', 1)
    if isinstance(workers, str) and re.fullmatch('[1-4]', workers):
        workers = int(workers)
    if type(workers) is not int or not 1 <= workers <= 4:
        raise invalid('max_workers', 'expected integer 1..4', params.get('max_workers'))
    return dict(repo_id=repo, repo_type=kind, revision=revision, max_workers=workers,
                include=patterns(params.get('include', ''), 'include'),
                exclude=patterns(params.get('exclude', ''), 'exclude'))


def destination(params, ai_root):
    root = ai_root / ('models' if params['repo_type'] == 'model' else 'datasets')
    namespace, name = params['repo_id'].split('/')
    if params['revision'] != 'main':
        name += '@' + params['revision'].replace('/', '--')
    target = root / 'huggingface' / namespace / name
    if not target.resolve().is_relative_to(root.resolve()):
        raise InvalidInput('destination escapes storage root')
    # Reject symlinks even when their current target happens to be inside the root.
    if any(p.is_symlink() for p in [root, *target.parents, target] if p.is_relative_to(root)):
        raise InvalidInput('destination contains symlink')
    return root, target


def preflight(ai_root, root, target):
    if (ai_root / '.homelab-export').read_text().strip() != 'ai':
        raise InvalidInput('AI export marker must be ai')
    # ismount() misses bind mounts on the same device; mountinfo lists every bind.
    mounts = {}
    for line in Path('/proc/self/mountinfo').read_text().splitlines():
        before, after = line.split(' - ', 1)
        mounts[before.split()[4]] = after.split()[0]
    for path in (ai_root, root):
        fs = mounts.get(str(path))
        allowed = os.environ.get('HFDL_MOUNT_TYPES', 'nfs,nfs4').split(',')
        if fs not in allowed:
            raise InvalidInput(f'{path}: expected separate mount of type {allowed}, got {fs}')
    if not root.is_dir() or not os.access(root, os.W_OK):
        raise InvalidInput(f'{root}: storage is not writable')
    destination_check = target.resolve()
    if not destination_check.is_relative_to(root.resolve()):
        raise InvalidInput('destination escapes storage root')


def argv(params, target):
    command = [os.environ.get('HFDL_HF_BIN', '/opt/hf/bin/hf'), 'download',
               '--repo-type', params['repo_type'], '--revision', params['revision'],
               '--local-dir', str(target), '--max-workers', str(params['max_workers'])]
    for name in ('include', 'exclude'):
        for pattern in params[name]:
            command += ['--' + name, pattern]
    return command + ['--', params['repo_id']]


def check_target(target):
    flags = os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW | os.O_CLOEXEC

    def visit(directory, path):
        with os.scandir(directory) as entries:
            for entry in entries:
                current = path / entry.name
                info = entry.stat(follow_symlinks=False)
                if stat.S_ISDIR(info.st_mode):
                    child = os.open(entry.name, flags, dir_fd=directory)
                    try:
                        visit(child, current)
                    finally:
                        os.close(child)
                elif not stat.S_ISREG(info.st_mode):
                    raise InvalidInput(f'{current}: symlink or special file in destination')

    try:
        try:
            directory = os.open(target, flags)
        except FileNotFoundError:
            return
        try:
            visit(directory, target)
        finally:
            os.close(directory)
    except (OSError, RecursionError) as error:
        raise InvalidInput(f'{target}: destination scan failed: {error}') from error


def cleanup_incomplete(target):
    removed = total_bytes = 0
    opened = False
    flags = os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW | os.O_CLOEXEC

    def warning(error):
        print(f'Incomplete cleanup warning: {error}', file=sys.stderr, flush=True)

    def visit(directory):
        nonlocal removed, total_bytes
        with os.scandir(directory) as entries:
            for entry in entries:
                try:
                    info = entry.stat(follow_symlinks=False)
                    if stat.S_ISDIR(info.st_mode):
                        child = os.open(entry.name, flags, dir_fd=directory)
                        try:
                            visit(child)
                        finally:
                            os.close(child)
                    elif stat.S_ISREG(info.st_mode) and entry.name.endswith('.incomplete'):
                        os.unlink(entry.name, dir_fd=directory)
                        removed += 1
                        total_bytes += info.st_size
                except OSError as error:
                    warning(error)

    try:
        # Open every component without following symlinks. All traversal and
        # unlinks are relative to directory descriptors below this cache root.
        with ExitStack() as stack:
            directory = os.open('/', flags)
            stack.callback(os.close, directory)
            cache = target.absolute() / '.cache/huggingface/download'
            for part in cache.parts[1:]:
                directory = os.open(part, flags, dir_fd=directory)
                stack.callback(os.close, directory)
            opened = True
            visit(directory)
    except FileNotFoundError:
        pass
    except (OSError, RecursionError) as error:
        warning(error)
    finally:
        if opened:
            print(f'Incomplete cleanup: removed {removed} files ({total_bytes} bytes)', flush=True)


def main():
    # Raising on termination interrupts lock waits too. Dagu signals the process
    # group; also forward explicitly and reap hf before closing the lock descriptor.
    child = None
    finishing = False

    def stop(signum, _frame):
        if not finishing:
            raise InterruptedError(signum)

    for signum in (signal.SIGTERM, signal.SIGINT):
        signal.signal(signum, stop)
    try:
        params = validate(json.loads(os.environ.get('DAG_PARAMS_JSON', '{}')))
        ai_root = Path(os.environ.get('HFDL_AI_ROOT', '/data/ai'))
        root, target = destination(params, ai_root)
        preflight(ai_root, root, target)
        lock_path = Path(os.environ.get('HFDL_LOCK_PATH', '/var/lib/dagu/hf-download.lock'))
        with lock_path.open('a') as lock:
            print('Waiting for download lock', flush=True)
            while True:
                try:
                    fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
                    break
                except BlockingIOError:
                    time.sleep(1)
            # A waiting job must check again after a mount change.
            preflight(ai_root, root, target)
            destination(params, ai_root)
            cleanup_incomplete(target)
            command = argv(params, target)
            env = os.environ.copy()
            env.pop('HF_TOKEN', None)
            env.pop('HUGGING_FACE_HUB_TOKEN', None)
            token = Path(env.get('HF_TOKEN_PATH', '/run/secrets/hf-downloader/hf-token'))
            if not token.is_file():
                raise InvalidInput('token file is missing')
            if token.stat().st_size == 0:
                env.pop('HF_TOKEN_PATH', None)
                env['HF_HUB_DISABLE_IMPLICIT_TOKEN'] = '1'
            env.update(HF_HUB_DISABLE_TELEMETRY='1', HF_HUB_DISABLE_PROGRESS_BARS='1',
                       HF_HUB_DISABLE_UPDATE_CHECK='1')
            check_target(target)
            print(f'Destination: {target}\nExecuting: {shlex.join(command)}', flush=True)
            try:
                child = subprocess.Popen(command, shell=False, env=env, umask=0, pass_fds=(lock.fileno(),))
                return child.wait()
            finally:
                # A repeated stop signal must not interrupt reaping or cleanup.
                finishing = True
                try:
                    if child is not None and child.poll() is None:
                        child.terminate()
                        try:
                            child.wait(timeout=30)
                        except subprocess.TimeoutExpired:
                            child.kill()
                            child.wait()
                finally:
                    try:
                        check_target(target)
                    except InvalidInput as error:
                        print(f'Destination scan warning: {error}', file=sys.stderr, flush=True)
                    cleanup_incomplete(target)
    except InterruptedError as error:
        print('Download stopped', flush=True)
        return 128 + error.args[0]
    except (InvalidInput, ValueError, OSError) as error:
        print(f'Download refused: {error}', file=sys.stderr, flush=True)
        return 1


if __name__ == '__main__':
    sys.exit(main())
