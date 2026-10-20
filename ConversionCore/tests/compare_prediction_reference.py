#!/usr/bin/env python3
"""Pinned real Android prediction-path compatibility gate, not semantic gold accuracy.

Builds an isolated git archive with an explicitly hash-pinned test-factory-only
FindPath injection. Android references are never edited. Full candidate arrays
are retained; prefix/correction/unsupported candidate types are not filtered.
"""
import argparse
import collections
import hashlib
import io
import json
import os
import pathlib
import shutil
import subprocess
import tarfile
import tempfile
import xml.etree.ElementTree as ET
from quality_assets import validate_dictionary_assets, atomic_write_bytes, atomic_write_json

ROOT = pathlib.Path(__file__).resolve().parents[2]
REFERENCES = pathlib.Path(__file__).parent / 'reference'
POLICY = json.loads((REFERENCES / 'prediction-policy.json').read_text())
REVISION = 'df1f38315bf56d860d32919a3eaed6a75499e91e'
FACTORY_PATH = 'app/src/test/java/com/kazumaproject/markdownhelperkeyboard/converter/MozcCompoundConversionParityTest.kt'
PATHS = ['KanaKanjiEngine.getCandidates', 'KanaKanjiEngine.getCandidatesOriginal']
OUTPUT_NAMES = ('source-manifest.json', 'android-build.log', 'baseline.jsonl',
                'provenance.json', 'comparison.json', 'quality-gate.json')


def validate_output_leaves(output):
    # Check every possible output, including ones not written in baseline-replay
    # mode, before a build can begin. Atomic writes provide race-safe replacement.
    for name in OUTPUT_NAMES:
        if (output / name).is_symlink():
            raise ValueError('output destination is a symlink: ' + name)


def open_build_log(path):
    # A fresh export requires a fresh log. EXCL prevents both symlink races and
    # overwriting hard-linked existing files; NOFOLLOW makes that policy explicit.
    descriptor = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
    return os.fdopen(descriptor, 'w')


def digest(raw):
    return hashlib.sha256(raw).hexdigest()


def require_hash(raw, expected, label):
    if digest(raw) != expected:
        raise ValueError(f'{label} SHA-256 mismatch')


def relative_file(root, relative):
    if not isinstance(relative, str) or '\\' in relative or any(p in ('', '.', '..') for p in relative.split('/')):
        raise ValueError('unsafe relative asset path')
    root = root.resolve()
    result = (root / relative).resolve()
    if root not in result.parents:
        raise ValueError('asset path escapes root')
    return result


def validate_policy(policy):
    ref, baseline, data, gate = (policy[k] for k in ('reference', 'baseline', 'conversion_data', 'gate'))
    if policy.get('schema_version') != 1 or ref.get('revision') != REVISION or data.get('source_revision') != REVISION:
        raise ValueError('unexpected schema or source revision')
    fixed = dict(paths=PATHS, categories=['none', 'all'], n=10, beam_width=20,
                 omission=False, prediction=True, prediction_minimum_input=3,
                 prediction_limit=4, prediction_lookahead=3, prediction_aggressiveness='standard',
                 system_ngram_rule_count=2194, system_ngram_storage_bytes=76503,
                 adapter_path='SumireIOSPredictionBaselineTest.kt', factory_path=FACTORY_PATH)
    for key, expected in fixed.items():
        if ref.get(key) != expected or type(ref.get(key)) is not type(expected):
            raise ValueError(f'unexpected reference option {key}')
    readings = baseline.get('readings')
    if not isinstance(readings, list) or len(readings) != 25 or len(set(readings)) != 25 or any(not isinstance(x, str) or not x for x in readings):
        raise ValueError('expected 25 unique fixed readings')
    if baseline.get('cases') != 100 or len(data.get('output_sha256', {})) != 44 or not data.get('asset_sha256'):
        raise ValueError('missing complete corpus or asset manifest')
    for key in ('minimum_top1_text_score_equal', 'minimum_top10_text_score_equal', 'required_complete'):
        if type(gate.get(key)) is not int or gate[key] != 100:
            raise ValueError('prediction reference agreement gate must require all 100 cases')
    for value in [ref['adapter_sha256'], ref['factory_original_sha256'], ref['factory_patched_sha256'],
                  baseline['sha256'], data['manifest_sha256'], *data['asset_sha256'].values(), *data['output_sha256'].values()]:
        if not isinstance(value, str) or len(value) != 64 or any(c not in '0123456789abcdef' for c in value):
            raise ValueError('invalid SHA-256 policy value')


def validate_dictionary_data(directory, policy):
    expected = policy['conversion_data']
    verified = validate_dictionary_assets(directory, expected['manifest_sha256'], expected['source_revision'], expected_count=44)
    manifest = json.loads((directory / 'manifest.json').read_bytes())
    for key in ('source_revision', 'asset_sha256', 'output_sha256'):
        if manifest.get(key) != expected[key]:
            raise ValueError(f'dictionary manifest differs: {key}')
    return verified


def validate_baseline_rows(rows, policy):
    ref = policy['reference']
    expected = {(reading, category, route) for reading in policy['baseline']['readings']
                for category in ref['categories'] for route in ref['paths']}
    if len(rows) != len(expected):
        raise ValueError('baseline case count differs')
    seen = set()
    options = ['n', 'beam_width', 'omission', 'prediction', 'prediction_minimum_input', 'prediction_limit',
               'prediction_lookahead', 'prediction_aggressiveness', 'system_ngram_rule_count', 'system_ngram_storage_bytes']
    for row in rows:
        if not isinstance(row, dict):
            raise ValueError('baseline row must be an object')
        key = (row.get('reading'), row.get('categories'), row.get('path'))
        if key not in expected or key in seen or row.get('source_revision') != ref['revision']:
            raise ValueError('unexpected/duplicate baseline identity or revision')
        seen.add(key)
        for option in options:
            if row.get(option) != ref[option] or type(row.get(option)) is not type(ref[option]):
                raise ValueError(f'baseline metadata differs: {option}')
        candidates = row.get('candidates')
        if not isinstance(candidates, list) or not candidates:
            raise ValueError('baseline candidates missing')
        for c in candidates:
            if not isinstance(c, dict) or not isinstance(c.get('text'), str) or any(type(c.get(k)) is not int for k in ('score', 'length_utf16', 'type')) or c['length_utf16'] < 0:
                raise ValueError('malformed reference candidate')
    if seen != expected:
        raise ValueError('baseline coverage differs')


def load_baseline(path, policy):
    raw = path.read_bytes()
    require_hash(raw, policy['baseline']['sha256'], 'baseline')
    rows = [json.loads(line) for line in raw.decode('utf-8').splitlines()]
    validate_baseline_rows(rows, policy)
    return rows


def patch_factory(raw, policy):
    ref = policy['reference']
    require_hash(raw, ref['factory_original_sha256'], 'original test factory')
    old = b'connectionMatrix: ConnectionMatrix.CostTable = ConnectionMatrix.fromShortArray(readConnectionIds()),\n'
    assignment = b'findPath = FindPath(),'
    if raw.count(old) != 1 or raw.count(assignment) != 1:
        raise ValueError('test factory patch context differs')
    patched = raw.replace(old, old + b'        findPath: FindPath = FindPath(),\n', 1).replace(assignment, b'findPath = findPath,', 1)
    require_hash(patched, ref['factory_patched_sha256'], 'patched test factory')
    return patched


def android_command():
    # A cached Test task need not restore this adapter's custom JSONL report.
    # Rerun only the selected test task, retaining cached compilation/assets.
    return ['./gradlew', '--offline', ':app:testFullStandardDebugUnitTest', '--rerun', '--tests', '*SumireIOSPredictionBaselineTest',
            '--no-configuration-cache', '--max-workers=2', '-Dorg.gradle.parallel=false']


def export_baseline(source, output, policy, java_home, android_sdk):
    revision = subprocess.check_output(['git', '-C', str(source), 'rev-parse', 'HEAD'], text=True).strip()
    if revision != REVISION:
        raise ValueError('reference HEAD differs from pin')
    archive = subprocess.check_output(['git', '-C', str(source), 'archive', REVISION])
    build = pathlib.Path(tempfile.mkdtemp(prefix='android-prediction-', dir=output))
    with tarfile.open(fileobj=io.BytesIO(archive)) as tree:
        tree.extractall(build, filter='data')
    source_files = {str(p.relative_to(build)): digest(p.read_bytes()) for p in sorted(build.rglob('*')) if p.is_file()}
    atomic_write_json(output / 'source-manifest.json', source_files)
    assets = build / 'app/src/main/assets'
    for relative, sha in policy['conversion_data']['asset_sha256'].items():
        require_hash(relative_file(assets, relative).read_bytes(), sha, 'Android ' + relative)
    adapter = REFERENCES / policy['reference']['adapter_path']
    require_hash(adapter.read_bytes(), policy['reference']['adapter_sha256'], 'Android adapter')
    factory = build / FACTORY_PATH
    factory.write_bytes(patch_factory(factory.read_bytes(), policy))
    shutil.copyfile(adapter, build / 'app/src/test/java/com/kazumaproject/markdownhelperkeyboard/converter' / adapter.name)
    env = dict(os.environ)
    env['JAVA_HOME'] = str(java_home)
    env['ANDROID_HOME'] = str(android_sdk)
    java_version = subprocess.check_output([str(java_home / 'bin/java'), '-version'], stderr=subprocess.STDOUT, text=True)
    if 'version \"21' not in java_version:
        raise ValueError('Android export requires JDK 21')
    command = android_command()
    with open_build_log(output / 'android-build.log') as log:
        subprocess.run(command, cwd=build, env=env, stdout=log, stderr=subprocess.STDOUT, check=True)
    xml_path = build / 'app/build/test-results/testFullStandardDebugUnitTest/TEST-com.kazumaproject.markdownhelperkeyboard.converter.SumireIOSPredictionBaselineTest.xml'
    xml = ET.fromstring(xml_path.read_bytes())
    if (xml.get('tests'), xml.get('failures'), xml.get('errors'), xml.get('skipped')) != ('1', '0', '0', '0'):
        raise ValueError('Android adapter was not executed successfully')
    baseline = output / 'baseline.jsonl'
    atomic_write_bytes(baseline, (build / 'app/build/reports/sumire-ios-prediction-baseline.jsonl').read_bytes())
    provenance = dict(source_revision=revision, source_archive_sha256=digest(archive), source_manifest_sha256=digest((output / 'source-manifest.json').read_bytes()),
                      adapter_sha256=digest(adapter.read_bytes()), factory_original_sha256=policy['reference']['factory_original_sha256'],
                      factory_patched_sha256=digest(factory.read_bytes()), baseline_sha256=digest(baseline.read_bytes()),
                      test_xml_sha256=digest(xml_path.read_bytes()), test_xml=str(xml_path), command=command, launcher_java_version=java_version,
                      pinned_gradle_daemon_jvm_criteria=(build / 'gradle/gradle-daemon-jvm.properties').read_text(),
                      patch_boundary='Only test factory FindPath parameter/provider injection and new test adapter; production source untouched',
                      boundaries=policy['boundaries'])
    atomic_write_json(output / 'provenance.json', provenance)
    return baseline


def compare(rows, cli, data):
    comparisons = []
    cache = {}
    for reference in rows:
        key = (reference['reading'], reference['categories'])
        if key not in cache:
            command = [str(cli), '--data', str(data), '--categories', key[1], '--nbest', '10', '--max-states', '200000',
                       '--predict-japanese', '--prefix-candidates', '--english-reading', key[0]]
            actual = json.loads(subprocess.check_output(command))
            if actual.get('reading') != key[0] or type(actual.get('complete')) is not bool or not isinstance(actual.get('candidates'), list):
                raise ValueError('malformed CLI response')
            for c in actual['candidates']:
                if not isinstance(c, dict) or not isinstance(c.get('text'), str) or type(c.get('score')) is not int or not isinstance(c.get('segments'), list):
                    raise ValueError('malformed CLI candidate')
            cache[key] = actual
        actual = cache[key]
        expected = reference['candidates']
        got = actual['candidates']
        expected_pairs = [(c['text'], c['score']) for c in expected]
        actual_pairs = [(c['text'], c['score']) for c in got]
        available = collections.Counter(actual_pairs)
        missing = []
        for c in expected:
            pair = (c['text'], c['score'])
            if available[pair]:
                available[pair] -= 1
            else:
                missing.append(c)
        comparisons.append(dict(reading=key[0], categories=key[1], path=reference['path'], cpp_complete=actual['complete'],
            top1_text_score_equal=expected_pairs[:1] == actual_pairs[:1], top10_text_score_equal=expected_pairs[:10] == actual_pairs[:10],
            full_text_score_order_equal=expected_pairs == actual_pairs,
            full_text_score_multiset_equal=collections.Counter(expected_pairs) == collections.Counter(actual_pairs),
            reference_count=len(expected), cpp_count=len(got),
            reference_type_counts=dict(collections.Counter(str(c['type']) for c in expected)),
            missing_reference_type_counts=dict(collections.Counter(str(c['type']) for c in missing)),
            missing_reference_candidates=missing,
            extra_cpp_text_score=[dict(text=t, score=s, count=n) for (t, s), n in available.items() if n],
            reference_candidates=expected, cpp_candidates=got))
    return comparisons


def compare_pinned_cli(rows, cli, data):
    observed_hash = digest(cli.read_bytes())
    comparisons = compare(rows, cli, data)
    require_hash(cli.read_bytes(), observed_hash, 'CLI executable changed during comparison')
    return comparisons, observed_hash


def evaluate(comparisons, policy):
    metrics = {key: sum(row[key] for row in comparisons) for key in (
        'cpp_complete', 'top1_text_score_equal', 'top10_text_score_equal', 'full_text_score_order_equal', 'full_text_score_multiset_equal')}
    metrics['cases'] = len(comparisons)
    metrics['reference_candidates'] = sum(row['reference_count'] for row in comparisons)
    metrics['cpp_candidates'] = sum(row['cpp_count'] for row in comparisons)
    failures = []
    for metric, minimum in [('top1_text_score_equal', 'minimum_top1_text_score_equal'), ('top10_text_score_equal', 'minimum_top10_text_score_equal'), ('cpp_complete', 'required_complete')]:
        if metrics[metric] < policy['gate'][minimum]:
            failures.append(f'{metric} {metrics[metric]} < {policy["gate"][minimum]}')
    if len(comparisons) != policy['baseline']['cases']:
        failures.append('comparison case count differs')
    return dict(passed=not failures, metrics=metrics, failures=failures, contract=policy['gate']['scope'],
                type_diagnostic_scope='Unmatched raw text/score occurrences; deduplication or correction display encoding may differ without a missing function.',
                not_proven=['Full raw candidate-array parity unless separately reported equal', 'Independent semantic Top-1/Top-10 accuracy',
                            'Omission, personal dictionaries, learning, English-word prediction, live IME presentation, iOS runtime/performance'])


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--source', type=pathlib.Path, default=ROOT / '.reference/JapaneseKeyboard')
    parser.add_argument('--cli', type=pathlib.Path, required=True)
    parser.add_argument('--data', type=pathlib.Path, required=True)
    parser.add_argument('--output', type=pathlib.Path, required=True, help='External artifact directory; fresh exports require a new build log')
    parser.add_argument('--baseline', type=pathlib.Path)
    parser.add_argument('--java-home', type=pathlib.Path, default=pathlib.Path(os.environ['JAVA_HOME']) if os.environ.get('JAVA_HOME') else None,
                        help='JDK 21 home for a fresh offline export; defaults to JAVA_HOME')
    parser.add_argument('--android-sdk', type=pathlib.Path, default=pathlib.Path(os.environ['ANDROID_HOME']) if os.environ.get('ANDROID_HOME') else None,
                        help='Android SDK directory for a fresh export; defaults to ANDROID_HOME')
    args = parser.parse_args()
    output = args.output.resolve()
    if output == ROOT or ROOT in output.parents:
        parser.error('output must be outside repository')
    output.mkdir(parents=True, exist_ok=True)
    try:
        validate_output_leaves(output)
        validate_policy(POLICY)
        require_hash((REFERENCES / POLICY['reference']['adapter_path']).read_bytes(), POLICY['reference']['adapter_sha256'], 'adapter')
        dictionary = validate_dictionary_data(args.data.resolve(), POLICY)
        if not args.baseline and (args.java_home is None or args.android_sdk is None):
            raise ValueError('fresh export requires JDK 21 (--java-home/JAVA_HOME) and Android SDK (--android-sdk/ANDROID_HOME)')
        baseline = args.baseline.resolve() if args.baseline else export_baseline(args.source.resolve(), output, POLICY, args.java_home.resolve(), args.android_sdk.resolve())
        rows = load_baseline(baseline, POLICY)
        comparisons, observed_cli_hash = compare_pinned_cli(rows, args.cli.resolve(), args.data.resolve())
        gate = evaluate(comparisons, POLICY)
        gate['dictionary'] = dictionary
        gate['reference_revision'] = REVISION
        gate['baseline_sha256'] = digest(baseline.read_bytes())
        gate['adapter_sha256'] = POLICY['reference']['adapter_sha256']
        gate['boundaries'] = POLICY['boundaries']
        gate['cli_sha256'] = observed_cli_hash
        gate['cli_configuration'] = dict(primary_nbest=10, max_states=200000, japanese_prediction=True,
                                         prefix_candidates=True, english_reading=True, omission=False,
                                         categories=['none', 'all'], personal_entries=0, learning=False)
        gate['policy_sha256'] = digest((REFERENCES / 'prediction-policy.json').read_bytes())
        gate['routes'] = {route: evaluate([r for r in comparisons if r['path'] == route],
                         {**POLICY, 'baseline': {**POLICY['baseline'], 'cases': 50},
                          'gate': {**POLICY['gate'], 'minimum_top1_text_score_equal': 50, 'minimum_top10_text_score_equal': 50, 'required_complete': 50}})
                          for route in PATHS}
        atomic_write_json(output / 'comparison.json', comparisons)
        atomic_write_json(output / 'quality-gate.json', gate)
        print(json.dumps(gate, indent=2))
        if not gate['passed']:
            raise SystemExit(1)
    except (OSError, ValueError, KeyError, TypeError, json.JSONDecodeError, subprocess.CalledProcessError) as error:
        parser.error(str(error))


if __name__ == '__main__':
    main()
