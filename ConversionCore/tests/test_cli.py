#!/usr/bin/env python3
"""Exercise the executable against an exhaustive small lattice and corrupt files."""
import array, importlib.util, itertools, json, pathlib, shutil, struct, subprocess, sys, tempfile, unittest
sys.dont_write_bytecode = True
spec=importlib.util.spec_from_file_location('builder',pathlib.Path(__file__).resolve().parents[2]/'Scripts/build_dictionary.py')
b=importlib.util.module_from_spec(spec);spec.loader.exec_module(b)
CLI=sys.argv.pop(1)
C_API=sys.argv.pop(1) if len(sys.argv)>1 else None

def bits(values):
    words=[0]*((len(values)+63)//64)
    for i,v in enumerate(values):
        if v:words[i//64]|=1<<(i%64)
    return array.array('Q',words)

def dictionary(path,entries):
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
ENTRIES=[('あ','A',1,100),('あ','B',2,200),('あ','A',2,150),('い','I',2,50),('あい','Whole',1,500)]

def connection(path):
    sections=[array.array('H',[0,1,2]),array.array('H',[0,1,2]),array.array('h',[0,0,0]),array.array('Q',[6,7,7]),array.array('h',[10,20,30,-50,70,40,-80,90]),array.array('I',[0,2,5,8]),array.array('H',[0,0,0])]
    b.pack_file(path,2,3,[b.le(a) for a in sections])

def brute(reading,entries):
    paths=[]
    def visit(i,rid,cost,text):
        if i==len(reading):paths.append((cost+MATRIX[rid][0],text));return
        for word,surface,pos,c in entries+[(reading[i],reading[i],0,16000)]:
            if reading.startswith(word,i):visit(i+len(word),pos,cost+MATRIX[rid][pos]+c,text+surface)
    visit(0,0,0,'');unique={}
    for cost,text in sorted(paths):unique.setdefault(text,cost)
    return unique

class Tests(unittest.TestCase):
    def setUp(self):
        self.temp=tempfile.TemporaryDirectory();self.data=pathlib.Path(self.temp.name)
        dictionary(self.data/'system.sud',ENTRIES);dictionary(self.data/'medical.sud',[('あい','Medical',1,-20)]);connection(self.data/'connection.sud')
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

    def test_reading_prefix_candidates_keep_consumed_range(self):
        result=json.loads(self.run_cli('--prefix-candidates','--nbest','1','あい').stdout)['candidates']
        self.assertEqual([c['text'] for c in result],['AI','Whole','A','B'])
        self.assertEqual([c['segments'][0]['length_utf16'] for c in result[1:]],[2,1,1])
        self.assertEqual([c['score'] for c in result[1:]],[500,100,200])

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

    def test_c_api_ownership_and_generations(self):
        if C_API is None:self.skipTest("C ABI executable not supplied")
        dictionary(self.data/'english.sud',[('hello',-2,0,123)])
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
