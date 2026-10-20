import copy
import unittest
import compare_display_reference as comparison


class DisplayComparisonTests(unittest.TestCase):
    def snapshots(self):
        android = []
        conditions = []
        for reading in comparison.POLICY['baseline']['readings']:
            for category in ('none', 'all'):
                for path in comparison.POLICY['reference']['paths']:
                    candidate = dict(text='橋', commit_text='橋', effective_commit_text='橋', correction_reading=None,
                                     score=10, length_utf16=1, type=5)
                    android.append(dict(reading=reading, categories=category, path=path,
                        source_revision=comparison.REVISION, n=20, beam_width=20, omission=False, prediction=True,
                        configuration=dict(locale='ja-JP', timezone='Asia/Tokyo', tail='', suppress_hentaigana=False,
                            live_conversion=False, inline_suggestions=False,
                            personal_learning_macros_ng_romaji_ai_utility_saved_order='disabled'),
                        raw_candidates=[candidate, candidate], projected_candidates=[candidate],
                        adapter_items=[dict(candidate_index=0, text='    橋    ', type_label='[部]')]))
                candidate = dict(candidate_index=0, id=7, text='橋', raw_text=None, corrected_reading=None,
                                 score=10, start_utf16=0, length_utf16=1, is_reading_prefix=True,
                                 display_annotation='[部]')
                item = dict(candidate_index=0, selected_index=0, selected_candidate_id=7,
                            semantic_text='橋', accessibility_label='橋', accessibility_value='[部]',
                            labels=[dict(identifier=None, text='橋', hidden=False),
                                    dict(identifier='candidate-annotation', text='[部]', hidden=False)])
                conditions.append(dict(reading=reading, categories=category,
                    category_mask=0 if category == 'none' else 0x3fffffff,
                    complete=True, flags=12, candidate_count=1, candidates=[candidate],
                    normal=dict(items=[item]), expanded=dict(items=[copy.deepcopy(item)])))
        ios = dict(schema_version=1, platform='ios', export_kind='production_ordinary_display_snapshot',
            reference_revision=comparison.REVISION, prediction_policy_sha256=comparison.digest(comparison.RAW_POLICY_PATH),
            readings=comparison.POLICY['baseline']['readings'],
            configuration=dict(candidate_count=20, max_states=200000, flags=12, omission=False,
                japanese_prediction=True, reading_prefix=True, english_reading=True, english=False,
                bunsetsu_search=False, include_bunsetsu=False, personal_entries=0, learning_enabled=False),
            provenance=dict(source_revision='1' * 40, manifest_sha256=comparison.POLICY['conversion_data']['manifest_sha256'],
                dictionary_file_sha256=comparison.POLICY['conversion_data']['output_sha256'], verified_manifest_output_count=44),
            condition_count=50, conditions=conditions)
        return android, ios

    def test_compares_final_lists_without_requiring_raw_counts_equal(self):
        android, ios = self.snapshots()
        report = comparison.compare(android, ios)
        self.assertTrue(report['compared_fields_parity_achieved'])
        self.assertEqual(report['metrics']['full_compared_fields_equal'], 50)
        self.assertEqual(report['conditions'][0]['android_raw_count'], 2)

    def test_preserves_correction_identity_and_candidate_whitespace(self):
        c = dict(text=' 橋 \tはし', effective_commit_text=' 橋 ', correction_reading='はし',
                 score=10, length_utf16=2, type=15)
        a = comparison.android_signature(c, dict(type_label='[読] はし', text='     橋     '), 'はし')
        i = comparison.ios_signature(dict(text=' 橋 ', raw_text=' 橋 \tはし', corrected_reading='はし',
                 score=10, length_utf16=2, is_reading_prefix=False, display_annotation='[読] はし'))
        self.assertEqual(a, i)
        self.assertEqual(a['display_text'], ' 橋 ')

    def test_prediction_lexical_reading_length_is_not_editor_consumed_range(self):
        c = dict(text='日本語化', commit_text='日本語化', effective_commit_text='日本語化', correction_reading=None,
                 score=10, length_utf16=5, type=9)
        projected = comparison.android_signature(c, dict(type_label=''), 'にほんご')
        self.assertEqual(projected['consumed_utf16'], 4)
        self.assertEqual(c['length_utf16'], 5)
        c.update(type=5, length_utf16=2)
        self.assertEqual(comparison.android_signature(c, dict(type_label='[部]'), 'にほんご')['consumed_utf16'], 2)
        c.update(type=13, length_utf16=2)
        self.assertEqual(comparison.android_signature(c, dict(type_label=''), 'にほんご')['consumed_utf16'], 4)

    def test_exact_input_commit_uses_display_copy_not_retained_base_commit(self):
        c = dict(text='Eye', commit_text='eye', effective_commit_text='Eye', length_utf16=2, type=2)
        self.assertEqual(comparison.android_effective_commit_text(c, 'あい'), 'Eye')
        self.assertEqual(comparison.android_effective_commit_text(c, 'あいう'), 'eye')
        android, ios = self.snapshots()
        android[0]['projected_candidates'][0]['effective_commit_text'] = 'WRONG'
        with self.assertRaises(ValueError):
            comparison.compare(android, ios)

    def test_rejects_unpaired_settings_assets_and_cell_selection(self):
        for mutation in ('n10', 'omission', 'hash', 'selection', 'missing', 'duplicate'):
            android, ios = self.snapshots()
            if mutation == 'n10': android[0]['n'] = 10
            if mutation == 'omission': ios['configuration']['flags'] = 13
            if mutation == 'hash': ios['provenance']['dictionary_file_sha256'] = {}
            if mutation == 'selection': ios['conditions'][0]['expanded']['items'][0]['selected_candidate_id'] = 8
            if mutation == 'missing': android.pop()
            if mutation == 'duplicate': ios['conditions'][1] = ios['conditions'][0]
            with self.subTest(mutation=mutation), self.assertRaises(ValueError):
                comparison.compare(android, ios)

    def test_rejects_wrong_rendered_titles_and_empty_lists(self):
        for mutation in ('android_title', 'ios_title', 'ios_annotation', 'empty'):
            android, ios = self.snapshots()
            if mutation == 'android_title': android[0]['adapter_items'][0]['text'] = 'WRONG'
            if mutation == 'ios_title': ios['conditions'][0]['normal']['items'][0]['labels'][0]['text'] = 'WRONG'
            if mutation == 'ios_annotation': ios['conditions'][0]['expanded']['items'][0]['labels'][1]['text'] = 'WRONG'
            if mutation == 'empty':
                for row in android:
                    row.update(raw_candidates=[], projected_candidates=[], adapter_items=[])
                for row in ios['conditions']:
                    row.update(candidate_count=0, candidates=[], normal=dict(items=[]), expanded=dict(items=[]))
            with self.subTest(mutation=mutation), self.assertRaises(ValueError):
                comparison.compare(android, ios)

    def test_visible_badge_whitespace_is_not_silently_discarded(self):
        android, ios = self.snapshots()
        next(row for row in android if row['path'] == comparison.ROUTE)['adapter_items'][0]['type_label'] = ' [部] '
        result = comparison.compare(android, ios)
        self.assertFalse(result['compared_fields_parity_achieved'])
        self.assertEqual(result['metrics']['full_compared_fields_equal'], 49)
        self.assertEqual(result['conditions'][0]['differences'][0]['fields'], ['annotation'])
        emoji = dict(text='🤍', type=11, commit_text='🤍', length_utf16=4, score=1)
        self.assertEqual(comparison.android_signature(emoji, dict(type_label='  '), 'しろい')['annotation'], '')
        self.assertEqual(comparison.android_signature(emoji, dict(type_label='   '), 'しろい')['annotation'], '   ')

    def test_reports_order_range_and_annotation_differences(self):
        android, ios = self.snapshots()
        ios['conditions'][0]['candidates'][0]['length_utf16'] = 2
        report = comparison.compare(android, ios)
        self.assertFalse(report['compared_fields_parity_achieved'])
        self.assertEqual(report['metrics']['ordered_top10_text_score_equal'], 50)
        self.assertEqual(report['metrics']['full_compared_fields_equal'], 49)
        self.assertEqual(report['conditions'][0]['differences'][0]['fields'], ['consumed_utf16'])


if __name__ == '__main__':
    unittest.main()
