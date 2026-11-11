#!/usr/bin/env python3
"""Operator-side main ruleset management/check using the operator's gh login."""
import argparse
import json
import os
import re
import subprocess
import sys


def api(path, method='GET', body=None, pages=False):
    args = ['gh', 'api', '--hostname', 'github.com', '-H', 'X-GitHub-Api-Version: 2022-11-28',
            '--method', method, path]
    if pages:
        args += ['--paginate']
    if body is not None:
        args += ['--input', '-']
    result = subprocess.run(args, input=None if body is None else json.dumps(body),
                            capture_output=True, text=True)
    if result.returncode:
        # gh errors may contain auth details: do not echo its output.
        raise ValueError('GitHub API failed: ' + method + ' ' + path)
    if pages:
        # gh 2.45/2.46 lack --slurp; --paginate emits consecutive JSON documents.
        decoder = json.JSONDecoder()
        documents = []
        remaining = result.stdout.lstrip()
        while remaining:
            value, offset = decoder.raw_decode(remaining)
            documents.append(value)
            remaining = remaining[offset:].lstrip()
        return documents
    return json.loads(result.stdout) if result.stdout.strip() else None


# DeployKey actor_id must be null (not a particular key ID):
# https://docs.github.com/en/rest/repos/rules#create-a-repository-ruleset
def desired(allow_deploy_key_bypass=False):
    bypass = [{'actor_id': 5, 'actor_type': 'RepositoryRole', 'bypass_mode': 'always'}]
    if allow_deploy_key_bypass:
        bypass.append({'actor_id': None, 'actor_type': 'DeployKey', 'bypass_mode': 'always'})
    return {'name': 'agent-main-protection', 'target': 'branch', 'enforcement': 'active',
            'bypass_actors': bypass,
            'conditions': {'ref_name': {'include': ['refs/heads/main'], 'exclude': []}},
            'rules': [{'type': 'update', 'parameters': {'update_allows_fetch_and_merge': False}},
                      {'type': 'deletion'}, {'type': 'non_fast_forward'}]}


def equivalent(current, wanted):
    def normalized(policy):
        # Compare policy fields, not response metadata such as IDs, URLs or timestamps.
        rules = []
        for rule in policy.get('rules') or []:
            value = {'type': rule.get('type')}
            if value['type'] == 'update':
                value['parameters'] = {'update_allows_fetch_and_merge':
                    (rule.get('parameters') or {}).get('update_allows_fetch_and_merge', False)}
            rules.append(value)
        actors = [{'actor_type': actor.get('actor_type'), 'actor_id': actor.get('actor_id'),
                   'bypass_mode': actor.get('bypass_mode', 'always')}
                  for actor in policy.get('bypass_actors') or []]
        refs = (policy.get('conditions') or {}).get('ref_name') or {}
        return {key: policy.get(key) for key in ('name', 'target', 'enforcement')} | {
            'rules': sorted(rules, key=lambda value: json.dumps(value, sort_keys=True)),
            'bypass_actors': sorted(actors, key=lambda value: json.dumps(value, sort_keys=True)),
            'conditions': {'ref_name': {key: sorted(refs.get(key) or []) for key in ('include', 'exclude')}}}
    return normalized(current) == normalized(wanted)


def rulesets(target):
    return [item for page in api('/repos/' + target + '/rulesets?includes_parents=false&per_page=100', pages=True)
            for item in page if item['name'] == 'agent-main-protection']


def show(target, wanted):
    found = rulesets(target)
    if len(found) > 1:
        raise ValueError('duplicate agent-main-protection rulesets; resolve manually')
    configured = api('/repos/' + target + '/rulesets/' + str(found[0]['id'])) if found else None
    matches = configured is not None and equivalent(configured, wanted)
    print(json.dumps({'repository': target, 'ruleset': configured, 'matches': matches}, indent=2, ensure_ascii=False))
    return 0 if matches else 1


def installation_guidance(target, identifier):
    print('Next: after confirming the ruleset, manually add ' + target +
          ' under Repository access (Only select repositories) at ' +
          'https://github.com/settings/installations/' + identifier +
          '. Installation access is not checked or changed by this script.')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('mode', choices=['onboard', 'check'])
    parser.add_argument('repository')
    parser.add_argument('installation', nargs='?', help='installation ID for the manual setup link only')
    parser.add_argument('--installation-id', default=os.environ.get('GITHUB_APP_INSTALLATION_ID', '180956595'),
                        help='installation ID for the manual setup link only')
    parser.add_argument('--allow-deploy-key-bypass', action='store_true',
                        help='allow deploy keys to bypass main protection; check compares against this policy')
    parser.add_argument('--dry-run', action='store_true')
    args = parser.parse_args()
    target = args.repository
    if not re.fullmatch(r'[A-Za-z0-9](?:[A-Za-z0-9-]{0,37}[A-Za-z0-9])?/[A-Za-z0-9_.-]{1,100}', target):
        parser.error('invalid owner/repo')
    owner, repo = target.split('/')
    if '--' in owner or repo in ('.', '..') or repo.endswith('.git'):
        parser.error('invalid owner/repo')
    identifier = args.installation or args.installation_id
    if args.mode == 'onboard' and not re.fullmatch(r'[1-9][0-9]*', identifier):
        parser.error('installation ID required: argument, --installation-id or GITHUB_APP_INSTALLATION_ID')
    if args.dry_run:
        print('No API calls. Read the repository ruleset list and matching ruleset details.')
        print('GET /repos/' + target + '/rulesets')
        if args.mode == 'onboard':
            print('Create or update /repos/' + target + '/rulesets (protect main BEFORE adding repo):')
            print(json.dumps(desired(args.allow_deploy_key_bypass), indent=2))
            installation_guidance(target, identifier)
        return 0
    if args.mode == 'onboard':
        repository = api('/repos/' + target)
        if not repository.get('permissions', {}).get('admin'):
            raise ValueError('operator must be repository admin')
        if repository['owner']['login'].lower() != owner.lower():
            raise ValueError('repository owner mismatch')
        found = rulesets(target)
        if len(found) > 1:
            raise ValueError('duplicate agent-main-protection rulesets; resolve manually')
        endpoint = '/repos/' + target + '/rulesets'
        wanted = desired(args.allow_deploy_key_bypass)
        if found:
            endpoint += '/' + str(found[0]['id'])
            current = api(endpoint)
            if not equivalent(current, wanted):
                api(endpoint, 'PUT', wanted)
        else:
            api(endpoint, 'POST', wanted)
    status = show(target, desired(args.allow_deploy_key_bypass))
    if args.mode == 'onboard' and status == 0:
        installation_guidance(target, identifier)
    return status


if __name__ == '__main__':
    try:
        sys.exit(main())
    except (ValueError, KeyError, OSError) as error:
        print('GitHub onboarding/check failed: ' + str(error), file=sys.stderr)
        sys.exit(1)
