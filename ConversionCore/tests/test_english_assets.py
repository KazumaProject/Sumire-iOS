#!/usr/bin/env python3
"""Compare every English entry against pinned source arrays through the real CLI.

Usage: test_english_assets.py CLI GENERATED_DIR ANDROID_REFERENCE
This verifies exact dictionary data, not Android candidate-generation parity.
"""
import array
import hashlib
import importlib.util
import json
import pathlib
import struct
import subprocess
import sys
import zipfile

sys.dont_write_bytecode = True
spec = importlib.util.spec_from_file_location('builder', pathlib.Path(__file__).resolve().parents[2] / 'Scripts/build_dictionary.py')
b = importlib.util.module_from_spec(spec)
spec.loader.exec_module(b)
cli, generated, reference = sys.argv[1:]
generated, reference = pathlib.Path(generated), pathlib.Path(reference)
manifest = json.loads((generated / 'manifest.json').read_text())
revision = subprocess.check_output(['git', '-C', str(reference), 'rev-parse', 'HEAD'], text=True).strip()
assert revision == b.REVISION == manifest['source_revision']


def read(name):
    data = (reference / 'app/src/main/assets' / name).read_bytes()
    assert hashlib.sha256(data).hexdigest() == manifest['asset_sha256'][name], name
    if name.endswith('.zip'):
        with zipfile.ZipFile(reference / 'app/src/main/assets' / name) as archive:
            return archive.read(pathlib.PurePosixPath(name).name[:-4])
    return data


def decode_trie(lbs, labels):
    # Traverse the stored breadth-first edge encoding independently of the
    # converter's rank/select parent reconstruction.
    words = {1: ''}
    node_words = {}
    parent = 0
    child = 0
    for position in range(len(lbs) * 64):
        if (lbs[position // 64] >> (position % 64)) & 1:
            child += 1
            if child == 1:
                continue
            words[child] = words[parent] + chr(labels[child])
            node_words[position] = words[child]
        else:
            parent += 1
        if child == len(labels) - 1:
            break
    return node_words


reports = []
for name, option in [('english', '--lookup-english'), ('english_reading', '--lookup-english-reading')]:
    english = name == 'english'
    lbs, leaf, labels, terms = b.JavaArrays(read(name + ('/reading.dat.zip' if english else '/yomi.dat.zip'))).all(4)
    surface_lbs, _, surface_labels = b.JavaArrays(read(name + ('/word.dat' if english else '/tango.dat.zip'))).all(3)
    tokens = b.JavaArrays(read(name + '/token.dat.zip')).all(3 if english else 4)
    costs, nodes, posting = tokens if english else tokens[1:]
    readings = decode_trie(lbs, labels)
    surfaces = decode_trie(surface_lbs, surface_labels)
    ranges = []
    offset = 0
    for position in range(len(posting) * 64):
        if (posting[position // 64] >> (position % 64)) & 1:
            offset += 1
        else:
            ranges.append(offset)
    assert offset == len(costs)
    # Compare every stored token, including any tokens not referenced by a
    # terminal reading in the original source trie.
    binary = (generated / (name + '.sud')).read_bytes()
    sections = []
    for index in range(10):
        start, size = struct.unpack_from('<QQ', binary, 24 + 24 * index)
        sections.append(binary[start:start + size])
    stored_costs = struct.unpack('<' + 'h' * len(costs), sections[6])
    refs = struct.unpack('<' + 'I' * len(nodes), sections[7])
    offsets = struct.unpack('<' + 'I' * (len(sections[8]) // 4), sections[8])
    assert list(stored_costs) == list(costs)
    for token, node in enumerate(nodes):
        sentinel = -2 if english and node == -1 else node
        if sentinel < 0:
            assert refs[token] == sentinel & 0xffffffff
        else:
            ref = refs[token]
            assert sections[9][offsets[ref]:offsets[ref + 1]].decode('utf-8') == surfaces[node]
    expected = {}
    reachable = set()
    term_index = 0
    for position, reading in readings.items():
        if not ((leaf[position // 64] >> (position % 64)) & 1):
            continue
        term = terms[term_index]
        term_index += 1
        rows = []
        for token in range(ranges[term - 1], ranges[term]):
            reachable.add(token)
            node = nodes[token]
            if node == -1 and english or node == -2:
                text = reading
            elif node == -1:
                text = ''.join(chr(ord(c) + 0x60) if '\u3041' <= c <= '\u3096' else c for c in reading)
            else:
                text = surfaces[node]
            rows.append((text, costs[token]))
        assert len(rows) <= 100, 'CLI limit would prevent exhaustive verification'
        expected[reading] = sorted(rows, key=lambda entry: entry[1])
    assert term_index == len(terms)
    assert sum(map(len, expected.values())) == len(reachable)
    assert hashlib.sha256((generated / (name + '.sud')).read_bytes()).hexdigest() == manifest['output_sha256'][name + '.sud']
    process = subprocess.run([cli, '--data', str(generated), option, '--nbest', '100', '--stdin'],
                             input='\n'.join(expected) + '\n', text=True, capture_output=True, check=True)
    results = process.stdout.splitlines()
    assert len(results) == len(expected)
    for reading, line in zip(expected, results):
        actual = json.loads(line)
        assert actual['reading'] == reading and actual['complete']
        assert [(c['text'], c['score']) for c in actual['candidates']] == expected[reading], reading
        for candidate in actual['candidates']:
            assert candidate['segments'][0]['dictionary'] == name
            assert candidate['segments'][0]['length_utf16'] == len(reading.encode('utf-16-le')) // 2
    reports.append({'dictionary': name, 'verified_readings': len(expected), 'verified_stored_tokens': len(costs), 'verified_reachable_tokens': len(reachable), 'source_unreferenced_tokens': len(costs) - len(reachable)})
print(json.dumps({'source_revision': revision, 'scope': 'all exact entries, surface, word cost, input range', 'results': reports}, indent=2))
