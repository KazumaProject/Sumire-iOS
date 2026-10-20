#!/usr/bin/env python3
"""Compare n20 Android final display snapshots to production iOS service/bar exports.

This checks synthetic containing-app snapshots, not physical keyboard acceptance.
Raw Android arrays and both engine routes remain in the source export. Only the
getCandidatesOriginal route corresponds to the default iOS ordinary route.
"""
import argparse
import hashlib
import json
import pathlib
from quality_assets import atomic_write_json

REFERENCE = pathlib.Path(__file__).parent / 'reference'
RAW_POLICY_PATH = REFERENCE / 'prediction-policy.json'
POLICY = json.loads(RAW_POLICY_PATH.read_text())
REVISION = POLICY['reference']['revision']
ROUTE = 'KanaKanjiEngine.getCandidatesOriginal'


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def require(condition, message):
    if not condition:
        raise ValueError(message)


def validate_ios(report):
    require(report.get('schema_version') == 1 and report.get('platform') == 'ios', 'unexpected iOS schema')
    require(report.get('export_kind') == 'production_ordinary_display_snapshot', 'ordinary export required; omission is unpaired')
    require(report.get('reference_revision') == REVISION, 'iOS reference revision mismatch')
    require(report.get('prediction_policy_sha256') == digest(RAW_POLICY_PATH), 'iOS corpus policy hash mismatch')
    require(report.get('readings') == POLICY['baseline']['readings'], 'iOS corpus mismatch')
    config = report.get('configuration', {})
    fixed = dict(candidate_count=20, max_states=200000, flags=12, omission=False,
                 japanese_prediction=True, reading_prefix=True, english_reading=True,
                 english=False, bunsetsu_search=False, include_bunsetsu=False,
                 personal_entries=0, learning_enabled=False)
    require(all(config.get(k) == v for k, v in fixed.items()), 'iOS configuration mismatch')
    provenance = report.get('provenance', {})
    revision = provenance.get('source_revision', '')
    require(isinstance(revision, str) and len(revision) == 40 and all(c in '0123456789abcdef' for c in revision), 'iOS source revision missing')
    require(provenance.get('manifest_sha256') == POLICY['conversion_data']['manifest_sha256'], 'iOS manifest mismatch')
    require(provenance.get('dictionary_file_sha256') == POLICY['conversion_data']['output_sha256'], 'iOS dictionary output hashes mismatch')
    require(provenance.get('verified_manifest_output_count') == 44, 'iOS complete 44-file verification required')
    expected = {(r, c) for r in POLICY['baseline']['readings'] for c in ('none', 'all')}
    rows = report.get('conditions', [])
    require(report.get('condition_count') == 50 and len(rows) == 50, 'iOS condition count mismatch')
    indexed = {}
    for row in rows:
        key = (row.get('reading'), row.get('categories'))
        require(key in expected and key not in indexed, 'unexpected or duplicate iOS condition')
        require(row.get('complete') is True and row.get('flags') == 12, 'incomplete or nonordinary iOS result')
        require(row.get('category_mask') == (0 if key[1] == 'none' else 0x3fffffff), 'iOS category mask mismatch')
        candidates = row.get('candidates', [])
        require(isinstance(candidates, list) and candidates and row.get('candidate_count') == len(candidates), 'iOS candidate count mismatch or empty result')
        ids = set()
        for index, c in enumerate(candidates):
            require(c.get('candidate_index') == index and type(c.get('id')) is int and c['id'] not in ids, 'iOS candidate identity mismatch')
            ids.add(c['id'])
            require(isinstance(c.get('text'), str) and type(c.get('score')) is int and
                    c.get('start_utf16') == 0 and type(c.get('length_utf16')) is int and c['length_utf16'] > 0,
                    'invalid iOS candidate metadata')
        for mode in ('normal', 'expanded'):
            items = row.get(mode, {}).get('items', [])
            require(len(items) == len(candidates), 'iOS bar count mismatch')
            for index, (c, item) in enumerate(zip(candidates, items)):
                require(item.get('candidate_index') == index and item.get('selected_index') == index and
                        item.get('selected_candidate_id') == c['id'], 'iOS selection identity mismatch')
                require(item.get('semantic_text') == c['text'] and item.get('accessibility_label') == c['text'] and
                        item.get('accessibility_value') == c.get('display_annotation'), 'iOS cell projection mismatch')
                labels = item.get('labels', [])
                titles = [v for v in labels if v.get('identifier') is None and not v.get('hidden')]
                annotations = [v for v in labels if v.get('identifier') == 'candidate-annotation' and not v.get('hidden')]
                require(len(titles) == 1 and titles[0].get('text') == c['text'], 'iOS rendered title mismatch')
                require([v.get('text') for v in annotations] == ([c['display_annotation']] if c.get('display_annotation') else []),
                        'iOS rendered annotation mismatch')
        indexed[key] = row
    require(set(indexed) == expected, 'iOS corpus incomplete')
    return indexed


def validate_android(rows):
    expected = {(r, c, p) for r in POLICY['baseline']['readings'] for c in ('none', 'all')
                for p in POLICY['reference']['paths']}
    indexed = {}
    for row in rows:
        key = (row.get('reading'), row.get('categories'), row.get('path'))
        require(key in expected and key not in indexed, 'unexpected or duplicate Android condition')
        require(row.get('source_revision') == REVISION and row.get('n') == 20 and row.get('beam_width') == 20 and
                row.get('omission') is False and row.get('prediction') is True, 'Android configuration mismatch')
        config = row.get('configuration', {})
        require(config.get('locale') == 'ja-JP' and config.get('timezone') == 'Asia/Tokyo' and config.get('tail') == '' and
                config.get('suppress_hentaigana') is False and config.get('live_conversion') is False and
                config.get('inline_suggestions') is False and
                config.get('personal_learning_macros_ng_romaji_ai_utility_saved_order') == 'disabled', 'Android display settings mismatch')
        candidates, items = row.get('projected_candidates', []), row.get('adapter_items', [])
        require(isinstance(candidates, list) and candidates and row.get('raw_candidates') and len(candidates) == len(items), 'Android Adapter count mismatch or empty result')
        for index, (c, item) in enumerate(zip(candidates, items)):
            require(item.get('candidate_index') == index and isinstance(c.get('text'), str) and
                    isinstance(c.get('effective_commit_text'), str) and type(c.get('score')) is int and
                    type(c.get('length_utf16')) is int and isinstance(item.get('text'), str) and
                    isinstance(item.get('type_label'), str), 'Android candidate metadata mismatch')
            require(c.get('effective_commit_text') == android_effective_commit_text(c, row['reading']), 'Android tap commit projection mismatch')
            raw = c['text']
            semantic = raw.split('\t', 1)[0] if c.get('type') == 15 else raw
            units = len(raw.encode('utf-16-le')) // 2
            padding = 4 if index == 0 or units == 1 else (2 if units == 2 else 1)
            require(item['text'] == ' ' * padding + semantic + ' ' * padding, 'Android rendered title mismatch')
        indexed[key] = row
    require(set(indexed) == expected, 'Android corpus incomplete')
    return indexed


def android_effective_commit_text(c, reading):
    if c['type'] == 15:
        return c['text'].split('\t', 1)[0]
    if c['type'] in {9, 11, 13} or len(reading.encode('utf-16-le')) // 2 == c['length_utf16']:
        return c['text']
    return c['commit_text']


def android_signature(c, item, reading):
    # Padding is represented separately by the original Adapter text. Do not
    # strip candidate whitespace: it may be actual dictionary content.
    raw = c['text']
    # Candidate.length is the dictionary reading length for predictions, not
    # necessarily an editor range. Pinned processCandidate commits all input
    # for prediction/correction/emoji/symbol types; partial ordinary matches
    # retain only the suffix beyond candidate.length.
    require(c.get('type') in {1, 2, 3, 4, 5, 7, 9, 11, 13, 15, 31},
            'new candidate type requires commit-semantics source audit')
    typed = len(reading.encode('utf-16-le')) // 2
    consumed = typed if c['type'] in {9, 11, 13, 15} else min(typed, c['length_utf16'])
    semantic = raw.split('\t', 1)[0] if c.get('type') == 15 else raw
    return dict(raw_text=raw, display_text=semantic, effective_commit_text=android_effective_commit_text(c, reading),
                corrected_reading=c.get('correction_reading'), consumed_utf16=consumed,
                score=c['score'], annotation=item['type_label'].strip(), is_reading_prefix=c.get('type') == 5)


def ios_signature(c):
    return dict(raw_text=c.get('raw_text') or c['text'], display_text=c['text'], effective_commit_text=c['text'],
                corrected_reading=c.get('corrected_reading'), consumed_utf16=c['length_utf16'], score=c['score'],
                annotation=c.get('display_annotation') or '', is_reading_prefix=c['is_reading_prefix'])


def compare(android, ios):
    a, i = validate_android(android), validate_ios(ios)
    conditions = []
    for reading in POLICY['baseline']['readings']:
        for category in ('none', 'all'):
            source, target = a[(reading, category, ROUTE)], i[(reading, category)]
            left = [android_signature(c, v, reading) for c, v in zip(source['projected_candidates'], source['adapter_items'])]
            right = [ios_signature(c) for c in target['candidates']]
            diffs = []
            for index in range(max(len(left), len(right))):
                x = left[index] if index < len(left) else None
                y = right[index] if index < len(right) else None
                if x != y:
                    diffs.append(dict(index=index, android=x, ios=y,
                                      fields=[k for k in x if x[k] != y[k]] if x is not None and y is not None else ['presence']))
            top = lambda xs: [(v['display_text'], v['score']) for v in xs]
            conditions.append(dict(reading=reading, categories=category,
                android_raw_count=len(source['raw_candidates']), android_display_count=len(left), ios_display_count=len(right),
                count_equal=len(left) == len(right), ordered_top1_text_score_equal=top(left[:1]) == top(right[:1]),
                ordered_top10_text_score_equal=top(left[:10]) == top(right[:10]),
                full_compared_fields_equal=left == right, differences=diffs))
    metrics = {name: sum(c[name] for c in conditions) for name in
               ('count_equal', 'ordered_top1_text_score_equal', 'ordered_top10_text_score_equal', 'full_compared_fields_equal')}
    return dict(schema_version=1, source_revision=REVISION, ios_source_revision=ios['provenance']['source_revision'], route=ROUTE, n=20, conditions_compared=50,
                scope='Synthetic Android pure pipeline + actual Adapter vs iOS service + actual CandidateBar. No physical keyboard/editor/commit acceptance.',
                compared_fields=list(ios_signature(dict(text='', length_utf16=1, score=0, is_reading_prefix=False))),
                unpaired_metadata=['Android lexical reading length/type/POS/yomi/category metadata vs iOS provenance labels', 'Actual editor commit and learning'],
                android_commit_projection='Pinned IMEService processCandidate25950/handlePartialOrExcessLength25900: type9/11/13/15 consume full input; other observed types consume min(inputUTF16,candidate.length). Lexical length retained in original export.',
                compared_fields_parity_achieved=metrics['full_compared_fields_equal'] == 50, metrics=metrics, conditions=conditions)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--android', required=True, type=pathlib.Path)
    parser.add_argument('--ios', required=True, type=pathlib.Path)
    parser.add_argument('--ios-revision', required=True, help='Expected full source commit used by the iOS test build')
    parser.add_argument('--android-provenance', required=True, type=pathlib.Path)
    parser.add_argument('--android-policy', required=True, type=pathlib.Path)
    parser.add_argument('--output', required=True, type=pathlib.Path)
    parser.add_argument('--diagnostic', action='store_true', help='retain differences without a failing parity exit status')
    args = parser.parse_args()
    root = pathlib.Path(__file__).resolve().parents[2]
    require(root not in args.output.resolve().parents and args.output.resolve() != root, 'report must be outside repository')
    provenance = json.loads(args.android_provenance.read_text())
    policy = json.loads(args.android_policy.read_text())
    canonical_policy = REFERENCE / 'display-policy.json'
    require(digest(args.android_policy) == digest(canonical_policy), 'Android policy is not the checked-in pinned policy')
    require(policy.get('adapter_sha256') == digest(REFERENCE / 'SumireIOSDisplayBaselineTest.kt'), 'Android checked-in adapter hash mismatch')
    require(provenance.get('baseline_sha256') == digest(args.android), 'Android snapshot hash mismatch')
    require(provenance.get('policy_sha256') == digest(args.android_policy) and
            provenance.get('adapter_sha256') == policy.get('adapter_sha256') and
            provenance.get('source_revision') == REVISION, 'Android provenance mismatch')
    ios = json.loads(args.ios.read_text())
    require(ios.get('provenance', {}).get('source_revision') == args.ios_revision, 'iOS source revision differs from expected build')
    report = compare([json.loads(line) for line in args.android.read_text().splitlines()], ios)
    report['inputs_sha256'] = {k: digest(getattr(args, k)) for k in ('android', 'ios', 'android_provenance', 'android_policy')}
    atomic_write_json(args.output, report)
    print(json.dumps({k: report[k] for k in ('conditions_compared', 'compared_fields_parity_achieved', 'metrics')}))
    return 0 if args.diagnostic or report['compared_fields_parity_achieved'] else 1


if __name__ == '__main__':
    raise SystemExit(main())
