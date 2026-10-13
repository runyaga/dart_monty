#!/usr/bin/env bash
# =============================================================================
# Every third-party action is pinned to a full commit SHA
# =============================================================================
# A tag such as `@v7` or a branch such as `@stable` is a pointer the action's
# owner can move. Whoever controls that repository (or steals its token) can
# repoint it, and the next workflow run executes the new code with this repo's
# GITHUB_TOKEN and secrets. A 40-hex commit SHA cannot be moved.
#
# Accepted:  uses: owner/repo[/path]@<40 lowercase hex>   (a `# v7` comment
#            after it names the release it came from)
#            uses: ./local/path                          (this repo's own code)
# Rejected:  everything else, including tags, branches, short SHAs and
#            docker:// references.
#
# Scans .github/workflows/*.yml|*.yaml and every action.yml|action.yaml under
# .github/actions/. Before the real tree it runs itself over two fixtures --
# one tag pin that must FAIL, one SHA pin that must PASS -- so a pattern that
# rots into matching nothing is a red, not a quiet green. It also fails when
# the tree yields no `uses:` at all.
#
# Dependabot (.github/dependabot.yml, ecosystem github-actions) proposes the
# bumps, as SHA + comment.
#
# Usage: bash tool/check_action_pins.sh
# =============================================================================
set -uo pipefail
cd "$(git rev-parse --show-toplevel)"

# scan <root>: print each bad `uses:` as file:line: value; print the totals
# as the last line "<checked> <bad>".
scan() {
  local root=$1 f
  local files=()
  while IFS= read -r f; do files+=("$f"); done < <(
    find "$root/.github/workflows" -maxdepth 1 -type f \( -name '*.yml' -o -name '*.yaml' \) 2>/dev/null
    find "$root/.github/actions" -type f \( -name 'action.yml' -o -name 'action.yaml' \) 2>/dev/null
  )
  [ "${#files[@]}" -eq 0 ] && { echo "0 0"; return; }
  # The key in any YAML spelling -- `uses:`, `uses :`, `"uses":`,
  # `{uses: ...}` -- anywhere on a line. A value that is not a plain scalar (an
  # alias, a block scalar) is rejected rather than skipped.
  awk '
    {
      # Only whole-line comments are skipped: a `#` inside a quoted value such
      # as `{name: "a # b", uses: x@v1}` is not a comment, so the rest of the
      # line is still read (a `uses:` in a trailing comment is reported).
      if ($0 ~ /^[[:space:]]*#/) next
      line = $0
      while (match(line, /["\047]?uses["\047]?[[:space:]]*:/)) {
        pre = RSTART > 1 ? substr(line, RSTART - 1, 1) : ""
        line = substr(line, RSTART + RLENGTH)
        if (pre ~ /[A-Za-z0-9_-]/) continue
        v = line
        sub(/^[[:space:]]*/, "", v)
        if (match(v, /[[:space:],}]/)) v = substr(v, 1, RSTART - 1)
        gsub(/^["\047]|["\047]$/, "", v)
        n++
        if (v ~ /^\.\// || v ~ /^[A-Za-z0-9_.-]+\/[A-Za-z0-9_.-]+(\/[^@[:space:]]+)?@[0-9a-f]+$/ && length(v) - index(v, "@") == 40) continue
        bad++
        print FILENAME ":" FNR ": " v
      }
    }
    END { print n + 0, bad + 0 }
  ' "${files[@]}"
}

# verdict <output of scan>: 0 when something was checked and nothing was bad.
verdict() {
  local totals
  totals=$(printf '%s\n' "$1" | tail -n 1)
  [ "${totals% *}" -gt 0 ] && [ "${totals#* }" -eq 0 ]
}

# Self-test: the checker must reject a tag pin and accept a SHA pin.
T=$(mktemp -d)
trap '/bin/rm -rf "$T"' EXIT
mkdir -p "$T/bad/.github/workflows" "$T/good/.github/workflows"
printf 'jobs:\n  a:\n    steps:\n      - uses: actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1 # v7\n      - uses: ./.github/actions/x\n' > "$T/good/.github/workflows/a.yaml"
# One tag pin per valid YAML spelling of the key; each must be the one bad line.
for TAG in '- uses: actions/checkout@v7' '- uses : actions/checkout@v7' \
           '- "uses": actions/checkout@v7' \
           '- {uses: actions/checkout@v7, with: {fetch-depth: 0}}' \
           '- {name: "a # b", uses: actions/checkout@v7}'; do
  printf 'jobs:\n  a:\n    steps:\n      %s\n' "$TAG" > "$T/bad/.github/workflows/a.yaml"
  if [ "$(scan "$T/bad")" != "$T/bad/.github/workflows/a.yaml:4: actions/checkout@v7
1 1" ]; then
    echo "FAIL: self-test -- a tag pin was not rejected: $TAG"
    exit 1
  fi
done
if ! verdict "$(scan "$T/good")"; then
  echo "FAIL: self-test -- a SHA pin was rejected."
  exit 1
fi

OUT=$(scan .)
TOTALS=$(printf '%s\n' "$OUT" | tail -n 1)
if [ "${TOTALS% *}" -eq 0 ]; then
  echo "FAIL: found no 'uses:' under .github -- the scan is not looking where the workflows are."
  exit 1
fi
if ! verdict "$OUT"; then
  echo "FAIL: ${TOTALS#* } of ${TOTALS% *} 'uses:' are not pinned to a full commit SHA:"
  printf '%s\n' "$OUT" | sed '$d' | sed 's/^/    /'
  echo "  Pin each to the 40-hex commit its tag resolves to, keeping the tag as a comment:"
  echo "    uses: owner/repo@<sha> # v1"
  echo "  (gh api repos/<owner>/<repo>/commits/<tag> --jq .sha)"
  exit 1
fi
echo "PASS -- all ${TOTALS% *} 'uses:' are SHA-pinned or local."
