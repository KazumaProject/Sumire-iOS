#!/usr/bin/env python3
"""Fixed host CLI benchmark; reports core timing, not iPhone input latency."""
import argparse
import hashlib
import json
import math
import pathlib
import platform
import subprocess

INPUTS = ['あ', 'しろ', 'しろい', 'しろくろ', 'しろあり', 'にほんご',
          'とうきょうえき', 'かっこんとう', 'きょうはいいてんきです',
          'わたしはにほんごをにゅうりょくします', 'すもももももももものうち',
          'あいうえおかきくけこさしすせそたちつてとなにぬねのはひふへほまみ']
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--cli', type=pathlib.Path, required=True)
parser.add_argument('--data', type=pathlib.Path, required=True)
parser.add_argument('--categories', default='none')
parser.add_argument('--iterations', type=int, default=50)
args = parser.parse_args()
if args.iterations < 1:
    parser.error('iterations must be positive')
readings = INPUTS * (args.iterations + 1)
process = subprocess.run([str(args.cli.resolve()), '--data', str(args.data.resolve()),
                          '--categories', args.categories, '--nbest', '10', '--stdin'],
                         input='\n'.join(readings)+'\n', text=True, capture_output=True, check=True)
rows = [json.loads(line) for line in process.stdout.splitlines()]
assert len(rows) == len(readings) and all('error' not in row for row in rows)
warm = rows[len(INPUTS):]
times = sorted(row['conversion_ms'] for row in warm)
percentile = lambda p: times[max(0, math.ceil(len(times)*p)-1)]
print(json.dumps({
    'platform': platform.platform(), 'processor': platform.machine(),
    'dictionary_manifest_sha256': hashlib.sha256((args.data/'manifest.json').read_bytes()).hexdigest(),
    'binary_sha256': hashlib.sha256(args.cli.read_bytes()).hexdigest(),
    'categories': args.categories, 'inputs': INPUTS, 'nbest': 10,
    'utf16_lengths': [len(s.encode('utf-16-le'))//2 for s in INPUTS],
    'warmup_requests': len(INPUTS), 'measured_requests': len(warm),
    'warm_p50_ms': percentile(.5), 'warm_p95_ms': percentile(.95), 'warm_p99_ms': percentile(.99),
    'first_open_ms': rows[0]['load_ms'], 'mapped_file_bytes': rows[0]['mapped_bytes'],
    'incomplete_requests': sum(not row['complete'] for row in rows),
    'note': 'Host Release CLI core timing only. First open is not an OS-cold-cache measurement. '
            'Mapped bytes are file sizes, not phys_footprint. No iOS performance claim.'
}, ensure_ascii=False, indent=2))
