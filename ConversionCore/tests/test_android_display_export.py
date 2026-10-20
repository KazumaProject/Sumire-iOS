import copy
import hashlib
import json
import unittest
import export_android_display as display


class AndroidDisplayExportTests(unittest.TestCase):
    def policy(self):
        return {'readings': ['あ']}

    def rows(self):
        return [dict(reading='あ', categories=c, path=p, n=20, source_revision=display.raw.REVISION,
                     raw_candidates=[dict(raw_index=0, text='あ', dictionary_categories=[])],
                     projected_candidates=[dict(text='あ', raw_indices=[0])],
                     adapter_items=[dict(candidate_index=0, text=' あ ', type_label='', yomi_label='')])
                for c in ('none', 'all') for p in display.raw.PATHS]

    def test_preserves_both_routes_and_exact_adapter_whitespace(self):
        rows = self.rows()
        display.validate_rows(rows, self.policy())
        self.assertEqual(rows[0]['adapter_items'][0]['text'], ' あ ')

    def test_rejects_missing_duplicate_wrong_n_and_foreign_identity(self):
        variants = []
        rows = self.rows(); variants.append(rows[:-1])
        rows = self.rows(); rows[-1] = copy.deepcopy(rows[0]); variants.append(rows)
        rows = self.rows(); rows[0]['n'] = 10; variants.append(rows)
        rows = self.rows(); rows[0]['projected_candidates'][0]['raw_indices'] = [1]; variants.append(rows)
        rows = self.rows(); rows[0]['raw_candidates'][0]['text'] = 'い'; variants.append(rows)
        rows = self.rows(); rows[0]['adapter_items'] = []; variants.append(rows)
        for rows in variants:
            with self.assertRaises(ValueError):
                display.validate_rows(rows, self.policy())

    def test_companion_pin_and_existing_raw_adapter_stay_independent(self):
        policy = json.loads(display.POLICY_PATH.read_text())
        display.validate_policy(policy)
        invalid = copy.deepcopy(policy); invalid['n'] = 10
        with self.assertRaises(ValueError):
            display.validate_policy(invalid)
        observed = hashlib.sha256((display.raw.REFERENCES / display.ADAPTER).read_bytes()).hexdigest()
        self.assertEqual(policy['adapter_sha256'], observed)
        raw_adapter = display.raw.REFERENCES / display.raw.POLICY['reference']['adapter_path']
        self.assertEqual(hashlib.sha256(raw_adapter.read_bytes()).hexdigest(), display.raw.POLICY['reference']['adapter_sha256'])
        self.assertEqual(display.raw.POLICY['reference']['n'], 10)
        self.assertEqual(policy['n'], 20)


if __name__ == '__main__':
    unittest.main()
