#!/usr/bin/env python3
"""Toolbox-only credential injection and short-lived canonical ACL input."""
import json
import os
from pathlib import Path
import shlex
import signal
import subprocess
import sys
import tempfile

KEYS = {
    'proxmox': ('TF_VAR_proxmox_api_token',),
    'tailscale': ('TAILSCALE_OAUTH_CLIENT_ID', 'TAILSCALE_OAUTH_CLIENT_SECRET', 'TAILSCALE_API_KEY'),
}
REPO = Path(__file__).absolute().parent.parent


def fail(message):
    print('operator: ' + message, file=sys.stderr)
    raise SystemExit(1)


def bundle_path(provider):
    if provider not in KEYS:
        fail('PROVIDER must be proxmox or tailscale')
    return REPO / 'files/infrastructure/secrets/operator' / (provider + '.sops.yaml')


def require_identity():
    identity = os.environ.get('SOPS_AGE_KEY_FILE') or os.environ.get('AGE_IDENTITY_FILE')
    if not identity or not Path(identity).is_file() or not os.access(identity, os.R_OK):
        fail('age identity is missing: restore ~/.config/sops/age/keys.txt or set AGE_IDENTITY_FILE to a readable file')


def sops(arguments, **kwargs):
    # SOPS errors may include input; do not forward its diagnostics.
    # Ancillary crypto commands do not need provider credentials.
    crypto_env = {k: v for k, v in os.environ.items()
                  if k not in sum(KEYS.values(), ()) and not k.startswith('OPERATOR_EXPLICIT_')}
    result = subprocess.run(['sops', *arguments], stderr=subprocess.PIPE, env=crypto_env, **kwargs)
    if result.returncode:
        fail('SOPS operation failed; check age identity, recipient and encrypted bundle')
    return result


def validate_payload(provider, payload):
    if (not isinstance(payload, dict) or not payload
            or not set(payload).issubset(KEYS[provider])
            or any(not isinstance(v, str) or not v for v in payload.values())):
        fail('operator bundle must contain only the documented string keys and nonempty string values')
    validate_credentials(provider, payload)
    if provider == 'tailscale' and 'TAILSCALE_API_KEY' in payload and len(payload) != 1:
        fail('choose either OAuth credentials or API key in the bundle')


def validate_credentials(provider, env):
    if provider == 'proxmox':
        valid = bool(env.get('TF_VAR_proxmox_api_token'))
    else:
        valid = bool(env.get('TAILSCALE_API_KEY')) or bool(
            env.get('TAILSCALE_OAUTH_CLIENT_ID') and env.get('TAILSCALE_OAUTH_CLIENT_SECRET'))
    if not valid:
        fail('missing ' + provider + ' credentials: run make operator-secrets-set PROVIDER=' + provider
             + ' or export the documented provider environment variables')


def encrypt(provider):
    target = bundle_path(provider)
    try:
        payload = json.load(sys.stdin)
    except (ValueError, TypeError):
        fail('invalid operator input')
    validate_payload(provider, payload)
    recipient = os.environ.get('AGE_RECIPIENT')
    if not recipient:
        fail('AGE_RECIPIENT is required')
    target.parent.mkdir(parents=True, exist_ok=True)
    if target.is_symlink():
        fail('operator bundle symlinks are not accepted')
    # The temporary file contains only ciphertext; plaintext travels via stdin.
    descriptor, temporary = tempfile.mkstemp(prefix='.operator-encrypt.', dir=target.parent)
    try:
        with os.fdopen(descriptor, 'wb') as output:
            sops(['encrypt', '--age', recipient, '--input-type', 'json', '--output-type', 'yaml', '/dev/stdin'],
                 input=json.dumps(payload).encode(), stdout=output)
        os.replace(temporary, target)
    finally:
        Path(temporary).unlink(missing_ok=True)
    print('operator bundle encrypted: ' + provider)


def wait_command(command, *, new_group=False, **kwargs):
    child = subprocess.Popen(command, start_new_session=new_group, **kwargs)
    try:
        return child.wait()
    except (SystemExit, KeyboardInterrupt):
        if new_group:
            os.killpg(child.pid, signal.SIGTERM)
        else:
            child.terminate()
        child.wait()
        raise


def check_acl_path(provider, policy):
    subprocess.run([str(REPO / 'scripts/validate-tailscale-acl-path.sh'), str(policy)],
                   check=True, stdout=subprocess.DEVNULL,
                   env={k: v for k, v in os.environ.items() if k not in KEYS[provider]})


def saved_acl_path(arguments, index):
    plans = [a for a in arguments[index + 1:] if not a.startswith('-')]
    if len(plans) != 1:
        fail('Tailscale apply requires exactly one saved plan')
    # Keep the complete plan JSON in memory; never forward its diagnostics/data.
    result = subprocess.run(['terraform', *arguments[:index], 'show', '-json', plans[0]],
                            stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
    if result.returncode:
        fail('cannot inspect saved plan ACL path; recreate the saved plan')
    try:
        value = json.loads(result.stdout)['variables']['acl_policy_file']['value']
        if not isinstance(value, str):
            raise ValueError
    except (ValueError, KeyError, TypeError):
        fail('saved plan has no valid ACL path; recreate the saved plan')
    return value


def run_terraform(provider, arguments):
    validate_credentials(provider, os.environ)
    operations = ('plan', 'import', 'apply')
    if provider != 'tailscale' or not any(a in operations for a in arguments):
        return wait_command(['terraform', *arguments])
    index = next(i for i, a in enumerate(arguments) if a in operations)
    applying = arguments[index] == 'apply'
    directory = REPO / 'tmp/tailscale-acl'
    policy = directory / 'policy.json'
    if applying:
        # The saved plan determines its input. Current Make overrides cannot
        # change a saved variable, and apply must never receive another -var.
        saved = saved_acl_path(arguments, index)
        if saved != str(policy):
            if saved:
                check_acl_path(provider, saved)
            return wait_command(['terraform', *arguments])
    elif any(a.startswith('-var=acl_policy_file=') for a in arguments):
        # An explicit plan/import input is checked by the host preflight.
        return wait_command(['terraform', *arguments])
    require_identity()
    parent = directory.parent
    if parent.is_symlink():
        fail('ACL temporary parent must not be a symlink')
    parent.mkdir(mode=0o700, exist_ok=True)
    # Atomic mkdir is both ownership of cleanup and the concurrent-run gate.
    # Never remove an existing directory, including one left by SIGKILL.
    try:
        directory.mkdir(mode=0o700)
    except FileExistsError:
        fail('ACL temporary directory already exists; stop other runs or inspect stale files before retrying')
    try:
        with policy.open('xb') as output:
            sops(['decrypt', '--input-type', 'json', '--output-type', 'binary',
                  str(REPO / 'files/infrastructure/secrets/tailscale/acl-policy.sops.json')], stdout=output)
        policy.chmod(0o600)
        live = REPO / 'files/infrastructure/terraform/tailscale/acl-policy.live.json'
        if live.exists() or live.is_symlink():
            if live.is_symlink() or not live.is_file():
                fail('local ACL must be a regular file')
            if live.read_bytes() != policy.read_bytes():
                fail('local acl-policy.live.json differs from canonical encrypted ACL; operator must choose the correct policy')
        check_acl_path(provider, policy)
        if not applying:
            # Terraform flags must precede import's resource address and ID.
            arguments[index + 1:index + 1] = ['-var=acl_policy_file=' + str(policy)]
        return wait_command(['terraform', *arguments])
    finally:
        policy.unlink(missing_ok=True)
        directory.rmdir()


def main():
    os.umask(0o077)
    signal.signal(signal.SIGTERM, lambda *_: sys.exit(143))
    mode = sys.argv[1]
    if mode == '--encrypt':
        encrypt(sys.argv[2])
        return 0
    if mode == '--check':
        provider = sys.argv[2]
        target = bundle_path(provider)
        require_identity()
        raw = sops(['decrypt', '--output-type', 'json', str(target)], stdout=subprocess.PIPE).stdout
        try:
            payload = json.loads(raw)
        except ValueError:
            fail('invalid operator bundle')
        validate_payload(provider, payload)
        print('\n'.join(sorted(payload)))
        return 0
    injected = mode == '--injected'
    provider = sys.argv[2] if injected else mode
    arguments = sys.argv[3:] if injected else sys.argv[2:]
    target = bundle_path(provider)
    if injected:
        for key in KEYS[provider]:
            explicit = os.environ.pop('OPERATOR_EXPLICIT_' + key, None)
            if explicit is not None:
                os.environ[key] = explicit
        # Explicit auth mode wins over the bundle's alternate auth mode.
        auth = os.environ.pop('OPERATOR_AUTH_MODE', '')
        if auth == 'api':
            for key in KEYS['tailscale'][:2]:
                os.environ.pop(key, None)
        elif auth == 'oauth':
            os.environ.pop('TAILSCALE_API_KEY', None)
    elif target.exists():
        require_identity()
        raw = sops(['decrypt', '--output-type', 'json', str(target)], stdout=subprocess.PIPE).stdout
        try:
            payload = json.loads(raw)
        except ValueError:
            fail('invalid operator bundle')
        validate_payload(provider, payload)
        env = os.environ.copy()
        for key in KEYS[provider]:
            if key in env:
                env['OPERATOR_EXPLICIT_' + key] = env[key]
        if provider == 'tailscale':
            if env.get('TAILSCALE_API_KEY'):
                env['OPERATOR_AUTH_MODE'] = 'api'
            elif env.get('TAILSCALE_OAUTH_CLIENT_ID') or env.get('TAILSCALE_OAUTH_CLIENT_SECRET'):
                env['OPERATOR_AUTH_MODE'] = 'oauth'
        # shlex quotes arguments once. Credential values are never shell code.
        command = shlex.join([sys.executable, str(Path(__file__).absolute()), '--injected', provider, *arguments])
        # Decryption/schema errors were checked with diagnostics suppressed above.
        # Preserve Terraform diagnostics and exit status in the actual execution.
        return wait_command(['sops', 'exec-env', str(target), command], new_group=True, env=env)
    return run_terraform(provider, arguments)


if __name__ == '__main__':
    try:
        sys.exit(main())
    except (OSError, subprocess.SubprocessError):
        fail('operator execution failed; check toolbox dependencies and input file permissions')
