"""Validate a pinned dictionary generation before evaluating conversion quality."""
import hashlib
import json
from pathlib import Path


def sha256_file(path):
    digest = hashlib.sha256()
    with Path(path).open('rb') as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b''):
            digest.update(chunk)
    return digest.hexdigest()


def validate_dictionary_assets(directory, manifest_sha256, revision, expected_count=44):
    directory = Path(directory).resolve(strict=True)
    manifest_path = directory / 'manifest.json'
    if manifest_path.resolve(strict=True).parent != directory:
        raise ValueError('dictionary manifest escapes its directory')
    if sha256_file(manifest_path) != manifest_sha256:
        raise ValueError('dictionary manifest SHA-256 mismatch')
    manifest = json.loads(manifest_path.read_text())
    if type(manifest.get('format')) is not int or manifest['format'] != 1 or manifest.get('source_revision') != revision:
        raise ValueError('dictionary format or source revision mismatch')
    outputs = manifest.get('output_sha256')
    if not isinstance(outputs, dict) or len(outputs) != expected_count:
        raise ValueError('dictionary output count mismatch')
    verified = {}
    for name, expected in outputs.items():
        if not isinstance(name, str) or Path(name).is_absolute() or '\\' in name or any(part in ('', '.', '..') for part in name.split('/')):
            raise ValueError('invalid dictionary output path')
        if not isinstance(expected, str) or len(expected) != 64 or any(c not in '0123456789abcdef' for c in expected):
            raise ValueError('invalid dictionary SHA-256')
        path = directory / name
        if not path.resolve(strict=True).is_relative_to(directory) or not path.is_file():
            raise ValueError('dictionary output escapes its directory or is missing')
        actual = sha256_file(path)
        if actual != expected:
            raise ValueError('dictionary output SHA-256 mismatch: ' + name)
        verified[name] = {'sha256': actual, 'bytes': path.stat().st_size}
    return {'manifest_sha256': manifest_sha256, 'source_revision': revision,
            'output_count': len(verified), 'outputs': verified}


def atomic_write_bytes(path, data):
    """Replace the destination entry; never follow an existing leaf symlink."""
    import os
    import tempfile
    path = Path(path)
    descriptor, temporary = tempfile.mkstemp(prefix='.' + path.name + '-', dir=path.parent)
    try:
        with os.fdopen(descriptor, 'wb') as stream:
            stream.write(data)
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(temporary, path)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)


def atomic_write_json(path, value):
    atomic_write_bytes(path, (json.dumps(value, ensure_ascii=False, indent=2) + '\n').encode('utf-8'))
