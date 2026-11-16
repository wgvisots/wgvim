# Releasing wgvim

A release is a signed tag `vX.Y.Z` on `master`. Pushing it starts the `release` workflow
(`.github/workflows/release.yml`). That workflow checks the tag, then builds and tests the
tagged commit in the offline UBI 9 container exactly as CI does. It then creates a **draft**
GitHub release with:

| File | What it is |
|---|---|
| `wgvim-X.Y.Z-linux-x86_64.tar.gz` | The tarball, already tested in a plain UBI 9 container (INSTALL.md) |
| `wgvim-X.Y.Z-linux-x86_64.spdx.json` | Its SBOM: SPDX 2.3, listing every file and bundled library |
| `wgvim-X.Y.Z-src.tar.gz` | The complete source of the release, with every bundled dependency |
| `SHA256SUMS` | The checksums of the three files above |
| `SHA256SUMS.asc` | **You add this:** your signature of `SHA256SUMS` |

Each file also gets a GitHub build attestation, which records that this workflow built it from
this tag. The release stays a draft until you have checked it and signed it.

Three signatures, each answering a different question:

- **The tag** (your key): you approved this commit as release X.Y.Z. The workflow refuses
  tags that GitHub can't verify.
- **The attestation** (GitHub, automatic): these files came out of this repository's
  workflow, from this tag.
- **`SHA256SUMS.asc`** (your key): you checked these files and stand behind them. It can be
  verified without GitHub, which matters for offline machines and for paperwork.

## One-time setup: your signing key

Use a key that is yours, on your own machine, protected by a passphrase. Don't use the key
of an automated or cloud session: a release signature is a personal statement, and it must
outlive any one session.

GPG is the usual choice for signing release files, and git can sign tags with it.

1. **Do you already have a key?**
   ```bash
   gpg --list-secret-keys --keyid-format long
   ```
   If one is listed with your name and the email address on your GitHub account, skip to
   step 3.

2. **Create one** (Ed25519, signing only, expires in two years; you can extend it later):
   ```bash
   gpg --quick-generate-key "Your Name <you@example.com>" ed25519 sign 2y
   ```
   Pick a good passphrase. The email address must be one that is verified on your GitHub
   account, or GitHub won't mark your tags as verified.

3. **Find its fingerprint and key ID:**
   ```bash
   gpg --list-secret-keys --keyid-format long --with-fingerprint you@example.com
   ```
   The key ID is the part after `ed25519/` on the `sec` line. The fingerprint is the
   40-character line below it.

4. **Give the public key to GitHub:** run `gpg --armor --export KEYID` and paste the output
   at GitHub → Settings → SSH and GPG keys → New GPG key. Anyone can then fetch it from
   `https://github.com/<your-username>.gpg`.

5. **Tell git to sign with it:**
   ```bash
   git config --global user.signingkey KEYID
   ```
   If your git is set up to sign with SSH (`gpg.format ssh`), that works for the tag too:
   GitHub verifies SSH-signed tags. Use GPG for `SHA256SUMS.asc` either way.

6. **Keep a backup and a revocation certificate offline**, for example on a USB stick in a
   drawer. Without a backup, a lost laptop means a new key and a note to everyone who
   trusted the old one. Without a revocation certificate, a stolen key can't be revoked.
   ```bash
   gpg --armor --export-secret-keys KEYID > wgvim-signing-key.secret.asc
   # gpg wrote a revocation certificate when it made the key:
   cp ~/.gnupg/openpgp-revocs.d/FINGERPRINT.rev wgvim-signing-key.revoke.asc
   ```

7. **Record the fingerprint** under "Release signing keys" at the end of this file, in a PR,
   so people who verify releases can check that they have the right key.

## Making a release

1. **The release PR** sets the version in `CMakeLists.txt` (`WGVIM_VERSION_*`, with
   `WGVIM_VERSION_PRERELEASE ""`) and adds a `## X.Y.Z` section to `CHANGELOG.md`. Merge it
   once CI passes.

2. **Tag the merge commit** on your machine:
   ```bash
   git fetch origin
   git checkout master && git pull --ff-only
   git log -1 --format='%h %s'                     # the release PR's merge commit
   git tag -s v1.0.0 -m "wgvim 1.0.0"
   git tag -v v1.0.0                               # shows "Good signature"
   scripts/check-release-tag.sh v1.0.0 --local     # the checks the workflow will make
   git push origin v1.0.0
   ```

3. **Wait for the `release` workflow** (Actions tab, about 20 minutes). It ends by creating
   the draft release and shows the checksums in its summary. If it fails, see below.

4. **Check the draft:**
   ```bash
   mkdir rel && cd rel
   gh release download v1.0.0 --repo wgvisots/wgvim
   sha256sum -c SHA256SUMS
   gh attestation verify wgvim-1.0.0-linux-x86_64.tar.gz --repo wgvisots/wgvim
   gh attestation verify wgvim-1.0.0-src.tar.gz --repo wgvisots/wgvim
   ```
   You can also unpack the tarball and try it: `./wgvim-1.0.0-linux-x86_64/bin/wgvim --version`
   should start with `WGVIM v1.0.0 (commit ...)`, naming the tagged commit.

5. **Sign the checksums** and upload the signature:
   ```bash
   gpg --armor --detach-sign --output SHA256SUMS.asc SHA256SUMS
   gpg --verify SHA256SUMS.asc SHA256SUMS          # shows "Good signature"
   gh release upload v1.0.0 SHA256SUMS.asc --repo wgvisots/wgvim
   ```

6. **Publish:** `gh release edit v1.0.0 --draft=false --repo wgvisots/wgvim`, or click
   "Publish release" on the draft.

7. **Start the next version:** a PR that sets `WGVIM_VERSION_PATCH` to the next number and
   `WGVIM_VERSION_PRERELEASE` to `"-dev"` (for example `1.0.1-dev`). Builds made between
   releases then can't be mistaken for the release.

## If something goes wrong

- **The workflow refused the tag** ("check the tag" step): the message says why (version
  mismatch, not on master, no CHANGELOG section, unverified signature). Delete the tag,
  fix the cause, and tag again:
  ```bash
  git push --delete origin v1.0.0 && git tag -d v1.0.0
  ```
- **The build or tests failed:** delete the tag and the draft release (if one was created),
  fix it in a PR, and tag the new merge commit.
- **After publishing:** never move or reuse a published tag. Publish a patch release
  (1.0.1) instead.

A tag ruleset is recommended (Settings → Rules → Rulesets → New tag ruleset, targeting
`v*`): restrict creation, updates and deletion to maintainers. Then a published release tag
can't be moved or deleted by accident.

## Verifying a release

For anyone receiving wgvim (and for your paperwork):

```bash
# 1. The maintainer's key: fetch it, and compare its fingerprint with the list below.
curl -sL https://github.com/<maintainer>.gpg | gpg --import
gpg --fingerprint
# 2. The signature of the checksums, then the checksums of the files.
gpg --verify SHA256SUMS.asc SHA256SUMS
sha256sum -c SHA256SUMS --ignore-missing
# 3. Optional: that GitHub's workflow built it from the tag.
gh attestation verify wgvim-1.0.0-linux-x86_64.tar.gz --repo wgvisots/wgvim
```

The SBOM (`.spdx.json`) lists every file in the tarball with its SHA-256, and every bundled
library with its version, licence, upstream source and the checksum of the archive it was
built from. Any SPDX 2.3 tool reads it.

## Release signing keys

| Maintainer | Key fingerprint | Since |
|---|---|---|
| (to be added with the first release) | | |
