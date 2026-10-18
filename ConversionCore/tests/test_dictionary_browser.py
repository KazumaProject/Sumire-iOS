#!/usr/bin/env python3
"""Paged browsing uses the exact same fixture format as conversion tests."""
import importlib.util, pathlib, subprocess, sys, tempfile, unittest
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
    def test_invalid_and_corrupt(self):
        self.browse(name='../system', ok=False)
        self.browse(mode=2, ok=False)
        self.browse(query='a'*1025, ok=False)
        path = self.root/'system.sud'; content=bytearray(path.read_bytes()); content[-1] ^= 1; path.write_bytes(content)
        self.browse(ok=False)
    def test_surface_size_limit(self):
        fixtures.dictionary(self.root/'system.sud', [('あ', 'x'*65537, 1, 0)])
        self.browse(ok=False)

if __name__ == '__main__': unittest.main()
