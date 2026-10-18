#!/usr/bin/env python3
import pathlib
import struct
import subprocess
import sys
import tempfile
import zlib


MAGIC = 0x4A4B4E47
WORD = 1


def varint(value):
    out = bytearray()
    while value >= 0x80:
        out.append((value & 0x7f) | 0x80)
        value >>= 7
    out.append(value)
    return bytes(out)


def record(signature, words):
    out = bytearray(struct.pack('<H', signature))
    for word in words:
        raw = word.encode('utf-8')
        out.extend(varint(len(raw)))
        out.extend(raw)
    return bytes(out)


def fnv_hash(value):
    value_hash = 14695981039346656037
    for byte in value:
        value_hash = ((value_hash ^ byte) * 1099511628211) & 0xffffffffffffffff
    value_hash = ((value_hash ^ (value_hash >> 33)) * (-49064778989728563 & 0xffffffffffffffff)) & 0xffffffffffffffff
    value_hash = ((value_hash ^ (value_hash >> 33)) * (-4265267296055464877 & 0xffffffffffffffff)) & 0xffffffffffffffff
    return value_hash ^ (value_hash >> 33)


def make_asset(path, version, words):
    order = len(words)
    signature = order | sum(WORD << (3 + i * 2) for i in range(order))
    packed_record = record(signature, words)
    encoded_records = varint(len(packed_record)) + packed_record
    buckets = 256
    bucket_bits = 8
    hashed = fnv_hash(packed_record)
    bucket = hashed >> (64 - bucket_bits)
    remainder = hashed & 0x0000ffffffffffff
    sig_offset = 80
    contexts_offset = sig_offset + 4
    bucket_offsets_offset = (contexts_offset + 1 + 3) & ~3
    hashes_offset = bucket_offsets_offset + (buckets + 1) * 4
    blocks_offset = hashes_offset + 10
    records_offset = blocks_offset + 8
    file_size = records_offset + len(encoded_records)
    bucket_offsets = [0] * (buckets + 1)
    for i in range(bucket + 1, buckets + 1):
        bucket_offsets[i] = 1
    sections = bytearray()
    sections.extend(struct.pack('<I', signature))
    sections.append(1)
    sections.extend(b'\0' * (bucket_offsets_offset - (contexts_offset + 1)))
    sections.extend(struct.pack('<' + 'I' * len(bucket_offsets), *bucket_offsets))
    sections.extend(remainder.to_bytes(6, 'little'))
    sections.extend(struct.pack('<I', 0))
    sections.extend(struct.pack('<II', 0, len(encoded_records)))
    sections.extend(encoded_records)
    assert len(sections) == file_size - 80

    header = bytearray(80)
    struct.pack_into('<IIIIIIIIIIIIIIIIII', header, 0,
                     MAGIC, version, 1, 1, 1, 1, len(packed_record), 16,
                     sig_offset, contexts_offset, bucket_offsets_offset,
                     hashes_offset, blocks_offset, records_offset, file_size,
                     0, buckets, 1)
    checksum = zlib.crc32(sections) & 0xffffffff
    struct.pack_into('<I', header, 60, checksum)
    path.write_bytes(header + sections)


def main():
    executable = pathlib.Path(sys.argv[1])
    with tempfile.TemporaryDirectory(prefix='sumire-system-ngram-') as directory:
        root = pathlib.Path(directory)
        v3 = root / 'system_ngram.dat'
        v4 = root / 'system_ngram_unigram.dat'
        corrupt = root / 'corrupt.dat'
        make_asset(v3, 3, ['猫', '好き'])
        make_asset(v4, 4, ['食べる'])
        damaged = bytearray(v3.read_bytes())
        damaged[-1] ^= 1
        corrupt.write_bytes(damaged)
        combined = subprocess.run([str(executable), str(v3), str(v4), str(corrupt)],
                                  check=True, text=True, capture_output=True)
        if 'passed' not in combined.stdout:
            raise SystemExit('native test did not report success')


if __name__ == '__main__':
    main()
