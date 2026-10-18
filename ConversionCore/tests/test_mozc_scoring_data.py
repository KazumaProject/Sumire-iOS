#!/usr/bin/env python3
import pathlib
import struct
import subprocess
import sys
import tempfile


def write_assets(root: pathlib.Path, *, invalid_table=False, trailing_attribute=False):
    mozc = root / "mozc"
    mozc.mkdir(parents=True)
    left_table = [2 if invalid_table else 0, 1, 1]
    right_table = [1, 0, 1]
    header = b"MSGM" + struct.pack("<7I", 1, 2, 2, len(left_table),
                                    len(right_table), 1, 8)
    segmenter = (header + struct.pack("<3H", *left_table) +
                 struct.pack("<3H", *right_table) + b"\xb5" +
                 struct.pack("<8H", 10, 11, 20, 21, 30, 31, 40, 41))
    (mozc / "segmenter.dat").write_bytes(segmenter)
    attributes = b"MNAT" + struct.pack("<2I", 1, 3) + struct.pack("<3I", 0, 1, 0)
    if trailing_attribute:
        attributes += b"\0"
    (mozc / "node_attribute_by_lid.dat").write_bytes(attributes)


def run(executable, mode, directory, expected):
    result = subprocess.run([executable, mode, str(directory)],
                            stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                            text=True)
    if (result.returncode == 0) != expected:
        raise AssertionError(
            f"{mode} {directory}: expected success={expected}, "
            f"exit={result.returncode}\nstdout={result.stdout}\nstderr={result.stderr}"
        )


def main():
    if len(sys.argv) != 2:
        raise SystemExit("expected path to sumire-mozc-scoring-test")
    executable = sys.argv[1]
    with tempfile.TemporaryDirectory(prefix="sumire-mozc-scoring-") as temp:
        root = pathlib.Path(temp)
        valid = root / "valid"
        write_assets(valid)
        run(executable, "--fixture", valid, True)

        bad_table = root / "bad-table"
        write_assets(bad_table, invalid_table=True)
        run(executable, "--fixture", bad_table, False)

        trailing = root / "trailing"
        write_assets(trailing, trailing_attribute=True)
        run(executable, "--fixture", trailing, False)


if __name__ == "__main__":
    main()
