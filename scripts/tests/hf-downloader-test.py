"""HF 入力境界・保存先・実行前拒否の回帰試験（標準ライブラリのみ）。"""
import importlib.util
import fcntl
import io
import json
import os
from pathlib import Path
import tempfile
import unittest
from contextlib import redirect_stdout, redirect_stderr
from types import SimpleNamespace
from unittest.mock import patch

MODULE = Path(__file__).resolve().parents[2] / 'files/services/compose/hf-downloader/bin/hf_download.py'
spec = importlib.util.spec_from_file_location('hf_download', MODULE)
hf = importlib.util.module_from_spec(spec)
spec.loader.exec_module(hf)



class DownloadTest(unittest.TestCase):
    def setUp(self):
        # Existing lifecycle fixtures must never query the Hub, even if the
        # host happens to have huggingface_hub installed.
        self.original_inventory = hf.list_targets
        self.inventory = patch.object(hf, 'list_targets', return_value={})
        self.inventory.start()
        self.addCleanup(self.inventory.stop)

    def test_inventory_uses_official_api_and_snapshot_filters(self):
        class RepoFile:
            def __init__(self, name, size):
                self.path, self.size = name, size
        entries = [RepoFile('sub/config.json', 42), SimpleNamespace(path='sub'), RepoFile('model.bin', 99)]
        from unittest.mock import Mock
        api = Mock()
        api.list_repo_tree.return_value = iter(entries)
        filter_objects = Mock(return_value=entries[:1])
        modules = {'huggingface_hub': SimpleNamespace(HfApi=lambda: api, RepoFile=RepoFile),
                   'huggingface_hub.utils': SimpleNamespace(filter_repo_objects=filter_objects)}
        params = hf.validate(dict(repo_id='a/b', repo_type='dataset', revision='refs/pr/1',
                                  include='*.json', exclude='*.tmp'))
        with patch.dict('sys.modules', modules):
            result = self.original_inventory(params)
        self.assertEqual(result, {'sub/config.json': 42})
        api.list_repo_tree.assert_called_once_with('a/b', recursive=True, repo_type='dataset', revision='refs/pr/1')
        args, kwargs = filter_objects.call_args
        self.assertEqual(list(args[0]), [entries[0], entries[2]])
        self.assertEqual(kwargs['allow_patterns'], ['*.json'])
        self.assertEqual(kwargs['ignore_patterns'], ['*.tmp'])
        self.assertEqual(kwargs['key'](entries[0]), 'sub/config.json')

    def test_progress_sizes_current_and_unrelated_files(self):
        params = hf.validate({'repo_id': 'a/b'})
        # Verified against huggingface_hub 2.4.0's _short_hash, independently
        # of our key function, including the per-download uuid suffix.
        self.assertEqual(hf.incomplete_key('model.safetensors'), 'xGOKKLRSlIhH692hSVvI1-gpoa8=')
        key = 'sub/xGOKKLRSlIhH692hSVvI1-gpoa8='
        files = {'config.json': 2_000_000, 'unrelated.bin': 9_000_000_000,
                 '.cache/huggingface/download/' + key + '.etag.ab12cd34.incomplete': 100_000_000,
                 '.cache/huggingface/download/unknown.etag.incomplete': 123,
                 '.cache/huggingface/download/config.json.metadata': 55}
        amount, done, current = hf.progress_amount(files, {'config.json': 2_000_000,
                                  'sub/model.safetensors': 1_000_000_000}, params, {})
        self.assertEqual((amount, done, current), (102_000_123, 1, 'sub/model.safetensors'))
        self.assertEqual(hf.progress_amount({'.cache/other': 42}, {'.cache/other': 42}, params, {}),
                         (42, 1, None))
        files['sub/model.safetensors'] = files.pop('.cache/huggingface/download/' + key + '.etag.ab12cd34.incomplete')
        self.assertEqual(hf.progress_amount(files, {'sub/model.safetensors': 1_000_000_000}, params, {}),
                         (100_000_123, 1, None))

    def test_progress_unknown_incomplete_format_counts_without_current(self):
        params = hf.validate({'repo_id': 'a/b'})
        targets = {'config.json': 200_000_000, 'model.bin': 800_000_000}
        initial = {'config.json': 200_000_000, 'unrelated.bin': 9_000_000_000}
        name = '.cache/huggingface/download/sub/new-upstream-format.incomplete'
        partial = {**initial, name: 400_000_000}
        over_total = {**initial, name: 1_200_000_000}
        self.assertEqual(hf.progress_amount(partial, targets, params, initial),
                         (600_000_000, 1, None))
        output = io.StringIO()
        with patch.object(hf, 'list_targets', return_value=targets), \
             patch.object(hf, 'scan_progress', side_effect=[initial, partial, over_total]), \
             patch.object(hf.time, 'monotonic', side_effect=[0, 10, 20]), redirect_stdout(output):
            progress = hf.Progress(Path('/unused'), params)
            progress.emit()
            progress.emit()
        lines = output.getvalue().splitlines()
        self.assertIn('0.6 / 1.0 GB (60.0%)  files 1/2  now 40 MB/s  avg 40 MB/s  ETA 1m', lines[0])
        self.assertIn('(100.0%)  files 1/2  now 80 MB/s  avg 60 MB/s  ETA 0m', lines[1])
        self.assertNotIn('current', output.getvalue())

    def test_progress_scan_never_follows_symlinks(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            (root / 'repo/sub').mkdir(parents=True)
            (root / 'outside').mkdir()
            (root / 'outside/secret').write_bytes(b'ignored')
            (root / 'repo/sub/file').write_bytes(b'ok')
            (root / 'repo/link').symlink_to(root / 'outside', target_is_directory=True)
            (root / 'repo/file-link').symlink_to(root / 'outside/secret')
            os.mkfifo(root / 'repo/fifo')
            self.assertEqual(hf.scan_progress(root / 'repo'), {'sub/file': 2})
            with self.assertRaises(OSError):
                hf.scan_progress(root / 'repo/link')
            self.assertEqual(hf.scan_progress(root / 'missing'), {})

    def test_progress_baseline_rates_eta_and_final(self):
        params = hf.validate({'repo_id': 'a/b'})
        targets = {'old.bin': 400_000_000, 'sub/new.bin': 600_000_000}
        initial = {'old.bin': 400_000_000, 'other.bin': 5_000_000_000}
        partial = {**initial, '.cache/huggingface/download/' + hf.incomplete_key('sub/new.bin') + '.hash.ab12cd34.incomplete': 200_000_000}
        final = {**initial, 'sub/new.bin': 600_000_000}
        output = io.StringIO()
        with patch.object(hf, 'list_targets', return_value=targets), \
             patch.object(hf, 'scan_progress', side_effect=[initial, initial, partial, partial, final]), \
             patch.object(hf.time, 'monotonic', side_effect=[0, 0, 10, 20, 30]), redirect_stdout(output):
            progress = hf.Progress(Path('/unused'), params)
            progress.emit()
            progress.emit()
            progress.emit()
            progress.finish(True)
        lines = output.getvalue().splitlines()
        self.assertIn('0.4 / 1.0 GB (40.0%)  files 1/2  now 0 MB/s  avg 0 MB/s  ETA --', lines[0])
        self.assertIn('0.6 / 1.0 GB (60.0%)  files 1/2  now 20 MB/s  avg 20 MB/s  ETA 1m  current sub/new.bin', lines[1])
        self.assertIn('now 0 MB/s  avg 10 MB/s  ETA --', lines[2])
        self.assertIn('(100.0%)  files 2/2', lines[3])
        self.assertIn('avg 20 MB/s', lines[3])  # 600MB / 30s; excludes existing 400MB.

    def test_progress_inventory_failure_still_reports_bytes(self):
        params = hf.validate(dict(repo_id='a/b', include='data/,*.json', exclude='*.tmp'))
        initial = {'unrelated.json': 9_000_000_000}
        final = {**initial, 'config.json': 100_000_000, 'data/a.bin': 200_000_000,
                 'other.bin': 9_000_000_000, 'data/ignored.tmp': 9_000_000_000,
                 '.cache/huggingface/download/hash.etag.incomplete': 100_000_000}
        output, errors = io.StringIO(), io.StringIO()
        with patch.object(hf, 'list_targets', side_effect=RuntimeError('never print remote exception')), \
             patch.object(hf, 'scan_progress', side_effect=[initial, final]), \
             patch.object(hf.time, 'monotonic', side_effect=[0, 10]), \
             redirect_stdout(output), redirect_stderr(errors):
            progress = hf.Progress(Path('/unused'), params)
            progress.emit()
            progress.warning('second warning')
        self.assertIn('Progress: 0.4 GB  now 40 MB/s  avg 40 MB/s  ETA --', output.getvalue())
        self.assertNotIn('%', output.getvalue())
        self.assertEqual(errors.getvalue().count('Progress warning:'), 1)
        self.assertNotIn('never print', errors.getvalue())

    def test_progress_errors_warn_once_and_do_not_escape(self):
        params = hf.validate({'repo_id': 'a/b'})
        errors = io.StringIO()
        with patch.object(hf, 'scan_progress', side_effect=[{}, OSError('broken')]), redirect_stderr(errors):
            progress = hf.Progress(Path('/unused'), params)
            progress.start()
            progress.finish(False)
        self.assertEqual(errors.getvalue().count('Progress warning:'), 1)
        self.assertFalse(progress.enabled)
        for interval in ('0', '-1', 'nan', 'inf', 'invalid'):
            with self.subTest(interval=interval), patch.dict(os.environ, {'HFDL_PROGRESS_INTERVAL': interval}), \
                 redirect_stderr(io.StringIO()):
                self.assertFalse(hf.Progress(Path('/unused'), params).enabled)

    def test_progress_background_stops_before_final_sampling(self):
        with patch.object(hf, 'scan_progress', return_value={}), \
             patch.dict(os.environ, {'HFDL_PROGRESS_INTERVAL': '0.001'}), redirect_stdout(io.StringIO()):
            progress = hf.Progress(Path('/unused'), hf.validate({'repo_id': 'a/b'}))
            progress.start()
            progress.finish(True)
        self.assertFalse(progress.thread.is_alive())
        self.assertTrue(progress.stopped.is_set())

    def test_progress_failure_preserves_exit_status_signals_and_cleanup(self):
        for outcome in (0, 7, 'stop'):
            for failure in ('inventory', 'baseline', 'sample'):
                with self.subTest(outcome=outcome, failure=failure), tempfile.TemporaryDirectory() as temp:
                    ai = Path(temp)
                    _, target = hf.destination(hf.validate({'repo_id': 'a/b'}), ai)
                    token = ai / 'token'
                    token.touch()
                    def launch(*args, **kwargs):
                        self.assertNotIn('HF_TOKEN', kwargs['env'])
                        self.assertNotIn('HUGGING_FACE_HUB_TOKEN', kwargs['env'])
                        self.assertEqual(os.environ['HF_HUB_DISABLE_IMPLICIT_TOKEN'], '1')
                        self.assertNotIn('HF_TOKEN_PATH', os.environ)
                        cache = target / '.cache/huggingface/download'
                        cache.mkdir(parents=True)
                        (cache / 'partial.incomplete').write_text('partial')
                        return SimpleNamespace(wait=wait, terminate=lambda: None,
                                               poll=lambda: None if outcome == 'stop' else outcome)
                    def wait(timeout=None):
                        if outcome == 'stop' and timeout is None:
                            raise InterruptedError(15)
                        return -15 if outcome == 'stop' else outcome
                    scans = OSError('scan failed') if failure == 'baseline' else ([{}, OSError('scan failed')] if failure == 'sample' else {})
                    errors = io.StringIO()
                    with patch.dict(os.environ, {'DAG_PARAMS_JSON': '{"repo_id":"a/b"}',
                         'HFDL_AI_ROOT': temp, 'HFDL_LOCK_PATH': str(ai / 'lock'), 'HF_TOKEN_PATH': str(token),
                         'HF_TOKEN': 'fixture-only', 'HUGGING_FACE_HUB_TOKEN': 'fixture-only'}), \
                         patch.object(hf, 'preflight'), patch.object(hf.subprocess, 'Popen', side_effect=launch), \
                         patch.object(hf, 'scan_progress', **({'side_effect': scans} if failure != 'inventory' else {'return_value': {}})), \
                         patch.object(hf, 'list_targets', **({'side_effect': RuntimeError('inventory')} if failure == 'inventory' else {'return_value': {}})), \
                         redirect_stdout(io.StringIO()), redirect_stderr(errors):
                        self.assertEqual(hf.main(), 143 if outcome == 'stop' else outcome)
                    self.assertEqual(errors.getvalue().count('Progress warning:'), 1)
                    self.assertFalse(list(target.rglob('*.incomplete')))
                    if outcome != 0:
                        self.assertFalse(target.exists())

    def test_progress_eta_hours(self):
        self.assertEqual(hf.format_eta(11340), '3h09m')
        self.assertEqual(hf.format_eta(0), '0m')
        self.assertEqual(hf.format_eta(None), '--')


    def test_cleanup_only_incomplete_files(self):
        with tempfile.TemporaryDirectory() as temp:
            target = Path(temp) / 'repo'
            cache = target / '.cache/huggingface/download'
            (cache / 'subdir').mkdir(parents=True)
            (cache / 'old.incomplete').write_bytes(b'abc')
            (cache / 'subdir/old.incomplete').write_bytes(b'12345')
            keep = [cache / 'file.metadata', cache / 'file.lock',
                    cache / 'file.incomplete.extra', target / 'other.incomplete']
            for file in keep:
                file.write_text('keep')
            output = io.StringIO()
            with redirect_stdout(output):
                hf.cleanup_incomplete(target)
            self.assertFalse(list(cache.rglob('*.incomplete')))
            self.assertTrue(all(file.read_text() == 'keep' for file in keep))
            self.assertEqual(output.getvalue(), 'Incomplete cleanup: removed 2 files (8 bytes)\n')

    def test_cleanup_never_follows_symlinks(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            target = root / 'repo'
            cache = target / '.cache/huggingface/download'
            cache.mkdir(parents=True)
            outside = root / 'outside'
            outside.mkdir()
            external = outside / 'keep.incomplete'
            external.write_text('keep')
            external_files = [external, outside / 'huggingface/download/keep.incomplete',
                              outside / 'download/keep.incomplete']
            for file in external_files[1:]:
                file.parent.mkdir(parents=True)
                file.write_text('keep')
            (cache / 'linked.incomplete').symlink_to(external)
            (cache / 'linked-directory').symlink_to(outside, target_is_directory=True)
            hf.cleanup_incomplete(target)
            self.assertEqual(external.read_text(), 'keep')
            self.assertTrue((cache / 'linked.incomplete').is_symlink())
            self.assertTrue((cache / 'linked-directory').is_symlink())
            # Refuse symlinks in any cache/target component, not just leaf entries.
            for part in ('.cache', '.cache/huggingface', '.cache/huggingface/download'):
                repo = root / part.replace('/', '-')
                link = repo / part
                link.parent.mkdir(parents=True)
                link.symlink_to(outside, target_is_directory=True)
                with redirect_stderr(io.StringIO()):
                    hf.cleanup_incomplete(repo)
                self.assertTrue(all(file.read_text() == 'keep' for file in external_files))
            alias = root / 'repo-alias'
            alias.symlink_to(target, target_is_directory=True)
            (cache / 'inside.incomplete').write_text('keep')
            with redirect_stderr(io.StringIO()):
                hf.cleanup_incomplete(alias)
            self.assertEqual(external.read_text(), 'keep')
            self.assertEqual((cache / 'inside.incomplete').read_text(), 'keep')

    def test_cleanup_missing_directory_and_failure(self):
        with tempfile.TemporaryDirectory() as temp:
            target = Path(temp)
            hf.cleanup_incomplete(target)
            cache = target / '.cache/huggingface/download'
            cache.mkdir(parents=True)
            failed = cache / 'old.incomplete'
            failed.touch()
            warning = io.StringIO()
            with patch.object(hf.os, 'unlink', side_effect=PermissionError('fixture denied')), redirect_stderr(warning):
                hf.cleanup_incomplete(target)
            self.assertTrue(failed.exists())
            self.assertIn('Incomplete cleanup warning: fixture denied', warning.getvalue())

    def test_cleanup_under_lock_before_start_and_after_reaping(self):
        for outcome in (0, 1, 'stop'):
            with self.subTest(outcome=outcome), tempfile.TemporaryDirectory() as temp:
                ai = Path(temp)
                params = hf.validate({'repo_id': 'org/repo'})
                _, target = hf.destination(params, ai)
                cache = target / '.cache/huggingface/download'
                cache.mkdir(parents=True)
                (cache / 'old.incomplete').write_text('old')
                (cache / 'keep.metadata').write_text('keep')
                token = ai / 'token'
                token.touch()
                lock_path = ai / 'download.lock'
                reaped = False

                def wait(timeout=None):
                    nonlocal reaped
                    if outcome == 'stop' and timeout is None:
                        raise InterruptedError(15)
                    reaped = True
                    return 143 if outcome == 'stop' else outcome

                def launch(*args, **kwargs):
                    self.assertEqual(kwargs['env']['HF_HUB_DISABLE_UPDATE_CHECK'], '1')
                    self.assertFalse((cache / 'old.incomplete').exists())
                    (cache / 'new.incomplete').write_text('new')
                    return SimpleNamespace(wait=wait, poll=lambda: None if outcome == 'stop' else outcome,
                                           terminate=lambda: None)

                original_cleanup = hf.cleanup_incomplete
                calls = []

                def cleanup(path):
                    with lock_path.open('a') as other:
                        with self.assertRaises(BlockingIOError):
                            fcntl.flock(other, fcntl.LOCK_EX | fcntl.LOCK_NB)
                    if calls:
                        self.assertTrue(reaped)
                    calls.append(path)
                    original_cleanup(path)

                with patch.dict(os.environ, {'DAG_PARAMS_JSON': '{"repo_id":"org/repo"}',
                     'HFDL_AI_ROOT': temp, 'HFDL_LOCK_PATH': str(lock_path), 'HF_TOKEN_PATH': str(token),
                     'HF_HUB_DISABLE_UPDATE_CHECK': '0'}), \
                     patch.object(hf, 'preflight'), patch.object(hf, 'cleanup_incomplete', side_effect=cleanup), \
                     patch.object(hf.subprocess, 'Popen', side_effect=launch):
                    self.assertEqual(hf.main(), 143 if outcome == 'stop' else outcome)
                self.assertEqual(calls, [target, target])
                self.assertFalse(list(cache.glob('*.incomplete')))
                self.assertEqual((cache / 'keep.metadata').read_text(), 'keep')

    def test_empty_destination_cleanup_after_hf(self):
        cases = ('failed', 'stopped', 'file', 'cache-files', 'existing-target', 'existing-namespace', 'success', 'denied')
        for case in cases:
            with self.subTest(case=case), tempfile.TemporaryDirectory() as temp:
                ai = Path(temp)
                _, target = hf.destination(hf.validate({'repo_id': 'org/repo'}), ai)
                namespace = target.parent
                if case == 'existing-target':
                    target.mkdir(parents=True)
                elif case == 'existing-namespace':
                    namespace.mkdir(parents=True)
                token = ai / 'token'
                token.touch()
                lock = ai / 'lock'
                reaped = False
                code = 0 if case == 'success' else 7

                def wait(timeout=None):
                    nonlocal reaped
                    if case == 'stopped' and timeout is None:
                        raise InterruptedError(15)
                    reaped = True
                    return -15 if case == 'stopped' else code

                def launch(*args, **kwargs):
                    cache = target / '.cache/huggingface/download'
                    cache.mkdir(parents=True)
                    (cache / 'partial.incomplete').write_text('partial')
                    if case == 'file':
                        (target / 'config.json').write_text('keep')
                    for name in ('CACHEDIR.TAG', '.gitignore', 'download/config.json.lock'):
                        (cache.parent / name).write_text('keep')
                    return SimpleNamespace(wait=wait, poll=lambda: None if case == 'stopped' else code,
                                           terminate=lambda: None)

                real_cleanup = hf.cleanup_empty_destination

                def cleanup(*args):
                    self.assertTrue(reaped)
                    self.assertFalse(list(target.rglob('*.incomplete')))
                    with lock.open('a') as other:
                        with self.assertRaises(BlockingIOError):
                            fcntl.flock(other, fcntl.LOCK_EX | fcntl.LOCK_NB)
                    real_cleanup(*args)

                output, errors = io.StringIO(), io.StringIO()
                with patch.dict(os.environ, {'DAG_PARAMS_JSON': '{"repo_id":"org/repo"}',
                     'HFDL_AI_ROOT': temp, 'HFDL_LOCK_PATH': str(lock), 'HF_TOKEN_PATH': str(token)}), \
                     patch.object(hf, 'preflight'), patch.object(hf.subprocess, 'Popen', side_effect=launch), \
                     patch.object(hf, 'cleanup_empty_destination', side_effect=cleanup) as cleaner, \
                     redirect_stdout(output), redirect_stderr(errors):
                    if case == 'denied':
                        with patch.object(hf.os, 'rmdir', side_effect=PermissionError('fixture denied')):
                            result = hf.main()
                    else:
                        result = hf.main()
                self.assertEqual(result, 143 if case == 'stopped' else code)
                if case == 'success':
                    cleaner.assert_not_called()
                else:
                    cleaner.assert_called_once()
                preserved = case in ('file', 'existing-target', 'success', 'denied')
                self.assertEqual(target.exists(), preserved)
                self.assertEqual(namespace.exists(), preserved or case == 'existing-namespace')
                if case == 'file':
                    self.assertEqual((target / 'config.json').read_text(), 'keep')
                if preserved and case != 'denied':
                    cache = target / '.cache/huggingface'
                    for name in ('CACHEDIR.TAG', '.gitignore', 'download/config.json.lock'):
                        self.assertEqual((cache / name).read_text(), 'keep')
                if case == 'existing-target':
                    self.assertTrue((target / '.cache/huggingface/download').is_dir())
                if not preserved:
                    self.assertIn('Destination cleanup: removed 3 files and ', output.getvalue())
                    self.assertEqual(output.getvalue().count('Destination cleanup:'), 1)
                    self.assertTrue(namespace.parent.is_dir())
                if case == 'denied':
                    self.assertIn('Empty destination cleanup warning: fixture denied', errors.getvalue())

    def test_empty_destination_cleanup_does_not_follow_symlinks(self):
        for component in ('subdir', 'repo', 'org', 'huggingface'):
            with self.subTest(component=component), tempfile.TemporaryDirectory() as temp:
                base = Path(temp)
                target = base / 'models/huggingface/org/repo'
                outside = base / 'outside'
                empty = outside / 'keep-empty'
                empty.mkdir(parents=True)
                link = target / 'subdir' if component == 'subdir' else next(
                    p for p in [target, *target.parents] if p.name == component)
                link.parent.mkdir(parents=True)
                link.symlink_to(outside, target_is_directory=True)
                with redirect_stderr(io.StringIO()):
                    hf.cleanup_empty_destination(target, False, False)
                self.assertTrue(empty.is_dir())
                self.assertTrue(link.is_symlink())

    def test_cache_cleanup_preserves_payload_outside_exact_cache_path(self):
        for name in ('config.json', 'nested/model.bin', '.cache/other', '.cache/huggingface-extra/file'):
            with self.subTest(name=name), tempfile.TemporaryDirectory() as temp:
                target = Path(temp) / 'huggingface/org/repo'
                cache_file = target / '.cache/huggingface/download/config.json.lock'
                cache_file.parent.mkdir(parents=True)
                cache_file.touch()
                payload = target / name
                payload.parent.mkdir(parents=True, exist_ok=True)
                payload.write_text('keep')
                (target / 'empty').mkdir()
                hf.cleanup_empty_destination(target, False, False)
                self.assertEqual(payload.read_text(), 'keep')
                self.assertTrue(cache_file.is_file())
                self.assertFalse((target / 'empty').exists())

    def test_cache_symlinks_and_special_files_prevent_all_cleanup(self):
        for name in ('.cache', '.cache/huggingface', '.cache/huggingface/download/link',
                     '.cache/huggingface/download/fifo'):
            with self.subTest(name=name), tempfile.TemporaryDirectory() as temp:
                base = Path(temp)
                target = base / 'huggingface/org/repo'
                (target / 'empty').mkdir(parents=True)
                outside = base / 'outside'
                (outside / 'empty').mkdir(parents=True)
                entry = target / name
                entry.parent.mkdir(parents=True, exist_ok=True)
                if name.endswith('/fifo'):
                    os.mkfifo(entry)
                else:
                    entry.symlink_to(outside, target_is_directory=True)
                if len(Path(name).parts) > 2:
                    (target / '.cache/huggingface/CACHEDIR.TAG').write_text('keep')
                before = set(target.rglob('*'))
                errors, output = io.StringIO(), io.StringIO()
                with redirect_stderr(errors), redirect_stdout(output):
                    hf.cleanup_empty_destination(target, False, False)
                self.assertEqual(set(target.rglob('*')), before)
                self.assertTrue((outside / 'empty').is_dir())
                self.assertIn('Empty destination cleanup warning:', errors.getvalue())
                self.assertEqual(output.getvalue(), '')

    def test_cache_unlink_failure_only_warns(self):
        with tempfile.TemporaryDirectory() as temp:
            target = Path(temp) / 'huggingface/org/repo'
            cache_file = target / '.cache/huggingface/CACHEDIR.TAG'
            cache_file.parent.mkdir(parents=True)
            cache_file.write_text('keep')
            errors = io.StringIO()
            with patch.object(hf.os, 'unlink', side_effect=PermissionError('fixture denied')), \
                 redirect_stderr(errors):
                hf.cleanup_empty_destination(target, False, False)
            self.assertEqual(cache_file.read_text(), 'keep')
            self.assertIn('Empty destination cleanup warning: fixture denied', errors.getvalue())

    def test_target_scan_rejects_links_and_special_files_before_hf(self):
        for kind in ('sub/link', '.cache/huggingface/link', 'fifo'):
            with self.subTest(kind=kind), tempfile.TemporaryDirectory() as temp:
                ai = Path(temp)
                _, target = hf.destination(hf.validate({'repo_id': 'org/repo'}), ai)
                entry = target / kind
                entry.parent.mkdir(parents=True)
                if kind == 'fifo':
                    os.mkfifo(entry)
                else:
                    entry.symlink_to('/var/lib/dagu')
                output = io.StringIO()
                with patch.dict(os.environ, {'DAG_PARAMS_JSON': '{"repo_id":"org/repo"}',
                     'HFDL_AI_ROOT': temp, 'HFDL_LOCK_PATH': str(ai / 'lock'),
                     'HF_TOKEN_PATH': str(ai / 'token')}), patch.object(hf, 'preflight'), \
                     patch.object(hf.subprocess, 'Popen') as process, redirect_stderr(output):
                    (ai / 'token').touch()
                    self.assertEqual(hf.main(), 1)
                    process.assert_not_called()
                self.assertIn(str(entry), output.getvalue())

    def test_target_scan_allows_regular_files_and_missing_target(self):
        with tempfile.TemporaryDirectory() as temp:
            target = Path(temp) / 'repo'
            hf.check_target(target)
            for name in ('model.bin', '.cache/huggingface/download/file.metadata'):
                entry = target / name
                entry.parent.mkdir(parents=True, exist_ok=True)
                entry.write_text('existing')
            hf.check_target(target)

    def test_target_scan_after_hf_only_warns(self):
        for code in (0, 1):
            with self.subTest(code=code), tempfile.TemporaryDirectory() as temp:
                ai = Path(temp)
                _, target = hf.destination(hf.validate({'repo_id': 'org/repo'}), ai)
                target.mkdir(parents=True)
                token = ai / 'token'
                token.touch()

                def launch(*args, **kwargs):
                    (target / 'injected').symlink_to('/var/lib/dagu')
                    return SimpleNamespace(wait=lambda: code, poll=lambda: code)

                output = io.StringIO()
                with patch.dict(os.environ, {'DAG_PARAMS_JSON': '{"repo_id":"org/repo"}',
                     'HFDL_AI_ROOT': temp, 'HFDL_LOCK_PATH': str(ai / 'lock'),
                     'HF_TOKEN_PATH': str(token)}), patch.object(hf, 'preflight'), \
                     patch.object(hf.subprocess, 'Popen', side_effect=launch), redirect_stderr(output):
                    self.assertEqual(hf.main(), code)
                self.assertIn('Destination scan warning:', output.getvalue())
                self.assertIn(str(target / 'injected'), output.getvalue())

    def test_revision_separator_collision_rejected(self):
        self.assertEqual(hf.validate({'repo_id': 'org/repo', 'revision': 'refs/pr/42'})['revision'],
                         'refs/pr/42')
        with self.assertRaisesRegex(hf.InvalidInput, 'commit SHA'):
            hf.validate({'repo_id': 'org/repo', 'revision': 'refs--pr--42'})

    def test_repo_validation(self):
        for value in ('org/name', 'a/b', 'org/a.b_c-d', 'x' * 96 + '/' + 'y' * 96):
            self.assertEqual(hf.validate({'repo_id': value})['repo_id'], value)
        for value in ('name', '../x', 'a/../x', '-a/b', 'a/b-', '.a/b', 'a/.b', 'a/b.git',
                      'a/b..c', 'a--b/c', 'a/b;c', 'a/$(id)', 'a/b\nc', 'x' * 97 + '/b'):
            with self.subTest(value=value), self.assertRaises(hf.InvalidInput):
                hf.validate({'repo_id': value})

    def test_surrounding_whitespace_is_ignored(self):
        for whitespace in (' ', '\t', '\n', '\r\n', '\u3000', ' \t\n\u3000'):
            with self.subTest(whitespace=whitespace):
                params = hf.validate({'repo_id': whitespace + 'org/repo' + whitespace,
                                      'revision': whitespace + 'refs/pr/42' + whitespace})
                self.assertEqual(params['repo_id'], 'org/repo')
                self.assertEqual(params['revision'], 'refs/pr/42')
                self.assertEqual(hf.validate({'repo_id': 'org/repo', 'revision': whitespace})['revision'], 'main')

    def test_internal_whitespace_and_controls_are_rejected(self):
        for whitespace in (' ', '\t', '\n', '\u3000', '\x00', '\x7f'):
            for name, value in (('repo_id', 'a' + whitespace + 'b/c'),
                                ('revision', 'a' + whitespace + 'b')):
                with self.subTest(name=name, whitespace=whitespace), self.assertRaises(hf.InvalidInput):
                    hf.validate({'repo_id': 'org/repo', name: value})

    def test_rejections_include_original_bounded_repr(self):
        for name, values in {
            'repo_id': [' a b/c ', None, 'x' * 194, 'a/b\x00'],
            'revision': [' bad rev ', None, 'refs--pr--42', 'x' * 129],
            'include': [' a,,b ', None, 'x' * 4097, ','.join(['x'] * 33)],
            'exclude': [' ../* ', 'a\n', 'x' * 257],
            'max_workers': ['1;id', True, None],
            'repo_type': ['space', None],
        }.items():
            for value in values:
                with self.subTest(name=name, value=value), self.assertRaises(hf.InvalidInput) as caught:
                    hf.validate({'repo_id': 'org/repo', name: value})
                received = repr(value)
                expected = received if len(received) <= 200 else received[:197] + '...'
                self.assertTrue(str(caught.exception).startswith(name + ':'))
                self.assertTrue(str(caught.exception).endswith('got ' + expected))

    def test_options_and_unknown_parameters(self):
        for name, values in {
            'repo_type': ['space', '--help'],
            'revision': ['--help', '../a', 'a//b', '/a', 'a/', 'a;b', 'a\nb', 'x' * 129],
            'include': ['--help', '/etc/passwd', 'x/../y', 'a,,b', 'a\x00', 'x' * 257, ','.join(['x'] * 33)],
            'exclude': ['--token=x', '../*'],
            'max_workers': [0, 5, True, 1.5, '1;id', '01'],
            'HFDL_HF_BIN': ['/bin/sh'],
            'HFDL_PROGRESS_INTERVAL': ['5'],
        }.items():
            for value in values:
                with self.subTest(name=name, value=value), self.assertRaises(hf.InvalidInput):
                    hf.validate({'repo_id': 'org/name', name: value})

    def test_destination_and_argv(self):
        params = hf.validate(dict(repo_id='org/repo', revision='refs/pr/42', repo_type='dataset',
                                  include=' *.json, data/* ', exclude='*.tmp', max_workers=4))
        root, target = hf.destination(params, Path('/data/ai'))
        self.assertEqual(root, Path('/data/ai/datasets'))
        self.assertEqual(target, Path('/data/ai/datasets/huggingface/org/repo@refs--pr--42'))
        self.assertEqual(hf.argv(params, target), ['/opt/hf/bin/hf', 'download', '--repo-type', 'dataset',
                         '--revision', 'refs/pr/42', '--local-dir', str(target), '--max-workers', '4',
                         '--include', '*.json', '--include', 'data/*', '--exclude', '*.tmp', '--', 'org/repo'])
        params = hf.validate({'repo_id': 'org/repo', 'revision': ''})
        self.assertEqual(hf.destination(params, Path('/data/ai'))[1], Path('/data/ai/models/huggingface/org/repo'))

    def test_symlink_escape(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            (root / 'models/huggingface').mkdir(parents=True)
            (root / 'models/huggingface/org').symlink_to('/tmp')
            with self.assertRaises(hf.InvalidInput):
                hf.destination(hf.validate({'repo_id': 'org/repo'}), root)

    def test_preflight_never_starts_hf(self):
        with tempfile.TemporaryDirectory() as temp:
            ai = Path(temp)
            (ai / 'models').mkdir()
            for marker in (None, 'wrong', 'ai'):
                if marker is not None:
                    (ai / '.homelab-export').write_text(marker)
                with self.subTest(marker=marker), patch.dict(os.environ, {
                    'DAG_PARAMS_JSON': json.dumps({'repo_id': 'org/name'}), 'HFDL_AI_ROOT': temp,
                }), patch.object(hf.subprocess, 'Popen') as process:
                    self.assertEqual(hf.main(), 1)
                    process.assert_not_called()


if __name__ == '__main__':
    unittest.main()
