#!/usr/bin/env python3
"""Separate real-English provider fixture; no modification of the fixed 25-input baseline.

Archives pinned production source, injects only the test factory's real English
provider/FindPath, and runs offline. Native dictionaries and all source assets
are hash-verified. Whole Japanese arrays remain diagnostic, not a parity claim.
"""
import argparse
import hashlib
import io
import json
import os
from pathlib import Path
import subprocess
import tarfile
import tempfile
import xml.etree.ElementTree as ET
import compare_prediction_reference as raw
from quality_assets import atomic_write_bytes, atomic_write_json, validate_dictionary_assets

REFERENCE = raw.REFERENCES
POLICY_PATH = REFERENCE / 'real-english-policy.json'
ADAPTER = REFERENCE / 'SumireIOSRealEnglishBaselineTest.kt'
INPUTS = ['a', 'A', 'ab', 'Ab', 'AB', 'app', 'ApP', 'APP', 'iPh', 'NASA', 'zzzzq',
          'ａｂ', 'Ａｂ', 'ＡＢ', '＋', '　', 'ａ＋ｂ', 'a1', 'a+b', 'é', '123', '１２３']


def patch_factory(data, policy):
    raw.require_hash(data, raw.POLICY['reference']['factory_original_sha256'], 'original test factory')
    declaration = b'connectionMatrix: ConnectionMatrix.CostTable = ConnectionMatrix.fromShortArray(readConnectionIds()),\n'
    assignment = b'val englishEngine = mock<EnglishEngine>()\n        whenever(englishEngine.getCandidates(any(), any())).thenReturn(emptyList<Candidate>())'
    if data.count(declaration) != 1 or data.count(assignment) != 1 or data.count(b'findPath = FindPath(),') != 1:
        raise ValueError('test factory patch boundary differs')
    data = data.replace(declaration, declaration + b'        findPath: FindPath = FindPath(),\n        englishEngineOverride: EnglishEngine? = null,\n')
    data = data.replace(assignment, b'val englishEngine = englishEngineOverride ?: mock<EnglishEngine>()\n        if (englishEngineOverride == null) whenever(englishEngine.getCandidates(any(), any())).thenReturn(emptyList<Candidate>())')
    data = data.replace(b'findPath = FindPath(),', b'findPath = findPath,')
    raw.require_hash(data, policy['factory_patched_sha256'], 'patched test factory')
    return data


def validate_rows(rows):
    if [r.get('reading') for r in rows] != INPUTS:
        raise ValueError('real-English corpus differs')
    for row in rows:
        if row.get('source_revision') != raw.REVISION or row.get('n') != 20 or row.get('beam_width') != 20 or row.get('typo_correction') is not False:
            raise ValueError('real-English configuration differs')
        text = row['reading']
        normalized = ''.join(' ' if c == '　' else chr(ord(c) - 0xfee0) if 'Ａ' <= c <= 'Ｚ' or 'ａ' <= c <= 'ｚ' else c for c in text)
        # Mirror the explicit pinned ASCII predicate, not locale-sensitive isalpha/isdecimal.
        eligible = all('a' <= c <= 'z' or 'A' <= c <= 'Z' for c in text) or (
            all(c == '　' or '！' <= c <= '～' for c in text) and not all('０' <= c <= '９' for c in text))
        if row.get('provider_input') != normalized or row.get('eligible') is not eligible:
            raise ValueError('provider eligibility/normalization differs')
        for field in ('provider', 'japanese_original', 'dedicated_english', 'projected'):
            values = row.get(field)
            if not isinstance(values, list) or (field != 'provider' and not values):
                raise ValueError('candidate array missing')
            for value in values:
                if not isinstance(value.get('text'), str) or type(value.get('score')) is not int or type(value.get('lexical_length_utf16')) is not int:
                    raise ValueError('candidate metadata missing')
        items = row.get('adapter_items')
        if not isinstance(items, list) or len(items) != len(row['projected']):
            raise ValueError('Android Adapter count differs')
        for candidate, item in zip(row['projected'], items):
            if (type(candidate.get('consumed_utf16')) is not int or not 0 <= candidate['consumed_utf16'] <= len(text.encode('utf-16-le')) // 2 or
                    not isinstance(candidate.get('effective_commit_text'), str) or
                    not isinstance(item.get('text'), str) or not isinstance(item.get('annotation'), str)):
                raise ValueError('Android display metadata missing')
        if eligible and not row['provider']:
            raise ValueError('eligible input lacks English fallback/provider')
        if not eligible and row['provider']:
            raise ValueError('ineligible input has English provider candidates')


def validate_replay(baseline, provenance, policy):
    if (provenance.get('baseline_sha256') != raw.digest(baseline) or
            provenance.get('source_revision') != raw.REVISION or
            provenance.get('adapter_sha256') != policy['adapter_sha256'] or
            provenance.get('policy_sha256') != raw.digest(POLICY_PATH.read_bytes())):
        raise ValueError('replay baseline provenance differs')


def compare(rows, cli, data):
    before = raw.digest(cli.read_bytes())
    results = []
    for row in rows:
        command = [str(cli), '--data', str(data), '--predict-japanese', '--nbest', '20', row['reading']]
        native = json.loads(subprocess.check_output(command, text=True))
        provider = [c for c in native['candidates'] if c['segments'] and all(s['dictionary'] == 'english' for s in c['segments'])]
        expected = [(c['text'], c['score']) for c in row['provider']]
        actual = [(c['text'], c['score']) for c in provider]
        dedicated = json.loads(subprocess.check_output([str(cli), '--data', str(data), '--english', '--nbest', '20', row['provider_input']], text=True))
        dedicated_expected = [(c['text'], c['score']) for c in row['dedicated_english'][:20]]
        dedicated_actual = [(c['text'], c['score']) for c in dedicated['candidates']]
        results.append(dict(reading=row['reading'], eligible=row['eligible'], complete=native['complete'],
            provider_equal=expected == actual, expected_provider=expected, actual_provider=actual,
            dedicated_top20_equal=dedicated_expected == dedicated_actual,
            expected_dedicated=dedicated_expected, actual_dedicated=dedicated_actual,
            android_japanese=row['japanese_original'], native_japanese=native['candidates']))
    raw.require_hash(cli.read_bytes(), before, 'CLI changed during comparison')
    return dict(cli_sha256=before, cases=len(results), provider_equal=sum(r['provider_equal'] for r in results),
        dedicated_top20_equal=sum(r['dedicated_top20_equal'] for r in results), conditions=results,
        scope='Real English assets/provider; Japanese full arrays diagnostic. No physical keyboard/editor acceptance.')


def compare_display(rows, ios):
    if ios.get('schema_version') != 1 or ios.get('platform') != 'ios' or ios.get('configuration') != dict(n=20, flags=12, categories='none', learning=False, personal=False):
        raise ValueError('iOS English display configuration differs')
    provenance = ios.get('provenance', {})
    if (provenance.get('manifest_sha256') != raw.POLICY['conversion_data']['manifest_sha256'] or
            provenance.get('dictionary_file_sha256') != raw.POLICY['conversion_data']['output_sha256'] or
            provenance.get('verified_manifest_output_count') != 44):
        raise ValueError('iOS dictionary provenance differs')
    targets = ios.get('conditions', [])
    if [r.get('reading') for r in targets] != INPUTS:
        raise ValueError('iOS English display corpus differs')
    validate_rows(rows)
    comparisons = []
    for source, target in zip(rows, targets):
        candidates = target['candidates']
        if not candidates:
            raise ValueError('empty iOS display result')
        for mode in ('normal', 'expanded'):
            items = target[mode]
            if len(items) != len(candidates):
                raise ValueError('iOS displayed candidate count differs')
            for candidate, item in zip(candidates, items):
                labels = item['labels']
                titles = [v['text'] for v in labels if not v['hidden'] and v['identifier'] is None]
                annotations = [v['text'] for v in labels if not v['hidden'] and v['identifier'] == 'candidate-annotation']
                if (item['selected_id'] != candidate['id'] or item['text'] != candidate['text'] or
                        titles != [candidate['text']] or item.get('annotation') != candidate.get('annotation') or
                        annotations != ([candidate['annotation']] if candidate.get('annotation') else [])):
                    raise ValueError('iOS actual cell/callback projection differs')
        expected = []
        for index, (candidate, item) in enumerate(zip(source['projected'], source['adapter_items'])):
            text = candidate['text']
            units = len(text.encode('utf-16-le')) // 2
            padding = 4 if index == 0 or units == 1 else 2 if units == 2 else 1
            if item['text'] != ' ' * padding + text + ' ' * padding:
                raise ValueError('Android actual Adapter text differs from padding contract')
            expected.append(dict(text=text, score=candidate['score'], consumed_utf16=candidate['consumed_utf16'],
                effective_commit_text=candidate['effective_commit_text'], annotation=item['annotation'].strip()))
        actual = [dict(text=c['text'], score=c['score'], consumed_utf16=c['consumed_utf16'],
            effective_commit_text=c['text'], annotation=c.get('annotation') or '') for c in candidates]
        comparisons.append(dict(reading=source['reading'], compared_fields_equal=expected == actual,
            android=expected, ios=actual))
    return dict(conditions=len(comparisons), compared_fields_equal=sum(r['compared_fields_equal'] for r in comparisons),
        comparisons=comparisons, scope='Actual Adapter/normal+expanded CandidateBar, compared text/score/consumed range/annotation/projected commit. No actual editor commit acceptance.')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--source', type=Path, default=raw.ROOT / '.reference/JapaneseKeyboard')
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--data', type=Path, required=True)
    parser.add_argument('--cli', type=Path, required=True)
    parser.add_argument('--java-home', type=Path, required=True)
    parser.add_argument('--android-sdk', type=Path, required=True)
    parser.add_argument('--baseline', type=Path)
    parser.add_argument('--baseline-provenance', type=Path)
    parser.add_argument('--ios-report', type=Path)
    parser.add_argument('--ios-revision', help='Exact committed revision used by the Release iOS export')
    args = parser.parse_args()
    output = args.output.resolve()
    if output == raw.ROOT or raw.ROOT in output.parents:
        raise ValueError('output must be outside repository')
    output.mkdir(parents=True, exist_ok=True)
    for name in ('source-manifest.json', 'android-build.log', 'baseline.jsonl', 'provenance.json', 'comparison.json', 'display-comparison.json'):
        if (output / name).exists() or (output / name).is_symlink():
            raise ValueError('fresh output leaves required')
    policy = json.loads(POLICY_PATH.read_text())
    if policy.get('schema_version') != 1 or policy.get('source_revision') != raw.REVISION:
        raise ValueError('real-English policy revision differs')
    raw.require_hash(ADAPTER.read_bytes(), policy['adapter_sha256'], 'real-English adapter')
    provenance = validate_dictionary_assets(args.data, raw.POLICY['conversion_data']['manifest_sha256'], raw.REVISION)
    if args.baseline:
        baseline = args.baseline.read_bytes()
        if not args.baseline_provenance:
            raise ValueError('replay requires source provenance')
        replay = json.loads(args.baseline_provenance.read_text())
        validate_replay(baseline, replay, policy)
        provenance['replayed_source_provenance'] = replay
        provenance['adapter_sha256'] = policy['adapter_sha256']
    else:
        archive = subprocess.check_output(['git', '-C', str(args.source), 'archive', raw.REVISION])
        build = Path(tempfile.mkdtemp(prefix='android-real-english-', dir=output))
        with tarfile.open(fileobj=io.BytesIO(archive)) as tree:
            tree.extractall(build, filter='data')
        sources = {str(p.relative_to(build)): raw.digest(p.read_bytes()) for p in sorted(build.rglob('*')) if p.is_file()}
        atomic_write_json(output / 'source-manifest.json', sources)
        for name, sha in raw.POLICY['conversion_data']['asset_sha256'].items():
            raw.require_hash(raw.relative_file(build / 'app/src/main/assets', name).read_bytes(), sha, name)
        factory = build / raw.FACTORY_PATH
        factory.write_bytes(patch_factory(factory.read_bytes(), policy))
        adapter_bytes = ADAPTER.read_bytes()
        (build / 'app/src/test/java/com/kazumaproject/markdownhelperkeyboard/converter' / ADAPTER.name).write_bytes(adapter_bytes)
        java_version = subprocess.check_output([str(args.java_home / 'bin/java'), '-version'], stderr=subprocess.STDOUT, text=True)
        if 'version \"21' not in java_version:
            raise ValueError('Android export requires JDK 21 launcher')
        command = ['./gradlew', '--offline', ':app:testFullStandardDebugUnitTest', '--rerun', '--tests', '*SumireIOSRealEnglishBaselineTest', '--no-configuration-cache', '--max-workers=2', '-Dorg.gradle.parallel=false']
        with raw.open_build_log(output / 'android-build.log') as log:
            subprocess.run(command, cwd=build, env={**os.environ, 'JAVA_HOME': str(args.java_home), 'ANDROID_HOME': str(args.android_sdk)}, stdout=log, stderr=subprocess.STDOUT, check=True)
        xml_bytes = (build / 'app/build/test-results/testFullStandardDebugUnitTest/TEST-com.kazumaproject.markdownhelperkeyboard.converter.SumireIOSRealEnglishBaselineTest.xml').read_bytes()
        xml = ET.fromstring(xml_bytes)
        if tuple(xml.get(k) for k in ('tests', 'failures', 'errors', 'skipped')) != ('1', '0', '0', '0'):
            raise ValueError('actual exporter test did not pass')
        baseline = (build / 'app/build/reports/sumire-ios-real-english.jsonl').read_bytes()
        provenance.update(source_archive_sha256=raw.digest(archive), adapter_sha256=raw.digest(adapter_bytes),
            factory_patched_sha256=raw.digest(factory.read_bytes()), command=command,
            launcher_java_version=java_version, pinned_gradle_daemon_jvm_criteria=(build / 'gradle/gradle-daemon-jvm.properties').read_text(),
            source_manifest_sha256=raw.digest((output / 'source-manifest.json').read_bytes()),
            test_xml_sha256=raw.digest(xml_bytes),
            patch_boundary='Test factory FindPath + real EnglishEngine parameter only; pinned production source unmodified')
    rows = [json.loads(line) for line in baseline.decode().splitlines()]
    validate_rows(rows)
    atomic_write_bytes(output / 'baseline.jsonl', baseline)
    provenance.update(baseline_sha256=raw.digest(baseline), policy_sha256=raw.digest(POLICY_PATH.read_bytes()),
        english_source_assets={k: v for k, v in raw.POLICY['conversion_data']['asset_sha256'].items() if k in ('english/reading.dat.zip', 'english/word.dat', 'english/token.dat.zip')})
    atomic_write_json(output / 'provenance.json', provenance)
    report = compare(rows, args.cli.resolve(), args.data.resolve())
    atomic_write_json(output / 'comparison.json', report)
    if args.ios_report:
        ios_bytes = args.ios_report.read_bytes()
        ios = json.loads(ios_bytes)
        if not args.ios_revision or ios.get('provenance', {}).get('source_revision') != args.ios_revision:
            raise ValueError('iOS report revision differs from expected build')
        display = compare_display(rows, ios)
        display['ios_report_sha256'] = raw.digest(ios_bytes)
        atomic_write_json(output / 'display-comparison.json', display)
    print(json.dumps({k: report[k] for k in ('cases', 'provider_equal', 'dedicated_top20_equal')}))
    return 0 if report['provider_equal'] == len(INPUTS) and report['dedicated_top20_equal'] == len(INPUTS) else 1


if __name__ == '__main__':
    raise SystemExit(main())
