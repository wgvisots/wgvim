#!/usr/bin/env python3
"""wgvim: summarize gcov line/function coverage of a build made with -D ENABLE_GCOV=ON.

Usage: scripts/coverage-summary.py <build-dir> <source-root> [output.md]

Runs `gcov --json-format --stdout` on every .gcda file in the build directory (needs only
gcc's gcov, no gcovr/lcov), merges the results per source file and writes a Markdown report:
totals, per-directory table, and the least-covered large files.
"""

import gzip
import json
import os
import subprocess
import sys
from collections import defaultdict


def gcov_json(gcda):
    out = subprocess.run(
        ['gcov', '--json-format', '--stdout', '--object-directory', os.path.dirname(gcda), gcda],
        capture_output=True,
        check=False,
    ).stdout
    if out[:2] == b'\x1f\x8b':
        out = gzip.decompress(out)
    docs = []
    for chunk in out.decode('utf-8', 'replace').splitlines():
        chunk = chunk.strip()
        if chunk.startswith('{'):
            try:
                docs.append(json.loads(chunk))
            except json.JSONDecodeError:
                pass
    return docs


def main():
    build, root = os.path.abspath(sys.argv[1]), os.path.abspath(sys.argv[2])
    outpath = sys.argv[3] if len(sys.argv) > 3 else None
    lines = defaultdict(dict)  # file -> {line: max count}
    funcs = defaultdict(dict)  # file -> {name: max count}
    gcdas = []
    for d, _, files in os.walk(build):
        gcdas += [os.path.join(d, f) for f in files if f.endswith('.gcda')]
    for gcda in gcdas:
        for doc in gcov_json(gcda):
            cwd = doc.get('current_working_directory', build)
            for f in doc.get('files', []):
                path = os.path.normpath(os.path.join(cwd, f['file']))
                if not path.startswith(os.path.join(root, 'src') + os.sep):
                    continue
                rel = os.path.relpath(path, root)
                for ln in f.get('lines', []):
                    n = ln['line_number']
                    lines[rel][n] = max(lines[rel].get(n, 0), ln['count'])
                for fn in f.get('functions', []):
                    name = fn.get('demangled_name') or fn['name']
                    funcs[rel][name] = max(funcs[rel].get(name, 0), fn['execution_count'])

    def pct(a, b):
        return 100.0 * a / b if b else 0.0

    per_dir = defaultdict(lambda: [0, 0, 0, 0])
    rows = []
    tl = th = tf = tfh = 0
    for rel in sorted(lines):
        l_tot = len(lines[rel])
        l_hit = sum(1 for c in lines[rel].values() if c > 0)
        f_tot = len(funcs[rel])
        f_hit = sum(1 for c in funcs[rel].values() if c > 0)
        rows.append((rel, l_hit, l_tot, f_hit, f_tot))
        d = os.path.dirname(rel)
        for i, v in enumerate((l_hit, l_tot, f_hit, f_tot)):
            per_dir[d][i] += v
        tl, th, tf, tfh = tl + l_tot, th + l_hit, tf + f_tot, tfh + f_hit

    out = []
    out.append('# wgvim functional-test coverage\n')
    out.append(f'Source: {len(gcdas)} .gcda files, {len(rows)} source files under `src/`.\n')
    out.append('| | Covered | Total | % |\n|---|---:|---:|---:|')
    out.append(f'| Lines | {th} | {tl} | {pct(th, tl):.1f} |')
    out.append(f'| Functions | {tfh} | {tf} | {pct(tfh, tf):.1f} |\n')
    out.append('## By directory\n')
    out.append('| Directory | Lines % | Lines (hit/total) | Functions % |\n|---|---:|---:|---:|')
    for d in sorted(per_dir):
        lh, lt, fh, ft = per_dir[d]
        out.append(f'| `{d}` | {pct(lh, lt):.1f} | {lh}/{lt} | {pct(fh, ft):.1f} |')
    out.append('\n## Least-covered files with more than 200 instrumented lines\n')
    out.append('| File | Lines % | Lines (hit/total) | Functions % |\n|---|---:|---:|---:|')
    big = [r for r in rows if r[2] > 200]
    for rel, lh, lt, fh, ft in sorted(big, key=lambda r: pct(r[1], r[2]))[:25]:
        out.append(f'| `{rel}` | {pct(lh, lt):.1f} | {lh}/{lt} | {pct(fh, ft):.1f} |')
    text = '\n'.join(out) + '\n'
    if outpath:
        with open(outpath, 'w') as f:
            f.write(text)
    print(text)


if __name__ == '__main__':
    main()
