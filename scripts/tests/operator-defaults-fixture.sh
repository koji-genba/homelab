#!/bin/bash
set -euo pipefail
repo_root=$(cd "$(dirname "$0")/../.." && pwd)
fixture=$(mktemp -d)
trap 'rm -rf "$fixture"' EXIT
# Everything below is synthetic, including keys, credentials, ACL and Terraform.
python3 - "$repo_root" "$fixture" <<'PY'
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys

source, temp = map(Path, sys.argv[1:])
repo = temp / 'repo'
(repo / 'scripts').mkdir(parents=True)
for name in ('operator-terraform.py', 'operator-secrets-set.sh', 'validate-tailscale-acl-path.sh', 'validate-secrets.sh'):
    shutil.copy(source / 'scripts' / name, repo / 'scripts' / name)
shutil.copy(source / 'Makefile', repo / 'Makefile')
secrets = repo / 'files/infrastructure/secrets'
secrets.mkdir(parents=True)
shutil.copy(source / 'files/infrastructure/secrets/age-recipient.txt', secrets)
(repo / 'files/infrastructure/terraform/tailscale').mkdir(parents=True)
(repo / 'root').mkdir()
keys = temp / 'keys.txt'
subprocess.run(['age-keygen', '-o', str(keys)], check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
recipient = subprocess.check_output(['age-keygen', '-y', str(keys)], text=True).strip()
binpath = temp / 'bin'
binpath.mkdir()
# Stub records booleans and public argv only; assertions compare values in memory.
(binpath / 'terraform').write_text('''#!/usr/bin/env python3
import json, os, pathlib, sys, time
forbidden=os.environ["FORBIDDEN_ARG_VALUE"].encode()
pid=os.getpid()
while pid > 1:
    assert forbidden not in pathlib.Path(f"/proc/{pid}/cmdline").read_bytes()
    pid=int(pathlib.Path(f"/proc/{pid}/stat").read_text().rsplit(")",1)[1].split()[1])
keys = ('TF_VAR_proxmox_api_token','TAILSCALE_OAUTH_CLIENT_ID','TAILSCALE_OAUTH_CLIENT_SECRET','TAILSCALE_API_KEY')
args=sys.argv[1:]
root=pathlib.Path(next((a.split('=',1)[1] for a in args if a.startswith('-chdir=')), '.'))
operation=next(a for a in args if not a.startswith('-'))
if operation == 'show':
    if os.environ.get('SHOW_FAIL'): sys.exit(1)
    sys.stdout.write((root / args[-1]).read_text()); sys.exit(0)
record = {'argv': args, 'present': [k for k in keys if os.environ.get(k)]}
policy=None
if operation == 'apply' and any(os.environ.get(k) for k in keys[1:]):
    assert not any(a.startswith('-var') for a in args)
    policy=json.loads((root / args[-1]).read_text())['variables']['acl_policy_file']['value']

for k in keys:
    if os.environ.get('EXPECT_' + k):
        assert os.environ.get(k) == os.environ['EXPECT_' + k]
for a in sys.argv:
    if a.startswith('-var=acl_policy_file='):
        policy=a.split('=',2)[2]
if policy:
    p=pathlib.Path(policy); assert p.read_text() == '{"acls":[]}'
    assert p.stat().st_mode & 0o777 == 0o600
    assert p.parent.stat().st_mode & 0o777 == 0o700
    record['acl'] = str(p)
if operation == 'plan':
    for a in args:
        if a.startswith('-out='):
            (root / a.split('=',1)[1]).write_text(json.dumps({'variables': {'acl_policy_file': {'value':policy}},
                'private_fixture_value':'fixture-plan-private-do-not-log'}))

with open(os.environ['CALLS'], 'a') as out: out.write(json.dumps(record)+'\\n')
if os.environ.get('TF_WAIT'): time.sleep(30)
sys.exit(int(os.environ.get('TF_EXIT', '0')))
''')
# Local stand-in for docker: capture argv and execute the toolbox Python command.
(binpath / 'docker').write_text('''#!/usr/bin/env python3
import json,os,sys
with open(os.environ['DOCKER_CALLS'],'a') as f: f.write(json.dumps(sys.argv[1:])+'\\n')
i=sys.argv.index('python3'); os.execvp(sys.argv[i],sys.argv[i:])
''')
for path in binpath.iterdir():
    path.chmod(0o755)
env = {k: v for k, v in os.environ.items() if not k.startswith(('TF_VAR_', 'TAILSCALE_', 'SOPS_', 'AGE_', 'MAKE'))}
env.update(PATH=str(binpath) + ':' + env['PATH'], AGE_IDENTITY_FILE=str(keys), SOPS_AGE_KEY_FILE=str(keys),
           AGE_RECIPIENT=recipient, CALLS=str(temp/'calls'), DOCKER_CALLS=str(temp/'docker-calls'))
wrapper = [sys.executable, 'scripts/operator-terraform.py']
secret = 'fixture-$dollar-\'quote"-`literal`-$(false)'
env['FORBIDDEN_ARG_VALUE'] = secret

def run(args, *, extra=None, data=None, ok=True):
    result = subprocess.run(args, cwd=repo, env=env | (extra or {}), input=data,
                            text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    assert secret not in result.stdout + result.stderr
    assert 'fixture-plan-private-do-not-log' not in result.stdout + result.stderr
    if ok:
        assert result.returncode == 0, result.stdout + result.stderr
    else:
        assert result.returncode != 0
    return result

def encrypt(provider, payload):
    run(wrapper + ['--encrypt', provider], data=json.dumps(payload))

def last():
    return json.loads((temp/'calls').read_text().splitlines()[-1])

# Both absent -> readable error, before Terraform is started.
result = run(wrapper + ['proxmox', '-chdir=root', 'plan'], ok=False)
assert 'missing proxmox credentials' in result.stderr
assert not (temp/'calls').exists()
encrypt('proxmox', {'TF_VAR_proxmox_api_token': secret})
run(wrapper + ['proxmox', '-chdir=root', 'plan', '-var=public=a b\'c"$d'],
    extra={'EXPECT_TF_VAR_proxmox_api_token': secret})
assert last()['present'] == ['TF_VAR_proxmox_api_token']
assert last()['argv'][-1] == '-var=public=a b\'c"$d'
for operation in ('apply','import','state'):
    run(wrapper + ['proxmox', '-chdir=root', operation], extra={'EXPECT_TF_VAR_proxmox_api_token': secret})
run(wrapper + ['proxmox', 'plan'], extra={'TF_VAR_proxmox_api_token':'explicit', 'EXPECT_TF_VAR_proxmox_api_token':'explicit'})
run(wrapper + ['--check','proxmox'])
result=run(wrapper + ['proxmox','plan'], extra={'SOPS_AGE_KEY_FILE':str(temp/'missing')}, ok=False)
assert 'age identity is missing' in result.stderr
# OAuth partial overrides and API/OAuth mode selection.
encrypt('tailscale', {'TAILSCALE_OAUTH_CLIENT_ID':'bundle-id','TAILSCALE_OAUTH_CLIENT_SECRET':secret})
run(wrapper + ['tailscale','state'], extra={'TAILSCALE_OAUTH_CLIENT_ID':'explicit-id',
    'EXPECT_TAILSCALE_OAUTH_CLIENT_ID':'explicit-id','EXPECT_TAILSCALE_OAUTH_CLIENT_SECRET':secret})
run(wrapper + ['tailscale','state'], extra={'TAILSCALE_API_KEY':'explicit-api', 'EXPECT_TAILSCALE_API_KEY':'explicit-api'})
assert last()['present']==['TAILSCALE_API_KEY']
encrypt('tailscale', {'TAILSCALE_API_KEY':secret})
run(wrapper + ['tailscale','state'], extra={'EXPECT_TAILSCALE_API_KEY':secret})
run(wrapper + ['tailscale','state'], extra={'TAILSCALE_OAUTH_CLIENT_ID':'env-id','TAILSCALE_OAUTH_CLIENT_SECRET':'env-secret'})
assert last()['present']==['TAILSCALE_OAUTH_CLIENT_ID','TAILSCALE_OAUTH_CLIENT_SECRET']
# ACL encrypted canonical source, no real ACL is opened.
acl = secrets / 'tailscale/acl-policy.sops.json'
acl.parent.mkdir()
with acl.open('wb') as out:
    subprocess.run(['sops','encrypt','--age',recipient,'--input-type','binary','--output-type','json','/dev/stdin'],
                   input=b'{"acls":[]}', stdout=out, stderr=subprocess.DEVNULL, check=True, env=env)
for operation in ('plan','import'):
    run(wrapper + ['tailscale','-chdir=root',operation])
    assert not Path(last()['acl']).exists()
run(wrapper + ['tailscale','plan'], extra={'TF_EXIT':'7'}, ok=False)
assert not Path(last()['acl']).exists()
# Saved plans retain a stable path, restored again before saved-plan apply.
fixed=repo/'tmp/tailscale-acl/policy.json'
run(wrapper + ['tailscale','-chdir=root','plan','-out=default.tfplan'])
assert last()['acl']==str(fixed) and not fixed.exists()
saved=json.loads((repo/'root/default.tfplan').read_text())
assert saved['variables']['acl_policy_file']['value']==str(fixed)
apply=wrapper + ['tailscale','-chdir=root','apply','-input=false','default.tfplan']
run(apply, extra={'ACL_POLICY_FILE':'an-override-cannot-change-the-saved-plan'})
assert last()['acl']==str(fixed) and not fixed.parent.exists()
run(apply, extra={'TF_EXIT':'7'}, ok=False)
assert not fixed.parent.exists()
# Explicit ACL plans remain explicit even when apply has no ACL_POLICY_FILE.
explicit_dir=repo/'explicit'; explicit_dir.mkdir(mode=0o700)
explicit=explicit_dir/'policy.json'; explicit.write_text('{"acls":[]}'); explicit.chmod(0o600)
run(wrapper + ['tailscale','-chdir=root','plan','-out=explicit.tfplan','-var=acl_policy_file='+str(explicit)])
run(wrapper + ['tailscale','-chdir=root','apply','explicit.tfplan'])
assert last()['acl']==str(explicit) and explicit.exists() and not fixed.parent.exists()
explicit.unlink()
result=run(wrapper + ['tailscale','-chdir=root','apply','explicit.tfplan'], ok=False)
assert not fixed.parent.exists()
# Invalid or uninspectable plans cannot fall back to an arbitrary default.
for plan_value in ('not json', '{}'):
    (repo/'root/bad.tfplan').write_text(plan_value)
    result=run(wrapper + ['tailscale','-chdir=root','apply','bad.tfplan'], ok=False)
    assert 'no valid ACL path' in result.stderr
    assert not fixed.parent.exists()
result=run(apply, extra={'SHOW_FAIL':'1'}, ok=False)
assert 'cannot inspect saved plan' in result.stderr
# Preexisting directories/files are never overwritten or removed by a loser.
fixed.parent.mkdir(mode=0o700); fixed.write_text('owned-by-another-run')
for command in (wrapper+['tailscale','plan'], apply):
    result=run(command,ok=False)
    assert 'already exists' in result.stderr
    assert fixed.read_text()=='owned-by-another-run'
fixed.unlink(); fixed.parent.rmdir()
# TERM stops Terraform and removes the fixed ACL for both plan and apply.
import time
for command in (wrapper+['tailscale','plan'], apply):
    before_count=len((temp/'calls').read_text().splitlines())
    child=subprocess.Popen(command, cwd=repo, env=env | {'TF_WAIT':'1'},
                           stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    for _ in range(100):
        if len((temp/'calls').read_text().splitlines()) > before_count: break
        time.sleep(0.05)
    else: raise AssertionError('Terraform stub did not start')
    assert fixed.exists()
    # A simultaneous operation must not delete the first operation's file.
    result=run(apply,ok=False)
    assert 'already exists' in result.stderr and fixed.exists()
    child.terminate()
    stdout,stderr=child.communicate(timeout=10)
    assert secret.encode() not in stdout+stderr
    for _ in range(100):
        if not fixed.parent.exists(): break
        time.sleep(0.05)
    assert not fixed.parent.exists()
live=repo/'files/infrastructure/terraform/tailscale/acl-policy.live.json'
live.write_text('{"acls":[]}')
run(wrapper + ['tailscale','plan'])
live.write_text('{"different":true}')
before=(temp/'calls').read_text()
result=run(wrapper + ['tailscale','plan'], ok=False)
assert 'differs from canonical' in result.stderr
result=run(apply,ok=False)
assert 'differs from canonical' in result.stderr
assert before==(temp/'calls').read_text()
assert not list((repo/'tmp').iterdir())
live.unlink()
# Drive the actual host prompt and encryption target; inspect every leftover file.
run(['bash','scripts/operator-secrets-set.sh','proxmox'], data='y\n'+secret+'\n')
run(wrapper + ['proxmox','plan'], extra={'EXPECT_TF_VAR_proxmox_api_token':secret})
run(['bash','scripts/operator-secrets-set.sh','proxmox'], data='n\n', ok=False)
for path in repo.rglob('*'):
    if path.is_file():
        assert secret.encode() not in path.read_bytes(), str(path)
assert secret not in (temp/'calls').read_text() + (temp/'docker-calls').read_text()
# Exercise both Tailscale host prompt choices as well as direct encryption.
run(['bash','scripts/operator-secrets-set.sh','tailscale'], data='y\noauth\nhost-id\n'+secret+'\n')
run(wrapper + ['tailscale','state'], extra={'EXPECT_TAILSCALE_OAUTH_CLIENT_ID':'host-id',
    'EXPECT_TAILSCALE_OAUTH_CLIENT_SECRET':secret})
run(['bash','scripts/operator-secrets-set.sh','tailscale'], data='y\napi\n'+secret+'\n')
run(wrapper + ['tailscale','state'], extra={'EXPECT_TAILSCALE_API_KEY':secret})
# Missing bundle retains allowlisted environment fallback.
(secrets/'operator/proxmox.sops.yaml').unlink()
run(wrapper + ['proxmox','plan'], extra={'TF_VAR_proxmox_api_token':secret,'EXPECT_TF_VAR_proxmox_api_token':secret})
# Make defaults and export to host children; do not invoke any real target.
(repo/'print.mk').write_text('include Makefile\nprint-defaults:\n\t@printf "%s\\n" "$$AGE_IDENTITY_FILE" "$$AGE_RECIPIENT" "$(MANAGE_TAILNET) $(ENABLE_ADGUARD_DNS) $(ADGUARD_READY) $(MANAGE_SUBNET_ROUTER) $(ADGUARD_NAMESERVER_IP)"\n')
default_env = {k:v for k,v in env.items() if k not in ('AGE_IDENTITY_FILE','AGE_RECIPIENT')}
result=subprocess.run(['make','-s','-f','print.mk','print-defaults'],cwd=repo,env=default_env,text=True,capture_output=True,check=True)
assert result.stdout.splitlines()==[env['HOME']+'/.config/sops/age/keys.txt', (secrets/'age-recipient.txt').read_text().strip(), 'true true true false 100.86.147.127']
result=run(['make','-s','-f','print.mk','print-defaults','AGE_IDENTITY_FILE=/override','AGE_RECIPIENT=override'])
assert result.stdout.startswith('/override\noverride\n')
# Plaintext operator file and values disguised as .sops.yaml must fail scan.
subprocess.run(['git','init','-q',str(repo)],check=True)
run(['sh','scripts/validate-secrets.sh'])
p=secrets/'operator/proxmox.sops.yaml'
p.write_text('TF_VAR_proxmox_api_token: fake-plaintext\nsops: {}\n')
run(['sh','scripts/validate-secrets.sh'],ok=False)
p.unlink()
p=secrets/'operator/proxmox.yaml';p.write_text('fake-plaintext')
run(['sh','scripts/validate-secrets.sh'],ok=False)
print('operator defaults fixture: ok')
PY
