#!/usr/bin/env python3
"""Check a harper-ls binary against Harper's Cargo.lock (|wgvim-harper|).

A Rust program carries the source paths of the crates it was built from, with their
versions (in panic messages and debug info). Every crate version found in the binary must
be one that contrib/harper/Cargo.lock (the lock file of the pinned Harper release) lists:
otherwise the binary was not built from that release's dependencies, and the cargo audit of
that lock file (CI) would not be about this binary.

Not every crate leaves a path behind, so passing is consistency, not proof; the SHA-256 pin
(scripts/install-harper.sh) is what ties wgvim to one exact binary.

Usage: scripts/check-harper.py BINARY|FILE.vsix [Cargo.lock]
Works offline, with the Python standard library only.
"""

import os
import re
import sys
import zipfile

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))


def lock_packages(path):
    """(name, version) of every package in a Cargo.lock (its TOML is simple enough to scan)."""
    text = open(path, encoding='utf-8').read()
    pkgs = set()
    for block in text.split('[[package]]')[1:]:
        name = re.search(r'^name = "([^"]+)"', block, re.M)
        ver = re.search(r'^version = "([^"]+)"', block, re.M)
        if name and ver:
            pkgs.add((name.group(1), ver.group(1)))
    return pkgs


def embedded_crates(data):
    """Crate versions whose source paths the binary contains (crates.io and git sources)."""
    found = set()
    pat = rb'(?:index\.crates\.io|github\.com)-[0-9a-f]{16}/([A-Za-z0-9_.-]+?)-(\d+\.\d+\.\d+[A-Za-z0-9.+-]*)/'
    for m in re.finditer(pat, data):
        found.add((m.group(1).decode(), m.group(2).decode()))
    return found


def main():
    if len(sys.argv) < 2:
        print(__doc__.strip().splitlines()[-2], file=sys.stderr)
        return 2
    target = sys.argv[1]
    lock = sys.argv[2] if len(sys.argv) > 2 else os.path.join(ROOT, 'contrib/harper/Cargo.lock')
    if target.endswith('.vsix'):
        with zipfile.ZipFile(target) as z:
            data = z.read('extension/bin/harper-ls')
    else:
        data = open(target, 'rb').read()
    pkgs = lock_packages(lock)
    crates = embedded_crates(data)
    if not crates:
        print(f'check-harper: no crate paths found in {target}: not a Rust build of harper-ls?')
        return 1
    missing = sorted(c for c in crates if c not in pkgs)
    print(f'check-harper: {len(crates)} crate versions in the binary, {len(pkgs)} in {lock}')
    if missing:
        print('check-harper: not in the lock file (built from other dependencies?):')
        for name, ver in missing:
            print(f'  {name} {ver}')
        return 1
    print('check-harper: all of them are in the lock file')
    return 0


if __name__ == '__main__':
    sys.exit(main())
