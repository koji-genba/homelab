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
