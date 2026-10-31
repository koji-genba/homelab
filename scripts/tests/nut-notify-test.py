#!/usr/bin/env python3
"""Local HTTP delivery and mocked UPS data; no secrets, UPS or SSH involved."""
import http.server
import importlib.machinery
import importlib.util
import json
from pathlib import Path
import sys
import tempfile
import threading
import unittest
from unittest.mock import patch

SOURCE = Path(__file__).resolve().parents[2] / (
    'files/infrastructure/ansible/pve1/roles/nut/files/homelab-nut-notify')
loader = importlib.machinery.SourceFileLoader('notify', str(SOURCE))
spec = importlib.util.spec_from_loader(loader.name, loader)
notify = importlib.util.module_from_spec(spec)
sys.dont_write_bytecode = True
loader.exec_module(notify)


class NotificationTest(unittest.TestCase):
    def test_json_delivery_and_secondary_detection(self):
        received = []

        class Handler(http.server.BaseHTTPRequestHandler):
            def do_POST(self):
                received.append(json.loads(self.rfile.read(int(self.headers['Content-Length']))))
                self.send_response(204)
                self.end_headers()

            def log_message(self, *args):
                pass

        with tempfile.TemporaryDirectory() as tmp, \
                http.server.HTTPServer(('127.0.0.1', 0), Handler) as server:
            webhook = Path(tmp) / 'webhook'
            webhook.write_text(f'http://127.0.0.1:{server.server_port}/dummy')
            thread = threading.Thread(target=server.handle_request, daemon=True)
            thread.start()
            def query(*args):
                if args[0] == '-c':
                    return '127.0.0.1\n::ffff:192.168.10.51'
                return 'battery.charge: 90\nbattery.runtime: 1000\nups.load: 20\ninput.voltage: 100'
            with patch.object(notify, 'WEBHOOK_FILE', webhook), \
                    patch.object(notify, 'query', query), \
                    patch.object(notify.socket, 'gethostname', return_value='pve1 "test"\n日本語'):
                notify.send('ONLINE')
            thread.join(timeout=3)
        self.assertEqual(len(received), 1)
        text = received[0]['content']
        self.assertIn('pve1 "test"\n日本語', text)
        self.assertIn('battery.runtime: 1000', text)
        self.assertIn('DGX(.52)', text)
        self.assertNotIn('DGX(.51)', text)
        self.assertEqual(received[0]['allowed_mentions'], {'parse': []})

    def test_missing_values_and_failed_client_query(self):
        with patch.object(notify, 'query', return_value=None):
            text = notify.message('ONLINE')
        self.assertIn('取得不可', text)
        self.assertIn('接続元を取得できません', text)
        self.assertNotIn('停止している可能性', text)

    def test_delivery_failure_logs_without_url(self):
        with tempfile.TemporaryDirectory() as tmp:
            webhook = Path(tmp) / 'webhook'
            webhook.write_text('http://127.0.0.1:1/private-value')
            actual_run = notify.subprocess.run
            logged = []
            def run(args, **kwargs):
                if args[0] == 'logger':
                    logged.append(args)
                    return None
                return actual_run(args, **kwargs)
            with patch.object(notify, 'WEBHOOK_FILE', webhook), \
                    patch.object(notify, 'query', return_value=None), \
                    patch.object(notify.subprocess, 'run', run):
                notify.send('ONBATT')
        self.assertEqual(len(logged), 1)
        self.assertNotIn('private-value', str(logged))


if __name__ == '__main__':
    unittest.main()
