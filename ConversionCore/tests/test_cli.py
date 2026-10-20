#!/usr/bin/env python3
"""Exercise the executable against an exhaustive small lattice and corrupt files."""
import array, importlib.util, itertools, json, pathlib, shutil, struct, subprocess, sys, tempfile, unittest
sys.dont_write_bytecode = True
spec=importlib.util.spec_from_file_location('builder',pathlib.Path(__file__).resolve().parents[2]/'Scripts/build_dictionary.py')
b=importlib.util.module_from_spec(spec);spec.loader.exec_module(b)
CLI=sys.argv.pop(1)
C_API=sys.argv.pop(1) if len(sys.argv)>1 else None
INCREMENTAL=sys.argv.pop(1) if len(sys.argv)>1 else None

def test_helper(filename,name):
    helper_spec=importlib.util.spec_from_file_location(name,pathlib.Path(__file__).resolve().with_name(filename))
    helper=importlib.util.module_from_spec(helper_spec);helper_spec.loader.exec_module(helper)
    return helper

SYSTEM_NGRAM_FIXTURE=test_helper('test_system_ngram.py','system_ngram_fixture')
MOZC_SCORING_FIXTURE=test_helper('test_mozc_scoring_data.py','mozc_scoring_fixture')

def bits(values):
    words=[0]*((len(values)+63)//64)
    for i,v in enumerate(values):
        if v:words[i//64]|=1<<(i%64)
    return array.array('Q',words)

def dictionary(path,entries):
    def units(value):
        data=value.encode('utf-16-le','surrogatepass')
        return ''.join(chr(v) for v in struct.unpack('<'+'H'*(len(data)//2),data))
    entries=[(units(reading),*rest) for reading,*rest in entries]
    root={}
    for reading,*_ in entries:
        node=root
        for c in reading:node=node.setdefault(c,{})
    queue=[('',root)];labels=[32,32];tree=[1,0];leaf=[0,0];terms=[];readings=[]
    for prefix,node in queue:
        for c,child in sorted(node.items()):
            word=prefix+c;queue.append((word,child));labels.append(ord(c));tree.append(1)
            terminal=any(e[0]==word for e in entries);leaf.append(terminal)
            if terminal:readings.append(word);terms.append(len(terms)+1)
        tree.append(0);leaf.append(0)
    postings=[0,0];pos=[];cost=[];refs=[];offsets=[0];blob=bytearray()
    for reading in readings:
        for word,text,p,c in entries:
            if word==reading:
                pos.append(p);cost.append(c)
                if isinstance(text,int):refs.append(text & 0xffffffff)
                else:refs.append(len(offsets)-1);blob.extend(text.encode());offsets.append(len(blob))
        postings.append(len(pos))
    sections=[bits(tree),array.array('H',labels),bits(leaf),array.array('I',terms),array.array('I',postings),array.array('H',pos),array.array('h',cost),array.array('I',refs),array.array('I',offsets)]
    b.pack_file(path,1,0,[b.le(a) for a in sections]+[blob])

MATRIX=[[0,10,20],[30,-50,70],[40,-80,90]]
MOZC_MAX_WORD_COST=32767
ENTRIES=[('あ','A',1,100),('あ','B',2,200),('あ','A',2,150),('い','I',2,50),('あい','Whole',1,500)]

def connection(path,dimension=3,overrides=None):
    if dimension == 3 and overrides is None:
        sections=[array.array('H',[0,1,2]),array.array('H',[0,1,2]),array.array('h',[0,0,0]),array.array('Q',[6,7,7]),array.array('h',[10,20,30,-50,70,40,-80,90]),array.array('I',[0,2,5,8]),array.array('H',[0,0,0])]
    else:
        blocks=(dimension+63)//64
        overrides=overrides or {}
        bit_words=[0]*(dimension*blocks);rank_starts=[0]*(dimension*blocks)
        values=[];starts=[0]
        for row in range(dimension):
            cells=overrides.get(row,{})
            rank=0
            for block in range(blocks):
                offset=row*blocks+block
                rank_starts[offset]=rank
                word=0
                for column,cost in sorted(cells.items()):
                    if column//64==block:
                        word|=1<<(column%64);values.append(cost)
                bit_words[offset]=word
                rank+=word.bit_count()
            starts.append(len(values))
        sections=[array.array('H',[0,1,2]),array.array('H',[0,1,2]),array.array('h',[0]*dimension),
                  array.array('Q',bit_words),array.array('h',values),array.array('I',starts),array.array('H',rank_starts)]
    b.pack_file(path,2,dimension,[b.le(a) for a in sections])

def standalone(path,words):
    offsets=array.array('I',[0]);text=bytearray()
    for word in sorted(w.encode() for w in words):text.extend(word);offsets.append(len(text))
    b.pack_file(path,3,len(words),[b.le(offsets),bytes(text)])

def brute(reading,entries):
    paths=[]
    def visit(i,rid,cost,text):
        if i==len(reading):paths.append((cost+MATRIX[rid][0],text));return
        matches=[entry for entry in entries if reading.startswith(entry[0],i)]
        if not matches:
            matches=[(reading[i],reading[i],0,10000)]
        for word,surface,pos,c in matches:
            if reading.startswith(word,i):visit(i+len(word),pos,cost+MATRIX[rid][pos]+c,text+surface)
    visit(0,0,0,'');unique={}
    for cost,text in sorted(paths):unique.setdefault(text,cost)
    return unique

class Tests(unittest.TestCase):
    def setUp(self):
        self.temp=tempfile.TemporaryDirectory();self.data=pathlib.Path(self.temp.name)
        dictionary(self.data/'system.sud',ENTRIES);dictionary(self.data/'medical.sud',[('あい','Medical',1,-20)]);connection(self.data/'connection.sud')
    def install_auxiliary_dictionary_fixture(self):
        dictionary(self.data/'emoji.sud',[
            ('あいう','EMOJI',0,6000),('あいうえ','EMOJI-PREDICT',0,6000),
            ('あいうえおかき','EMOJI-TOO-FAR',0,6000),
        ])
        dictionary(self.data/'emoticon.sud',[
            ('あいう','EMOTICON',0,4000),('あいうえ','EMOTICON-PREDICT',0,4000),
        ])
        dictionary(self.data/'symbol.sud',[
            ('あいう','SYMBOL',0,3000),('あいうえ','SYMBOL-PREDICT',0,2000),
        ])
        dictionary(self.data/'single_kanji.sud',[('あいう','SINGLE-KANJI',0,1900)])
    def test_pinned_surface_utf16_conversion_keeps_pairs_and_replaces_lone_surrogates(self):
        self.assertEqual(b.decode_surface_utf16([0xd842,0xdc00]).decode('utf-8'),'\U00020800')
        self.assertEqual(b.decode_surface_utf16([0xd842]).decode('utf-8'),'\ufffd')
        self.assertEqual(b.decode_surface_utf16([0xdc00]).decode('utf-8'),'\ufffd')
    def test_classified_exact_candidates_ignore_nbest_count_and_use_utf16_ties(self):
        dictionary(self.data/'system.sud',[('あい','Primary',1,-1000)])
        surfaces=['甲','乙','丙','\U00010000','\ue000']+[f'Word{i}' for i in range(12)]
        dictionary(self.data/'medical.sud',[('あい',s,1,10) for s in surfaces])
        result=json.loads(self.run_cli('--categories','medical','--nbest','1','あい').stdout)
        candidates=result['candidates']
        self.assertEqual(len(candidates),len(surfaces)+1)
        self.assertEqual(candidates[0]['text'],'Primary')
        self.assertEqual([c['text'] for c in candidates[1:]],sorted(surfaces,key=lambda s:s.encode('utf-16-be')))
        self.assertTrue(all(c['categories']==['medical'] for c in candidates[1:]))
        self.assertLessEqual(result['workspace_cache_bytes'],4*1024*1024)
    def test_exact_origins_union_without_replacing_lower_cost_selected_path(self):
        dictionary(self.data/'system.sud',[('あい','Same',1,-1000)])
        dictionary(self.data/'medical.sud',[('あい','Same',1,10)])
        dictionary(self.data/'person.sud',[('あい','Same',2,20)])
        candidates=json.loads(self.run_cli('--categories','medical,person','--nbest','1','あい').stdout)['candidates']
        self.assertEqual(len(candidates),1)
        self.assertEqual(candidates[0]['score'],-960)
        self.assertEqual(candidates[0]['categories'],['medical','person'])
        self.assertEqual(candidates[0]['segments'][0]['dictionary'],'system')
    def test_standalone_later_duplicate_promotes_without_lowering_score(self):
        entries=[('し','し',1,-100),('ろ','ろ',1,-100),('しろ','城',1,-500),('しろ','しろ',1,100)]
        dictionary(self.data/'system.sud',entries)
        standalone(self.data/'standalone.sud',['しろ','ごと'])
        for n in [1,4,10,20,100]:
            enabled=json.loads(self.run_cli('--nbest',str(n),'しろ').stdout)['candidates']
            self.assertEqual(enabled[0]['text'],'しろ')
            self.assertEqual(enabled[0]['score'],-210)
            self.assertTrue(enabled[0]['standalone_unigram_matched'])
            self.assertEqual(len(enabled[0]['segments']),2)
        disabled=json.loads(self.run_cli('--no-standalone-priority','--nbest','1','しろ').stdout)['candidates']
        self.assertEqual(disabled[0]['text'],'城')
        self.assertFalse(disabled[0]['standalone_unigram_matched'])
        compound=json.loads(self.run_cli('--nbest','10','しろあ').stdout)['candidates']
        self.assertFalse(any(c['standalone_unigram_matched'] for c in compound))
        dictionary(self.data/'system.sud',entries[:3])  # Literal output exists only as two nodes.
        multi=json.loads(self.run_cli('--nbest','1','しろ').stdout)['candidates']
        self.assertEqual(multi[0]['text'],'城')
        self.assertFalse(multi[0]['standalone_unigram_matched'])
        dictionary(self.data/'system.sud',[('ごと','ごと',1,-100)])
        corrected=json.loads(self.run_cli('--omission','こと').stdout)['candidates']
        self.assertFalse(any(c['standalone_unigram_matched'] for c in corrected))
        entries = [('し', f'First{i}', 1, i) for i in range(10)]
        entries += [('ろ', f'Second{i}', 1, i + 20) for i in range(10)]
        entries += [('しろ', 'しろ', 1, 1000)]
        dictionary(self.data/'system.sud', entries)
        standalone(self.data/'standalone.sud', ['しろ'])
        large=json.loads(self.run_cli('--nbest','100','しろ').stdout)['candidates']
        self.assertEqual(len(large),100)  # Safety lookahead must not cap N at64.
        self.assertEqual(large[0]['text'],'しろ')
        self.assertTrue(large[0]['standalone_unigram_matched'])
    def test_oversampled_primary_top_k_preserves_utf16_tie_order(self):
        surfaces=['\ue000','𐀀','Ω','𐀁']
        entries=[('あ',surface,1,0) for surface in surfaces]+[('あ','あ',1,30000)]
        dictionary(self.data/'system.sud',entries)
        standalone(self.data/'standalone.sud',['あ'])

        candidates=json.loads(self.run_cli('--nbest','4','あ').stdout)['candidates']

        # The old stable full sort orders by UTF-16 (Kotlin String order):
        # supplementary U+10000/U+10001 precede BMP private-use U+E000.
        self.assertEqual([candidate['text'] for candidate in candidates],['あ','Ω','𐀀','𐀁'])
        self.assertTrue(candidates[0]['standalone_unigram_matched'])
        self.assertTrue(all(not candidate['standalone_unigram_matched'] for candidate in candidates[1:]))
    def test_corrupt_standalone_fails_closed_but_disabled_table_is_not_opened(self):
        standalone(self.data/'standalone.sud',['しろ'])
        path=self.data/'standalone.sud';good=path.read_bytes()
        for damaged in [good[:-1],good[:70],good[:-1]+bytes([good[-1]^1])]:
            path.write_bytes(damaged);self.run_cli('しろ',ok=False)
            self.run_cli('--no-standalone-priority','しろ')
        # Structurally valid CRC is insufficient: reject unordered words/UTF8.
        b.pack_file(path,3,2,[b.le(array.array('I',[0,1,2])),b'ba'])
        self.run_cli('しろ',ok=False)
        b.pack_file(path,3,1,[b.le(array.array('I',[0,1])),b'\xff'])
        self.run_cli('しろ',ok=False)
    def test_japanese_completion_defaults_and_preserved_full_candidates(self):
        entries=[('あいう','Exact',1,100), ('あいうえ','Next',1,-9000),
                 ('あいうえお','Long',1,-9000), ('あいうえおか','Longest',1,-9000),
                 ('あいうえおかき','TooFar',1,-30000), ('あいうか','Cheap',1,-9500),
                 ('あいうき','Fifth',1,10000)]
        dictionary(self.data/'system.sud',entries)
        plain=json.loads(self.run_cli('--nbest','2','あいう').stdout)
        predicted=json.loads(self.run_cli('--nbest','2','--predict-japanese','あいう').stdout)
        candidates=predicted['candidates']
        self.assertEqual([c['text'] for c in candidates[:2]],['Cheap','Next'])
        self.assertEqual({c['text']:c['score'] for c in candidates if c['text'] in ['Cheap','Next','Long','Longest']},
                         {'Cheap':-1500,'Next':-1000,'Long':7000,'Longest':15000})
        self.assertTrue(all(any(c['text']==p['text'] and c['score']==p['score'] and c['segments']==p['segments'] for c in candidates) for p in plain['candidates']))
        self.assertNotIn('TooFar',[c['text'] for c in candidates])
        self.assertNotIn('Fifth',[c['text'] for c in candidates])
        for c in candidates:
            if c['text'] in ['Cheap','Next','Long','Longest']:
                self.assertEqual(c['segments'][0]['length_utf16'],3)
                self.assertEqual(c['segments'][0]['dictionary'],'system')
                self.assertEqual(c['bunsetsu_boundaries_utf16'],[])
        short=json.loads(self.run_cli('--predict-japanese','あい').stdout)
        self.assertNotIn('Next',[c['text'] for c in short['candidates']])

    def test_japanese_prediction_deduplicates_against_final_primary_list(self):
        entries=[('あいう','あいうえ',1,-25000)]
        entries.extend(('あいう',f'候補{i:02}',1,-24000+i*100) for i in range(15))
        entries.extend([('あいう','あいう',1,30000), ('あいうえ','あいうえ',1,10)])
        dictionary(self.data/'system.sud',entries)
        standalone(self.data/'standalone.sud',['あいう'])

        result=json.loads(self.run_cli('--nbest','1','--predict-japanese','あいう').stdout)
        texts=[candidate['text'] for candidate in result['candidates']]

        self.assertEqual(texts[0],'あいう')
        self.assertIn('あいうえ',texts)

    def test_digit_surface_penalty_matches_android_and_applies_once(self):
        dictionary(self.data/'system.sud', [
            ('あ','2',1,100), ('あ','A',1,100),
            ('い','3',1,200), ('い','B',1,200),
        ])
        candidates = json.loads(self.run_cli('--nbest','10','あい').stdout)['candidates']
        by_text = {candidate['text']: candidate['score'] for candidate in candidates}
        self.assertEqual(by_text['AB'], 290)
        self.assertEqual(by_text['23'], 2290)
        self.assertEqual(by_text['2B'], 2290)
        self.assertEqual(by_text['A3'], 2290)

        dictionary(self.data/'system.sud', [('あ','５',1,100)])
        fullwidth = json.loads(self.run_cli('あ').stdout)['candidates']
        self.assertEqual(fullwidth[0]['text'], '５')
        self.assertEqual(fullwidth[0]['score'], 2140)

    def test_omission_digit_penalty_uses_emitted_surface(self):
        dictionary(self.data/'system.sud', [
            ('ご','2',1,100), ('ご','語',1,1100),
        ])
        candidates = json.loads(self.run_cli('--omission','こ').stdout)['candidates']
        by_text = {candidate['text']: candidate['score'] for candidate in candidates}
        self.assertEqual(by_text['語'], 3040)
        self.assertEqual(by_text['2'], 4040)
        self.assertLess(candidates.index(next(c for c in candidates if c['text']=='語')),
                        candidates.index(next(c for c in candidates if c['text']=='2')))

    def test_classified_exact_digit_uses_android_whole_input_score(self):
        dictionary(self.data/'system.sud', [('あ','Base',1,1000)])
        dictionary(self.data/'medical.sud', [('あ','2',1,100)])
        candidates = json.loads(
            self.run_cli('--categories','medical','あ').stdout
        )['candidates']
        exact = next(candidate for candidate in candidates if candidate['text']=='2')
        # Android merges classified exact terms after A* and scores BOS -> word
        # -> EOS directly, without the A* output-digit surcharge.
        self.assertEqual(exact['score'], 140)
        self.assertEqual(exact['categories'], ['medical'])

    def test_forward_beam_prunes_nodes_after_twenty_per_reading_position(self):
        entries = [('あ', f'候補{i:02}', 1, i) for i in range(21)]
        dictionary(self.data/'system.sud', entries)
        candidates = json.loads(self.run_cli('--nbest','100','あ').stdout)['candidates']
        self.assertEqual(len(candidates), 20)
        self.assertNotIn('候補20', [candidate['text'] for candidate in candidates])
        self.assertEqual([candidate['score'] for candidate in candidates],
                         sorted(candidate['score'] for candidate in candidates))

    def test_unknown_fallback_matches_reference_cost_and_dictionary_suppression(self):
        dictionary(self.data/'system.sud',[])
        connection(self.data/'connection.sud',1842,{0:{1841:13},1841:{0:-9}})

        multi=json.loads(self.run_cli('abc').stdout)['candidates']
        self.assertEqual(multi[0]['text'],'abc')
        self.assertEqual(multi[0]['score'],MOZC_MAX_WORD_COST//2+13-9)
        self.assertEqual(multi[0]['segments'][0]['length_utf16'],3)

        single=json.loads(self.run_cli('A').stdout)['candidates']
        self.assertEqual(single[0]['text'],'A')
        self.assertEqual(single[0]['score'],MOZC_MAX_WORD_COST+13-9)

        dictionary(self.data/'system.sud',[('猫','KNOWN',1,100)])
        connection(self.data/'connection.sud')
        known=json.loads(self.run_cli('--nbest','10','猫').stdout)['candidates']
        self.assertEqual([candidate['text'] for candidate in known],['KNOWN'])

        dictionary(self.data/'system.sud',[])
        fallback=json.loads(self.run_cli('猫').stdout)['candidates']
        self.assertEqual(fallback[0]['text'],'猫')
        self.assertEqual(fallback[0]['score'],10000)

        emoji=json.loads(self.run_cli('💩').stdout)['candidates']
        self.assertEqual(emoji[0]['text'],'💩')
        self.assertEqual(emoji[0]['score'],10000)
        self.assertEqual(emoji[0]['segments'][0]['length_utf16'],2)

    def test_japanese_completion_utf16_surface_penalty_and_budget(self):
        dictionary(self.data/'system.sud', [('あいうえおかき',-2,1,100), ('あいうえおかく',-1,1,200)])
        result=json.loads(self.run_cli('--predict-japanese','あいうえおか').stdout)
        completions=[c for c in result['candidates'] if c['text'] in ['あいうえおかき','アイウエオカク']]
        self.assertEqual([c['score'] for c in completions],[6100,6200])
        self.assertTrue(all(c['segments'][0]['length_utf16']==6 for c in completions))
        limited=json.loads(self.run_cli('--predict-japanese','--max-states','1','あいうえおか').stdout)
        self.assertFalse(limited['complete'])
        for reading in ['あいうえおかきくけこさしすせそたち', 'あいうえおかきくけこさしすせそた']:
            dictionary(self.data/'system.sud',[(reading+'な','Completion',1,100)])
            value=json.loads(self.run_cli('--predict-japanese',reading).stdout)
            self.assertEqual('Completion' in [c['text'] for c in value['candidates']], len(reading)==16)

    def test_classified_prediction_per_category_limit_penalty_and_switches(self):
        dictionary(self.data/'system.sud', [('あいう', 'Exact', 1, 100)])
        dictionary(self.data/'medical.sud', [
            ('あいうえ', f'Medical{i}', 1, 100) for i in range(5)
        ] + [('あいうえおかき', 'TooFar', 1, -30000)])
        dictionary(self.data/'place.sud', [('あいうえお', 'Place', 1, 50)])
        args=['--categories','medical,place','--nbest','1','--predict-japanese']
        result=json.loads(self.run_cli(*args,'あいう').stdout)
        predicted=[c for c in result['candidates'] if c['text'].startswith('Medical')]
        self.assertEqual([c['text'] for c in predicted], [f'Medical{i}' for i in range(4)])
        self.assertTrue(all(c['score']==1600 and c['categories']==['medical'] for c in predicted))
        self.assertTrue(all(c['segments'][0]['length_utf16']==3 for c in predicted))
        place=next(c for c in result['candidates'] if c['text']=='Place')
        self.assertEqual(place['score'],3050)
        self.assertEqual(place['categories'],['place'])
        self.assertNotIn('TooFar',[c['text'] for c in result['candidates']])
        for flags,reading in [([], 'あいう'), (['--predict-japanese'], 'あい'),
                              (['--categories','medical'], 'あいう')]:
            value=json.loads(self.run_cli(*flags,reading).stdout)
            self.assertFalse(any(c['text'].startswith('Medical') for c in value['candidates']))
        limited=json.loads(self.run_cli(*args,'--max-states','1','あいう').stdout)
        self.assertFalse(limited['complete'])

    def test_classified_prediction_keeps_all_thirty_enabled_categories(self):
        dictionary(self.data/'system.sud', [('あいう', 'Primary', 1, 100)])
        for category in b.CATEGORIES:
            dictionary(self.data/(category+'.sud'), [('あいうえ', category, 1, 100)])
        result=json.loads(self.run_cli('--categories','all','--nbest','1','--predict-japanese','あいう').stdout)
        labels={label for candidate in result['candidates'] for label in candidate['categories']}
        self.assertEqual(labels,set(b.CATEGORIES))
        self.assertTrue(all(any(c['text']==name and c['categories']==[name] for c in result['candidates'])
                            for name in b.CATEGORIES))
        self.assertTrue(result['complete'])

    def test_classified_prediction_preserves_distinct_readings_scores_and_primary(self):
        dictionary(self.data/'system.sud', [('あいう', 'Shared', 1, 100)])
        dictionary(self.data/'medical.sud', [('あいうえ', 'Shared', 1, 100),
                                             ('あいうお', 'Shared', 1, 100)])
        dictionary(self.data/'place.sud', [('あいうえ', 'Shared', 1, 100),
                                           ('あいうえ', 'Shared', 2, 100),
                                           ('あいうえ', 'Shared', 1, 200)])
        result=json.loads(self.run_cli('--categories','medical,place','--predict-japanese','あいう').stdout)
        shared=[c for c in result['candidates'] if c['text']=='Shared']
        self.assertEqual(len(shared),5) # Primary + four distinct prediction identities.
        self.assertEqual(sorted(c['score'] for c in shared),[140,1600,1600,1600,1700])
        self.assertEqual(sum(c['categories']==['medical','place'] for c in shared),1)
        self.assertEqual(sum(c['categories']==['medical'] for c in shared),1)
        self.assertEqual(sum(c['categories']==['place'] for c in shared),2)

    def test_classified_prediction_utf16_limits_long_penalty_and_posting_budget(self):
        for reading in ['あい😀', 'あいうえおか', 'あいうえおかきくけこさしすせそた', 'あいうえおかきくけこさしすせそたち']:
            dictionary(self.data/'medical.sud', [(reading+'😀', -2, 1, 100)])
            result=json.loads(self.run_cli('--categories','medical','--predict-japanese',reading).stdout)
            matches=[c for c in result['candidates'] if c['text']==reading+'😀']
            units=len(reading.encode('utf-16-le'))//2
            self.assertEqual(bool(matches), units<=16)
            if matches:
                self.assertEqual(matches[0]['score'],3100)
                self.assertEqual(matches[0]['segments'][0]['length_utf16'],units)
        dictionary(self.data/'medical.sud', [('かきくけ', f'Budget{i}', 1, -i) for i in range(100)])
        result=json.loads(self.run_cli('--categories','medical','--predict-japanese','--max-states','10','かきく').stdout)
        self.assertFalse(result['complete'])
        self.assertNotIn('Budget99',[c['text'] for c in result['candidates']])

    def test_japanese_completion_postings_consume_budget(self):
        # One terminal, many tokens: traversing just two nodes cannot allow an
        # unbounded posting scan. The cheapest token occurs after the budget.
        dictionary(self.data/'system.sud', [('かきくけ',f'Word{i}',1,-i) for i in range(100)])
        limited=json.loads(self.run_cli('--nbest','1','--max-states','10','--predict-japanese','かきく').stdout)
        self.assertFalse(limited['complete'])
        self.assertNotIn('Word99',[c['text'] for c in limited['candidates']])
        complete=json.loads(self.run_cli('--nbest','1','--predict-japanese','かきく').stdout)
        self.assertTrue(complete['complete'])
        self.assertIn('Word99',[c['text'] for c in complete['candidates']])
        baseline=json.loads(self.run_cli('--nbest','1','--max-states','10','かきく').stdout)
        self.assertTrue(baseline['complete'])

    def test_bunsetsu_boundaries_follow_selected_path(self):
        # Context IDs 1 and 2 map to independent POS 12/13. Every connection
        # cost is zero: boundaries must come from POS, not matrix values.
        sections=[array.array('H',[0,12,13]),array.array('H',[0,1,2]),
                  array.array('h',[0]*27),array.array('Q',[0]*27),
                  array.array('h'),array.array('I',[0]*28),array.array('H',[0]*27)]
        b.pack_file(self.data/'connection.sud',2,27,[b.le(a) for a in sections])
        result=json.loads(subprocess.check_output([CLI,'--data',str(self.data),'あい'],text=True))
        by_text={c['text']:c for c in result['candidates']}
        self.assertEqual(by_text['AI']['bunsetsu_boundaries_utf16'],[1])
        self.assertEqual(by_text['Whole']['bunsetsu_boundaries_utf16'],[])
        self.assertEqual(by_text['AI']['segments'][1]['start_utf16'],1)
        emoji=json.loads(subprocess.check_output([CLI,'--data',str(self.data),'😀あ'],text=True))
        self.assertEqual(emoji['candidates'][0]['bunsetsu_boundaries_utf16'],[2])

    def test_bunsetsu_split_map_keeps_paths_outside_nbest_and_clears_exact_categories(self):
        # More than the visible N-best paths share the same input. Android
        # keeps their per-surface split map before truncating candidates.
        system=[]
        for i in range(12): system.append(('あ',f'A{i:02}',1,100+i))
        for i in range(12): system.append(('い',f'I{i:02}',2,200+i))
        system.append(('あい','ExactPath',1,50))
        dictionary(self.data/'system.sud',system)
        dictionary(self.data/'medical.sud',[('あい','A00I00',1,500)])
        SYSTEM_NGRAM_FIXTURE.make_asset(self.data/'system_ngram.dat',3,['Never','Occurs'])
        SYSTEM_NGRAM_FIXTURE.make_asset(self.data/'system_ngram_unigram.dat',4,['A11'])
        MOZC_SCORING_FIXTURE.write_assets(self.data)

        plain=json.loads(self.run_cli('--bunsetsu','--nbest','1','あい').stdout)
        patterns=plain['split_pattern_by_candidate']
        self.assertGreater(len(patterns),1)
        self.assertIn('A00I00',patterns)
        self.assertTrue(any(surface not in {c['text'] for c in plain['candidates']} for surface in patterns))

        classified=json.loads(self.run_cli('--bunsetsu','--categories','medical','--nbest','1','あい').stdout)
        self.assertEqual(classified['split_pattern_by_candidate']['A00I00'],[])
        selected=next(c for c in classified['candidates'] if c['text']=='A00I00')
        self.assertEqual(selected['bunsetsu_boundaries_utf16'],[])

    def test_reading_prefix_candidates_keep_consumed_range(self):
        result=json.loads(self.run_cli('--prefix-candidates','--nbest','1','あい').stdout)['candidates']
        self.assertEqual([c['text'] for c in result],['AI','Whole','A','B'])
        self.assertEqual([c['segments'][0]['length_utf16'] for c in result[1:]],[2,1,1])
        self.assertEqual([c['score'] for c in result[1:]],[500,100,200])
        self.assertEqual([c['is_reading_prefix'] for c in result],[False,False,True,True])
        ordinary=json.loads(self.run_cli('--nbest','1','あい').stdout)['candidates']
        self.assertTrue(all(not c['is_reading_prefix'] for c in ordinary))
        overlap=json.loads(self.run_cli('--prefix-candidates','--nbest','100','あい').stdout)['candidates']
        whole=[c for c in overlap if c['text']=='Whole']
        self.assertEqual(len(whole),1)
        self.assertFalse(whole[0]['is_reading_prefix'])

    def test_bunsetsu_includes_raw_reading_prefix_and_english_candidates(self):
        dictionary(self.data/'system.sud',[
            ('あ','A',1,100),('あ','A',2,150),('あい','Whole',1,500),
        ])
        dictionary(self.data/'english_reading.sud',[('あい','eye',0,12500)])
        SYSTEM_NGRAM_FIXTURE.make_asset(self.data/'system_ngram.dat',3,['A','Whole'])
        SYSTEM_NGRAM_FIXTURE.make_asset(self.data/'system_ngram_unigram.dat',4,['Whole'])
        MOZC_SCORING_FIXTURE.write_assets(self.data)

        result=json.loads(self.run_cli('--bunsetsu','--english-reading','--nbest','1','あい').stdout)['candidates']

        self.assertEqual([(c['text'],c['score']) for c in result[1:4]],
                         [('eye',12500),('Eye',14000),('EYE',15500)])
        self.assertEqual([(c['text'],c['score']) for c in result[4:7]],
                         [('あい',6000),('アイ',6000),('ｱｲ',6000)])
        self.assertEqual([(c['text'],c['score']) for c in result[7:]],
                         [('Whole',500),('A',100),('A',150)])
        self.assertEqual([c['segments'][0]['length_utf16'] for c in result[7:]],
                         [2,1,1])
        self.assertTrue(all(not c['is_reading_prefix'] for c in result[:7]))
        self.assertEqual([c['is_reading_prefix'] for c in result[7:]],[False,True,True])

    def test_bunsetsu_auxiliary_exact_candidates_do_not_ignore_disabled_prediction(self):
        self.install_auxiliary_dictionary_fixture()
        SYSTEM_NGRAM_FIXTURE.make_asset(self.data/'system_ngram.dat',3,['Primary','Secondary'])
        SYSTEM_NGRAM_FIXTURE.make_asset(self.data/'system_ngram_unigram.dat',4,['Primary'])
        MOZC_SCORING_FIXTURE.write_assets(self.data)

        row=json.loads(self.run_cli('--bunsetsu','あいう').stdout)
        candidates={(c['segments'][0]['dictionary'],c['text']):c for c in row['candidates'] if c['segments']}
        expected={
            ('emoji','EMOJI'):6000,
            ('emoticon','EMOTICON'):4000,
            ('symbol','SYMBOL'):3000,
            ('single_kanji','SINGLE-KANJI'):1900,
        }
        for key,score in expected.items():
            self.assertIn(key,candidates)
            self.assertEqual(candidates[key]['score'],score)
        self.assertFalse(any(c['text']=='EMOJI-TOO-FAR' for c in row['candidates']))
        self.assertFalse(any(c['text'].endswith('-PREDICT') for c in row['candidates']))
        self.assertTrue(row['complete'])

        (self.data/'symbol.sud').unlink()
        self.run_cli('--bunsetsu','あいう',ok=False)

    def test_reading_correction_metadata_and_prediction_gates(self):
        reading='あいう'
        dictionary(self.data/'system.sud',[(reading,'PRIMARY',1,100)])
        corrections=[('あいうえ',f'訂正{i}\tていせい{i}',1,i) for i in range(6)]
        corrections += [('あいう','EXACT\tよみ',1,-20000),
                        ('あいうえおかき','TOO-FAR\tよみ',1,-20000),
                        ('あいうえ','NO-TAB',1,0), ('あいうえ','\tよみ',1,0),
                        ('あいうえ','EMPTY\t',1,0), ('あいうえ','MULTI\tよみ\t余分',1,0),
                        ('あいうえ','NUL\x00\tよみ',1,0)]
        dictionary(self.data/'reading_correction.sud',corrections)
        plain=json.loads(self.run_cli(reading).stdout)
        predicted=json.loads(self.run_cli('--predict-japanese',reading).stdout)
        self.assertFalse(any(c['raw_text'] for c in plain['candidates']))
        self.assertFalse(predicted['complete'], 'skipped malformed metadata must report incompleteness')
        correction=[c for c in predicted['candidates'] if c['raw_text']]
        self.assertEqual([c['text'] for c in correction],[f'訂正{i}' for i in range(6)])
        self.assertEqual([c['score'] for c in correction],list(range(8000,8006)))
        self.assertEqual([c['corrected_reading'] for c in correction],[f'ていせい{i}' for i in range(6)])
        self.assertTrue(all(c['raw_text']==c['text']+'\t'+c['corrected_reading'] for c in correction))
        self.assertTrue(all(c['segments']==[{'text':c['text'],'dictionary':'reading_correction','start_utf16':0,'length_utf16':3}] for c in correction))
        self.assertTrue(all('\t' not in c['text'] for c in predicted['candidates']))
        (self.data/'reading_correction.sud').unlink()
        absent=json.loads(self.run_cli('--predict-japanese',reading).stdout)
        self.assertFalse(any(c['raw_text'] for c in absent['candidates']))

    def test_reading_correction_utf16_limits_order_and_budget(self):
        for reading, allowed in [('あい',False),('あ😀',True),('あ'*16,True),('あ'*17,False)]:
            dictionary(self.data/'system.sud',[(reading,'PRIMARY',1,100)])
            dictionary(self.data/'reading_correction.sud',[(reading+'え','😀訂正\tせい',1,0)])
            size=(self.data/'reading_correction.sud').stat().st_size
            result=json.loads(self.run_cli('--predict-japanese',reading).stdout)
            correction=[c for c in result['candidates'] if c['raw_text']]
            self.assertEqual(bool(correction),allowed)
            if correction:
                self.assertEqual(correction[0]['segments'][0]['length_utf16'],len(reading.encode('utf-16-le'))//2)
                self.assertEqual(correction[0]['score'],8000)
            (self.data/'reading_correction.sud').unlink()
            self.assertEqual(result['mapped_bytes']-json.loads(self.run_cli('--predict-japanese',reading).stdout)['mapped_bytes'],size)
        reading='あいう'
        dictionary(self.data/'system.sud',[(reading,'Z-PRIMARY',1,10000)])
        dictionary(self.data/'reading_correction.sud',[(reading+'え','A-CORRECTION\tえ',1,0)])
        result=json.loads(self.run_cli('--predict-japanese',reading).stdout)
        self.assertEqual(result['candidates'][0]['text'],'A-CORRECTION')
        limited=json.loads(self.run_cli('--predict-japanese','--max-states','1',reading).stdout)
        self.assertFalse(limited['complete'])
        self.assertFalse(any(c['raw_text'] for c in limited['candidates']))
        # Optional files are still fully validated when present.
        damaged=bytearray((self.data/'reading_correction.sud').read_bytes()); damaged[-1]^=1
        (self.data/'reading_correction.sud').write_bytes(damaged)
        self.run_cli('--predict-japanese',reading,ok=False)
        dictionary(self.data/'reading_correction.sud',[(reading+'え','POS\tよみ',999,0)])
        self.run_cli('--predict-japanese',reading,ok=False)

    def test_reading_correction_raw_metadata_orders_equal_display_surfaces(self):
        reading='あいう'
        dictionary(self.data/'system.sud',[(reading,'PRIMARY',1,100)])
        dictionary(self.data/'reading_correction.sud',[
            (reading+'え','同じ\tい',1,0),(reading+'え','同じ\tあ',1,0)])
        correction=[c for c in json.loads(self.run_cli('--predict-japanese',reading).stdout)['candidates'] if c['raw_text']]
        self.assertEqual([c['corrected_reading'] for c in correction],['あ','い'])
        self.assertEqual([c['text'] for c in correction],['同じ','同じ'])

    def test_japanese_prediction_includes_kana_without_dictionary_completion(self):
        for reading, katakana, halfwidth in [('あ', 'ア', 'ｱ'),
                                              ('がぱゔ', 'ガパヴ', 'ｶﾞﾊﾟゔ'),
                                              ('ゐゑゎ・か\u3099', 'ヰヱヮ・カ\u3099', 'ゐゑゎ・ｶ\u3099'),
                                              ('あ😀', 'ア😀', 'ｱ😀')]:
            dictionary(self.data/'system.sud', [(reading, 'Primary', 1, 100)])
            plain=json.loads(self.run_cli('--nbest','1',reading).stdout)['candidates']
            predicted=json.loads(self.run_cli('--predict-japanese','--nbest','1',reading).stdout)['candidates']
            self.assertEqual([c['text'] for c in plain], ['Primary'])
            self.assertEqual([c['text'] for c in predicted], ['Primary', reading, katakana, halfwidth])
            self.assertEqual([c['score'] for c in predicted[1:]], [6000,6000,6000])
            self.assertTrue(all(not c['segments'] for c in predicted[1:]))
        # A dictionary candidate with the same surface must retain its score
        # and order; kana choices are auxiliary, not a cheaper primary path.
        dictionary(self.data/'system.sud', [('あ', 'あ', 1, 100)])
        predicted=json.loads(self.run_cli('--predict-japanese','あ').stdout)['candidates']
        self.assertEqual([c['score'] for c in predicted if c['text']=='あ'], [140,6000])

    def test_japanese_prediction_enables_auxiliary_reading_completion(self):
        self.install_auxiliary_dictionary_fixture()
        baseline=json.loads(self.run_cli('あいう').stdout)
        predicted=json.loads(self.run_cli('--predict-japanese','あいう').stdout)
        baseline_texts={c['text'] for c in baseline['candidates']}
        predicted_candidates={(c['segments'][0]['dictionary'],c['text']):c for c in predicted['candidates'] if c['segments']}
        for key,score in {
            ('emoji','EMOJI-PREDICT'):7000,
            ('emoticon','EMOTICON-PREDICT'):5000,
            ('symbol','SYMBOL-PREDICT'):3000,
        }.items():
            self.assertNotIn(key[1],baseline_texts)
            self.assertIn(key,predicted_candidates)
            self.assertEqual(predicted_candidates[key]['score'],score)
        self.assertFalse(any(c['text']=='EMOJI-TOO-FAR' for c in predicted['candidates']))

    def test_auxiliary_completion_ranges_consume_only_typed_utf16(self):
        dictionary(self.data/'english_reading.sud',[('えいご','English',0,10000)])
        dictionary(self.data/'single_kanji.sud',[('べつ','別',0,10000)])
        for name,text,cost in [('emoji','⚪️',6000),('emoticon','(^_^)',4000),('symbol','㎥',2000)]:
            dictionary(self.data/(name+'.sud'),[('あいうえ',text,0,cost),('😀あい',text,0,cost)])
        for reading in ('あいう','😀あ'):
            result=json.loads(self.run_cli('--predict-japanese','--prefix-candidates','--english-reading','--nbest','20',reading).stdout)
            for name,text,score in [('emoji','⚪️',7000),('emoticon','(^_^)',5000),('symbol','㎥',3000)]:
                candidate=next(c for c in result['candidates'] if c['text']==text)
                self.assertEqual(candidate['score'],score)
                self.assertEqual(candidate['segments'],[dict(text=text,dictionary=name,start_utf16=0,length_utf16=3)])
                self.assertFalse(candidate['is_reading_prefix'])
            disabled=json.loads(self.run_cli('--nbest','20',reading).stdout)
            self.assertFalse({'⚪️','(^_^)','㎥'} & {c['text'] for c in disabled['candidates']})
        if C_API is not None:
            result=subprocess.run([C_API,str(self.data),'--aux-completion'],capture_output=True)
            self.assertEqual(result.returncode,0,result.stderr.decode())

    def test_prediction_kana_symbol_and_prefix_order(self):
        self.install_auxiliary_dictionary_fixture()
        dictionary(self.data/'system.sud', [('あ','Prefix',1,100), ('あいう','Primary',1,100)])
        texts=[c['text'] for c in json.loads(self.run_cli('--predict-japanese','--prefix-candidates','--nbest','20','あいう').stdout)['candidates']]
        # df1f383 getCandidatesOriginal:1341 (tabs default OFF), not the
        # alternate getCandidates:2858 symbol-after-prefix ordering.
        self.assertLess(texts.index('EMOJI'),texts.index('SYMBOL'))
        self.assertLess(texts.index('SYMBOL'),texts.index('あいう'))
        self.assertLess(texts.index('ｱｲｳ'),texts.index('Prefix'))
        self.assertLess(texts.index('Prefix'),texts.index('SINGLE-KANJI'))
        no_prediction=[c['text'] for c in json.loads(self.run_cli('--prefix-candidates','--nbest','20','あいう').stdout)['candidates']]
        self.assertLess(no_prediction.index('EMOJI'),no_prediction.index('SYMBOL'))
        self.assertLess(no_prediction.index('SYMBOL'),no_prediction.index('Prefix'))
        dictionary(self.data/'emoji.sud',[('あ','EMOJI',0,6000)])
        dictionary(self.data/'symbol.sud',[('あ','SYMBOL',0,3000)])
        texts=[c['text'] for c in json.loads(self.run_cli('--predict-japanese','--nbest','1','あ').stdout)['candidates']]
        self.assertLess(texts.index('ｱ'),texts.index('EMOJI'))
        self.assertLess(texts.index('EMOJI'),texts.index('SYMBOL'))

    def test_bunsetsu_marks_legacy_generation_without_auxiliary_dictionaries_incomplete(self):
        SYSTEM_NGRAM_FIXTURE.make_asset(self.data/'system_ngram.dat',3,['A','B'])
        SYSTEM_NGRAM_FIXTURE.make_asset(self.data/'system_ngram_unigram.dat',4,['A'])
        MOZC_SCORING_FIXTURE.write_assets(self.data)
        row=json.loads(self.run_cli('--bunsetsu','あ').stdout)
        self.assertFalse(row['complete'])

    def test_kana_english_entries_append_after_primary_candidates(self):
        dictionary(self.data/'english_reading.sud',[('あい','eye',0,12500)])
        primary=json.loads(self.run_cli('--nbest','1','あい').stdout)['candidates']
        result=json.loads(self.run_cli('--english-reading','--nbest','1','あい').stdout)['candidates']
        self.assertEqual(result[:1],primary)
        self.assertEqual([(c['text'],c['score']) for c in result[1:]],[('eye',12500),('Eye',14000),('EYE',15500)])
        self.assertEqual(json.loads(self.run_cli('--english-reading','--nbest','1','あ').stdout)['candidates'],json.loads(self.run_cli('--nbest','1','あ').stdout)['candidates'])
    def test_english_unicode_prefix_and_original_utf16_range(self):
        dictionary(self.data/'english.sud',[('café',-2,0,100),('i\u0307x',-2,0,200)])
        for reading,expected in [('CAFÉ','café'),('İ','i\u0307x')]:
            result=json.loads(self.run_cli('--predict-english',reading).stdout)
            self.assertEqual([c['text'] for c in result['candidates']],[expected])
            self.assertEqual(result['candidates'][0]['segments'][0]['length_utf16'],len(reading.encode('utf-16-le'))//2)
    def test_english_unicode_uppercase_expansion_keeps_input_range(self):
        dictionary(self.data/'english.sud',[('pokémon','Pokémon',0,100),('straße',-2,0,200)])
        for reading,expected in [('POKÉ','POKÉMON'),('STRA','STRASSE')]:
            result=json.loads(self.run_cli('--english',reading).stdout)
            self.assertEqual(result['candidates'][0]['text'],expected)
            self.assertTrue(all(c['segments'][0]['length_utf16']==len(reading) for c in result['candidates']))
        result=json.loads(self.run_cli('--english','ß').stdout)
        self.assertIn('SS',[c['text'] for c in result['candidates']])
        self.assertTrue(all(c['segments'][0]['length_utf16']==1 for c in result['candidates']))
    def test_unicode_input_case_and_simple_initial_uppercase(self):
        dictionary(self.data/'english.sud',[('école',-2,0,100),('straße',-2,0,100),('e\u0301cole',-2,0,100)])
        for reading,expected in [('É','ÉCOLE'),('é','école'),('Éc','École'),('E\u0301','E\u0301COLE')]:
            result=json.loads(self.run_cli('--english',reading).stdout)
            self.assertEqual(result['candidates'][0]['text'],expected,reading)
        result=json.loads(self.run_cli('--english','é').stdout)
        self.assertIn('École',[c['text'] for c in result['candidates']])
        result=json.loads(self.run_cli('--english','ß').stdout)
        self.assertEqual([c['text'] for c in result['candidates']],['ß','ß','SS'])
        result=json.loads(self.run_cli('--english','ᾀ').stdout)
        self.assertEqual([c['text'] for c in result['candidates']],['ᾀ','ᾈ','ἈΙ'])
    def test_english_case_candidates_and_fallback_scores(self):
        dictionary(self.data/'english.sud',[('hello',-2,0,123),('iphone','iPhone',0,90)])
        cases={
          'hel':[('hello',123),('hel',500),('Hello',623),('HELLO',2123),('Hel',9000),('HEL',9001)],
          'Hel':[('Hello',123),('Hel',500),('hello',623),('HELLO',2123),('HEL',9001)],
          'HEL':[('HELLO',123),('HEL',500),('hello',623),('Hello',623)],
          'iph':[('iPhone',90),('iph',500),('IPhone',590),('IPHONE',2090),('Iph',9000),('IPH',9001)],
          'zzz':[('zzz',10000),('Zzz',10001),('ZZZ',10002)],
          'ZZZ':[('ZZZ',8500),('ZZZ',10000),('ZZZ',10002)]}
        for reading,expected in cases.items():
            result=json.loads(self.run_cli('--english',reading).stdout)
            self.assertEqual([(c['text'],c['score']) for c in result['candidates']],expected,reading)
        self.assertEqual(json.loads(self.run_cli('--english','').stdout)['candidates'],[])
        self.run_cli('--english','--lookup','hello',ok=False)
    def test_english_prediction_trie_order_limit_and_full_surface(self):
        entries=[('apple'+chr(97+i),-2,0,100-i) for i in range(15)]
        dictionary(self.data/'english.sud',entries)
        short=json.loads(self.run_cli('--predict-english','AP','--nbest','100').stdout)
        self.assertEqual([c['text'] for c in short['candidates']],[e[0] for e in entries[:6]][::-1])
        long=json.loads(self.run_cli('--predict-english','App','--nbest','100').stdout)
        self.assertEqual([c['text'] for c in long['candidates']],[e[0] for e in entries[:12]][::-1])
        self.assertTrue(all(c['segments'][0]['length_utf16']==3 for c in long['candidates']))
        self.assertEqual(json.loads(self.run_cli('--predict-english','').stdout)['candidates'],[])
        self.assertEqual(json.loads(self.run_cli('--predict-english','zzz').stdout)['candidates'],[])
        self.run_cli('--predict-english','--lookup-english','app',ok=False)
    def test_english_words_keep_case_surfaces_and_identity_sentinel(self):
        self.run_cli('--lookup-english','hello',ok=False)
        dictionary(self.data/'english.sud',[('hello',-2,0,123),('iphone','iPhone',0,90)])
        for reading,text,cost in [('hello','hello',123),('iphone','iPhone',90)]:
            result=json.loads(self.run_cli('--lookup-english',reading).stdout)
            self.assertEqual(result['mode'],'english-lookup')
            self.assertEqual([(c['text'],c['score']) for c in result['candidates']],[(text,cost)])
        self.assertEqual(json.loads(self.run_cli('--lookup-english','hel').stdout)['candidates'],[])
        self.assertEqual(json.loads(self.run_cli('--lookup','hello').stdout)['candidates'],[])
        self.run_cli('--lookup-english','--lookup-english-reading','hello',ok=False)
    def test_english_reading_is_optional_and_uses_word_cost(self):
        self.run_cli('--lookup-english-reading','はろー',ok=False)
        dictionary(self.data/'english_reading.sud',[('はろー','hello',1,80),('はろー','Hallo',2,100)])
        result=json.loads(self.run_cli('--lookup-english-reading','はろー').stdout)
        self.assertEqual(result['mode'],'english-reading-lookup')
        self.assertEqual([(c['text'],c['score']) for c in result['candidates']],[('hello',80),('Hallo',100)])
        self.assertEqual(result['candidates'][0]['segments'][0]['dictionary'],'english_reading')
        self.assertEqual(json.loads(self.run_cli('--lookup','はろー').stdout)['candidates'],[])
        self.assertEqual(json.loads(self.run_cli('--lookup-english-reading','はろ').stdout)['candidates'],[])
        self.run_cli('--lookup-english-reading','--omission','はろー',ok=False)
        data=bytearray((self.data/'english_reading.sud').read_bytes());data[-1]^=1
        (self.data/'english_reading.sud').write_bytes(data)
        self.run_cli('--lookup-english-reading','はろー',ok=False)
    def test_fixture_entries_convert_prefix_and_exact_template(self):
        options=['--user-entry','あ','User','1','-1000',
                 '--user-entry','い','Second','2','-900',
                 '--template-entry','あい','Template','2','-2000','--nbest','100']
        exact=json.loads(self.run_cli(*options,'あい').stdout)['candidates']
        by_text={candidate['text']:candidate for candidate in exact}
        self.assertEqual(by_text['Template']['score'],-2000)
        self.assertEqual(by_text['Template']['segments'][0]['dictionary'],'template')
        self.assertIn('UserSecond',by_text)
        self.assertIn('Whole',by_text)
        self.assertEqual(by_text['UserSecond']['segments'][0]['dictionary'],'user')
        longer=json.loads(self.run_cli(*options,'あいい').stdout)['candidates']
        self.assertFalse(any(segment['dictionary']=='template' for candidate in longer for segment in candidate['segments']))
        shorter=json.loads(self.run_cli(*options,'あ').stdout)['candidates']
        self.assertIn('User',[candidate['text'] for candidate in shorter])
        self.assertNotIn('Template',[candidate['text'] for candidate in shorter])

    def test_fixture_entries_english_prediction_and_case_sensitive_prefix(self):
        dictionary(self.data/'english.sud',[('hello',-2,0,100)])
        options=['--user-entry','help','Personal','1','-100',
                 '--template-entry','hel','Exact','2','-200','--predict-english']
        exact=json.loads(self.run_cli(*options,'hel').stdout)['candidates']
        self.assertEqual([candidate['text'] for candidate in exact],['Exact','Personal','hello'])
        self.assertEqual([candidate['segments'][0]['dictionary'] for candidate in exact[:2]],['template','user'])
        longer=json.loads(self.run_cli(*options,'help').stdout)['candidates']
        self.assertIn('Personal',[candidate['text'] for candidate in longer])
        self.assertNotIn('Exact',[candidate['text'] for candidate in longer])
        upper=json.loads(self.run_cli(*options,'HEL').stdout)['candidates']
        self.assertNotIn('Personal',[candidate['text'] for candidate in upper])

    def test_fixture_entries_validate_integer_ranges_and_missing_arguments(self):
        for option in ['--user-entry','--template-entry']:
            for context,score in [('x','0'),('1x','0'),('-1','0'),('65536','0'),
                                  ('3','0'),('1','x'),('1','1.0'),('1','2147483648'),
                                  ('1','-2147483649'),('99999999999999999999999','0')]:
                with self.subTest(option=option,context=context,score=score):
                    self.run_cli(option,'あ','Fixture',context,score,'あ',ok=False)
            for arguments in [[],['あ'],['あ','Fixture'],['あ','Fixture','1']]:
                with self.subTest(option=option,arguments=arguments):
                    self.run_cli(option,*arguments,ok=False)
        for score in ['-2147483648','2147483647']:
            result=json.loads(self.run_cli('--template-entry','あ','Boundary','0',score,'あ').stdout)
            self.assertIn('Boundary',[candidate['text'] for candidate in result['candidates']])
        self.run_cli('--user-entry','','Fixture','1','0','あ',ok=False)
        self.run_cli('--user-entry','あ','','1','0','あ',ok=False)

    def test_fixture_entries_reject_lookup_and_listing_combinations(self):
        for option in ['--user-entry','--template-entry']:
            for mode in ['--lookup','--lookup-english','--lookup-english-reading','--list-categories']:
                with self.subTest(option=option,mode=mode):
                    result=self.run_cli(option,'あ','Fixture','1','0',mode,'あ',ok=False)
                    self.assertIn(b'fixture entries apply',result.stderr)

    def tearDown(self):self.temp.cleanup()
    def run_cli(self,*args,input=None,ok=True):
        r=subprocess.run([CLI,'--data',str(self.data),*args],input=input,capture_output=True)
        if ok:self.assertEqual(r.returncode,0,r.stderr.decode())
        else:self.assertNotEqual(r.returncode,0)
        return r
    def test_omission_traversal_and_surface_sentinels(self):
        dictionary(self.data/'system.sud', [('がっこう','学校',1,0),('がっこう',-2,1,10),('がっこう',-1,1,20),('かつこう','Exact',1,5000)])
        off=json.loads(self.run_cli('--nbest','100','かつこう').stdout)
        self.assertNotIn('学校',[c['text'] for c in off['candidates']])
        on=json.loads(self.run_cli('--omission','--nbest','100','かつこう').stdout)
        result={c['text']:c['score'] for c in on['candidates']}
        self.assertTrue(on['complete'])
        self.assertEqual(result['学校'],1940)
        self.assertEqual(result['がっこう'],1950)
        self.assertEqual(result['ガッコウ'],1960)
        self.assertEqual(result['Exact'],5040)
        reverse=json.loads(self.run_cli('--omission','--nbest','100','がっこう').stdout)
        self.assertNotIn('Exact',[c['text'] for c in reverse['candidates']])
        readings = ['かつこう', 'か', '', 'がっこう', 'かつこう', '👩\u200d💻']
        rows = [json.loads(line) for line in self.run_cli('--omission', '--nbest', '100', '--stdin',
            input=('\n'.join(readings)+'\n').encode()).stdout.splitlines()]
        for reading, row in zip(readings, rows):
            fresh = json.loads(self.run_cli('--omission', '--nbest', '100', '--', reading).stdout)
            self.assertEqual(row['candidates'], fresh['candidates'])
            self.assertLessEqual(row['workspace_cache_bytes'], 4 * 1024 * 1024)
        self.run_cli('--lookup','--omission','かつこう',ok=False)

    def test_incremental_search_rows_match_fresh_conversion(self):
        if INCREMENTAL is None:self.skipTest("Incremental executable not supplied")
        dictionary(self.data/'system.sud',ENTRIES+[('しろ','しろ',1,100),('しろ','城',1,-500)])
        standalone(self.data/'standalone.sud',['しろ'])
        result=subprocess.run([INCREMENTAL,str(self.data)],capture_output=True)
        self.assertEqual(result.returncode,0,result.stderr.decode())
        self.assertIn(b'reused_search_rows=',result.stdout)

    def test_c_api_ownership_and_generations(self):
        if C_API is None:self.skipTest("C ABI executable not supplied")
        dictionary(self.data/'english.sud',[('hello',-2,0,123)])
        dictionary(self.data/'system.sud',ENTRIES+[('かきくけ','PredictionABI',1,-10000)])
        dictionary(self.data/'person.sud',[('あい','Medical',1,100)])
        dictionary(self.data/'medical.sud',[('あい','Medical',1,-20), ('かきくけ','CategoryABI',1,100)])
        dictionary(self.data/'reading_correction.sud',[('かきくけ','訂正\tていせい',1,200)])
        standalone(self.data/'standalone.sud',['しろ'])
        SYSTEM_NGRAM_FIXTURE.make_asset(self.data/'system_ngram.dat',3,['A','I'])
        SYSTEM_NGRAM_FIXTURE.make_asset(self.data/'system_ngram_unigram.dat',4,['A'])
        MOZC_SCORING_FIXTURE.write_assets(self.data)
        result=subprocess.run([C_API,str(self.data)],capture_output=True)
        self.assertEqual(result.returncode,0,result.stderr.decode())
    def test_exhaustive_nbest(self):
        for reading in ['あ','あい','あいあい']:
            r=json.loads(self.run_cli('--nbest','100',reading).stdout);expected=brute(reading,ENTRIES)
            actual={c['text']:c['score'] for c in r['candidates']}
            self.assertEqual(actual,expected)
            scores=[c['score'] for c in r['candidates']];self.assertEqual(scores,sorted(scores));self.assertTrue(r['complete'])
    def test_category_isolation_and_lookup(self):
        off=json.loads(self.run_cli('--lookup','あい').stdout)
        on=json.loads(self.run_cli('--categories','medical','--lookup','あい').stdout)
        self.assertNotIn('Medical',[c['text'] for c in off['candidates']]);self.assertEqual(on['candidates'][0]['text'],'Medical')
        self.assertEqual(on['candidates'][0]['segments'][0]['dictionary'],'medical')
        converted=json.loads(self.run_cli('--categories','medical','あい').stdout)
        self.assertEqual(converted['candidates'][0]['text'],'Medical')
        self.run_cli('--categories','missing','あ',ok=False)
        # Inactive broken categories must never be opened.
        (self.data/'medical.sud').write_bytes(b'broken');self.run_cli('あ');self.run_cli('--categories','medical','あ',ok=False)
    def test_unicode_stdin_and_limits(self):
        connection(self.data/'connection.sud',1842)
        r=self.run_cli('--stdin','--nbest','1',input='👩\u200d💻e\u0301\n\nあ\n'.encode())
        lines=[json.loads(x) for x in r.stdout.splitlines()]
        self.assertEqual(len(lines),3);self.assertEqual(lines[0]['candidates'][0]['text'],'👩\u200d💻e\u0301')
        segments=lines[0]['candidates'][0]['segments'];self.assertEqual(sum(s['length_utf16'] for s in segments),7)
        self.assertEqual(lines[1]['candidates'][0]['text'],'')
        self.run_cli('--stdin',input=b'\xff\n',ok=False)
        self.run_cli('a'*8193,ok=False)
        long_input='🦊'*2000
        long_result=json.loads(self.run_cli('--nbest','1',long_input).stdout)
        self.assertEqual(long_result['candidates'][0]['text'],long_input)
        r=json.loads(self.run_cli('--max-states','1','あい').stdout);self.assertFalse(r['complete'])
        self.run_cli('--nbest','-1','あ',ok=False)
    def test_workspace_reuse_matches_fresh_conversions(self):
        readings = ['あいあい', 'あ', '', '👩\u200d💻', 'あい', 'あいあい']
        streamed = [json.loads(line) for line in self.run_cli('--stdin', input=('\n'.join(readings)+'\n').encode()).stdout.splitlines()]
        for reading, actual in zip(readings, streamed):
            fresh = json.loads(self.run_cli('--', reading).stdout)
            self.assertEqual(actual['candidates'], fresh['candidates'])
            self.assertEqual(actual['complete'], fresh['complete'])
            self.assertLessEqual(actual['workspace_cache_bytes'], 4 * 1024 * 1024)
        self.assertGreater(streamed[0]['workspace_cache_bytes'], 0)

    def test_oversized_workspace_is_released_before_next_input(self):
        reading = 'あい' * 4096
        rows = [json.loads(line) for line in self.run_cli('--stdin', '--nbest', '100',
            input=(reading+'\nあ\n').encode()).stdout.splitlines()]
        self.assertEqual(rows[0]['workspace_cache_bytes'], 0)
        # The existing explicit search-state limit is still reported, not hidden.
        self.assertFalse(rows[0]['complete'])
        self.assertEqual(rows[0]['reading'], reading)
        fresh = json.loads(self.run_cli('--nbest', '100', 'あ').stdout)
        self.assertEqual(rows[1]['candidates'], fresh['candidates'])
        self.assertGreater(rows[1]['workspace_cache_bytes'], 0)
        self.assertLessEqual(rows[1]['workspace_cache_bytes'], 4 * 1024 * 1024)

    def test_corrupt_files(self):
        p=self.data/'system.sud';original=p.read_bytes()
        for damaged in [original[:20],original[:-1],original[:8]+struct.pack('<I',99)+original[12:],original[:-1]+bytes([original[-1]^1])]:
            p.write_bytes(damaged);self.run_cli('あ',ok=False)
        p.write_bytes(original)
        # Well-checksummed but invalid references must also fail.
        content=bytearray(original);offset=struct.unpack_from('<Q',content,24+7*24)[0];struct.pack_into('<I',content,offset,0xfffffffd)
        off,length=struct.unpack_from('<QQ',content,24+7*24);struct.pack_into('<I',content,24+7*24+16,b.zlib.crc32(content[off:off+length]))
        p.write_bytes(content);self.run_cli('あ',ok=False)
    def test_category_catalog(self):
        r=json.loads(self.run_cli('--list-categories').stdout);self.assertEqual(r['categories'],b.CATEGORIES);self.assertEqual(len(r['categories']),30)
    def test_restricted_reader(self):
        for bad in [b'',b'\xac\xed\x00\x05\x70',b'\xac\xed\x00\x05\x71\xff\xff\xff\xff']:
            with self.assertRaises(ValueError):b.JavaArrays(bad).all(1)

if __name__=='__main__':unittest.main()
