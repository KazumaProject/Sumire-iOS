#!/usr/bin/env python3
"""Evaluate authored fixed Japanese tasks independently of Android agreement.

The provisional corpus is not a population sample or human-validated benchmark.
Reports and generated outputs must stay outside the checkout. No network is used.
"""
import argparse
import json
from pathlib import Path
import subprocess

from quality_assets import atomic_write_json, sha256_file, validate_dictionary_assets

ROOT = Path(__file__).resolve().parents[2]
CORPUS = Path(__file__).with_name('reference') / 'semantic-corpus.json'
CORPUS_SHA256 = '72a316b113919a0160637ed4f2caf883f177419f3e86dc847d4985d889ec3cae'
MANIFEST_SHA256 = '60f44627887e96ef2618d90571234853e89ec193a0b23c2d0f8ab54ce2265f46'
REVISION = 'df1f38315bf56d860d32919a3eaed6a75499e91e'
POLICY_PATH = CORPUS.with_name('semantic-policy.json')
GROUPS = {'word', 'compound', 'sentence', 'homonym', 'omission', 'personal', 'completion'}


def text(value):
    return isinstance(value, str) and bool(value) and '\0' not in value


def integer(value, low, high):
    return type(value) is int and low <= value <= high


def validate_corpus(corpus):
    if corpus.get('schema_version') != 1 or corpus.get('corpus_id') != 'japanese-curated-v1':
        raise ValueError('unsupported authored corpus')
    config = corpus.get('configuration')
    if config != dict(categories=['none', 'all'], nbest=20, max_states=200000,
                      prediction=True, prefix_candidates=True, english_reading=True):
        raise ValueError('corpus conversion configuration differs from its frozen version')
    if corpus.get('targets') != dict(minimum_top1_rate=0.80, minimum_top10_rate=0.95, all_critical_top10=True):
        raise ValueError('corpus target differs from its frozen version')
    cases = corpus.get('cases')
    if not isinstance(cases, list) or not cases:
        raise ValueError('corpus has no cases')
    ids = set()
    for case in cases:
        if not isinstance(case, dict) or not text(case.get('id')) or case['id'] in ids:
            raise ValueError('missing or duplicate corpus case ID')
        ids.add(case['id'])
        if case.get('group') not in GROUPS or not text(case.get('reading')) or type(case.get('critical')) is not bool:
            raise ValueError('invalid case group, reading or critical flag')
        accepted = case.get('accepted')
        if not isinstance(accepted, list) or not accepted or not all(text(s) for s in accepted) or len(set(accepted)) != len(accepted):
            raise ValueError('invalid accepted surfaces')
        categories = case.get('categories', config['categories'])
        if not isinstance(categories, list) or not categories or not set(categories) <= {'none', 'all'} or len(set(categories)) != len(categories):
            raise ValueError('invalid category configurations')
        if type(case.get('omission', False)) is not bool:
            raise ValueError('invalid omission flag')
        entries = case.get('personal', [])
        if not isinstance(entries, list):
            raise ValueError('invalid personal entries')
        for entry in entries:
            if not isinstance(entry, dict) or entry.get('kind') not in {'user', 'template'} or not text(entry.get('reading')) or not text(entry.get('text')):
                raise ValueError('invalid personal entry')
            if not integer(entry.get('context_id'), 0, 65535) or not integer(entry.get('score'), -(2**31), 2**31 - 1):
                raise ValueError('invalid personal context or score')
    if {case['group'] for case in cases} != GROUPS:
        raise ValueError('corpus does not cover all required groups')
    return corpus


def command(cli, data, case, categories, configuration):
    args = [str(cli), '--data', str(data), '--categories', categories,
            '--nbest', str(configuration['nbest']), '--max-states', str(configuration['max_states']),
            '--predict-japanese', '--prefix-candidates', '--english-reading']
    if case.get('omission'):
        args += ['--omission']
    for entry in case.get('personal', []):
        flag = '--template-entry' if entry['kind'] == 'template' else '--user-entry'
        args += [flag, entry['reading'], entry['text'], str(entry['context_id']), str(entry['score'])]
    return args + [case['reading']]


def assess(case, categories, result):
    if not isinstance(result, dict) or result.get('reading') != case['reading'] or type(result.get('complete')) is not bool:
        raise ValueError('CLI result does not match the requested input')
    candidates = result.get('candidates')
    if not isinstance(candidates, list) or not all(isinstance(c, dict) and text(c.get('text')) and type(c.get('score')) is int for c in candidates):
        raise ValueError('invalid CLI candidates')
    surfaces = [candidate['text'] for candidate in candidates]
    accepted = set(case['accepted'])
    # Incomplete search is a failed task even when an accepted candidate happened
    # to appear before exhaustion; it cannot be used to improve the hit rates.
    complete = result['complete']
    return dict(id=case['id'], group=case['group'], reading=case['reading'], categories=categories,
                critical=case['critical'], accepted=case['accepted'], omission=case.get('omission', False),
                personal_fixture_count=len(case.get('personal', [])), complete=complete,
                top1=complete and bool(surfaces) and surfaces[0] in accepted,
                top10=complete and any(s in accepted for s in surfaces[:10]),
                candidate_count=len(candidates), candidates=candidates)


def rates(rows):
    total = len(rows)
    return dict(cases=total, complete=sum(r['complete'] for r in rows),
                top1_hits=sum(r['top1'] for r in rows), top10_hits=sum(r['top10'] for r in rows),
                top1_rate=sum(r['top1'] for r in rows) / total if total else 0,
                top10_rate=sum(r['top10'] for r in rows) / total if total else 0)


def summarize(rows, targets, baseline=None):
    if not rows:
        raise ValueError('evaluation produced no tasks')
    overall = rates(rows)
    critical_failures = [dict(id=r['id'], categories=r['categories']) for r in rows if r['critical'] and not r['top10']]
    passed = (overall['complete'] == len(rows) and not critical_failures and
              overall['top1_rate'] >= targets['minimum_top1_rate'] and
              overall['top10_rate'] >= targets['minimum_top10_rate'])
    regression = None
    if baseline is not None:
        regression = dict(passed=(overall['cases'] == baseline['cases'] and
                                  overall['complete'] == baseline['required_complete'] and
                                  overall['top1_hits'] >= baseline['minimum_top1_hits'] and
                                  overall['top10_hits'] >= baseline['minimum_top10_hits'] and
                                  len(critical_failures) <= baseline['maximum_critical_failures']),
                          minimum_top1_hits=baseline['minimum_top1_hits'], minimum_top10_hits=baseline['minimum_top10_hits'])
        passed = passed and regression['passed']
    return dict(passed=passed, targets=targets, regression=regression, overall=overall, critical_failures=critical_failures,
                groups={group: rates([r for r in rows if r['group'] == group]) for group in sorted(GROUPS)},
                categories={category: rates([r for r in rows if r['categories'] == category]) for category in ('none', 'all')})


def validate_policy(policy):
    if policy.get('schema_version') != 1 or policy.get('corpus_sha256') != CORPUS_SHA256 or policy.get('dictionary_manifest_sha256') != MANIFEST_SHA256 or policy.get('source_revision') != REVISION:
        raise ValueError('semantic policy provenance differs from its frozen version')
    baseline = policy.get('baseline', {})
    required = dict(cases=92, minimum_top1_hits=80, minimum_top10_hits=90, required_complete=92, maximum_critical_failures=0)
    if any(type(baseline.get(key)) is not int or baseline[key] != value for key, value in required.items()):
        raise ValueError('semantic regression floor differs from its measured baseline')
    for key in ('baseline_cases_sha256', 'cli_sha256'):
        value = baseline.get(key)
        if not isinstance(value, str) or len(value) != 64 or any(c not in '0123456789abcdef' for c in value):
            raise ValueError('invalid semantic baseline hash')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--cli', type=Path, required=True)
    parser.add_argument('--data', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    try:
        output = args.output.resolve()
        if output == ROOT or ROOT in output.parents:
            raise ValueError('output must be outside the source repository')
        if sha256_file(CORPUS) != CORPUS_SHA256:
            raise ValueError('authored corpus SHA-256 mismatch')
        corpus = validate_corpus(json.loads(CORPUS.read_text()))
        policy = json.loads(POLICY_PATH.read_text())
        validate_policy(policy)
        assets = validate_dictionary_assets(args.data, MANIFEST_SHA256, REVISION)
        cli = args.cli.resolve(strict=True)
        cli_hash = sha256_file(cli)
        output.mkdir(parents=True, exist_ok=True)
        rows = []
        for case in corpus['cases']:
            for category in case.get('categories', corpus['configuration']['categories']):
                completed = subprocess.run(command(cli, args.data.resolve(), case, category, corpus['configuration']),
                                           text=True, encoding='utf-8', capture_output=True, check=True, timeout=60)
                rows.append(assess(case, category, json.loads(completed.stdout)))
        if sha256_file(cli) != cli_hash:
            raise ValueError('CLI changed during evaluation')
        report = summarize(rows, corpus['targets'], policy['baseline'])
        report.update(baseline=policy['baseline'], policy_sha256=sha256_file(POLICY_PATH), evaluation_kind='provisional_fixed_target_hit_rate', release_acceptance_proven=False,
                      limitations=['Accepted homonym surfaces are not exhaustive; a miss is not proof of incorrect Japanese.',
                                   'Completion cases measure a specified destination, not unrestricted semantic accuracy.',
                                   'This corpus is provisional and not a representative or human-validated population sample.'],
                      scope=corpus['scope'], label_status=corpus['label_status'], corpus_sha256=CORPUS_SHA256,
                      cli_sha256=cli_hash, dictionary=assets, configuration=corpus['configuration'])
        report['source_file_sha256'] = {str(p.relative_to(ROOT)): sha256_file(p) for p in sorted((ROOT / 'ConversionCore/src').glob('*')) if p.is_file()}
        atomic_write_json(output / 'cases.json', rows)
        atomic_write_json(output / 'report.json', report)
        print(json.dumps({key: report[key] for key in ('passed', 'overall', 'critical_failures', 'groups')}, ensure_ascii=False, indent=2))
        return 0 if report['passed'] else 1
    except (OSError, ValueError, subprocess.SubprocessError) as error:
        parser.error(str(error))


if __name__ == '__main__':
    raise SystemExit(main())
