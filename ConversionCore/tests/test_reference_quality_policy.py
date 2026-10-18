#!/usr/bin/env python3
import pathlib
import sys
import tempfile
import unittest

sys.path.insert(0, str(pathlib.Path(__file__).parent))
from compare_reference import (  # noqa: E402
    QUALITY_POLICY,
    evaluate_quality_gate,
    load_baseline,
    validate_dictionary_data,
    validate_baseline_rows,
)


def baseline_rows():
    reference = QUALITY_POLICY['reference']
    rows = []
    for index in range(QUALITY_POLICY['baseline']['readings']):
        reading = f'よみ{index}'
        length = len(reading.encode('utf-16-le')) // 2
        for category in reference['categories']:
            rows.append({
                'reading': reading,
                'categories': category,
                'source_revision': reference['revision'],
                'path': reference['path'],
                'n': reference['n'],
                'beam_width': reference['beam_width'],
                'omission': reference['omission'],
                'candidates': [{'text': f'候補{index}', 'length_utf16': length}],
            })
    return rows


def comparisons():
    rows = []
    for index in range(QUALITY_POLICY['baseline']['cases']):
        rows.append({
            'complete': True,
            'top1_equal': index < 36,
            'reference_top1_in_cpp10': True,
            'top10_equal': index < 36,
            'top10_scores_equal': index < 36,
        })
    return rows


class ReferenceQualityPolicyTests(unittest.TestCase):
    def test_pinned_baseline_rows_cover_both_category_sets(self):
        validate_baseline_rows(baseline_rows(), QUALITY_POLICY)

    def test_reference_revision_mismatch_is_rejected(self):
        rows = baseline_rows()
        rows[0]['source_revision'] = '9506a0baa7f2b56a74f85f2e3e776fe22f6b6e93'
        with self.assertRaisesRegex(ValueError, 'different reference revision'):
            validate_baseline_rows(rows, QUALITY_POLICY)

    def test_missing_category_case_is_rejected(self):
        rows = baseline_rows()[:-1]
        with self.assertRaisesRegex(ValueError, 'cases; expected'):
            validate_baseline_rows(rows, QUALITY_POLICY)

    def test_baseline_byte_hash_is_checked_before_parsing(self):
        with tempfile.TemporaryDirectory() as directory:
            path = pathlib.Path(directory) / 'baseline.jsonl'
            path.write_bytes(b'{}\n')
            with self.assertRaisesRegex(ValueError, 'reference baseline SHA-256 mismatch'):
                load_baseline(path, QUALITY_POLICY)

    def test_conversion_manifest_hash_is_checked(self):
        with tempfile.TemporaryDirectory() as directory:
            data = pathlib.Path(directory)
            (data / 'manifest.json').write_text('{}\n')
            with self.assertRaisesRegex(ValueError, 'conversion dictionary manifest SHA-256 mismatch'):
                validate_dictionary_data(data, QUALITY_POLICY)

    def test_pinned_thresholds_accept_current_baseline_floors(self):
        gate = evaluate_quality_gate(comparisons(), QUALITY_POLICY)
        self.assertTrue(gate['passed'], gate['failures'])
        self.assertEqual(gate['metrics']['cases'], 38)
        self.assertEqual(gate['metrics']['top1_equal'], 36)
        self.assertEqual(gate['metrics']['reference_top1_in_cpp10'], 38)
        self.assertEqual(gate['metrics']['top10_equal'], 36)

    def test_top10_reference_candidate_regression_fails(self):
        rows = comparisons()
        rows[-1]['reference_top1_in_cpp10'] = False
        gate = evaluate_quality_gate(rows, QUALITY_POLICY)
        self.assertFalse(gate['passed'])
        self.assertTrue(any('reference_top1_in_cpp10 37 < required 38' in issue
                            for issue in gate['failures']))

    def test_top1_top10_and_incomplete_search_regressions_fail(self):
        for field in ('top1_equal', 'top10_equal'):
            with self.subTest(field=field):
                rows = comparisons()
                rows[0][field] = False
                self.assertFalse(evaluate_quality_gate(rows, QUALITY_POLICY)['passed'])

        rows = comparisons()
        rows[-1]['complete'] = False
        self.assertFalse(evaluate_quality_gate(rows, QUALITY_POLICY)['passed'])


if __name__ == '__main__':
    unittest.main()
