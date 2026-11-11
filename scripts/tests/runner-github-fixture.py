#!/usr/bin/env python3
"""Offline broker/helper/wrapper/operator integration with ephemeral keys and HTTP API."""
import base64
import datetime
import importlib.machinery
import importlib.util
import io
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import threading
import time
import unittest
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from unittest.mock import patch

sys.dont_write_bytecode = True
ROOT = Path(__file__).resolve().parents[2]
FILES = ROOT / 'files/infrastructure/ansible/agent/roles/runner/files'


def load(name, path):
    loader = importlib.machinery.SourceFileLoader(name, str(path))
    spec = importlib.util.spec_from_loader(name, loader)
    module = importlib.util.module_from_spec(spec)
    loader.exec_module(module)
    return module


broker = load('broker', FILES / 'agent-job-github-token')
helper = load('credential', FILES / 'agent-job-github-credential')
wrapper = load('wrapper', FILES / 'gh-agent')
operator = load('operator_repo', ROOT / 'scripts/github-agent-repo.py')


class GitHub(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        broker.CONFIG = self.root / 'app.json'
        broker.KEY = self.root / 'key.pem'
        broker.CACHE = self.root / 'cache'
        broker.CACHE.mkdir(mode=0o700)
        broker.CONFIG.write_text(json.dumps({'app_id': '123', 'installation_id': '456'}))
        subprocess.run(['openssl', 'genrsa', '-out', str(broker.KEY), '2048'], check=True,
                       stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        self.public = self.root / 'public.pem'
        subprocess.run(['openssl', 'rsa', '-in', str(broker.KEY), '-pubout', '-out', str(self.public)],
                       check=True, capture_output=True)
        self.calls = []
        self.fail_api = False
        case = self

        class API(BaseHTTPRequestHandler):
            def log_message(self, *args):
                pass

            def do_GET(self):
                case.calls.append(('GET', self.path, self.headers['Authorization'], None))
                self.send_response(200)
                self.end_headers()
                self.wfile.write(b'{"account":{"login":"owner"}}')

            def do_POST(self):
                body = json.loads(self.rfile.read(int(self.headers['Content-Length'])))
                case.calls.append(('POST', self.path, self.headers['Authorization'], body))
                self.send_response(403 if case.fail_api else 201)
                self.end_headers()
                expires = datetime.datetime.now(datetime.timezone.utc) + datetime.timedelta(hours=1)
                self.wfile.write(json.dumps({'token': 'ghs_FIXTURE', 'expires_at': expires.isoformat(),
                                            'error': 'secret-response-sentinel'}).encode())

        server = ThreadingHTTPServer(('127.0.0.1', 0), API)
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        self.addCleanup(server.server_close)
        self.addCleanup(server.shutdown)
        broker.API = 'http://127.0.0.1:' + str(server.server_port)

    def test_jwt_signature_scope_cache_and_expiry(self):
        self.assertEqual(broker.token('owner/repo'), 'ghs_FIXTURE')
        self.assertEqual(len(self.calls), 2)
        request = self.calls[-1]
        self.assertEqual(request[1], '/app/installations/456/access_tokens')
        self.assertEqual(request[3], {'repositories': ['repo'], 'permissions': {
            'contents': 'write', 'pull_requests': 'write', 'metadata': 'read'}})
        jwt = request[2].removeprefix('Bearer ')
        header, payload, signature = jwt.split('.')
        decode = lambda value: base64.urlsafe_b64decode(value + '=' * (-len(value) % 4))
        self.assertEqual(json.loads(decode(header)), {'alg': 'RS256', 'typ': 'JWT'})
        claims = json.loads(decode(payload))
        self.assertEqual(claims['iss'], '123')
        self.assertLessEqual(abs(claims['iat'] - (time.time() - 60)), 2)
        self.assertEqual(claims['exp'] - claims['iat'], 600)
        sig = self.root / 'signature'
        sig.write_bytes(decode(signature))
        subprocess.run(['openssl', 'dgst', '-sha256', '-verify', str(self.public), '-signature', str(sig)],
                       input=(header + '.' + payload).encode(), check=True, capture_output=True)
        self.assertEqual(broker.token('owner/repo'), 'ghs_FIXTURE')
        self.assertEqual(len(self.calls), 2)
        cached = next(broker.CACHE.glob('*.json'))
        self.assertEqual(cached.stat().st_mode & 0o777, 0o600)
        item = json.loads(cached.read_text())
        item['expires_at'] = (datetime.datetime.now(datetime.timezone.utc) + datetime.timedelta(minutes=4)).isoformat()
        cached.write_text(json.dumps(item))
        broker.token('owner/repo')
        self.assertEqual(len(self.calls), 4)
        broker.token('owner/other')
        self.assertEqual(self.calls[-1][3]['repositories'], ['other'])
        self.assertEqual(len(list(broker.CACHE.glob('*.json'))), 2)
        broker.CONFIG.write_text(json.dumps({'app_id': '124', 'installation_id': '456'}))
        broker.token('owner/repo')
        self.assertEqual(len(self.calls), 8, 'rotation invalidates cached token')

    def test_owner_and_repository_validation(self):
        for value in ('owner/../repo', '../repo', 'a/b/c', '-owner/repo', 'owner/.', 'owner/..',
                      'https://github.com/a/b', 'owner/repo\n', 'owner/repo.git', 'a--b/repo', 'owner/r?x'):
            with self.subTest(value=value), self.assertRaises(ValueError):
                broker.token(value)
        with self.assertRaises(ValueError):
            broker.token('someone/repo')
        self.assertEqual(len(self.calls), 1, 'owner mismatch must never mint a token')

    def test_no_secrets_in_failure_output(self):
        self.fail_api = True
        out, err = io.StringIO(), io.StringIO()
        with patch.object(sys, 'argv', ['broker', 'owner/repo']), patch('sys.stdout', out), patch('sys.stderr', err):
            self.assertEqual(broker.main(), 1)
        self.assertEqual(out.getvalue(), '')
        self.assertEqual(err.getvalue(), 'GitHub App token unavailable\n')

    def fake_broker(self):
        script = self.root / 'token.py'
        script.write_text('import sys\nassert sys.argv[1] == "owner/repo"\nprint("ghs_LOCAL_FIXTURE")\n')
        return [sys.executable, str(script)]

    def test_credential_protocol_and_host(self):
        with patch.object(helper, 'BROKER', self.fake_broker()):
            self.assertEqual(helper.credential('get', 'protocol=https\nhost=github.com\npath=owner/repo.git\n\n'),
                             'username=x-access-token\npassword=ghs_LOCAL_FIXTURE\n\n')
            for host in ('gitlab.com', 'github.com.evil', 'github.com:443'):
                self.assertEqual(helper.credential('get', 'protocol=https\nhost=' + host + '\npath=owner/repo\n'), '')
            self.assertEqual(helper.credential('get', 'protocol=http\nhost=github.com\npath=owner/repo\n'), '')
            for operation in ('store', 'erase'):
                self.assertEqual(helper.credential(operation, 'password=do-not-store'), '')
            for target in ('owner/../repo', 'owner/repo/extra', '-o/repo', 'o/..', 'o/repo\rjunk'):
                with self.assertRaises(ValueError):
                    helper.credential('get', 'protocol=https\nhost=github.com\npath=' + target + '\n')

    def fake_gh(self, draft=True):
        script = self.root / 'gh'
        script.write_text('#!/usr/bin/python3\nimport json, os, sys\n'
                          'assert os.environ["GH_TOKEN"] == "ghs_LOCAL_FIXTURE"\n'
                          'assert sys.argv[1:3] == ["--repo", "owner/repo"]\n'
                          'print(json.dumps({"isDraft": ' + str(draft) + '}))\n')
        script.chmod(0o755)
        credential = self.root / 'helper'
        credential.write_text('#!/bin/sh\ncat >/dev/null\nprintf "username=x-access-token\\npassword=ghs_LOCAL_FIXTURE\\n\\n"\n')
        credential.chmod(0o755)
        wrapper.GH = str(script)
        wrapper.HELPER = str(credential)

    def test_wrapper_allowed_commands_and_draft_edits(self):
        self.fake_gh()
        for args in (['pr', 'create', '--draft', '--base', 'main', '--head', 'agent/topic', '--title', 'test'],
                     ['pr', 'view', '1', '--json', 'isDraft'], ['pr', 'list'], ['pr', 'edit', '1', '--body', 'test']):
            self.assertEqual(wrapper.run('owner/repo', args), 0)
        self.fake_gh(draft=False)
        with self.assertRaises(ValueError):
            wrapper.run('owner/repo', ['pr', 'edit', '1', '--body', 'test'])

    def test_wrapper_create_accepts_non_main_base(self):
        self.fake_gh()
        for base in ('master', 'develop', 'release/v1.2', 'agent/previous'):
            with self.subTest(base=base):
                self.assertEqual(wrapper.run('owner/repo', [
                    'pr', 'create', '--draft', '--base', base, '--head', 'agent/topic', '--title', 'test']), 0)

    def test_wrapper_create_rejects_invalid_or_identical_refs(self):
        for base, head in (('', 'agent/topic'), ('bad..ref', 'agent/topic'),
                           ('bad ref', 'agent/topic'), ('-develop', 'agent/topic'),
                           ('@{-1}', 'agent/topic'), ('develop.lock', 'agent/topic'),
                           ('develop/', 'agent/topic'), ('develop\n', 'agent/topic'),
                           ('agent/topic', 'agent/topic'), ('develop', 'agent/bad..ref'),
                           ('develop', 'agent/')):
            with self.subTest(base=base, head=head), \
                 patch.object(wrapper.subprocess, 'run', wraps=subprocess.run) as run:
                with self.assertRaises(ValueError):
                    wrapper.run('owner/repo', ['pr', 'create', '--draft', '--base', base, '--head', head])
                self.assertFalse(any(call.args[0][0] == wrapper.HELPER for call in run.call_args_list))

    def test_wrapper_rejects_commands_before_credentials(self):
        for args in (['pr', 'merge', '1'], ['api', '/repos/owner/repo'], ['pr', 'ready', '1'],
                     ['pr', 'create', '--base', 'main', '--head', 'agent/topic'],
                     ['pr', 'view', '--repo', 'evil/repo'], ['pr', 'edit', '1', '--repo=evil/repo'],
                     ['pr', 'create', '--draft', '--base', 'main', '--head', 'main']):
            with self.subTest(args=args), self.assertRaises(ValueError):
                wrapper.run('owner/repo', args)

    def test_optional_bundle_gating_and_git_configuration(self):
        import jinja2
        import yaml
        role = FILES.parent
        tasks = yaml.safe_load((role / 'tasks/github.yml').read_text())
        expression = tasks[0]['ansible.builtin.set_fact']['runner_github_enabled']
        environment = jinja2.Environment(undefined=jinja2.ChainableUndefined)
        for bundle, enabled in (({}, False), ({'app_id': None, 'installation_id': None, 'private_key': None}, False),
                                ({'app_id': '123'}, False),
                                ({'app_id': '123', 'installation_id': '456', 'private_key': 'fixture'}, True)):
            result = environment.from_string(expression).render(runner_github_app=bundle).strip()
            self.assertEqual(result, str(enabled))
        block = next(task['block'] for task in tasks if 'block' in task)
        for task in block:
            copy = task.get('ansible.builtin.copy', {})
            if copy.get('dest') in ('/etc/homelab/secrets/github-app.pem', '/etc/homelab/secrets/github-app.json'):
                self.assertEqual((copy['mode'], copy['owner'], task['no_log']), ('0400', 'gh-broker', True))
        template = environment.from_string((role / 'templates/runner.gitconfig.j2').read_text())
        for enabled in (False, True):
            rendered = template.render(runner_user='hermes-runner', runner_github_enabled=enabled,
                                       runner_github_app_slug='fixture' if enabled else '',
                                       runner_github_bot_user_id='123' if enabled else '')
            config = self.root / 'gitconfig'
            config.write_text(rendered)
            result = subprocess.check_output(['git', 'config', '--file', str(config), '--get', 'user.name'], text=True)
            self.assertEqual(result.strip(), 'fixture[bot]' if enabled else 'Agent Job Bot')
            self.assertIn('useHttpPath = true', rendered)
            self.assertEqual('helper = /usr/local/libexec/' in rendered, enabled)

    def test_operator_pagination_compatible_with_older_gh(self):
        fake = self.root / 'gh'
        output = '[ {"id": 1} ]\n[ {"id": 2} ]'
        fake.write_text('#!/usr/bin/python3\nimport sys\nassert "--slurp" not in sys.argv\n'
                        'assert "--paginate" in sys.argv\nprint(' + repr(output) + ')\n')
        fake.chmod(0o755)
        with patch.dict(os.environ, {'PATH': str(self.root) + ':/usr/bin:/bin'}):
            self.assertEqual(operator.api('/repos/owner/repo/rulesets', pages=True), [[{'id': 1}], [{'id': 2}]])

    def test_operator_dry_run_never_calls_api(self):
        for mode in ('onboard', 'check'):
            with patch.object(operator, 'api', side_effect=AssertionError('API forbidden')), \
                 patch.object(sys, 'argv', ['repo', mode, 'owner/repo', '--installation-id', '456', '--dry-run']), \
                 patch('sys.stdout', io.StringIO()):
                self.assertEqual(operator.main(), 0)

    def test_operator_idempotency_and_protect_before_install(self):
        calls, rules = [], []
        current = {}
        def api(path, method='GET', body=None, pages=False):
            calls.append((method, path))
            if path.startswith('/user/installations?'):
                return [{'installations': [{'id': 456, 'account': {'login': 'owner'}, 'repository_selection': 'selected'}]}]
            if path == '/repos/owner/repo':
                return {'id': 99, 'permissions': {'admin': True}, 'owner': {'login': 'owner'}}
            if path.startswith('/repos/owner/repo/rulesets?'):
                return [rules]
            if path == '/repos/owner/repo/rulesets' and method == 'POST':
                current.update(body)
                rules.append({'name': 'agent-main-protection', 'id': 1})
                return current
            if path == '/repos/owner/repo/rulesets/1':
                return current
            if path.endswith('/repositories/99'):
                self.assertEqual(current, operator.desired())
                return None
            if '/repositories?' in path:
                return [{'repositories': [{'full_name': 'owner/repo'}]}]
            raise AssertionError(path)
        with patch.object(operator, 'api', api), patch('sys.stdout', io.StringIO()), \
             patch.object(sys, 'argv', ['repo', 'onboard', 'owner/repo', '456']):
            self.assertEqual(operator.main(), 0)
            self.assertEqual(operator.main(), 0)
        self.assertEqual(sum(method == 'POST' for method, _ in calls), 1)
        self.assertFalse(any(method == 'PUT' and '/rulesets/' in path for method, path in calls))
        ruleset = operator.desired()
        reordered = dict(ruleset, rules=list(reversed(ruleset['rules'])))
        self.assertTrue(operator.equivalent(reordered, ruleset))
        drifted = dict(ruleset, enforcement='disabled')
        self.assertFalse(operator.equivalent(drifted, ruleset))
        self.assertEqual(ruleset['bypass_actors'], [{'actor_id': 5, 'actor_type': 'RepositoryRole', 'bypass_mode': 'always'}])
        self.assertEqual({rule['type'] for rule in ruleset['rules']}, {'update', 'deletion', 'non_fast_forward'})


if __name__ == '__main__':
    unittest.main()
