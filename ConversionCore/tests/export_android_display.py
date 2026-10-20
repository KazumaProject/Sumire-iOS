#!/usr/bin/env python3
"""Export constrained pinned Android display pipeline; never an iOS parity gate.

Companion to compare_prediction_reference.py. Preserves its n=10 raw contract.
Uses actual production pure functions and RecyclerView Adapter in an external
archive; private IMEService routing, editor lifecycle and device UI are not run.
"""
import argparse
import io
import json
import os
import pathlib
import shutil
import subprocess
import tarfile
import tempfile
import xml.etree.ElementTree as ET
import compare_prediction_reference as raw
from quality_assets import atomic_write_bytes, atomic_write_json

ADAPTER = 'SumireIOSDisplayBaselineTest.kt'
POLICY_PATH = raw.REFERENCES / 'display-policy.json'


def validate_policy(policy):
    if (policy.get('schema_version') != 1 or policy.get('source_revision') != raw.REVISION
            or policy.get('n') != 20 or policy.get('beam_width') != 20
            or policy.get('readings') != raw.POLICY['baseline']['readings']):
        raise ValueError('display policy differs from fixed source/configuration/corpus')
    sha = policy.get('adapter_sha256')
    if not isinstance(sha, str) or len(sha) != 64 or any(c not in '0123456789abcdef' for c in sha):
        raise ValueError('malformed adapter hash')


def validate_rows(rows, policy):
    expected = {(r, c, p) for r in policy['readings'] for c in ('none', 'all') for p in raw.PATHS}
    observed = set()
    for row in rows:
        key = (row.get('reading'), row.get('categories'), row.get('path'))
        if key not in expected or key in observed or row.get('n') != 20 or row.get('source_revision') != raw.REVISION:
            raise ValueError('unexpected display row identity/configuration')
        observed.add(key)
        original, projected, bound = (row[k] for k in ('raw_candidates', 'projected_candidates', 'adapter_items'))
        if len(projected) != len(bound):
            raise ValueError('Adapter count differs from projection')
        for index, c in enumerate(original):
            if c.get('raw_index') != index or not isinstance(c.get('dictionary_categories'), list):
                raise ValueError('raw metadata missing')
        for index, (c, item) in enumerate(zip(projected, bound)):
            ids = c.get('raw_indices')
            if not ids or any(type(i) is not int or i < 0 or i >= len(original) or original[i]['text'] != c['text'] for i in ids):
                raise ValueError('raw identity mapping differs')
            if item.get('candidate_index') != index or any(not isinstance(item.get(k), str) for k in ('text', 'type_label', 'yomi_label')):
                raise ValueError('Adapter metadata missing')
    if observed != expected:
        raise ValueError('display corpus incomplete')


def export(source, output, java_home, sdk, policy):
    if subprocess.check_output(['git', '-C', str(source), 'rev-parse', 'HEAD'], text=True).strip() != raw.REVISION:
        raise ValueError('reference HEAD differs from pin')
    adapter = raw.REFERENCES / ADAPTER
    raw.require_hash(adapter.read_bytes(), policy['adapter_sha256'], 'display adapter')
    archive = subprocess.check_output(['git', '-C', str(source), 'archive', raw.REVISION])
    build = pathlib.Path(tempfile.mkdtemp(prefix='android-display-', dir=output))
    with tarfile.open(fileobj=io.BytesIO(archive)) as tree:
        tree.extractall(build, filter='data')
    source_hashes = {str(p.relative_to(build)): raw.digest(p.read_bytes()) for p in sorted(build.rglob('*')) if p.is_file()}
    atomic_write_json(output / 'source-manifest.json', source_hashes)
    for relative, sha in raw.POLICY['conversion_data']['asset_sha256'].items():
        raw.require_hash(raw.relative_file(build / 'app/src/main/assets', relative).read_bytes(), sha, relative)
    factory = build / raw.FACTORY_PATH
    factory.write_bytes(raw.patch_factory(factory.read_bytes(), raw.POLICY))
    shutil.copyfile(adapter, build / 'app/src/test/java/com/kazumaproject/markdownhelperkeyboard/converter' / ADAPTER)
    version = subprocess.check_output([str(java_home / 'bin/java'), '-version'], stderr=subprocess.STDOUT, text=True)
    if 'version "21' not in version:
        raise ValueError('requires JDK21')
    command = ['./gradlew', '--offline', ':app:testFullStandardDebugUnitTest', '--rerun', '--tests', '*SumireIOSDisplayBaselineTest', '--no-configuration-cache', '--max-workers=2', '-Dorg.gradle.parallel=false']
    with raw.open_build_log(output / 'android-build.log') as log:
        subprocess.run(command, cwd=build, env={**os.environ, 'JAVA_HOME': str(java_home), 'ANDROID_HOME': str(sdk)}, stdout=log, stderr=subprocess.STDOUT, check=True)
    xml = ET.fromstring((build / 'app/build/test-results/testFullStandardDebugUnitTest/TEST-com.kazumaproject.markdownhelperkeyboard.converter.SumireIOSDisplayBaselineTest.xml').read_bytes())
    if tuple(xml.get(k) for k in ('tests', 'failures', 'errors', 'skipped')) != ('4', '0', '0', '0'):
        raise ValueError('all four exporter tests must execute successfully')
    baseline = (build / 'app/build/reports/sumire-ios-display-baseline.jsonl').read_bytes()
    rows = [json.loads(line) for line in baseline.decode().splitlines()]
    validate_rows(rows, policy)
    atomic_write_bytes(output / 'display-baseline.jsonl', baseline)
    atomic_write_json(output / 'provenance.json', dict(source_revision=raw.REVISION, source_archive_sha256=raw.digest(archive), source_manifest_sha256=raw.digest((output / 'source-manifest.json').read_bytes()), adapter_sha256=raw.digest(adapter.read_bytes()), policy_sha256=raw.digest(POLICY_PATH.read_bytes()), baseline_sha256=raw.digest(baseline), command=command, java_launcher_version=version, pinned_gradle_daemon_jvm_criteria=(build / 'gradle/gradle-daemon-jvm.properties').read_text(), rows=len(rows), limits=policy['limits']))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--source', type=pathlib.Path, default=raw.ROOT / '.reference/JapaneseKeyboard')
    parser.add_argument('--output', required=True, type=pathlib.Path)
    parser.add_argument('--java-home', required=True, type=pathlib.Path)
    parser.add_argument('--android-sdk', required=True, type=pathlib.Path)
    args = parser.parse_args()
    output = args.output.resolve()
    if output == raw.ROOT or raw.ROOT in output.parents:
        parser.error('output must be outside repository')
    output.mkdir(parents=True, exist_ok=True)
    for name in ('source-manifest.json', 'android-build.log', 'display-baseline.jsonl', 'provenance.json'):
        if (output / name).exists() or (output / name).is_symlink():
            parser.error('fresh export requires unused output leaves')
    policy = json.loads(POLICY_PATH.read_text())
    validate_policy(policy)
    export(args.source.resolve(), output, args.java_home.resolve(), args.android_sdk.resolve(), policy)


if __name__ == '__main__':
    main()
