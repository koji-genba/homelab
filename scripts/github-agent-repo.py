#!/usr/bin/env python3
"""Operator-side GitHub App onboarding/check using the operator's gh login."""
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


def desired():
    return {'name': 'agent-main-protection', 'target': 'branch', 'enforcement': 'active',
            'bypass_actors': [{'actor_id': 5, 'actor_type': 'RepositoryRole', 'bypass_mode': 'always'}],
            'conditions': {'ref_name': {'include': ['refs/heads/main'], 'exclude': []}},
            'rules': [{'type': 'update', 'parameters': {'update_allows_fetch_and_merge': False}},
                      {'type': 'deletion'}, {'type': 'non_fast_forward'}]}


def equivalent(current, wanted):
    actual = {key: current.get(key) for key in wanted}
    # API response ordering is not part of the protection policy.
    for key in ('rules', 'bypass_actors'):
        actual[key] = sorted(actual.get(key) or [], key=lambda value: json.dumps(value, sort_keys=True))
    expected = dict(wanted)
    for key in ('rules', 'bypass_actors'):
        expected[key] = sorted(wanted[key], key=lambda value: json.dumps(value, sort_keys=True))
    return actual == expected


def installation_info(identifier, owner):
    items = [item for page in api('/user/installations?per_page=100', pages=True)
             for item in page['installations'] if item['id'] == int(identifier)]
    if len(items) != 1 or items[0]['account']['login'].lower() != owner.lower():
        raise ValueError('installation not found on the repository owner account')
    if items[0]['repository_selection'] != 'selected':
        raise ValueError('App installation must use selected repositories')
    if items[0].get('suspended_at'):
        raise ValueError('App installation is suspended')
    return items[0]


def rulesets(target):
    return [item for page in api('/repos/' + target + '/rulesets?includes_parents=false&per_page=100', pages=True)
            for item in page if item['name'] == 'agent-main-protection']


def show(target, identifier):
    found = rulesets(target)
    if len(found) > 1:
        raise ValueError('duplicate agent-main-protection rulesets; resolve manually')
    configured = api('/repos/' + target + '/rulesets/' + str(found[0]['id'])) if found else None
    installed = any(repo['full_name'].lower() == target.lower()
                    for page in api('/user/installations/' + identifier + '/repositories?per_page=100', pages=True)
                    for repo in page['repositories'])
    print(json.dumps({'repository': target, 'installation_id': identifier,
                      'installed': installed, 'ruleset': configured}, indent=2, ensure_ascii=False))
    return 0 if installed and configured else 1


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('mode', choices=['onboard', 'check'])
    parser.add_argument('repository')
    parser.add_argument('installation', nargs='?', help='installation ID (or --installation-id / GITHUB_APP_INSTALLATION_ID)')
    parser.add_argument('--installation-id', default=os.environ.get('GITHUB_APP_INSTALLATION_ID', ''))
    parser.add_argument('--dry-run', action='store_true')
    args = parser.parse_args()
    target = args.repository
    if not re.fullmatch(r'[A-Za-z0-9](?:[A-Za-z0-9-]{0,37}[A-Za-z0-9])?/[A-Za-z0-9_.-]{1,100}', target):
        parser.error('invalid owner/repo')
    owner, repo = target.split('/')
    if '--' in owner or repo in ('.', '..') or repo.endswith('.git'):
        parser.error('invalid owner/repo')
    identifier = args.installation or args.installation_id
    if not re.fullmatch(r'[1-9][0-9]*', identifier):
        parser.error('installation ID required: argument, --installation-id or GITHUB_APP_INSTALLATION_ID')
    if args.dry_run:
        print('No API calls. Read repo ID, installation owner/selected repositories, and existing rulesets.')
        print('GET /repos/' + target + '/rulesets; GET /user/installations/' + identifier + '/repositories')
        if args.mode == 'onboard':
            print('Create or update /repos/' + target + '/rulesets (protect main BEFORE adding repo):')
            print(json.dumps(desired(), indent=2))
            print('PUT /user/installations/' + identifier + '/repositories/<repo_id>')
        return 0
    installation_info(identifier, owner)
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
        wanted = desired()
        if found:
            endpoint += '/' + str(found[0]['id'])
            current = api(endpoint)
            if not equivalent(current, wanted):
                api(endpoint, 'PUT', wanted)
        else:
            api(endpoint, 'POST', wanted)
        api('/user/installations/' + identifier + '/repositories/' + str(repository['id']), 'PUT')
    return show(target, identifier)


if __name__ == '__main__':
    try:
        sys.exit(main())
    except (ValueError, KeyError, OSError) as error:
        print('GitHub onboarding/check failed: ' + str(error), file=sys.stderr)
        sys.exit(1)
