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
import shlex
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
        self.token_response = 'ghs_FIXTURE'
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
                self.wfile.write(json.dumps({'token': case.token_response, 'expires_at': expires.isoformat(),
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

    def test_token_formats_and_length_limits(self):
        source = 'protocol=https\nhost=github.com\npath=owner/repo\n\n'
        for token in ('ghs_header.payload_with-hyphen.signature', 'a', 'a' * 2048,
                      '', 'a' * 2049, 'ghs_bad/token', 'ghs_bad/\nheader', 'ghs_bad token'):
            valid = bool(token) and len(token) <= 2048 and not any(c in token for c in '/\n ')
            with self.subTest(length=len(token), valid=valid):
                self.token_response = token
                for cached in broker.CACHE.glob('*.json'):
                    cached.unlink()
                if valid:
                    self.assertEqual(broker.token('owner/repo'), token)
                    self.assertEqual(broker.token('owner/repo'), token, 'cached token preserves format')
                else:
                    with self.assertRaises(ValueError):
                        broker.token('owner/repo')
                result = subprocess.CompletedProcess([], 0, stdout=token + '\n')
                with patch.object(helper.subprocess, 'run', return_value=result):
                    if valid:
                        self.assertEqual(helper.credential('get', source),
                                         'username=x-access-token\npassword=' + token + '\n\n')
                    else:
                        with self.assertRaises(ValueError):
                            helper.credential('get', source)
                result.stdout = 'username=x-access-token\npassword=' + token + '\n\n'
                # Use list so no branch-ref subprocess is needed before the helper.
                with patch.object(wrapper.subprocess, 'run', return_value=result) as run:
                    if valid:
                        self.assertEqual(wrapper.run('owner/repo', ['pr', 'list']), 0)
                        self.assertEqual(run.call_args.kwargs['env']['GH_TOKEN'], token)
                    else:
                        with self.assertRaises(ValueError):
                            wrapper.run('owner/repo', ['pr', 'list'])
                        self.assertEqual(run.call_count, 1, 'invalid token must never reach gh')

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

    def test_credential_ignores_array_fields(self):
        source = ('capability[]=authtype\ncapability[]=state\n'
                  'protocol=https\nhost=github.com\npath=owner/repo.git\n'
                  'wwwauth[]=Basic realm="GitHub"\nwwwauth[]=Bearer\n'
                  'state[]=other-helper:opaque\nstate[]=\n'
                  'unknown[]=first\nunknown[]=second\n\n')
        with patch.object(helper, 'BROKER', self.fake_broker()):
            self.assertEqual(helper.credential('get', source),
                             'username=x-access-token\npassword=ghs_LOCAL_FIXTURE\n\n')

    def test_credential_rejects_duplicate_scalar_fields(self):
        source = 'capability[]=authtype\ncapability[]=state\nprotocol=https\nhost=github.com\npath=owner/repo\n'
        for field, value in (('protocol', 'https'), ('host', 'github.com'),
                             ('path', 'owner/repo'), ('username', 'user'), ('unknown', 'value')):
            extra = field + '=' + value + '\n'
            duplicate = extra if field in ('protocol', 'host', 'path') else extra * 2
            with self.subTest(field=field), patch.object(helper.subprocess, 'run') as run:
                with self.assertRaisesRegex(ValueError, 'duplicate field'):
                    helper.credential('get', source + duplicate + '\n')
                run.assert_not_called()

    def test_git_credential_fill_calls_helper(self):
        # Isolate Git from user/system configuration and use only a fake token.
        launcher = self.root / 'credential.py'
        captured = self.root / 'credential-input'
        launcher.write_text(
            'import io, pathlib, runpy, sys\n'
            'source = sys.stdin.read()\n'
            f'pathlib.Path({str(captured)!r}).write_text(source)\n'
            'sys.stdin = io.StringIO(source)\n'
            f'module = runpy.run_path({str(FILES / "agent-job-github-credential")!r})\n'
            f'module["credential"].__globals__["BROKER"] = {self.fake_broker()!r}\n'
            'sys.exit(module["main"]())\n')
        source = ('protocol=https\nhost=github.com\npath=owner/repo.git\n'
                  'wwwauth[]=Basic realm="GitHub"\nwwwauth[]=Bearer\n\n')
        result = subprocess.run(
            ['git', '-c', 'credential.helper=', '-c',
             'credential.helper=!' + shlex.join([sys.executable, '-I', str(launcher)]),
             '-c', 'credential.useHttpPath=true', 'credential', 'fill'],
            input=source, text=True, capture_output=True, check=True, timeout=10,
            cwd=self.root, env={'PATH': '/usr/bin:/bin', 'HOME': str(self.root),
                               'GIT_CONFIG_NOSYSTEM': '1', 'GIT_CONFIG_GLOBAL': '/dev/null',
                               'GIT_TERMINAL_PROMPT': '0'})
        self.assertIn('username=x-access-token\npassword=ghs_LOCAL_FIXTURE\n', result.stdout)
        received = captured.read_text().splitlines()
        for field in source.splitlines():
            if field:
                self.assertIn(field, received)

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
            if copy.get('dest') in ('/etc/gh-broker/github-app.pem', '/etc/gh-broker/github-app.json'):
                self.assertEqual((copy['mode'], copy['owner'], task['no_log']), ('0400', 'gh-broker', True))
        copies = {task['ansible.builtin.copy']['dest'] for task in block if 'ansible.builtin.copy' in task}
        self.assertTrue({'/etc/gh-broker/github-app.pem', '/etc/gh-broker/github-app.json'} <= copies)
        directory = next(task['ansible.builtin.file'] for task in block
                         if task.get('ansible.builtin.file', {}).get('path') == '/etc/gh-broker')
        self.assertEqual((directory['owner'], directory['group'], directory['mode']),
                         ('gh-broker', 'gh-broker', '0700'))
        for task in [*tasks, *block]:
            file = task.get('ansible.builtin.file', {})
            paths = task.get('loop', [file.get('path')])
            self.assertFalse({'/etc/homelab', '/etc/homelab/secrets'} & {path for path in paths if isinstance(path, str)})
        cleanup = next(task for task in tasks if task['name'] == 'Remove legacy GitHub App credential files')
        self.assertNotIn('when', cleanup)
        self.assertEqual(cleanup['ansible.builtin.file']['state'], 'absent')
        self.assertEqual(set(cleanup['loop']), {'/etc/homelab/secrets/github-app.pem',
                                              '/etc/homelab/secrets/github-app.json'})
        disabled = next(task for task in tasks if task['name'].startswith('Disable GitHub publication'))
        self.assertIn('/etc/gh-broker', disabled['loop'])
        common = yaml.safe_load((role.parent / 'common/tasks/main.yml').read_text())
        secrets = next(task['ansible.builtin.file'] for task in common
                       if task.get('ansible.builtin.file', {}).get('path') == '/etc/homelab/secrets')
        self.assertEqual((secrets['owner'], secrets['group'], secrets['mode']), ('root', 'root', '0700'))
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

    def test_operator_deploy_key_bypass_opt_in_and_updates(self):
        admin = {'actor_id': 5, 'actor_type': 'RepositoryRole', 'bypass_mode': 'always'}
        deploy_key = {'actor_id': None, 'actor_type': 'DeployKey', 'bypass_mode': 'always'}
        self.assertEqual(operator.desired()['bypass_actors'], [admin])
        self.assertEqual(operator.desired(True)['bypass_actors'], [admin, deploy_key])
        rules, current, writes = [], {}, []
        def api(path, method='GET', body=None, pages=False):
            if path == '/repos/owner/repo' and method == 'GET':
                return {'permissions': {'admin': True}, 'owner': {'login': 'owner'}}
            if path == '/repos/owner/repo/rulesets?includes_parents=false&per_page=100' and method == 'GET':
                return [rules]
            if path == '/repos/owner/repo/rulesets' and method == 'POST':
                rules.append({'name': 'agent-main-protection', 'id': 1})
            elif path != '/repos/owner/repo/rulesets/1':
                raise AssertionError((method, path))
            if method in ('POST', 'PUT'):
                writes.append(json.loads(json.dumps(body)))
                current.clear()
                current.update(body)
            return current
        for allow in (False, True, True, False):
            args = ['repo', 'onboard', 'owner/repo'] + (['--allow-deploy-key-bypass'] if allow else [])
            with patch.object(operator, 'api', api), patch('sys.stdout', io.StringIO()), \
                 patch.object(sys, 'argv', args):
                self.assertEqual(operator.main(), 0)
            self.assertEqual(current['bypass_actors'], [admin, deploy_key] if allow else [admin])
            self.assertEqual(current['rules'], operator.desired()['rules'])
        self.assertEqual(len(writes), 3, 'same flag is idempotent; opt-in and opt-out update existing ruleset')
        with patch.object(operator, 'api', side_effect=AssertionError('API forbidden')), \
             patch.object(sys, 'argv', ['repo', 'onboard', 'owner/repo', '--allow-deploy-key-bypass', '--dry-run']), \
             patch('sys.stdout', io.StringIO()) as output:
            self.assertEqual(operator.main(), 0)
        self.assertIn('"actor_type": "DeployKey"', output.getvalue())
        self.assertIn('"actor_id": null', output.getvalue())
        self.assertNotIn('5715751', output.getvalue(), 'Hermes App never receives bypass')

    def test_ruleset_response_normalization_and_check(self):
        import copy
        for deploy in (False, True):
            wanted = operator.desired(deploy)
            response = copy.deepcopy(wanted)
            response.update(id=27049802, source='owner/repo', source_type='Repository', created_at='fixture')
            for rule in response['rules']:
                rule.update(id=1, source='GitHub')
                if rule['type'] == 'update':
                    del rule['parameters']
            for actor in response['bypass_actors']:
                actor['display_name'] = 'response metadata'
                if actor['actor_type'] == 'DeployKey':
                    del actor['actor_id']
            self.assertTrue(operator.equivalent(response, wanted))
            self.assertTrue(operator.equivalent(wanted, response))
            def api(path, method='GET', body=None, pages=False):
                self.assertEqual(method, 'GET', 'normalized response must not trigger an update')
                if path == '/repos/owner/repo':
                    return {'permissions': {'admin': True}, 'owner': {'login': 'owner'}}
                if path.endswith('?includes_parents=false&per_page=100'):
                    return [[{'name': 'agent-main-protection', 'id': 27049802}]]
                self.assertEqual(path, '/repos/owner/repo/rulesets/27049802')
                return response
            for mode in ('onboard', 'check'):
                with patch.object(operator, 'api', api), patch('sys.stdout', io.StringIO()) as output, \
                     patch.object(sys, 'argv', ['repo', mode, 'owner/repo'] + (['--allow-deploy-key-bypass'] if deploy else [])):
                    self.assertEqual(operator.main(), 0)
                self.assertIn('"matches": true', output.getvalue())
            for field, value in (('enforcement', 'disabled'), ('bypass_actors', []),
                                 ('conditions', {'ref_name': {'include': ['refs/heads/other'], 'exclude': []}}),
                                 ('rules', [{'type': 'update', 'parameters': {'update_allows_fetch_and_merge': True}},
                                            {'type': 'deletion'}, {'type': 'non_fast_forward'}])):
                changed = copy.deepcopy(response)
                changed[field] = value
                self.assertFalse(operator.equivalent(changed, wanted), field)

    def test_operator_check_reads_only_rulesets_without_installation_id(self):
        endpoint = '/repos/owner/repo/rulesets'
        for exists in (True, False):
            calls = []
            def api(path, method='GET', body=None, pages=False):
                self.assertEqual(method, 'GET')
                calls.append(path)
                if path == endpoint + '?includes_parents=false&per_page=100':
                    return [[{'name': 'agent-main-protection', 'id': 1}]] if exists else [[]]
                if path == endpoint + '/1':
                    return operator.desired()
                raise AssertionError(path)
            with patch.object(operator, 'api', api), patch('sys.stdout', io.StringIO()) as output, \
                 patch.object(sys, 'argv', ['repo', 'check', 'owner/repo']), \
                 patch.dict(os.environ, {'GITHUB_APP_INSTALLATION_ID': ''}):
                self.assertEqual(operator.main(), 0 if exists else 1)
            result = json.loads(output.getvalue())
            self.assertEqual(set(result), {'repository', 'ruleset', 'matches'})
            self.assertTrue(all(path.startswith(endpoint) for path in calls))

    def test_operator_ruleset_idempotency_update_and_manual_install_guidance(self):
        calls, rules = [], []
        current = {}
        def api(path, method='GET', body=None, pages=False):
            calls.append((method, path))
            self.assertTrue(path.startswith('/repos/owner/repo'), path)
            if path == '/repos/owner/repo':
                return {'id': 99, 'permissions': {'admin': True}, 'owner': {'login': 'owner'}}
            if path.startswith('/repos/owner/repo/rulesets?'):
                return [rules]
            if path == '/repos/owner/repo/rulesets' and method == 'POST':
                current.update(body)
                rules.append({'name': 'agent-main-protection', 'id': 1})
                return current
            if path == '/repos/owner/repo/rulesets/1':
                if method == 'PUT':
                    current.update(body)
                return current
            raise AssertionError(path)
        with patch.object(operator, 'api', api), patch('sys.stdout', io.StringIO()) as output, \
             patch.object(sys, 'argv', ['repo', 'onboard', 'owner/repo', '456']):
            self.assertEqual(operator.main(), 0)
            self.assertEqual(operator.main(), 0)
        self.assertEqual(sum(method == 'POST' for method, _ in calls), 1)
        self.assertFalse(any(method == 'PUT' and '/rulesets/' in path for method, path in calls))
        self.assertIn('https://github.com/settings/installations/456', output.getvalue())
        self.assertIn('Repository access', output.getvalue())
        self.assertIn('not checked or changed', output.getvalue())
        current['enforcement'] = 'disabled'
        with patch.object(operator, 'api', api), patch('sys.stdout', io.StringIO()), \
             patch.object(sys, 'argv', ['repo', 'onboard', 'owner/repo', '456']):
            self.assertEqual(operator.main(), 0)
        self.assertEqual(current['enforcement'], 'active')
        self.assertEqual(sum(method == 'PUT' for method, _ in calls), 1)
        ruleset = operator.desired()
        reordered = dict(ruleset, rules=list(reversed(ruleset['rules'])))
        self.assertTrue(operator.equivalent(reordered, ruleset))
        drifted = dict(ruleset, enforcement='disabled')
        self.assertFalse(operator.equivalent(drifted, ruleset))
        self.assertEqual(ruleset['bypass_actors'], [{'actor_id': 5, 'actor_type': 'RepositoryRole', 'bypass_mode': 'always'}])
        self.assertEqual({rule['type'] for rule in ruleset['rules']}, {'update', 'deletion', 'non_fast_forward'})


if __name__ == '__main__':
    unittest.main()
