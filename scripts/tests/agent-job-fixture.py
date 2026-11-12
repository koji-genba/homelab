#!/usr/bin/env python3
"""Offline real subprocess/temporary Git fixtures; never uses a live Runner."""
import copy
import importlib.machinery
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import sys
sys.dont_write_bytecode = True
import tempfile
import threading
import time
import unittest
from unittest.mock import patch

SOURCE = Path(__file__).resolve().parents[2] / 'files/infrastructure/ansible/agent/roles/runner/files/agent-job'
loader = importlib.machinery.SourceFileLoader('agent_job', str(SOURCE))
spec = importlib.util.spec_from_loader(loader.name, loader)
job = importlib.util.module_from_spec(spec)
loader.exec_module(job)


class Jobs(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        job.ROOT = self.root
        job.HELPER = self.root / 'missing-helper'
        self.repo = self.root / 'repos/owner/repo'
        self.repo.mkdir(parents=True)
        self.git('init', '-q', '-b', 'main')
        self.git('-c', 'user.name=Fixture', '-c', 'user.email=fixture@localhost', 'commit', '-q', '--allow-empty', '-m', 'base')
        self.bin = self.root / 'bin'
        self.bin.mkdir()
        # The actual child process is a shell script. Its JSON is generated from
        # argv and a per-repo fixture mode; no provider or credentials are used.
        fake = self.bin / 'fake.py'
        fake.write_text('''import json, pathlib, sys, time
cli, args = sys.argv[1], sys.argv[2:]
p = pathlib.Path('calls')
n = int(p.read_text()) + 1 if p.exists() else 1
p.write_text(str(n))
with pathlib.Path('argv').open('a') as f: f.write(json.dumps([cli, *args]) + '\\n')
mode = pathlib.Path('mode').read_text()
if mode == 'sleep': time.sleep(10)
if mode in ('no-session-fail', 'no-session-malformed') and n == 1:
 if mode == 'no-session-malformed': print('not-json')
 sys.exit(1 if mode == 'no-session-fail' else 0)
status = 'blocked' if mode == 'blocked' else 'continue' if mode == 'continue' or n == 1 and mode in ('sequence', 'drift', 'drift-dirty') else 'done'
text = 'AGENT_JOB_STATUS: ' + status + ' fixture'
if status == 'done': pathlib.Path('implementation.txt').write_text('implemented')
if mode == 'drift-dirty' and n == 1: pathlib.Path('stray.txt').write_text('left by someone else')
if mode.startswith('drift') and n == 1:
 import subprocess
 subprocess.run(['git', 'switch', '-q', 'main'], check=True)
if mode == 'no-status' and n == 1: text = 'still working'
if mode == 'recover' and n < 4: text = 'AGENT_JOB_STATUS: continue fixture'
if cli == 'claude': print(json.dumps({'session_id':'claude-session','result':text,'is_error':False}))
if cli == 'codex':
 print(json.dumps({'type':'thread.started','thread_id':'codex-session'}))
 print(json.dumps({'type':'item.completed','item':{'type':'agent_message','text':text}}))
 print(json.dumps({'type':'turn.completed'}))
if cli == 'dsh':
 print(json.dumps({'type':'session','sessionId':'session-dsh'}))
 print(json.dumps({'type':'final','sessionId':'session-dsh','reason':{'kind':'completed'},'text':text}))
if mode == 'malformed': print('not-json')
sys.exit(1 if mode == 'fail' or mode == 'recover' and n in (1, 3) else 0)
''')
        for cli in ('claude', 'codex', 'dsh'):
            script = self.bin / cli
            script.write_text('#!/bin/sh\nexec /usr/bin/python3 ' + str(fake) + ' ' + cli + ' "$@"\n')
            script.chmod(0o755)
        # Fixture control files are ignored and never checkpointed.
        (self.repo / '.git/info/exclude').write_text('mode\ncalls\nargv\n')
        original = job.env
        self.home = self.root / 'home'
        self.home.mkdir()
        self.env_patch = patch.object(job, 'env', lambda: original() | {'HOME': str(self.home), 'PATH': str(self.bin) + ':/usr/bin:/bin'})
        self.env_patch.start()
        self.addCleanup(self.env_patch.stop)
        (self.root / 'tasks').mkdir()

    def git(self, *args):
        return subprocess.check_output(['git', '-C', str(self.repo), *args], stderr=subprocess.DEVNULL, text=True).strip()

    def plan(self, cli='claude', mode='done', stages=1):
        (self.repo / 'mode').write_text(mode)
        plan = {'id': 'fixture', 'repo': str(self.repo), 'branch': 'agent/fixture', 'base': 'main', 'stages': [dict(name='stage-' + str(n), cli=cli, prompt='implement', acceptance='tests pass', network=False) for n in range(stages)], 'publish': dict(enabled=True, title='fixture', body='tested offline')}
        return job.validate(plan)

    def prepare(self, plan):
        task = self.root / 'tasks' / plan['id']
        task.mkdir()
        job.atomic(task / 'plan.json', plan)
        state = dict(id=plan['id'], repo=plan['repo'], stage=0, launches=0, stage_launches=0, consecutive_failures=0, sessions={}, cli_sessions={}, deadline_at=time.time() + 100, created_at=time.time(), status='queued')
        job.save(task, state)
        return task, state

    def run_job(self, **kwargs):
        plan = self.plan(**kwargs)
        task, state = self.prepare(plan)
        job.worker(task, state)
        return task, job.read(task / 'state.json')

    def test_resume_all_three_and_checkpoint(self):
        for cli in ('claude', 'codex', 'dsh'):
            with self.subTest(cli=cli):
                plan = self.plan(cli, 'sequence', 2)
                plan['id'] = cli
                plan['branch'] = 'agent/' + cli
                for file in ('calls', 'argv'):
                    (self.repo / file).unlink(missing_ok=True)
                task, state = self.prepare(plan)
                job.worker(task, state)
                self.assertEqual(state['status'], 'ready_to_publish')
                self.assertEqual(state['launches'], 3)
                self.assertEqual(state['stage'], 2)
                self.assertEqual([job.read(task / 'runs' / str(n) / 'result.json')['stage'] for n in (1, 2, 3)], [0, 0, 1])
                calls = [json.loads(line) for line in (self.repo / 'argv').read_text().splitlines()]
                self.assertIn({'claude': '--resume', 'codex': 'resume', 'dsh': '--session-id'}[cli], calls[1])
                self.assertNotIn({'claude': '--resume', 'codex': 'resume', 'dsh': '--session-id'}[cli], calls[2])
                self.assertIn('続けて。', calls[1][-1])
                self.assertNotIn(plan['stages'][0]['prompt'], calls[1][-1])
                self.assertEqual(self.git('log', '--format=%s', 'main..HEAD').splitlines(), [f'agent-job({cli}): stage-1', f'agent-job({cli}): stage-0'])
                self.assertEqual(self.git('log', '-1', '--format=%an <%ae>'), 'Agent Job Bot <agent-job@localhost>')
                self.assertEqual(self.git('show', 'HEAD:implementation.txt'), 'implemented')
                self.git('switch', '-q', 'main')

    def test_app_identity_global_ignore_and_publication(self):
        from types import SimpleNamespace
        class TrustedHelper(type(Path())):
            def stat(self, **kwargs):
                return SimpleNamespace(st_uid=0, st_mode=0o100755)
        helper = self.root / 'helper'
        helper.write_text('#!/bin/sh\ncat >/dev/null\nprintf "username=x-access-token\\npassword=ghs_FIXTURE\\n\\n"\n')
        helper.chmod(0o755)
        job.HELPER = TrustedHelper(helper)
        self.git('remote', 'add', 'origin', 'https://github.com/owner/repo.git')
        (self.home / '.gitconfig').write_text('[user]\nname = fixture-app[bot]\nemail = 123+fixture-app[bot]@users.noreply.github.com\n[core]\nexcludesFile = ' + str(self.home / 'ignore') + '\n')
        (self.home / 'ignore').write_text('*.pyc\n')
        (self.repo / 'generated.pyc').write_bytes(b'fixture')
        original = subprocess.run
        published = []
        def run(args, **kwargs):
            if args[0] == '/usr/local/bin/gh-agent' or args[0] == 'git' and 'push' in args:
                self.assertNotIn('GH_TOKEN', kwargs['env'])
                published.append(args)
                return subprocess.CompletedProcess(args, 0)
            return original(args, **kwargs)
        self.git('branch', 'develop')
        plan = self.plan()
        plan['base'] = 'develop'
        task, state = self.prepare(plan)
        with patch.object(subprocess, 'run', run):
            job.worker(task, state)
        self.assertEqual(state['status'], 'published')
        self.assertEqual(len(published), 2)
        self.assertIn('HEAD:refs/heads/agent/fixture', published[0])
        self.assertIn('credential.useHttpPath=true', published[0])
        self.assertEqual(published[1][:5], ['/usr/local/bin/gh-agent', 'owner/repo', 'pr', 'create', '--draft'])
        self.assertEqual(published[1][published[1].index('--base') + 1], 'develop')
        body_file = Path(published[1][published[1].index('--body-file') + 1])
        self.assertEqual(body_file, task / 'pr-body.md')
        body = body_file.read_text()
        self.assertTrue(body.startswith(plan['publish']['body'] + '\n\n## agent-job の記録\n'))
        result = job.read(task / 'runs/1/result.json')
        self.assertIn('| stage-0 | claude | 1 | ' + result['summary'] + ' |', body)
        self.assertEqual(self.git('log', '-1', '--format=%an <%ae>'),
                         'fixture-app[bot] <123+fixture-app[bot]@users.noreply.github.com>')
        self.assertNotIn('generated.pyc', self.git('ls-files'))

    def current_branch(self):
        return self.git('branch', '--show-current')

    def test_branch_restored_when_clean(self):
        # Between runs someone switched the clone to another branch (clean tree).
        task, state = self.run_job()
        self.assertEqual(state['status'], 'ready_to_publish')
        self.git('switch', '-q', 'main')
        job.worker(task, state)
        self.assertEqual((state['status'], self.current_branch()), ('ready_to_publish', 'agent/fixture'))
        # Detached HEAD is restored in the same way.
        self.git('switch', '-q', '--detach', 'main')
        job.worker(task, state)
        self.assertEqual((state['status'], self.current_branch()), ('ready_to_publish', 'agent/fixture'))

    def test_branch_restored_before_next_launch(self):
        # The CLI itself leaves the job branch without changes; the next launch must run on it again.
        task, state = self.run_job(mode='drift')
        self.assertEqual((state['status'], state['launches']), ('ready_to_publish', 2))
        self.assertEqual(self.current_branch(), 'agent/fixture')
        self.assertEqual(self.git('log', '--format=%s', 'main..HEAD').splitlines(), ['agent-job(fixture): stage-0'])
        self.assertEqual(self.git('show', 'HEAD:implementation.txt'), 'implemented')

    def test_dirty_tree_on_other_branch_blocks(self):
        # Uncommitted work appears on another branch: do not switch, do not launch the CLI.
        task, state = self.run_job(mode='drift-dirty')
        self.assertEqual((state['status'], state['launches']), ('blocked', 1))
        self.assertIn('working tree changed outside the job', state['summary'])
        self.assertEqual(self.current_branch(), 'main')
        self.assertEqual((self.repo / 'stray.txt').read_text(), 'left by someone else')
        # After a human cleans up, resuming returns to the job branch and finishes.
        (self.repo / 'stray.txt').unlink()
        job.worker(task, state)
        self.assertEqual((state['status'], self.current_branch()), ('ready_to_publish', 'agent/fixture'))

    def test_dirty_tree_blocks_before_checkpoint(self):
        # The CLI reports done after leaving the branch with its changes in the tree: no checkpoint.
        task, state = self.run_job(mode='drift-done')
        self.assertEqual((state['status'], state['stage']), ('blocked', 0))
        self.assertIn('working tree changed outside the job', state['summary'])
        self.assertEqual(self.git('log', '--format=%s', 'main..agent/fixture'), '')

    def test_dirty_tree_blocks_before_publication(self):
        task, state = self.run_job()
        self.assertEqual(state['status'], 'ready_to_publish')
        self.trust_helper()
        self.git('remote', 'add', 'origin', 'https://github.com/owner/repo.git')
        self.git('switch', '-q', 'main')
        (self.repo / 'stray.txt').write_text('uncommitted')
        calls = []
        with patch.object(subprocess, 'run', self.fake_publish(calls)):
            job.worker(task, state)
        self.assertEqual(state['status'], 'blocked')
        self.assertIn('working tree changed outside the job', state['summary'])
        self.assertEqual((calls, self.current_branch()), ([], 'main'))

    def trust_helper(self, token='ghs_FIXTURE'):
        from types import SimpleNamespace
        class TrustedHelper(type(Path())):
            def stat(self, **kwargs):
                return SimpleNamespace(st_uid=0, st_mode=0o100755)
        helper = self.root / 'helper'
        helper.write_text('#!/bin/sh\ncat >/dev/null\nprintf "username=x-access-token\\npassword=' + token + '\\n\\n"\n')
        helper.chmod(0o755)
        job.HELPER = TrustedHelper(helper)

    def fake_publish(self, calls, push=(0, b'', b''), create=(0, b'', b'')):
        # Only the push and gh-agent commands are replaced; every other command runs for real.
        original = subprocess.run
        def run(args, **kwargs):
            step = push if args[0] == 'git' and 'push' in args else create if args[0] == '/usr/local/bin/gh-agent' else None
            if step is None:
                return original(args, **kwargs)
            calls.append(args)
            if isinstance(step, BaseException):
                raise step
            return subprocess.CompletedProcess(args, *step)
        return run

    def test_pr_body_stage_records_redaction_and_limits(self):
        plan = self.plan(stages=2)
        plan['stages'][1]['cli'] = 'codex'
        task, _ = self.prepare(plan)
        samples = {
            1: dict(status='done', summary='legacy ignored'),
            2: dict(stage=0, status='continue', summary='unfinished'),
            3: dict(stage=0, status='done', summary='older done'),
            10: dict(stage=0, status='done', summary='tests pass | boundary\nfixed token=fixture-secret ghs_fixture-token'),
            11: dict(stage=0, status='blocked', summary='later blocked'),
            12: dict(stage=0, status='done', failed=True, summary='failed done'),
            13: dict(stage=1, status='running'),
        }
        for n, result in samples.items():
            (task / 'runs' / str(n)).mkdir(parents=True)
            job.atomic(task / 'runs' / str(n) / 'result.json', result)
        (task / 'runs/publish-1').mkdir()
        job.atomic(task / 'runs/publish-1/result.json', dict(status='done', summary='publication ignored'))
        body = job.pr_body(task, plan)
        self.assertIn('| stage-0 | claude | 5 | tests pass &#124; boundary fixed token=[REDACTED] [REDACTED] |', body)
        self.assertIn('| stage-1 | codex | 1 | 記録なし |', body)
        for text in ('fixture-secret', 'ghs_fixture-token', 'older done', 'legacy ignored', 'failed done', 'publication ignored'):
            self.assertNotIn(text, body)

        # Redact the complete summary before cutting through a credential.
        samples[10]['summary'] = '検' * 990 + ' token=' + 's' * 5000
        job.atomic(task / 'runs/10/result.json', samples[10])
        body = job.pr_body(task, plan)
        summary = body.split('| stage-0 | claude | 5 | ')[1].split(' |')[0]
        self.assertEqual(len(summary), 1000)
        self.assertTrue(summary.endswith('…'))
        self.assertNotIn('sssss', body)

        # Reserve every stage row even when the original body fills GitHub's limit.
        plan['publish']['body'] = '元の本文' * 20000
        body = job.pr_body(task, plan)
        self.assertEqual(len(body), 65536)
        self.assertTrue(body.startswith('元の本文'))
        self.assertIn('…\n\n## agent-job の記録\n', body)
        self.assertTrue(body.endswith('| stage-1 | codex | 1 | 記録なし |\n'))

    def test_publish_failure_is_logged_and_redacted(self):
        token = 'ghs_header.payload_with-hyphen.signature'
        self.trust_helper(token)
        self.git('remote', 'add', 'origin', 'https://github.com/owner/repo.git')
        task, state = self.prepare(self.plan())
        calls = []
        pushed = (0, b'To https://github.com/owner/repo.git\n * [new branch]      HEAD -> agent/fixture\n', b'')
        failed = (1, b'', ('error: https://x-access-token:' + token + '@github.com/owner/repo.git failed\n'
                           'Authorization: Bearer ' + token + '\nGH_TOKEN=' + token + '\n').encode())
        with patch.object(subprocess, 'run', self.fake_publish(calls, pushed, failed)):
            job.worker(task, state)
        self.assertEqual(state['status'], 'failed')
        self.assertIn('pr create', state['summary'])
        self.assertIn('exit 1', state['summary'])
        self.assertIn('runs/publish-1', state['summary'])
        self.assertEqual(len(calls), 2)
        log = task / 'runs/publish-1'
        stdout, stderr = (log / 'stdout').read_text(), (log / 'stderr').read_text()
        self.assertIn('== push ==', stdout)
        self.assertIn('[new branch]', stdout)
        self.assertIn('== pr create ==', stderr)
        self.assertIn('https://[REDACTED]@github.com/owner/repo.git failed', stderr)
        for text in (stdout, stderr, (log / 'result.json').read_text(), state['summary']):
            for part in (token, 'payload_with-hyphen', 'signature', 'ghs_FIXTURE'):
                self.assertNotIn(part, text)
        result = job.read(log / 'result.json')
        self.assertEqual((result['status'], result['failed_step']), ('failed', 'pr create'))
        self.assertEqual([(step['name'], step['exit_code']) for step in result['steps']], [('push', 0), ('pr create', 1)])
        # A later resume gets its own directory and keeps the earlier log.
        with patch.object(subprocess, 'run', self.fake_publish(calls)):
            job.worker(task, state)
        self.assertEqual(state['status'], 'published')
        self.assertEqual(job.read(task / 'runs/publish-2/result.json')['status'], 'published')
        self.assertIn('== pr create ==', (log / 'stderr').read_text())

    def test_publish_push_failure_stops_before_pr(self):
        self.trust_helper()
        self.git('remote', 'add', 'origin', 'https://github.com/owner/repo.git')
        task, state = self.prepare(self.plan())
        calls = []
        rejected = (128, b'', b'remote: Permission denied\nfatal: unable to access https://x-access-token:ghu_abc.def-ghi@github.com/owner/repo.git/\n')
        with patch.object(subprocess, 'run', self.fake_publish(calls, rejected)):
            job.worker(task, state)
        self.assertEqual(state['status'], 'failed')
        self.assertIn('push (exit 128)', state['summary'])
        self.assertEqual(len(calls), 1)
        stderr = (task / 'runs/publish-1/stderr').read_text()
        self.assertIn('Permission denied', stderr)
        self.assertNotIn('ghu_abc', stderr)
        self.assertNotIn('def-ghi', stderr)

    def test_publish_timeout_is_deadline_with_partial_log(self):
        self.trust_helper()
        self.git('remote', 'add', 'origin', 'https://github.com/owner/repo.git')
        task, state = self.prepare(self.plan())
        timeout = subprocess.TimeoutExpired(['git'], 1, output=b'partial', stderr=b'ghs_a.b-c waiting')
        with patch.object(subprocess, 'run', self.fake_publish([], timeout)):
            job.worker(task, state)
        self.assertEqual(state['status'], 'deadline')
        self.assertIn('push', state['summary'])
        self.assertIn('partial', (task / 'runs/publish-1/stdout').read_text())
        self.assertNotIn('ghs_a', (task / 'runs/publish-1/stderr').read_text())

    def test_credential_helper_failure_is_logged_without_token(self):
        self.trust_helper()
        self.git('remote', 'add', 'origin', 'https://github.com/owner/repo.git')
        Path(job.HELPER).write_text('#!/bin/sh\ncat >/dev/null\nprintf "password=ghs_SHOULD_NOT_LOG\\n"\necho "broker unavailable" >&2\nexit 1\n')
        task, state = self.prepare(self.plan())
        calls = []
        with patch.object(subprocess, 'run', self.fake_publish(calls)):
            job.worker(task, state)
        self.assertEqual((state['status'], calls), ('failed', []))
        self.assertIn('credential helper (exit 1)', state['summary'])
        log = task / 'runs/publish-1'
        self.assertIn('broker unavailable', (log / 'stderr').read_text())
        self.assertNotIn('SHOULD_NOT_LOG', (log / 'stdout').read_text() + (log / 'stderr').read_text())

    def test_clean_redacts_github_token_shapes(self):
        for text in ('ghs_FIXTURE', 'ghu_FIXTURE', 'ghp_FIXTURE', 'github_pat_FIX_TURE',
                     'ghs_header.payload_with-hyphen.signature', 'ghu_a-b.c_d.e-f',
                     'https://x-access-token:secret.value@github.com/o/r.git',
                     'https://user:hunter2@example.com/path', 'x-access-token:abc@github.com'):
            with self.subTest(text=text):
                cleaned = job.clean('before ' + text + ' after')
                self.assertTrue(cleaned.startswith('before ') and cleaned.endswith(' after'))
                for part in ('ghs_', 'ghu_', 'ghp_', 'github_pat_', 'payload', 'signature', 'secret.value', 'hunter2', 'abc@', 'e-f'):
                    self.assertNotIn(part, cleaned)
        # Hosts and ordinary text stay readable.
        self.assertEqual(job.clean('https://x-access-token:t0k3n@github.com/o/r.git'), 'https://[REDACTED]@github.com/o/r.git')
        self.assertEqual(job.clean('git@github.com:o/r.git ssh://git@github.com/o/r.git'), 'git@github.com:o/r.git ssh://git@github.com/o/r.git')
        self.assertEqual(job.clean('push to origin: 3 commits'), 'push to origin: 3 commits')

    def test_retry_without_session_keeps_original_prompt(self):
        for cli in ('claude', 'codex', 'dsh'):
            for mode in ('no-session-fail', 'no-session-malformed'):
                with self.subTest(cli=cli, mode=mode):
                    plan = self.plan(cli, mode)
                    plan['id'] = cli + '-' + mode
                    plan['branch'] = 'agent/' + plan['id']
                    plan['stages'][0]['prompt'] = 'Implement the original requested feature.'
                    for file in ('calls', 'argv'):
                        (self.repo / file).unlink(missing_ok=True)
                    task, state = self.prepare(plan)
                    job.worker(task, state)
                    self.assertEqual((state['status'], state['launches']), ('ready_to_publish', 2))
                    calls = [json.loads(line) for line in (self.repo / 'argv').read_text().splitlines()]
                    for call in calls:
                        self.assertIn(plan['stages'][0]['prompt'], call[-1])
                        self.assertIn(plan['stages'][0]['acceptance'], call[-1])
                        self.assertNotIn('続けて。', call[-1])
                        self.assertNotIn({'claude': '--resume', 'codex': 'resume', 'dsh': '--session-id'}[cli], call)
                    first_result = job.read(task / 'runs/1/result.json')
                    self.assertTrue(first_result['failed'])
                    self.git('switch', '-q', 'main')

    def test_launch_memory_limit(self):
        task, state = self.prepare(self.plan())
        with patch.object(job.subprocess, 'run', return_value=subprocess.CompletedProcess([], 0)) as run:
            job.launch(task, state)
        argv = run.call_args.args[0]
        self.assertEqual(argv[0], 'systemd-run')
        self.assertIn('--property=MemoryMax=6G', argv)
        self.assertNotIn('--property=MemoryMax=8G', argv)

    def test_blocked(self):
        _, s = self.run_job(mode='blocked')
        self.assertEqual((s['status'], s['launches']), ('blocked', 1))

    def test_failures(self):
        for cli in ('claude', 'codex', 'dsh'):
            plan = self.plan(cli, 'fail')
            plan['id'] = cli
            plan['branch'] = 'agent/' + cli
            task, s = self.prepare(plan)
            job.worker(task, s)
            self.assertEqual((s['status'], s['launches'], s['consecutive_failures']), ('failed', 3, 3))
            (self.repo / 'implementation.txt').unlink(missing_ok=True)
            self.git('switch', '-q', 'main')

    def test_success_resets_consecutive_failures(self):
        _, s = self.run_job(mode='recover')
        self.assertEqual((s['status'], s['launches'], s['consecutive_failures']), ('ready_to_publish', 4, 0))

    def test_malformed(self):
        _, s = self.run_job(cli='codex', mode='malformed')
        self.assertEqual((s['status'], s['consecutive_failures']), ('failed', 3))

    def test_no_status_resumes(self):
        _, s = self.run_job(mode='no-status')
        self.assertEqual((s['status'], s['launches']), ('ready_to_publish', 2))
        calls = [json.loads(line) for line in (self.repo / 'argv').read_text().splitlines()]
        self.assertIn('--resume', calls[1])

    def test_real_timeout_is_failure(self):
        plan = self.plan(mode='sleep')
        plan['stages'][0]['timeout_minutes'] = 0.001
        task, s = self.prepare(plan)
        job.worker(task, s)
        self.assertEqual((s['status'], s['consecutive_failures']), ('failed', 3))
        self.assertTrue(job.read(task / 'runs/3/result.json')['timeout'])

    def test_deadline_kills_inflight_child(self):
        plan = self.plan(mode='sleep')
        task, s = self.prepare(plan)
        s['deadline_at'] = time.time() + 0.1
        job.worker(task, s)
        self.assertEqual((s['status'], s['launches']), ('deadline', 1))

    def test_launch_limit(self):
        _, s = self.run_job(cli='dsh', mode='continue')
        self.assertEqual((s['status'], s['launches']), ('failed', 30))

    def test_deadline(self):
        task, s = self.prepare(self.plan())
        s['deadline_at'] = time.time() - 1
        job.worker(task, s)
        self.assertEqual((s['status'], s['launches']), ('deadline', 0))

    def test_timeout_and_stop_flag(self):
        task, s = self.prepare(self.plan(mode='sleep'))
        def stop():
            while not (task / 'runs/1').exists():
                time.sleep(0.01)
            time.sleep(0.1)
            (task / 'stop').touch()
        thread = threading.Thread(target=stop)
        thread.start()
        job.worker(task, s)
        thread.join()
        self.assertEqual(s['status'], 'stopped')
        self.assertTrue(job.read(task / 'runs/1/result.json')['timeout'])

    def invoke(self, *args):
        with patch.object(sys, 'argv', ['agent-job', *args]):
            return job.main()

    def test_start_admission_and_global_limit(self):
        plan = self.plan()
        path = self.root / 'plan.json'
        job.atomic(path, plan)
        def queued(task, s):
            job.save(task, s, 'queued')
        with patch.object(job, 'launch', queued), patch.object(job, 'alive', return_value=False):
            self.invoke('start', str(path))
            plan['id'] = 'second'
            job.atomic(path, plan)
            with self.assertRaises(ValueError):
                self.invoke('start', str(path))
            # A second repository is admitted, the third is refused.
            for n in ('second', 'third'):
                repo = self.root / 'repos/owner' / n
                repo.mkdir()
                plan.update(id=n, repo=str(repo))
                job.atomic(path, plan)
                if n == 'second':
                    self.invoke('start', str(path))
                else:
                    with self.assertRaises(ValueError):
                        self.invoke('start', str(path))

    def test_repo_flock(self):
        plan = self.plan()
        task, s = self.prepare(plan)
        import hashlib
        lockfile = self.root / 'tasks' / ('.repo-' + hashlib.sha256(plan['repo'].encode()).hexdigest())
        with job.lock(lockfile):
            with self.assertRaises(BlockingIOError):
                job.worker(task, s)

    def test_alerts_once_and_driver_lost(self):
        import io
        task, s = self.prepare(self.plan())
        for event in ('blocked', 'failed', 'deadline', 'done', 'ready_to_publish', 'stopped', 'running'):
            job.save(task, s, event)
            s['updated_at'] -= 60
            job.atomic(task / 'state.json', s)
            out = io.StringIO()
            with patch.object(job, 'alive', return_value=False), context_stdout(out):
                self.invoke('alerts')
                self.invoke('alerts')
            expected = 'driver_lost' if event == 'running' else event
            self.assertEqual(out.getvalue(), 'agent-job fixture: ' + expected + '\n')

    def test_stop_calls_systemd_cgroup(self):
        task, s = self.prepare(self.plan())
        with patch.object(job, 'systemctl') as ctl, patch.object(job, 'alive', return_value=False):
            self.invoke('stop', s['id'])
            ctl.assert_called_once_with('stop', 'agent-job-fixture.service')
        self.assertTrue((task / 'stop').exists())
        self.assertEqual(job.read(task / 'state.json')['status'], 'stopped')

    def test_resume_explicit_budget(self):
        task, s = self.prepare(self.plan())
        s.update(launches=30, deadline_at=time.time()-1)
        job.save(task, s, 'failed')
        with patch.object(job, 'alive', return_value=False), patch.object(job, 'launch') as launch:
            with self.assertRaises(ValueError):
                self.invoke('resume', s['id'])
            self.invoke('resume', s['id'], '--max-launches', '60', '--deadline-hours', '6')
            self.assertEqual(job.read(task / 'plan.json')['max_launches'], 60)
            self.assertTrue(launch.called)

    def test_terminated_driver_saves_cli_output(self):
        import signal
        plan = self.plan(mode='sleep')
        task, s = self.prepare(plan)
        bootstrap = self.root / 'driver.py'
        # Run the real _run entrypoint in an isolated child with the fake CLI PATH.
        bootstrap.write_text(
            'import importlib.machinery, sys, pathlib\nsys.dont_write_bytecode=True\n'
            'm=importlib.machinery.SourceFileLoader("job", ' + repr(str(SOURCE)) + ').load_module()\n'
            'm.ROOT=pathlib.Path(' + repr(str(self.root)) + ')\n'
            'original=m.env\n'
            'm.env=lambda: original() | {"PATH": ' + repr(str(self.bin) + ':/usr/bin:/bin') + '}\n'
            'sys.argv=["agent-job", "_run", "fixture"]\n'
            'sys.exit(m.main())\n')
        child = subprocess.Popen(['/usr/bin/python3', str(bootstrap)])
        try:
            deadline = time.monotonic() + 5
            while not (self.repo / 'calls').exists() and child.poll() is None and time.monotonic() < deadline:
                time.sleep(0.01)
            self.assertIsNone(child.poll())
            child.send_signal(signal.SIGTERM)
            self.assertEqual(child.wait(timeout=8), 0)
            result = job.read(task / 'runs/1/result.json')
            self.assertIsNotNone(result['exit_code'])
            self.assertEqual(job.read(task / 'state.json')['status'], 'stopped')
            import io
            out = io.StringIO()
            with context_stdout(out):
                self.invoke('alerts')
                self.invoke('alerts')
            self.assertEqual(out.getvalue(), 'agent-job fixture: stopped\n')
        finally:
            if child.poll() is None:
                child.kill()
                child.wait()

    def test_resume_lost_driver(self):
        task, s = self.prepare(self.plan())
        job.save(task, s, 'running')
        s['updated_at'] -= 60
        job.atomic(task / 'state.json', s)
        with patch.object(job, 'alive', return_value=False), patch.object(job, 'launch') as launch:
            self.invoke('resume', s['id'])
            self.assertTrue(launch.called)

    def test_model_and_network_commands(self):
        for cli in ('claude', 'codex', 'dsh'):
            stage = dict(cli=cli, model='fixture-model', network=False)
            command = job.command(stage, 'previous-session', 'continue', self.root)
            if cli == 'dsh':
                self.assertIn('--patch', command)
                self.assertNotIn('--model', command)
                self.assertEqual(job.read(self.root / 'model.yml')[0]['config']['model'], 'fixture-model')
            else:
                self.assertIn('--model', command)
            if cli == 'codex':
                self.assertIn('sandbox_mode="workspace-write"', command)
                self.assertIn('sandbox_workspace_write.network_access=false', command)
                self.assertNotIn('--sandbox', command)

    def test_validation(self):
        plan = self.plan()
        invalid = [('id', '../escape'), ('branch', 'main'), ('repo', '/tmp'), ('deadline_hours', 7), ('deadline_hours', float('nan')), ('max_launches', 31), ('max_launches', True), ('max_launches', 0), ('max_consecutive_failures', 4), ('stages', [])]
        for key, value in invalid:
            bad = copy.deepcopy(plan)
            bad[key] = value
            with self.subTest(key=key, value=value), self.assertRaises((ValueError, TypeError)):
                job.validate(bad)
        for key, value in [('timeout_minutes', 121), ('network', 'yes'), ('cli', 'sh'), ('acceptance', '')]:
            bad = copy.deepcopy(plan)
            bad['stages'][0][key] = value
            with self.assertRaises(ValueError):
                job.validate(bad)

    def test_agent_watchdog_silence_failure_suppression_and_recovery(self):
        source = SOURCE.parents[2] / 'agent_stack/templates/runner-agent-job-alerts.py.j2'
        script = self.root / 'watch.py'
        template = source.read_text()
        expression = '{{ (agent_stack_runner_user ~ \'@\' ~ agent_stack_runner_host) | to_json }}'
        script.write_text(template.replace(expression, json.dumps('runner@fixture.invalid')))
        ssh = self.bin / 'ssh'
        ssh.write_text('#!/bin/sh\ncat "$HERMES_HOME/reply"\nexit "$(cat "$HERMES_HOME/rc")"\n')
        ssh.chmod(0o755)
        environment = {'PATH': str(self.bin) + ':/usr/bin:/bin', 'HERMES_HOME': str(self.root)}
        def invoke(code, text):
            (self.root / 'rc').write_text(str(code))
            (self.root / 'reply').write_text(text)
            return subprocess.check_output(['/usr/bin/python3', str(script)], env=environment, text=True)
        self.assertEqual(invoke(0, ''), '')
        self.assertEqual(invoke(0, 'agent-job fixture: blocked\n'), 'agent-job fixture: blocked\n')
        self.assertEqual(len(invoke(255, '').splitlines()), 1)
        self.assertEqual(invoke(255, ''), '')
        self.assertEqual(invoke(0, ''), '')
        self.assertEqual(len(invoke(255, '').splitlines()), 1)

    def test_secret_environment_and_redaction(self):
        with patch.dict(os.environ, {'OPENAI_API_KEY':'hidden', 'ANTHROPIC_API_KEY':'hidden', 'GH_TOKEN':'hidden'}):
            self.assertFalse(set(job.env()) & {'OPENAI_API_KEY', 'ANTHROPIC_API_KEY', 'GH_TOKEN'})
        self.assertNotIn('hidden', job.clean('token=hidden Bearer hidden'))


from contextlib import redirect_stdout as context_stdout
if __name__ == '__main__':
    unittest.main()
