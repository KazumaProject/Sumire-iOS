#!/usr/bin/env python3
"""Failure-path checks for authored evaluation and dictionary provenance."""
import copy
import hashlib
import json
from pathlib import Path
import tempfile
import unittest

import evaluate_conversion_quality as evaluation
from quality_assets import atomic_write_json, validate_dictionary_assets


class CorpusEvaluationTests(unittest.TestCase):
    def setUp(self):
        self.corpus = json.loads(evaluation.CORPUS.read_text())

    def test_frozen_authored_cases_cover_all_groups_and_options(self):
        self.assertEqual(hashlib.sha256(evaluation.CORPUS.read_bytes()).hexdigest(), evaluation.CORPUS_SHA256)
        evaluation.validate_corpus(self.corpus)
        self.assertEqual(len(self.corpus['cases']), 48)
        self.assertEqual(sum(len(c.get('categories', ['none', 'all'])) for c in self.corpus['cases']), 92)
        self.assertEqual({c['group'] for c in self.corpus['cases']}, evaluation.GROUPS)

    def test_invalid_case_metadata_or_relaxed_targets_are_rejected(self):
        for change in [lambda c: c['targets'].update(minimum_top10_rate=0),
                       lambda c: c['configuration'].update(prediction=False),
                       lambda c: c['cases'].append(c['cases'][0]),
                       lambda c: c['cases'][0].update(accepted=[]),
                       lambda c: c['cases'][0].update(categories=['all', 'all']),
                       lambda c: c['cases'][0].update(omission=1),
                       lambda c: c['cases'][0].update(personal=[dict(kind='user', reading='a', text='A', context_id=True, score=0)]),
                       lambda c: c.update(cases=[r for r in c['cases'] if r['group'] != 'omission'])]:
            with self.subTest(change=change):
                corpus = copy.deepcopy(self.corpus); change(corpus)
                with self.assertRaises(ValueError): evaluation.validate_corpus(corpus)

    def test_measured_baseline_floor_cannot_be_relaxed(self):
        policy = json.loads(evaluation.POLICY_PATH.read_text())
        evaluation.validate_policy(policy)
        changed = copy.deepcopy(policy); changed['baseline']['minimum_top10_hits'] = 89
        with self.assertRaises(ValueError): evaluation.validate_policy(changed)
        case = self.corpus['cases'][0]
        row = evaluation.assess(case, 'all', dict(reading=case['reading'], complete=True, candidates=[dict(text=case['accepted'][0], score=0)]))
        self.assertFalse(evaluation.summarize([row], self.corpus['targets'], policy['baseline'])['passed'])

    def test_personal_argument_boundaries_and_omission_are_preserved(self):
        case = dict(reading='よみ', omission=True, personal=[dict(kind='template', reading='よみ', text='一行目\n二行目 $(never)', context_id=1851, score=-5000)])
        args = evaluation.command(Path('/cli'), Path('/data'), case, 'all', self.corpus['configuration'])
        self.assertIn('--omission', args)
        index = args.index('--template-entry')
        self.assertEqual(args[index + 1:index + 5], ['よみ', '一行目\n二行目 $(never)', '1851', '-5000'])
        self.assertEqual(args[-1], 'よみ')

    def test_display_order_and_top10_cutoff_are_not_filtered(self):
        case = self.corpus['cases'][0]
        candidates = [dict(text=str(i), score=i) for i in range(10)] + [dict(text=case['accepted'][0], score=11)]
        row = evaluation.assess(case, 'all', dict(reading=case['reading'], complete=True, candidates=candidates))
        self.assertFalse(row['top1']); self.assertFalse(row['top10'])
        self.assertEqual(row['candidate_count'], 11)
        candidates.insert(1, dict(text=case['accepted'][0], score=0))
        row = evaluation.assess(case, 'all', dict(reading=case['reading'], complete=True, candidates=candidates))
        self.assertTrue(row['top10']); self.assertFalse(row['top1'])

    def test_incomplete_and_critical_misses_cannot_pass(self):
        case = self.corpus['cases'][0]
        result = dict(reading=case['reading'], complete=False, candidates=[dict(text=case['accepted'][0], score=0)])
        row = evaluation.assess(case, 'all', result)
        report = evaluation.summarize([row], self.corpus['targets'])
        self.assertFalse(report['passed']); self.assertEqual(report['overall']['top10_hits'], 0)
        self.assertEqual(report['critical_failures'], [dict(id=case['id'], categories='all')])
        result['complete'] = True
        row = evaluation.assess(case, 'all', result)
        self.assertTrue(evaluation.summarize([row], self.corpus['targets'])['passed'])

    def test_cli_shape_and_requested_reading_are_checked(self):
        case = self.corpus['cases'][0]
        for result in [dict(reading='wrong', complete=True, candidates=[]),
                       dict(reading=case['reading'], complete=1, candidates=[]),
                       dict(reading=case['reading'], complete=True, candidates=[dict(text='日本語', score=True)])]:
            with self.assertRaises(ValueError): evaluation.assess(case, 'all', result)


class DictionaryAssetTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name) / 'data'; self.root.mkdir()
        (self.root / 'mozc').mkdir()
        (self.root / 'system.sud').write_bytes(b'system')
        (self.root / 'mozc/segmenter.dat').write_bytes(b'segmenter')
        self.manifest = dict(format=1, source_revision='revision', output_sha256={
            name: hashlib.sha256((self.root / name).read_bytes()).hexdigest()
            for name in ['system.sud', 'mozc/segmenter.dat']})

    def save(self):
        data = json.dumps(self.manifest).encode()
        (self.root / 'manifest.json').write_bytes(data)
        return hashlib.sha256(data).hexdigest()

    def validate(self, digest=None):
        return validate_dictionary_assets(self.root, digest or self.save(), 'revision', expected_count=2)

    def test_atomic_report_replaces_symlink_without_touching_its_target(self):
        checkout_file = Path(self.temp.name) / 'tracked-source'
        checkout_file.write_text('preserve source')
        output = self.root / 'report.json'; output.symlink_to(checkout_file)
        atomic_write_json(output, {'result': 'report'})
        self.assertEqual(checkout_file.read_text(), 'preserve source')
        self.assertFalse(output.is_symlink())
        self.assertEqual(json.loads(output.read_text()), {'result': 'report'})
        self.assertFalse(list(self.root.glob('.report.json-*')))

    def test_nested_assets_are_verified_including_bytes(self):
        result = self.validate()
        self.assertEqual(result['output_count'], 2)
        self.assertEqual(result['outputs']['mozc/segmenter.dat']['bytes'], 9)

    def test_tampered_or_omitted_output_and_manifest_are_rejected(self):
        digest = self.save()
        (self.root / 'system.sud').write_bytes(b'tampered')
        with self.assertRaises(ValueError): self.validate(digest)
        del self.manifest['output_sha256']['system.sud']
        with self.assertRaises(ValueError): self.validate()
        (self.root / 'manifest.json').write_bytes(b'{}')
        with self.assertRaises(ValueError): self.validate(digest)

    def test_missing_files_revision_and_symlink_escape_are_rejected(self):
        digest = self.save(); (self.root / 'system.sud').unlink()
        with self.assertRaises((ValueError, OSError)): self.validate(digest)
        external = Path(self.temp.name) / 'external'; external.write_bytes(b'system')
        (self.root / 'system.sud').symlink_to(external)
        with self.assertRaises(ValueError): self.validate(digest)
        self.manifest['source_revision'] = 'other'
        with self.assertRaises(ValueError): self.validate()

    def test_unsafe_output_names_are_rejected(self):
        for name in ['../escape', '/absolute', 'mozc/../escape', 'mozc//segmenter.dat', './system.sud', 'mozc\\segmenter.dat']:
            with self.subTest(name=name):
                self.manifest['output_sha256'] = {name: '0' * 64, 'system.sud': '0' * 64}
                with self.assertRaises(ValueError): self.validate()


if __name__ == '__main__':
    unittest.main()
