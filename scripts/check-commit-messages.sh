#!/usr/bin/env bash
# Reject AI advertisements in commits (AGENTS.md): disclose AI use only with a bare
# "AI-assisted" trailer; do not name the model or service, and do not list an AI service as the
# author or committer.
#
#   scripts/check-commit-messages.sh [REVISION-RANGE]     (default: origin/master..HEAD)
#
# Ported from the "no-ai-advertisements" job of Neovim's labeler_pr.yml, extended to check the
# author and committer. Exit status: 0 if clean, 1 if something was found, 2 on usage errors.

set -euo pipefail

RANGE="${1:-origin/master..HEAD}"
git rev-parse --git-dir >/dev/null 2>&1 || { echo "error: not in a git repository" >&2; exit 2; }

# One line per message line (and per author/committer), prefixed with the commit.
commits=$(git log --format='%H%x00%an <%ae>%x00%cn <%ce>%x00%B%x01' "$RANGE" | awk '
  BEGIN { RS = "\001"; FS = "\000" }
  NF >= 4 {
    sha = $1; sub(/^\n+/, "", sha); sha = substr(sha, 1, 12)
    print sha " Author: " $2
    print sha " Committer: " $3
    n = split($4, lines, "\n")
    for (i = 1; i <= n; i++) print sha " " lines[i]
  }')

tools='aider|anthropic|chatgpt|claude|cline|codex|copilot|cursor|devin|gemini|openai|opencode|windsurf|\bamp\b|\bai\b|\bllm\b|\bgpt\b'
by='(co-authored|signed-off|assisted|helped|generated|written|created|reviewed|suggested|reported|tested|debugged)[ -]?by'
hosts='claude\.ai|anthropic\.com|openai\.com|chatgpt\.com|copilot\.microsoft\.com|cursor\.(com|sh)|ampcode\.com|codeium\.com|windsurf\.com|(gemini|aistudio)\.google\.com'

found=$({
  # Attribution trailers and phrasing.
  grep -Ei "^\S+ +$by:.*($tools)" <<< "$commits" || true
  grep -Ei "(generated|written|assisted|supported|powered|created|helped)[ -](by|with)[: ]+.*($tools)" <<< "$commits" || true
  # Session links and trailers.
  grep -Ei "^\S+ +($tools)[a-z0-9-]*-(session|thread|chat|conversation|link|url|id):" <<< "$commits" || true
  grep -Ei "https?://[^ ]*($hosts)" <<< "$commits" || true
  grep -Ei '@(anthropic|openai)\.com' <<< "$commits" || true
  # An AI service as author or committer.
  grep -Ei "^\S+ +(Author|Committer): .*($tools|$hosts)" <<< "$commits" || true
  # The "AI-assisted" trailer must not name the tool.
  grep -Ei '^\S+ +AI-assisted:.*\S' <<< "$commits" || true
  grep -F '🤖' <<< "$commits" || true
} | sort -u)

if [[ -n "$found" ]]; then
  echo 'Remove AI advertisements from commits ("Co-authored-by: Claude", AI authors, etc.).'
  echo 'Only a generic "AI-assisted" trailer is allowed, see AGENTS.md.'
  echo
  echo "$found"
  exit 1
fi
echo "commit messages: ok ($(git rev-list --count "$RANGE") commits in $RANGE)"
