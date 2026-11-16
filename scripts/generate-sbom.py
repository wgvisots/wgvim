#!/usr/bin/env python3
"""Write the SPDX 2.3 SBOM (JSON) of a wgvim install tree.

    scripts/generate-sbom.py --tree DIR --name NAME --out FILE [--deps-src DIR]

It describes:
  - wgvim (version and commit from bin/wgvim --version), a descendant of the Neovim snapshot
    (CMakeLists.txt: WGVIM_UPSTREAM_COMMIT) and of Vim;
  - every bundled library the build used (one per directory in --deps-src, default
    .deps/build/src) and the code vendored under src/ and runtime/, with version, licence,
    upstream source, purl and the SHA256 of the pinned archive (cmake.deps/upstream.txt,
    cmake.deps/deps.txt);
  - the programs and parsers in the tree (bin/*, lib*/wgvim/parser/*.so) with their checksums;
  - the system libraries they load (ldd), with their RPM package when rpm is available.

The document is reproducible: its date is $SOURCE_DATE_EPOCH (default: now), its namespace is
derived from the name and the tree's checksums. Python 3.9 (RHEL 9) or later; standard library
only.
"""

import argparse
import datetime
import hashlib
import json
import os
import re
import shutil
import subprocess
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
REPO_URL = 'https://github.com/wgvisots/wgvim'


def die(msg):
    sys.stderr.write('generate-sbom: error: %s\n' % msg)
    sys.exit(2)


def read(path):
    with open(path, encoding='utf-8') as f:
        return f.read()


def file_sums(path):
    sha1, sha256 = hashlib.sha1(), hashlib.sha256()
    with open(path, 'rb') as f:
        for block in iter(lambda: f.read(1 << 16), b''):
            sha1.update(block)
            sha256.update(block)
    return sha1.hexdigest(), sha256.hexdigest()


def spdx_id(text):
    """An SPDX identifier from arbitrary text (letters, digits, '.' and '-' only)."""
    return re.sub(r'[^A-Za-z0-9.-]+', '-', text).strip('-')


def deps_txt():
    """{KEY: (archive file name, sha256)} from cmake.deps/deps.txt."""
    out, sha = {}, {}
    for line in read(os.path.join(ROOT, 'cmake.deps', 'deps.txt')).splitlines():
        m = re.match(r'^([A-Z0-9_]+)_(URL|SHA256)\s+(\S+)', line)
        if m:
            (out if m.group(2) == 'URL' else sha)[m.group(1)] = m.group(3)
    return {k: (os.path.basename(v), sha.get(k)) for k, v in out.items()}


def upstream_txt():
    rows = {}
    for n, line in enumerate(read(os.path.join(ROOT, 'cmake.deps', 'upstream.txt')).splitlines(), 1):
        line = line.strip()
        if not line or line.startswith('#'):
            continue
        f = [x.strip() for x in line.split('|')]
        if len(f) != 6:
            die('cmake.deps/upstream.txt:%d: expected 6 fields, got %d' % (n, len(f)))
        rows[f[0]] = {'name': f[1], 'version': f[2], 'license': f[3], 'url': f[4],
                      'purl': None if f[5] == '-' else f[5]}
    return rows


def cmake_var(name):
    m = re.search(r'set\(%s\s+"?([^")\s]*)"?\)' % re.escape(name),
                  read(os.path.join(ROOT, 'CMakeLists.txt')))
    return m.group(1) if m else None


def system_libs(paths):
    """{library path: (package name, version) or None} that ldd reports for `paths`."""
    if not shutil.which('ldd'):
        return {}
    libs = set()
    for p in paths:
        r = subprocess.run(['ldd', p], stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
                           universal_newlines=True)
        for line in r.stdout.splitlines():
            m = re.search(r'=>\s+(/\S+)', line) or re.match(r'\s*(/\S+)', line)
            if m:
                libs.add(os.path.realpath(m.group(1)))
    out = {}
    for lib in sorted(libs):
        pkg = None
        if shutil.which('rpm'):
            r = subprocess.run(['rpm', '-qf', '--qf', '%{NAME} %{VERSION}-%{RELEASE}\n', lib],
                               stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
                               universal_newlines=True)
            if r.returncode == 0 and r.stdout.strip():
                name, ver = r.stdout.splitlines()[0].split(' ', 1)
                pkg = (name, ver)
        out[lib] = pkg
    return out


def main():
    ap = argparse.ArgumentParser(description=__doc__.split('\n')[0])
    ap.add_argument('--tree', required=True, help='the install tree')
    ap.add_argument('--name', required=True, help='the tarball name, e.g. wgvim-1.0.0-linux-x86_64')
    ap.add_argument('--out', required=True)
    ap.add_argument('--deps-src', default=os.path.join(ROOT, '.deps', 'build', 'src'))
    a = ap.parse_args()

    tree = os.path.abspath(a.tree)
    wgvim = os.path.join(tree, 'bin', 'wgvim')
    first = subprocess.run([wgvim, '--version'], stdout=subprocess.PIPE,
                           universal_newlines=True, check=True).stdout.splitlines()[0]
    m = re.match(r'^WGVIM v(\S+)(?: \(commit ([0-9a-f]+)(-dirty)?\))?$', first)
    if not m:
        die('unexpected first line of wgvim --version: %r' % first)
    version, commit, dirty = m.group(1), m.group(2), bool(m.group(3))

    deps = deps_txt()
    up = upstream_txt()

    # The bundled dependencies this build used: the directories CMake extracted.
    if not os.path.isdir(a.deps_src):
        die('%s not found (the bundled dependency sources)' % a.deps_src)
    used = sorted(d for d in os.listdir(a.deps_src)
                  if os.path.isdir(os.path.join(a.deps_src, d))
                  and not d.endswith(('-build', '-stamp')))
    components = []
    for d in used:
        key = d.upper()
        if key not in up:
            die('bundled dependency %s has no line in cmake.deps/upstream.txt' % key)
        if key not in deps or not deps[key][1]:
            die('bundled dependency %s has no URL/SHA256 in cmake.deps/deps.txt' % key)
        archive, sha = deps[key]
        if up[key]['version'] not in archive:
            die('%s: version %s (cmake.deps/upstream.txt) is not in the pinned archive %s '
                '(cmake.deps/deps.txt): update upstream.txt' % (key, up[key]['version'], archive))
        components.append(dict(up[key], key=key, sha256=sha, archive=archive))
    for key, row in up.items():
        if '/' in key:  # vendored in the source tree
            components.append(dict(row, key=key, sha256=None, archive=None))

    nv = '%s.%s.%s%s' % (cmake_var('NVIM_VERSION_MAJOR'), cmake_var('NVIM_VERSION_MINOR'),
                         cmake_var('NVIM_VERSION_PATCH'), cmake_var('NVIM_VERSION_PRERELEASE') or '')
    upstream_commit = cmake_var('WGVIM_UPSTREAM_COMMIT')
    if not upstream_commit:
        die('WGVIM_UPSTREAM_COMMIT not found in CMakeLists.txt')

    # Files: every file in the tree but this SBOM, with its checksums.
    sbom_rel = os.path.relpath(os.path.abspath(a.out), tree)
    files, ids = [], set()
    for dirpath, dirnames, filenames in os.walk(tree):
        dirnames.sort()
        for fn in sorted(filenames):
            p = os.path.join(dirpath, fn)
            rel = os.path.relpath(p, tree)
            if rel == sbom_rel or os.path.islink(p) or not os.path.isfile(p):
                continue
            sha1, sha256 = file_sums(p)
            sid = base = 'SPDXRef-File-' + spdx_id(rel)
            n = 1
            while sid in ids:
                n += 1
                sid = '%s-%d' % (base, n)
            ids.add(sid)
            native = rel.startswith('bin/') or rel.endswith('.so')
            ext = os.path.splitext(fn)[1]
            files.append({
                'fileName': './' + rel,
                'SPDXID': sid,
                'checksums': [{'algorithm': 'SHA1', 'checksumValue': sha1},
                              {'algorithm': 'SHA256', 'checksumValue': sha256}],
                'fileTypes': ['BINARY'] if native
                else ['SOURCE'] if ext in ('.lua', '.vim', '.scm', '.sh', '.te', '.if', '.fc')
                else ['DOCUMENTATION'] if ('/doc/' in rel or '/man/' in rel or ext in ('.txt', '.md'))
                else ['OTHER'],
                'licenseConcluded': 'NOASSERTION',
                'copyrightText': 'NOASSERTION',
            })

    # Package verification code (SPDX 2.3, 7.9): over all files but the SBOM itself.
    vcode = hashlib.sha1(''.join(sorted(f['checksums'][0]['checksumValue'] for f in files))
                         .encode()).hexdigest()

    epoch = int(os.environ.get('SOURCE_DATE_EPOCH') or datetime.datetime.now().timestamp())
    created = datetime.datetime.fromtimestamp(epoch, datetime.timezone.utc).strftime(
        '%Y-%m-%dT%H:%M:%SZ')
    ns_hash = hashlib.sha256((a.name + vcode).encode()).hexdigest()[:16]

    pkgs, rels = [], []
    wg_id = 'SPDXRef-Package-wgvim'
    wg = {
        'name': 'wgvim',
        'SPDXID': wg_id,
        'versionInfo': version,
        'supplier': 'NOASSERTION',
        'downloadLocation': ('git+%s.git@%s' % (REPO_URL, commit)) if commit and not dirty
        else 'NOASSERTION',
        'homepage': REPO_URL,
        'filesAnalyzed': True,
        'packageVerificationCode': {
            'packageVerificationCodeValue': vcode,
            'packageVerificationCodeExcludedFiles': ['./' + sbom_rel],
        },
        'hasFiles': [f['SPDXID'] for f in files],
        'licenseConcluded': 'Apache-2.0 AND Vim',
        'licenseDeclared': 'Apache-2.0 AND Vim',
        'copyrightText': 'NOASSERTION',
        'primaryPackagePurpose': 'APPLICATION',
        'description': 'An offline, hardened build of Neovim. Nearly all of it is the work of '
                       'the Neovim and Vim contributors; see NOTICE.',
        'comment': ('Built from commit %s%s. The files are those of the tarball %s (paths '
                    'relative to its top directory). Harper (optional grammar checker) is not '
                    'included in the tarball.' % (commit or 'unknown',
                                                 ' with uncommitted changes' if dirty else '',
                                                 a.name)),
    }
    if commit and not dirty:
        wg['externalRefs'] = [{'referenceCategory': 'PACKAGE-MANAGER', 'referenceType': 'purl',
                               'referenceLocator': 'pkg:github/wgvisots/wgvim@%s' % commit}]
    pkgs.append(wg)
    rels.append(('SPDXRef-DOCUMENT', 'DESCRIBES', wg_id))

    nv_id = 'SPDXRef-Package-neovim'
    pkgs.append({
        'name': 'Neovim', 'SPDXID': nv_id, 'versionInfo': '%s (snapshot %s)' % (nv, upstream_commit[:7]),
        'supplier': 'Organization: Neovim contributors',
        'downloadLocation': 'git+https://github.com/neovim/neovim.git@%s' % upstream_commit,
        'homepage': 'https://neovim.io', 'filesAnalyzed': False,
        'licenseConcluded': 'Apache-2.0 AND Vim', 'licenseDeclared': 'Apache-2.0 AND Vim',
        'copyrightText': 'NOASSERTION', 'primaryPackagePurpose': 'APPLICATION',
        'externalRefs': [{'referenceCategory': 'PACKAGE-MANAGER', 'referenceType': 'purl',
                          'referenceLocator': 'pkg:github/neovim/neovim@%s' % upstream_commit}],
    })
    rels.append((wg_id, 'DESCENDANT_OF', nv_id))
    vim_id = 'SPDXRef-Package-vim'
    pkgs.append({
        'name': 'Vim', 'SPDXID': vim_id, 'versionInfo': 'NOASSERTION',
        'supplier': 'Organization: Bram Moolenaar and the Vim contributors',
        'downloadLocation': 'NOASSERTION', 'homepage': 'https://www.vim.org',
        'filesAnalyzed': False, 'licenseConcluded': 'Vim', 'licenseDeclared': 'Vim',
        'copyrightText': 'NOASSERTION', 'primaryPackagePurpose': 'APPLICATION',
    })
    rels.append((nv_id, 'DESCENDANT_OF', vim_id))

    parser_files = {f['fileName']: f['SPDXID'] for f in files
                    if '/parser/' in f['fileName'] and f['fileName'].endswith('.so')}
    for c in components:
        cid = 'SPDXRef-Package-' + spdx_id(c['key'].lower())
        p = {
            'name': c['name'], 'SPDXID': cid, 'versionInfo': c['version'],
            'supplier': 'NOASSERTION', 'downloadLocation': c['url'], 'filesAnalyzed': False,
            'licenseConcluded': c['license'], 'licenseDeclared': c['license'],
            'copyrightText': 'NOASSERTION', 'primaryPackagePurpose': 'LIBRARY',
        }
        if c['sha256']:
            p['checksums'] = [{'algorithm': 'SHA256', 'checksumValue': c['sha256']}]
            p['sourceInfo'] = ('Vendored as deps/%s in the wgvim source; CMake checks its '
                               'SHA256 before building.' % c['archive'])
        else:
            p['sourceInfo'] = 'Vendored in the wgvim source under %s.' % c['key']
        if c['purl']:
            p['externalRefs'] = [{'referenceCategory': 'PACKAGE-MANAGER', 'referenceType': 'purl',
                                  'referenceLocator': c['purl']}]
        pkgs.append(p)
        lang = c['key'][len('TREESITTER_'):].lower() if c['key'].startswith('TREESITTER_') else None
        # A grammar can give several parsers (markdown: markdown.so, markdown_inline.so).
        target = [sid for fn, sid in parser_files.items()
                  if lang and re.search(r'/%s(_[a-z]+)?\.so$' % re.escape(lang), fn)]
        for sid in target:
            rels.append((sid, 'GENERATED_FROM', cid))
        if target:
            continue
        if c['key'].startswith('runtime/'):
            rels.append((wg_id, 'CONTAINS', cid))
        else:
            rels.append((wg_id, 'STATIC_LINK', cid))

    # System libraries (not shipped; provided by the operating system).
    native = [os.path.join(tree, f['fileName'][2:]) for f in files if f['fileTypes'] == ['BINARY']]
    for lib, pkg in system_libs(native).items():
        name = pkg[0] if pkg else os.path.basename(lib)
        sid = 'SPDXRef-Package-system-' + spdx_id(name)
        if any(x['SPDXID'] == sid for x in pkgs):
            continue
        pkgs.append({
            'name': name, 'SPDXID': sid, 'versionInfo': pkg[1] if pkg else 'NOASSERTION',
            'supplier': 'NOASSERTION', 'downloadLocation': 'NOASSERTION', 'filesAnalyzed': False,
            'licenseConcluded': 'NOASSERTION', 'licenseDeclared': 'NOASSERTION',
            'copyrightText': 'NOASSERTION', 'primaryPackagePurpose': 'OPERATING-SYSTEM',
            'comment': 'Provided by the operating system, not shipped in the tarball (%s%s).'
                       % (lib, ', as found in the build container' if pkg else ''),
        })
        rels.append((wg_id, 'DEPENDS_ON', sid))

    extracted = []
    if any('LicenseRef-utf8proc-Unicode-data' in c['license'] for c in components):
        lic = os.path.join(a.deps_src, 'utf8proc', 'LICENSE.md')
        text = read(lic)
        i = text.find('## Unicode data license ##')
        if i < 0:
            die('%s: Unicode data licence section not found' % lic)
        extracted.append({
            'licenseId': 'LicenseRef-utf8proc-Unicode-data',
            'name': 'utf8proc Unicode data licence',
            'extractedText': text[i:].strip(),
            'comment': 'The licence of the Unicode data files in utf8proc (its LICENSE.md).',
        })

    doc = {
        'spdxVersion': 'SPDX-2.3',
        'dataLicense': 'CC0-1.0',
        'SPDXID': 'SPDXRef-DOCUMENT',
        'name': a.name,
        'documentNamespace': '%s/spdx/%s-%s' % (REPO_URL, a.name, ns_hash),
        'creationInfo': {
            'created': created,
            'creators': ['Tool: wgvim-scripts-generate-sbom.py'],
        },
        'packages': pkgs,
        'files': files,
        'relationships': [{'spdxElementId': x, 'relationshipType': r, 'relatedSpdxElement': y}
                          for x, r, y in rels],
    }
    if extracted:
        doc['hasExtractedLicensingInfos'] = extracted
    with open(a.out, 'w', encoding='utf-8') as f:
        json.dump(doc, f, indent=2, sort_keys=False)
        f.write('\n')
    print('generate-sbom: %s: %d packages, %d files' % (a.out, len(pkgs), len(files)))


if __name__ == '__main__':
    main()
