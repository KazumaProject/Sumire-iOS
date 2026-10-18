import importlib.util
import pathlib
import struct
import sys
import tempfile
import unittest
import zlib
sys.dont_write_bytecode = True
spec = importlib.util.spec_from_file_location('builder', pathlib.Path(__file__).resolve().parents[1] / 'build_dictionary.py')
builder = importlib.util.module_from_spec(spec)
spec.loader.exec_module(builder)

def packed_word(word=b'a'):
    record = b'\x09\x00' + bytes([len(word)]) + word
    value = (-3750763034362895579) & ((1 << 64) - 1)
    for byte in record:
        value = ((value ^ byte) * 1099511628211) & ((1 << 64) - 1)
    for multiplier in [-49064778989728563, -4265267296055464877]:
        value = ((value ^ (value >> 33)) * multiplier) & ((1 << 64) - 1)
    value ^= value >> 33
    bucket = value >> 56
    bucket_offsets = [0 if i <= bucket else 1 for i in range(257)]
    sig, context, buckets = 80, 84, 88
    hashes = buckets + 4 * 257
    blocks, records = hashes + 10, hashes + 18
    body = struct.pack('<I', 9) + b'\x01\x00\x00\x00'
    body += struct.pack('<257I', *bucket_offsets)
    body += (value & ((1 << 48) - 1)).to_bytes(6, 'little') + struct.pack('<I', 0)
    body += struct.pack('<II', 0, len(record) + 1) + bytes([len(record)]) + record
    header = struct.pack('<20I', 0x4a4b4e47, 5, 1, 1, 1, 1, len(record), 16,
                         sig, context, buckets, hashes, blocks, records,
                         80 + len(body), zlib.crc32(body), 256, 1, 0, 0)
    return header + body

class StandaloneImportTests(unittest.TestCase):
    def test_raw_word_is_preserved_and_runtime_sections_are_checksummed(self):
        data = packed_word('しろ'.encode())
        self.assertEqual(builder.standalone_words(data), ['しろ'.encode()])
        with tempfile.TemporaryDirectory() as directory:
            path = pathlib.Path(directory) / 'standalone.sud'
            self.assertEqual(builder.pack_standalone(path, data), 1)
            runtime = path.read_bytes()
            self.assertEqual(struct.unpack_from('<8sIIII', runtime), (b'SUMIRE01', 1, 3, 2, 1))
            for index in range(2):
                offset, size, crc, reserved = struct.unpack_from('<QQII', runtime, 24 + index * 24)
                self.assertEqual(crc, zlib.crc32(runtime[offset:offset + size]))
                self.assertEqual(reserved, 0)
            self.assertTrue(runtime.endswith('しろ'.encode()))

    def test_invalid_dimensions_indices_utf8_and_front_coding_are_rejected(self):
        good = packed_word()
        for offset, value in [(0, 0), (4, 4), (8, 0xffffffff), (20, 0),
                              (24, 0xffffffff), (28, 0), (32, 0), (52, 0xffffffff),
                              (64, 257), (68, 0xffffffff)]:
            with self.subTest(offset=offset):
                damaged = bytearray(good)
                struct.pack_into('<I', damaged, offset, value)
                with self.assertRaises(ValueError): builder.standalone_words(damaged)
        for damaged in [good[:-1], good[:70], good[:-1] + bytes([good[-1] ^ 1]), packed_word(b'\xff')]:
            with self.assertRaises(ValueError): builder.standalone_words(damaged)
        # Recompute CRC to exercise semantic validation, not just corruption.
        for offset, value in [(84, 0), (88, 1), (1116 + 6, 1), (1134, 127)]:
            damaged = bytearray(good)
            damaged[offset] = value
            struct.pack_into('<I', damaged, 60, zlib.crc32(damaged[80:]))
            with self.assertRaises(ValueError): builder.standalone_words(damaged)

if __name__ == '__main__': unittest.main()
