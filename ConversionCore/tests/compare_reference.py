#!/usr/bin/env python3
"""Compare C++ candidates with the pinned Android production candidate path.

Requires the Android SDK and a JDK accepted by the reference Gradle wrapper when
creating a baseline. Outputs and build trees stay outside this repository. The
exported Android ordering is a compatibility reference, not an independent gold
set.
"""
import argparse
import hashlib
import io
import json
import pathlib
import shutil
import subprocess
import tarfile
import tempfile

ROOT = pathlib.Path(__file__).resolve().parents[2]
REFERENCE_DIR = pathlib.Path(__file__).parent / 'reference'
POLICY_PATH = REFERENCE_DIR / 'quality-policy.json'
QUALITY_POLICY = json.loads(POLICY_PATH.read_text())
REVISION = QUALITY_POLICY['reference']['revision']


def sha256(data):
    return hashlib.sha256(data).hexdigest()


def require_sha256(data, expected, label):
    actual = sha256(data)
    if actual != expected:
        raise ValueError(f'{label} SHA-256 mismatch: expected {expected}, got {actual}')


def validate_policy(policy):
    if policy.get('schema_version') != 1:
        raise ValueError('unsupported quality policy schema version')
    reference = policy['reference']
    if reference.get('revision') != REVISION:
        raise ValueError('quality policy revision differs from the script pin')
    if reference.get('path') != 'KanaKanjiEngine.getCandidatesWithoutPrediction':
        raise ValueError('quality policy does not pin the production no-prediction path')
    if reference.get('categories') != ['none', 'all']:
        raise ValueError('quality policy must cover none and all dictionary categories')
    quality = policy['quality']
    for key in ('minimum_top1_equal', 'minimum_top10_equal',
                'minimum_reference_top1_in_cpp10'):
        value = quality.get(key)
        if type(value) is not int or value < 0:
            raise ValueError(f'quality policy has invalid {key}')


def validate_baseline_rows(rows, policy):
    validate_policy(policy)
    reference = policy['reference']
    baseline_policy = policy['baseline']
    expected_cases = baseline_policy['cases']
    if len(rows) != expected_cases:
        raise ValueError(f'baseline has {len(rows)} cases; expected {expected_cases}')

    categories = set(reference['categories'])
    by_reading = {}
    seen = set()
    required = {'reading', 'categories', 'source_revision', 'path',
                'n', 'beam_width', 'omission', 'candidates'}
    for index, row in enumerate(rows, start=1):
        if not isinstance(row, dict) or not required.issubset(row):
            raise ValueError(f'baseline row {index} is missing required metadata')
        reading = row['reading']
        category = row['categories']
        if not isinstance(reading, str) or not reading:
            raise ValueError(f'baseline row {index} has an invalid reading')
        if not isinstance(category, str) or category not in categories:
            raise ValueError(f'baseline row {index} has unexpected category {category!r}')
        if row['source_revision'] != reference['revision']:
            raise ValueError(f'baseline row {index} has a different reference revision')
        if row['path'] != reference['path']:
            raise ValueError(f'baseline row {index} has a different candidate path')
        if type(row['n']) is not int or row['n'] != reference['n']:
            raise ValueError(f'baseline row {index} has an unexpected n value')
        if type(row['beam_width']) is not int or row['beam_width'] != reference['beam_width']:
            raise ValueError(f'baseline row {index} has an unexpected beam width')
        if type(row['omission']) is not bool or row['omission'] is not reference['omission']:
            raise ValueError(f'baseline row {index} has an unexpected omission setting')
        candidates = row['candidates']
        if not isinstance(candidates, list) or not candidates:
            raise ValueError(f'baseline row {index} has no reference candidates')
        for candidate in candidates:
            if (not isinstance(candidate, dict) or not isinstance(candidate.get('text'), str)
                    or type(candidate.get('length_utf16')) is not int):
                raise ValueError(f'baseline row {index} has an invalid candidate record')
        pair = (reading, category)
        if pair in seen:
            raise ValueError(f'baseline contains duplicate reading/category pair {pair!r}')
        seen.add(pair)
        by_reading.setdefault(reading, set()).add(category)

    expected_readings = baseline_policy['readings']
    if len(by_reading) != expected_readings:
        raise ValueError(f'baseline has {len(by_reading)} readings; expected {expected_readings}')
    incomplete = [reading for reading, observed in by_reading.items() if observed != categories]
    if incomplete:
        raise ValueError(f'baseline does not cover every category for: {incomplete[:3]}')


def load_baseline(path, policy):
    raw = path.read_bytes()
    require_sha256(raw, policy['baseline']['sha256'], 'reference baseline')
    rows = []
    for index, line in enumerate(raw.decode('utf-8').splitlines(), start=1):
        try:
            rows.append(json.loads(line))
        except json.JSONDecodeError as error:
            raise ValueError(f'baseline row {index} is not valid JSON: {error}') from error
    validate_baseline_rows(rows, policy)
    return rows


def validate_dictionary_data(data, policy):
    manifest_path = data / 'manifest.json'
    raw = manifest_path.read_bytes()
    conversion = policy['conversion_data']
    require_sha256(raw, conversion['manifest_sha256'], 'conversion dictionary manifest')
    manifest = json.loads(raw)
    if manifest.get('source_revision') != conversion['source_revision']:
        raise ValueError('conversion dictionary manifest has a different source revision')


def compare(baseline_rows, cli, data):
    comparisons = []
    for reference in baseline_rows:
        reading = reference['reading']
        actual = json.loads(subprocess.check_output([
            str(cli), '--data', str(data), '--categories', reference['categories'], reading]))
        # Prefix candidates do not represent a complete conversion of this input.
        length = len(reading.encode('utf-16-le')) // 2
        expected_candidates = [candidate for candidate in reference['candidates']
                               if candidate['length_utf16'] == length][:10]
        actual_candidates = actual['candidates'][:10]
        expected = [candidate['text'] for candidate in expected_candidates]
        got = [candidate['text'] for candidate in actual_candidates]
        expected_scores = [candidate['score'] for candidate in expected_candidates]
        actual_scores = [candidate['score'] for candidate in actual_candidates]
        comparisons.append(dict(reading=reading, categories=reference['categories'],
            reference=expected, cpp=got, complete=actual['complete'],
            top1_equal=bool(expected and got) and expected[0] == got[0],
            reference_top1_in_cpp10=bool(expected) and expected[0] in got,
            top10_equal=expected == got,
            reference_scores=expected_scores, cpp_scores=actual_scores,
            top10_scores_equal=expected == got and expected_scores == actual_scores))
    return comparisons


def evaluate_quality_gate(comparisons, policy):
    expected = policy['baseline']['cases']
    quality = policy['quality']
    metrics = {
        'cases': len(comparisons),
        'complete': sum(bool(row['complete']) for row in comparisons),
        'top1_equal': sum(bool(row['top1_equal']) for row in comparisons),
        'reference_top1_in_cpp10': sum(bool(row['reference_top1_in_cpp10']) for row in comparisons),
        'top10_equal': sum(bool(row['top10_equal']) for row in comparisons),
        'top10_scores_equal': sum(bool(row['top10_scores_equal']) for row in comparisons),
    }
    minimums = {
        'top1_equal': quality['minimum_top1_equal'],
        'reference_top1_in_cpp10': quality['minimum_reference_top1_in_cpp10'],
        'top10_equal': quality['minimum_top10_equal'],
    }
    failures = []
    if metrics['cases'] != expected:
        failures.append(f'case count {metrics["cases"]} != {expected}')
    if metrics['complete'] != expected:
        failures.append(f'only {metrics["complete"]}/{expected} searches completed')
    for metric, minimum in minimums.items():
        if metrics[metric] < minimum:
            failures.append(f'{metric} {metrics[metric]} < required {minimum}')
    return {'passed': not failures, 'metrics': metrics,
            'minimums': minimums, 'failures': failures}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--source', type=pathlib.Path, default=ROOT/'.reference/JapaneseKeyboard')
    parser.add_argument('--cli', type=pathlib.Path, required=True)
    parser.add_argument('--data', type=pathlib.Path, required=True)
    parser.add_argument('--output', type=pathlib.Path, required=True)
    parser.add_argument('--baseline', type=pathlib.Path, help='Compare a previously exported pinned baseline')
    args = parser.parse_args()
    output = args.output.resolve()
    if output == ROOT or ROOT in output.parents:
        parser.error('--output must be outside the source repository')
    output.mkdir(parents=True, exist_ok=True)
    policy = QUALITY_POLICY
    try:
        validate_policy(policy)
        adapter = REFERENCE_DIR / policy['reference']['adapter_path']
        require_sha256(adapter.read_bytes(), policy['reference']['adapter_sha256'], 'Android adapter')
        validate_dictionary_data(args.data.resolve(), policy)
    except (OSError, ValueError, json.JSONDecodeError) as error:
        parser.error(str(error))

    if args.baseline:
        baseline_path = args.baseline.resolve()
    else:
        source = args.source.resolve()
        revision = subprocess.check_output(['git', '-C', str(source), 'rev-parse', 'HEAD'], text=True).strip()
        if revision != REVISION:
            parser.error('reference HEAD differs from pinned revision')
        # Read committed files, never alter the source or run Gradle inside it.
        archive = subprocess.check_output(['git', '-C', str(source), 'archive', REVISION])
        build = pathlib.Path(tempfile.mkdtemp(prefix='android-reference-', dir=output))
        with tarfile.open(fileobj=io.BytesIO(archive)) as tree:
            tree.extractall(build, filter='data')
        assets = build/'app/src/main/assets'
        hashes = {str(path.relative_to(assets)): sha256(path.read_bytes())
                  for path in sorted(assets.rglob('*')) if path.is_file()}
        destination = build/'app/src/test/java/com/kazumaproject/markdownhelperkeyboard/converter'/adapter.name
        shutil.copyfile(adapter, destination)
        with (output/'android-build.log').open('w') as log:
            subprocess.run(['./gradlew', ':app:testLiteStandardDebugUnitTest', '--tests', '*SumireIOSBaselineTest',
                            '--no-configuration-cache', '--max-workers=4'], cwd=build,
                           stdout=log, stderr=subprocess.STDOUT, check=True)
        baseline_path = output/'baseline.jsonl'
        shutil.copyfile(build/'app/build/reports/sumire-ios-baseline.jsonl', baseline_path)
        metadata = dict(revision=revision, adapter_sha256=sha256(adapter.read_bytes()),
                        shipped_asset_sha256=hashes, build_directory=str(build),
                        path=policy['reference']['path'], n=policy['reference']['n'],
                        beam_width=policy['reference']['beam_width'],
                        prediction=False, omission=False, user_dictionary=False, learning=False,
                        scope='Robolectric SDK 35; real dictionaries; mocked English engine and empty user repository')
        (output/'provenance.json').write_text(json.dumps(metadata, indent=2)+'\n')

    try:
        baseline_rows = load_baseline(baseline_path, policy)
        comparisons = compare(baseline_rows, args.cli.resolve(), args.data.resolve())
    except (OSError, ValueError, json.JSONDecodeError, subprocess.CalledProcessError) as error:
        parser.error(str(error))
    gate = evaluate_quality_gate(comparisons, policy)
    (output/'comparison.json').write_text(json.dumps(comparisons, ensure_ascii=False, indent=2)+'\n')
    (output/'quality-gate.json').write_text(json.dumps(gate, ensure_ascii=False, indent=2)+'\n')
    print(json.dumps(gate, ensure_ascii=False, indent=2))
    if not gate['passed']:
        raise SystemExit(1)


if __name__ == '__main__':
    main()
