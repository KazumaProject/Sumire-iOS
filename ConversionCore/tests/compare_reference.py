#!/usr/bin/env python3
"""Run the pinned Android candidate path in an isolated copy, then compare C++.

Requires the Android SDK and a JDK accepted by the reference Gradle wrapper.
JAVA_HOME and ANDROID_HOME are passed through. Outputs and build trees stay outside
this repository. The exported reference ordering is not an independent gold set.
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

REVISION = 'df1f38315bf56d860d32919a3eaed6a75499e91e'
ROOT = pathlib.Path(__file__).resolve().parents[2]


def compare(baseline, cli, data):
    comparisons = []
    for line in baseline.read_text().splitlines():
        reference = json.loads(line)
        reading = reference['reading']
        actual = json.loads(subprocess.check_output([
            str(cli), '--data', str(data), '--categories', reference['categories'], reading]))
        # Prefix candidates do not represent a complete conversion of this input.
        length = len(reading.encode('utf-16-le')) // 2
        expected = [c['text'] for c in reference['candidates'] if c['length_utf16'] == length][:10]
        got = [c['text'] for c in actual['candidates']][:10]
        comparisons.append(dict(reading=reading, categories=reference['categories'],
            reference=expected, cpp=got, complete=actual['complete'],
            top1_equal=bool(expected and got) and expected[0] == got[0],
            reference_top1_in_cpp10=bool(expected) and expected[0] in got,
            top10_equal=expected == got))
    return comparisons


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--source', type=pathlib.Path, default=ROOT/'.reference/JapaneseKeyboard')
    parser.add_argument('--cli', type=pathlib.Path, required=True)
    parser.add_argument('--data', type=pathlib.Path, required=True)
    parser.add_argument('--output', type=pathlib.Path, required=True)
    parser.add_argument('--baseline', type=pathlib.Path, help='Compare an existing export without rebuilding Android')
    args = parser.parse_args()
    output = args.output.resolve()
    if output == ROOT or ROOT in output.parents:
        parser.error('--output must be outside the source repository')
    output.mkdir(parents=True, exist_ok=True)
    if args.baseline:
        baseline = args.baseline.resolve()
    else:
        source = args.source.resolve()
        revision = subprocess.check_output(['git','-C',str(source),'rev-parse','HEAD'],text=True).strip()
        if revision != REVISION:
            parser.error('reference HEAD differs from pinned revision')
        # Read committed files, never alter the source or run Gradle inside it.
        archive = subprocess.check_output(['git','-C',str(source),'archive',REVISION])
        build = pathlib.Path(tempfile.mkdtemp(prefix='android-reference-', dir=output))
        with tarfile.open(fileobj=io.BytesIO(archive)) as tree:
            tree.extractall(build, filter='data')
        assets = build/'app/src/main/assets'
        hashes = {str(p.relative_to(assets)):hashlib.sha256(p.read_bytes()).hexdigest()
                  for p in sorted(assets.rglob('*')) if p.is_file()}
        adapter = pathlib.Path(__file__).parent/'reference/SumireIOSBaselineTest.kt'
        destination = build/'app/src/test/java/com/kazumaproject/markdownhelperkeyboard/converter'/adapter.name
        shutil.copyfile(adapter, destination)
        with (output/'android-build.log').open('w') as log:
            subprocess.run(['./gradlew',':app:testLiteStandardDebugUnitTest','--tests','*SumireIOSBaselineTest',
                            '--no-configuration-cache','--max-workers=4'],cwd=build,stdout=log,stderr=subprocess.STDOUT,check=True)
        baseline = output/'baseline.jsonl'
        shutil.copyfile(build/'app/build/reports/sumire-ios-baseline.jsonl', baseline)
        metadata = dict(revision=revision, adapter_sha256=hashlib.sha256(adapter.read_bytes()).hexdigest(),
                        shipped_asset_sha256=hashes, build_directory=str(build),
                        path='KanaKanjiEngine.getCandidatesWithoutPrediction', n=10, beam_width=20,
                        prediction=False, omission=False, user_dictionary=False, learning=False,
                        scope='Robolectric SDK 35; real dictionaries; mocked English engine and empty user repository')
        (output/'provenance.json').write_text(json.dumps(metadata,indent=2)+'\n')
    comparisons = compare(baseline, args.cli.resolve(), args.data.resolve())
    (output/'comparison.json').write_text(json.dumps(comparisons,ensure_ascii=False,indent=2)+'\n')
    print(json.dumps(dict(cases=len(comparisons), top1_equal=sum(r['top1_equal'] for r in comparisons),
                         reference_top1_in_cpp10=sum(r['reference_top1_in_cpp10'] for r in comparisons),
                         top10_equal=sum(r['top10_equal'] for r in comparisons)),indent=2))
    if not comparisons or not all(r['complete'] and r['top1_equal'] for r in comparisons):
        raise SystemExit(1)

if __name__ == '__main__':
    main()
