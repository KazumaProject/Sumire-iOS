import copy
import json
import unittest
import export_real_english as exporter


class RealEnglishExportTests(unittest.TestCase):
    def rows(self):
        rows = []
        eligible = {'a', 'A', 'ab', 'Ab', 'AB', 'app', 'ApP', 'APP', 'iPh', 'NASA', 'zzzzq',
                    'ａｂ', 'Ａｂ', 'ＡＢ', '＋', '　', 'ａ＋ｂ'}
        for text in exporter.INPUTS:
            normalized = text.translate(str.maketrans({ord(c): ord(c) - 0xfee0 for c in text if '！' <= c <= '～'})).replace('　', ' ')
            value = dict(text='word', score=100, lexical_length_utf16=4, consumed_utf16=1, effective_commit_text='word')
            rows.append(dict(reading=text, provider_input=normalized, eligible=text in eligible,
                source_revision=exporter.raw.REVISION, n=20, beam_width=20, typo_correction=False,
                provider=[value] if text in eligible else [], japanese_original=[value], dedicated_english=[value], projected=[value], adapter_items=[dict(text='    word    ', annotation='')]))
        return rows

    def test_rejects_missing_duplicate_and_changed_route_metadata(self):
        exporter.validate_rows(self.rows())
        for mutation in ('missing', 'duplicate', 'revision', 'normalization', 'eligibility', 'empty', 'score', 'adapter_count', 'commit'):
            rows = copy.deepcopy(self.rows())
            if mutation == 'missing': rows.pop()
            if mutation == 'duplicate': rows[1] = rows[0]
            if mutation == 'revision': rows[0]['source_revision'] = 'other'
            if mutation == 'normalization': rows[11]['provider_input'] = 'ａｂ'
            if mutation == 'eligibility': rows[0]['eligible'] = False
            if mutation == 'empty': rows[0]['dedicated_english'] = []
            if mutation == 'score': rows[0]['provider'][0]['score'] = '100'
            if mutation == 'adapter_count': rows[0]['adapter_items'] = []
            if mutation == 'commit': rows[0]['projected'][0]['effective_commit_text'] = None
            with self.subTest(mutation=mutation), self.assertRaises(ValueError):
                exporter.validate_rows(rows)

    def test_replay_requires_baseline_policy_adapter_and_revision_identity(self):
        policy = json.loads(exporter.POLICY_PATH.read_text())
        baseline = b'fixture'
        provenance = dict(baseline_sha256=exporter.raw.digest(baseline), source_revision=exporter.raw.REVISION,
            adapter_sha256=policy['adapter_sha256'], policy_sha256=exporter.raw.digest(exporter.POLICY_PATH.read_bytes()))
        exporter.validate_replay(baseline, provenance, policy)
        for key in provenance:
            altered = {**provenance, key: 'changed'}
            with self.subTest(key=key), self.assertRaises(ValueError):
                exporter.validate_replay(baseline, altered, policy)
        with self.assertRaises(ValueError): exporter.validate_replay(b'changed', provenance, policy)

    def test_factory_patch_rejects_unpinned_source_before_edit(self):
        with self.assertRaises(ValueError): exporter.patch_factory(b'not pinned factory', {})


if __name__ == '__main__':
    unittest.main()
