#!/usr/bin/env python3
"""Paged browsing uses the exact same fixture format as conversion tests."""
import importlib.util, pathlib, subprocess, sys, tempfile, unittest, struct, zlib
BROWSER = sys.argv.pop(1)
saved = sys.argv[:]
sys.argv = [sys.argv[0], 'unused-cli']
spec = importlib.util.spec_from_file_location('fixtures', pathlib.Path(__file__).with_name('test_cli.py'))
fixtures = importlib.util.module_from_spec(spec)
spec.loader.exec_module(fixtures)
sys.argv = saved

class BrowserTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(); self.addCleanup(self.temp.cleanup)
        self.root = pathlib.Path(self.temp.name)
        self.entries = [('あ', '亜', 1, -100), ('あ', '阿', 2, 20), ('あい', '愛', 3, 30),
                        ('あいう', -2, 4, 40), ('い', -1, 5, 50), ('😀', '笑顔', 6, 60)]
        # Fixture generator works in scalar BMP units, so supplementary UTF-16
        # is supplied as its two code units (the runtime returns valid UTF-8).
        self.entries[-1] = ('\ud83d\ude00', '笑顔', 6, 60)
        fixtures.dictionary(self.root / 'system.sud', self.entries)
    def browse(self, query='', mode=0, name='system', ok=True):
        run = subprocess.run([BROWSER, str(self.root), name, query, str(mode)], text=True, capture_output=True)
        self.assertEqual(run.returncode == 0, ok, run.stderr)
        return [line.split('\t') for line in run.stdout.splitlines()]
    def test_all_pages_and_fields(self):
        rows = self.browse(); self.assertEqual(len(rows), 6)
        self.assertEqual([(x[3], x[4]) for x in rows], [('あ','亜'),('あ','阿'),('あい','愛'),('あいう','あいう'),('い','イ'),('😀','笑顔')])
        self.assertEqual(rows[0][1:3], ['1', '-100'])
        self.assertEqual(len({x[0] for x in rows}), 6)
    def test_prefix_and_surface(self):
        self.assertEqual([x[4] for x in self.browse('あい')], ['愛', 'あいう'])
        self.assertEqual([x[4] for x in self.browse('愛', 1)], ['愛'])
        self.assertEqual(self.browse('なし'), [])
        self.assertEqual(self.browse('なし', 1), [])
    def test_reference_normalized_reading_and_surface_contains(self):
        fixtures.dictionary(self.root/'system.sud', [
            ('がっこう', '学校', 1, 0), ('あい', '愛', 1, 0),
            ('えいご', 'ＦＯＯ', 1, 0), ('ぎりしゃ', 'ΟΔΟΣ', 1, 0),
            ('ごうじ', '㍿', 1, 0), ('すまほ', 'iPhone', 1, 0)])
        for query, expected in [('ｶﾞｯｺｳ', '学校'), ('アイ', '愛'), ('ｆｏｏ', 'ＦＯＯ'),
                                ('οδος', 'ΟΔΟΣ'), ('株式会社', '㍿'), ('ＩＰＨＯＮＥ', 'iPhone')]:
            self.assertEqual([r[4] for r in self.browse(query, 2)], [expected])
        # It searches within a reading rather than only its first characters.
        self.assertEqual([r[4] for r in self.browse('っこ', 2)], ['学校'])
        self.assertEqual(self.browse('ｶﾞｯｺｳ', 0), [])
        self.assertEqual(self.browse('ｆｏｏ', 1), [])

    def test_invalid_and_corrupt(self):
        self.browse(name='../system', ok=False)
        self.browse(mode=3, ok=False)
        self.browse(query='a'*1025, ok=False)
        path = self.root/'system.sud'; content=bytearray(path.read_bytes()); content[-1] ^= 1; path.write_bytes(content)
        self.browse(ok=False)
    def test_empty_dictionary(self):
        fixtures.dictionary(self.root/'system.sud', [])
        self.assertEqual(self.browse(), [])
    def test_step_budget(self):
        fixtures.dictionary(self.root/'system.sud', [(str(i).zfill(5), 'word', 1, 0) for i in range(4200)])
        run = subprocess.run([BROWSER, str(self.root), 'system', 'no-match', '1', 'bounded'], capture_output=True, text=True)
        self.assertEqual(run.returncode, 0, run.stderr)
    def test_valid_crc_invalid_posting_reference(self):
        path=self.root/'system.sud'; content=bytearray(path.read_bytes())
        offset,length=struct.unpack_from('<QQ',content,24+3*24)
        struct.pack_into('<I',content,offset,0xffffffff)
        struct.pack_into('<I',content,24+3*24+16,zlib.crc32(content[offset:offset+length]))
        path.write_bytes(content); self.browse(ok=False)
    def test_invalid_section_range(self):
        path=self.root/'system.sud'; content=bytearray(path.read_bytes())
        struct.pack_into('<Q',content,24,len(content)+8)
        path.write_bytes(content); self.browse(ok=False)
    def test_surface_size_limit(self):
        fixtures.dictionary(self.root/'system.sud', [('あ', 'x'*65537, 1, 0)])
        self.browse(ok=False)

if __name__ == '__main__': unittest.main()
