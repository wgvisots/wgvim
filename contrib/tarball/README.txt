@NAME@
==========================================================================

wgvim @VERSION@ (commit @COMMIT@), built on Red Hat UBI 9 for RHEL 9 and
compatible systems (glibc 2.34 or later), x86_64.

wgvim is an offline, hardened build of Neovim. Nearly all of it is the work of
the Neovim contributors and, before them, of Bram Moolenaar and the Vim
contributors; see NOTICE. It is not the Neovim project and is not supported by it.


Check the download
------------------
A release (https://github.com/wgvisots/wgvim/releases) comes with SHA256SUMS,
signed by the maintainer (SHA256SUMS.asc; RELEASING.md in the source says how
to get and check the key):

    gpg --verify SHA256SUMS.asc SHA256SUMS
    sha256sum -c SHA256SUMS --ignore-missing

A build between releases (a CI artifact) has only a .sha256 file:

    sha256sum -c @NAME@.tar.gz.sha256

Releases, and builds from the master branch, also carry a GitHub build
attestation; with the GitHub CLI:

    gh attestation verify @NAME@.tar.gz --repo wgvisots/wgvim

sbom.spdx.json (SPDX 2.3) lists every file in this tarball with its SHA-256,
and every library built into wgvim with its version, licence and source.


Install (recommended: /opt/wgvim)
---------------------------------
    sudo rm -rf /opt/wgvim
    sudo mkdir -p /opt/wgvim
    sudo tar -C /opt/wgvim --strip-components=1 -xzf @NAME@.tar.gz
    sudo ln -sf /opt/wgvim/bin/wgvim /usr/local/bin/wgvim    # optional

/opt/wgvim is where the SELinux policy below expects it. The tree also works
from any other directory (for example ~/.local/opt/wgvim, without root): wgvim
finds its runtime files and tree-sitter parsers next to its binary. Run it by
its real path or through a symlink; do not copy bin/wgvim out of the tree.

Contents: bin/wgvim (the editor), bin/tablefmt (the table formatter for C and
C++, see ":help wgvim-tablefmt"), @LIBDIR@/parser/ (the bundled tree-sitter
parsers), share/wgvim/runtime/ (runtime files and help), share/man/,
share/wgvim/selinux/ (the SELinux policy), licenses/ (the licence of every
library built into wgvim), sbom.spdx.json (the SBOM).


SELinux (optional, recommended on RHEL)
---------------------------------------
The policy confines wgvim in its own domain, below wgvim's own sandbox. With
the tree in /opt/wgvim:

    sudo dnf install selinux-policy-devel policycoreutils-python-utils
    sudo /opt/wgvim/share/wgvim/selinux/wgvim-selinux.sh install

It starts in permissive mode (denials are logged, nothing is blocked); after a
while, "wgvim-selinux.sh denials" shows what would have been refused and
"wgvim-selinux.sh enforce" turns it on. See ":help wgvim-selinux".

If the tree is elsewhere, label its binary with "--binary PATH/bin/wgvim"; an
unlabelled binary runs unconfined by SELinux (the sandbox still applies).


Harper (optional grammar checker)
---------------------------------
Not included. It is installed from a wgvim source checkout, with the pinned
and checksummed release in deps/: see ":help wgvim-harper".


Licences and source
-------------------
wgvim is under the Apache License 2.0 and the Vim licence (LICENSE.txt);
NOTICE lists what wgvim changed. The bundled libraries keep their own licences
(licenses/). Among them, unibilium is under the GNU LGPL 3.0 or later.

The complete source of this build, including the source archive of every
bundled library (deps/, each checked against the SHA256 recorded in
cmake.deps/deps.txt), is commit @COMMIT@ of

    https://github.com/wgvisots/wgvim

That source rebuilds this tarball offline: see BUILD.md there and
"scripts/rhel9-container-test.sh --package".
