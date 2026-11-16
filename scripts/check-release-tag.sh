#!/usr/bin/env bash
# Check that a tag may be released (RELEASING.md). The release workflow runs it first; run it
# yourself before pushing a tag to see the same answer.
#
#   scripts/check-release-tag.sh TAG [--local]
#
# Checks:
#   1. TAG is vX.Y.Z and equals "v" + the wgvim version in CMakeLists.txt at the tagged
#      commit, which has no pre-release part (WGVIM_VERSION_PRERELEASE "").
#   2. The tagged commit is on master (origin/master).
#   3. CHANGELOG.md at the tagged commit has a "## X.Y.Z" section (the release notes).
#   4. The tag is annotated and GitHub reports its signature as verified (skipped with --local,
#      for a tag not pushed yet: then "git tag -v TAG" checks the signature on your machine).
#
# Needs git, and gh (GitHub CLI, authenticated, or $GH_TOKEN) for check 4.

set -euo pipefail

TAG="${1:?usage: check-release-tag.sh TAG [--local]}"
LOCAL=0
[ "${2:-}" = "--local" ] && LOCAL=1
REPO="${GITHUB_REPOSITORY:-wgvisots/wgvim}"
fail() { echo "check-release-tag: FAIL: $*" >&2; exit 1; }
ok() { echo "check-release-tag: ok: $*"; }

[[ "$TAG" =~ ^v([0-9]+)\.([0-9]+)\.([0-9]+)$ ]] || fail "$TAG is not vX.Y.Z"
WANT="${TAG#v}"
COMMIT="$(git rev-parse --verify "$TAG^{commit}" 2>/dev/null)" || fail "no tag $TAG here"

# 1. The version at the tagged commit.
CML="$(git show "$COMMIT:CMakeLists.txt")"
get() { sed -n "s/^set(WGVIM_VERSION_$1 \"\{0,1\}\([^\")]*\)\"\{0,1\})$/\1/p" <<<"$CML"; }
HAVE="$(get MAJOR).$(get MINOR).$(get PATCH)"
PRE="$(get PRERELEASE)"
[ -z "$PRE" ] || fail "the version at $TAG is $HAVE$PRE: a release commit has WGVIM_VERSION_PRERELEASE \"\""
[ "$HAVE" = "$WANT" ] || fail "tag $TAG, but CMakeLists.txt at that commit says $HAVE"
ok "version $HAVE at ${COMMIT:0:12}"

# 2. On master.
git rev-parse --verify -q origin/master >/dev/null || git fetch -q origin master
git merge-base --is-ancestor "$COMMIT" origin/master \
  || fail "${COMMIT:0:12} is not on origin/master (tag the merge commit of the release PR)"
ok "the tagged commit is on master"

# 3. Release notes.
git show "$COMMIT:CHANGELOG.md" 2>/dev/null | grep -qE "^## $(sed 's/\./\\./g' <<<"$WANT")( |$)" \
  || fail "CHANGELOG.md at $TAG has no \"## $WANT\" section"
ok "CHANGELOG.md has a $WANT section"

# 4. Annotated and signed, as GitHub sees it.
[ "$(git cat-file -t "$TAG")" = tag ] || fail "$TAG is a lightweight tag: use git tag -s"
if [ "$LOCAL" = 1 ]; then
  ok "annotated (signature not checked with --local; run: git tag -v $TAG)"
  exit 0
fi
OBJ="$(gh api "repos/$REPO/git/ref/tags/$TAG" --jq '.object.type + " " + .object.sha')" \
  || fail "tag $TAG not found on GitHub ($REPO)"
[ "${OBJ%% *}" = tag ] || fail "on GitHub, $TAG is not an annotated tag"
read -r VERIFIED REASON TAGGER < <(gh api "repos/$REPO/git/tags/${OBJ#* }" \
  --jq '[(.verification.verified|tostring), .verification.reason, .tagger.name] | join(" ")')
[ "$VERIFIED" = true ] || fail "GitHub does not verify the signature of $TAG (reason: $REASON)"
ok "signed by $TAGGER, verified by GitHub"
