#!/usr/bin/env python3
"""Adversarial checks for fixed production prediction comparison metadata."""
import copy
import importlib.util
import json
import pathlib
import tempfile
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location('prediction', pathlib.Path(__file__).with_name('compare_prediction_reference.py'))
p = importlib.util.module_from_spec(spec)
spec.loader.exec_module(p)


def baseline():
    reference = p.POLICY['reference']
    rows = []
    for route in reference['paths']:
        for category in reference['categories']:
            for reading in p.POLICY['baseline']['readings']:
                row = {key: reference[key] for key in ['n', 'beam_width', 'omission', 'prediction', 'prediction_minimum_input', 'prediction_limit',
                    'prediction_lookahead', 'prediction_aggressiveness', 'system_ngram_rule_count', 'system_ngram_storage_bytes']}
                row.update(reading=reading, categories=category, path=route, source_revision=p.REVISION,
                    candidates=[dict(text='候補', score=100, length_utf16=1, type=255)])
                rows.append(row)
    return rows


class Tests(unittest.TestCase):
    def test_all_output_symlink_leaves_are_rejected_without_modifying_target(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = pathlib.Path(temporary); output = root / 'output'; output.mkdir()
            protected = root / 'protected'; protected.write_bytes(b'preserve')
            for name in p.OUTPUT_NAMES:
                leaf = output / name; leaf.symlink_to(protected)
                with self.assertRaises(ValueError): p.validate_output_leaves(output)
                self.assertEqual(protected.read_bytes(), b'preserve')
                leaf.unlink()
            p.validate_output_leaves(output)

    def test_build_log_does_not_follow_symlink_or_truncate_existing_hardlink(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = pathlib.Path(temporary); protected = root / 'protected'; protected.write_bytes(b'preserve')
            log = root / 'log'; log.symlink_to(protected)
            with self.assertRaises(OSError): p.open_build_log(log)
            log.unlink(); log.hardlink_to(protected)
            with self.assertRaises(OSError): p.open_build_log(log)
            self.assertEqual(protected.read_bytes(), b'preserve')
            log.unlink()
            with p.open_build_log(log) as stream: stream.write('new log')
            self.assertEqual(log.read_text(), 'new log')

    def test_export_forces_only_selected_test_task_offline(self):
        command = p.android_command()
        self.assertIn('--offline', command)
        self.assertEqual(command[command.index(':app:testFullStandardDebugUnitTest') + 1], '--rerun')
        self.assertNotIn('--rerun-tasks', command)

    def test_pinned_policy_and_adapter(self):
        p.validate_policy(p.POLICY)
        p.require_hash((p.REFERENCES / p.POLICY['reference']['adapter_path']).read_bytes(), p.POLICY['reference']['adapter_sha256'], 'adapter')

    def test_exact_case_coverage_and_unknown_candidate_types_are_preserved(self):
        rows = baseline()
        p.validate_baseline_rows(rows, p.POLICY)
        self.assertEqual(rows[0]['candidates'][0]['type'], 255)
        for bad in [rows[:-1], rows + [rows[0]], rows[:-1] + [rows[0]]]:
            with self.assertRaises(ValueError): p.validate_baseline_rows(bad, p.POLICY)

    def test_every_runtime_option_revision_and_route_are_validated(self):
        for field, value in dict(source_revision='0' * 40, path='fake', categories='missing', reading='unlisted', n=20,
                beam_width=1, omission=True, prediction=False, prediction_minimum_input=1, prediction_limit=3,
                prediction_lookahead=4, prediction_aggressiveness='other', system_ngram_rule_count=0,
                system_ngram_storage_bytes=0).items():
            rows = baseline(); rows[0][field] = value
            with self.assertRaises(ValueError, msg=field): p.validate_baseline_rows(rows, p.POLICY)
        rows = baseline(); rows[0]['n'] = True
        with self.assertRaises(ValueError): p.validate_baseline_rows(rows, p.POLICY)

    def test_malformed_candidate_metadata_rejected(self):
        for value in [None, [], [{}], [dict(text=1, score=100, length_utf16=1, type=1)],
                      [dict(text='A', score=True, length_utf16=1, type=1)],
                      [dict(text='A', score=1, length_utf16=-1, type=1)],
                      [dict(text='A', score=1, length_utf16=1)]]:
            rows = baseline(); rows[0]['candidates'] = value
            with self.assertRaises(ValueError): p.validate_baseline_rows(rows, p.POLICY)

    def test_baseline_content_hash_rejected_before_parsing(self):
        with tempfile.TemporaryDirectory() as temporary:
            path = pathlib.Path(temporary) / 'baseline.jsonl'; path.write_text('{}\n')
            with self.assertRaisesRegex(ValueError, 'SHA-256'): p.load_baseline(path, p.POLICY)

    def test_policy_cannot_silently_relax_gate_or_options(self):
        for section, field, value in [('gate', 'minimum_top1_text_score_equal', 99), ('reference', 'n', 20),
                                      ('reference', 'omission', 0), ('baseline', 'cases', 99)]:
            policy = copy.deepcopy(p.POLICY); policy[section][field] = value
            with self.assertRaises(ValueError): p.validate_policy(policy)

    def test_factory_pin_rejects_unknown_original(self):
        with self.assertRaisesRegex(ValueError, 'SHA-256'): p.patch_factory(b'unreviewed factory', p.POLICY)

    def test_asset_hashes_missing_files_and_omitted_outputs_rejected(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = pathlib.Path(temporary)
            hashes = {}
            for name in p.POLICY['conversion_data']['output_sha256']:
                file = root / name; file.parent.mkdir(parents=True, exist_ok=True); file.write_bytes(b'fixture')
                hashes[name] = p.digest(b'fixture')
            manifest = dict(format=1, source_revision=p.REVISION, output_sha256=hashes, asset_sha256={'source': p.digest(b'original')})
            raw = json.dumps(manifest).encode(); (root / 'manifest.json').write_bytes(raw)
            policy = copy.deepcopy(p.POLICY); policy['conversion_data'].update(manifest_sha256=p.digest(raw), output_sha256=hashes, asset_sha256=manifest['asset_sha256'])
            self.assertEqual(p.validate_dictionary_data(root, policy)['output_count'], 44)
            (root / 'reading_correction.sud').write_bytes(b'tampered')
            with self.assertRaises(ValueError): p.validate_dictionary_data(root, policy)
            (root / 'reading_correction.sud').unlink()
            with self.assertRaises((ValueError, OSError)): p.validate_dictionary_data(root, policy)
            del manifest['output_sha256']['reading_correction.sud']
            raw = json.dumps(manifest).encode(); (root / 'manifest.json').write_bytes(raw)
            policy['conversion_data']['manifest_sha256'] = p.digest(raw)
            with self.assertRaises(ValueError): p.validate_dictionary_data(root, policy)

    def test_comparison_retains_prefix_unknown_type_duplicates_and_false_complete(self):
        row = baseline()[0]
        row['candidates'] = [dict(text='prefix', score=1, length_utf16=1, type=255),
                             dict(text='prefix', score=1, length_utf16=1, type=255),
                             dict(text='whole', score=2, length_utf16=4, type=1)]
        actual = dict(reading=row['reading'], complete=False, candidates=[
            dict(text='prefix', score=1, segments=[]), dict(text='whole', score=2, segments=[])])
        with patch.object(p.subprocess, 'check_output', return_value=json.dumps(actual).encode()):
            compared = p.compare([row], pathlib.Path('/fixture/cli'), pathlib.Path('/fixture/data'))[0]
        self.assertEqual(compared['reference_candidates'], row['candidates'])
        self.assertEqual(compared['reference_count'], 3)
        self.assertEqual(compared['cpp_count'], 2)
        self.assertEqual(compared['missing_reference_type_counts'], {'255': 1})
        self.assertFalse(compared['cpp_complete'])
        self.assertFalse(compared['top10_text_score_equal'])

    def test_cli_replacement_during_comparison_is_rejected(self):
        with tempfile.TemporaryDirectory() as temporary:
            cli = pathlib.Path(temporary) / 'cli'; cli.write_bytes(b'original executable')
            def changing_compare(*args):
                cli.write_bytes(b'replaced executable')
                return []
            with patch.object(p, 'compare', side_effect=changing_compare):
                with self.assertRaisesRegex(ValueError, 'CLI executable changed'):
                    p.compare_pinned_cli([], cli, pathlib.Path(temporary))
            with patch.object(p, 'compare', return_value=[]):
                result, observed = p.compare_pinned_cli([], cli, pathlib.Path(temporary))
            self.assertEqual(result, [])
            self.assertEqual(observed, p.digest(b'replaced executable'))

    def test_gate_records_full_array_deficits_without_claiming_parity(self):
        rows = [dict(cpp_complete=True, top1_text_score_equal=True, top10_text_score_equal=True,
            full_text_score_order_equal=False, full_text_score_multiset_equal=False,
            reference_count=12, cpp_count=10) for _ in range(100)]
        gate = p.evaluate(rows, p.POLICY)
        self.assertTrue(gate['passed'])
        self.assertEqual(gate['metrics']['full_text_score_order_equal'], 0)
        self.assertEqual(gate['metrics']['reference_candidates'], 1200)
        self.assertTrue(gate['not_proven'])
        rows[0]['cpp_complete'] = False
        self.assertFalse(p.evaluate(rows, p.POLICY)['passed'])
        rows[0]['cpp_complete'] = True; rows[0]['top10_text_score_equal'] = False
        self.assertFalse(p.evaluate(rows, p.POLICY)['passed'])


if __name__ == '__main__': unittest.main()
