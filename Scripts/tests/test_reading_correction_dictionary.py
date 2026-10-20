import array
import hashlib
import importlib.util
import json
import os
import pathlib
import struct
import sys
import tempfile
import unittest
from unittest import mock
import zlib

sys.dont_write_bytecode = True
spec = importlib.util.spec_from_file_location('builder', pathlib.Path(__file__).resolve().parents[1] / 'build_dictionary.py')
builder = importlib.util.module_from_spec(spec)
spec.loader.exec_module(builder)


class ReadingCorrectionDictionaryTests(unittest.TestCase):
    def test_changed_pinned_asset_is_rejected_before_decoding(self):
        name = 'reading_correction/token_reading_correction.dat'
        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory)
            (root / name).parent.mkdir()
            (root / name).write_bytes(b'not the pinned dictionary')
            with self.assertRaisesRegex(ValueError, 'pinned auxiliary asset hash mismatch'):
                builder.read_pinned_asset(root, name)
            # Exercise the positive branch with an explicitly pinned test value.
            digest = hashlib.sha256((root / name).read_bytes()).hexdigest()
            with mock.patch.dict(builder.AUXILIARY_ASSET_SHA256, {name: digest}):
                self.assertEqual(builder.read_pinned_asset(root, name), b'not the pinned dictionary')

    @unittest.skipUnless(os.environ.get('SUMIRE_REFERENCE_SOURCE'), 'requires pinned Android source via SUMIRE_REFERENCE_SOURCE')
    def test_real_dictionary_roundtrip_preserves_every_token_and_metadata(self):
        source = pathlib.Path(os.environ['SUMIRE_REFERENCE_SOURCE'])
        assets = source / 'app/src/main/assets'
        with tempfile.TemporaryDirectory(prefix='sumire-reading-correction-') as directory:
            output = pathlib.Path(directory) / 'generation'
            builder.build(source, output)
            manifest = json.loads((output / 'manifest.json').read_text())
            self.assertEqual(manifest['source_revision'], builder.REVISION)
            self.assertEqual(manifest['dictionaries']['reading_correction']['entries'], 751)
            self.assertEqual(manifest['dictionaries']['reading_correction']['readings'], 733)
            for role in ('yomi', 'tango', 'token'):
                name = f'reading_correction/{role}_reading_correction.dat'
                expected = builder.AUXILIARY_ASSET_SHA256[name]
                self.assertEqual(hashlib.sha256((assets / name).read_bytes()).hexdigest(), expected)
                self.assertEqual(manifest['asset_sha256'][name], expected)
            raw = (output / 'reading_correction.sud').read_bytes()
            self.assertEqual(manifest['output_sha256']['reading_correction.sud'], hashlib.sha256(raw).hexdigest())
            self.assertEqual(struct.unpack_from('<8sIIII', raw), (b'SUMIRE01', 1, 1, 10, 0))
            sections = []
            for index in range(10):
                offset, size, crc, reserved = struct.unpack_from('<QQII', raw, 24 + index * 24)
                self.assertEqual(offset % 8, 0)
                self.assertLessEqual(offset + size, len(raw))
                section = raw[offset:offset + size]
                self.assertEqual(zlib.crc32(section), crc)
                self.assertEqual(reserved, 0)
                sections.append(section)
            lbs, leaf, labels, terms = builder.JavaArrays((assets / 'reading_correction/yomi_reading_correction.dat').read_bytes()).all(4)
            pos, costs, nodes, post = builder.JavaArrays((assets / 'reading_correction/token_reading_correction.dat').read_bytes()).all(4)
            for index, values in ((0, lbs), (1, labels), (2, leaf), (3, terms), (5, pos), (6, costs)):
                self.assertEqual(sections[index], builder.le(values))
            postings = struct.unpack('<' + 'I' * (len(sections[4]) // 4), sections[4])
            self.assertEqual(postings[-1], len(nodes))
            self.assertTrue(all(a <= b for a, b in zip(postings, postings[1:])))
            refs = struct.unpack('<751I', sections[7])
            offsets = struct.unpack('<' + 'I' * (len(sections[8]) // 4), sections[8])
            tlbs, _, tlabels = builder.JavaArrays((assets / 'reading_correction/tango_reading_correction.dat').read_bytes()).all(3)
            bits = builder.Bits(tlbs)
            parents = {index: bit + 1 - index for index, bit in enumerate(bits.ones(), 1)}
            tabbed = 0
            for node, ref in zip(nodes, refs):
                if node in (-1, -2):
                    self.assertEqual(ref, node & 0xffffffff)
                    continue
                label = bits.rank(node)
                units = []
                while label > 1:
                    units.append(tlabels[label])
                    label = parents[label]
                expected = builder.le(array.array('H', reversed(units))).decode('utf-16-le').encode('utf-8')
                surface = sections[9][offsets[ref]:offsets[ref + 1]]
                self.assertEqual(surface, expected)
                tabbed += b'\t' in surface
            self.assertGreater(tabbed, 0, 'correction-reading metadata must not be stripped during generation')
            # Preserve the upstream provenance limits and complete notices verbatim.
            notice = 'licenses/auxiliary.html'
            self.assertEqual((output / notice).read_bytes(), (assets / notice).read_bytes())
            self.assertIn('unconfirmed', (output / notice).read_text())


if __name__ == '__main__':
    unittest.main()
