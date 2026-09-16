#!/usr/bin/env bash
# =============================================================================
# Every guest-derived value interpolated into innerHTML must be escaped
# =============================================================================
# The published demos run UNTRUSTED Python and display what it returns. Any of
# that data reaching `innerHTML` unescaped is parsed as HTML, so a script can
# inject markup and execute JavaScript in the page that embeds it.
#
# CONFIRMED, not theoretical. Reproduced in a replica of vfs.html's own render
# path: `<img src=x onerror=window.__PWNED=1>` returned from a sandboxed script
# executed. `JSON.stringify` escapes `"` and so mangles QUOTED payloads on the
# object branch -- which nearly hid this -- but a top-level string return takes
# the `String(v)` branch, which escapes nothing, and fires with quotes intact.
#
# WHY A CHECK AND NOT JUST THE FIX. `escapeHtml` already existed in vfs.html and
# was applied to exactly ONE of six sinks -- `f.preview` at :467 -- while
# `f.path` on that SAME LINE went unescaped. The author knew the hazard, wrote
# the helper, and the other five drifted. Inconsistent escaping is not caught by
# review; it is caught by a check.
#
# GUEST-CONTROLLED, and all of it reached a sink: the return value, the error
# text, OS-call op names and arguments, and FILE PATHS -- a script that calls
# open('/sandbox/<img src=x onerror=...>', 'w') gets its filename rendered by
# the file tree, needing no return value at all.
set -uo pipefail
cd "$(git rev-parse --show-toplevel)" || exit 1

PAGES="$(git ls-files 'example/web/web/*.html')"
[ -n "$PAGES" ] || { echo "FAIL: no published pages matched example/web/web/*.html."
                     echo "  A glob that stopped matching would verify nothing."; exit 1; }

# Interpolations that are provably not guest data. Each is a length, a counter
# or a duration produced by the page itself. Adding a name here is a deliberate,
# reviewable act -- it is how you assert "this one cannot carry markup".
SAFE='_callCount|content\.length|entry\.durationMs|f\.size|result\.osCallLog\.length'

RC=0; N=0; SINKS=0
for page in $PAGES; do
  N=$((N+1))
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    SINKS=$((SINKS+1))
    num="${line%%:*}"; body="${line#*:}"
    # Every ${...} in this innerHTML template must be escapeHtml(...) or SAFE.
    while IFS= read -r expr; do
      [ -n "$expr" ] || continue
      inner="${expr#\$\{}"; inner="${inner%\}}"
      case "$inner" in
        escapeHtml\(*) continue ;;
      esac
      if printf '%s' "$inner" | grep -qE "^($SAFE)$"; then continue; fi
      echo "FAIL: $page:$num interpolates \${$inner} into innerHTML unescaped."
      echo "      Wrap it: \${escapeHtml($inner)} -- or, if it provably cannot"
      echo "      carry markup, add it to SAFE in tool/check_html_escaping.sh"
      echo "      with a reason."
      RC=1
    done < <(printf '%s' "$body" | grep -oE '\$\{[^}]*\}')
  done < <(grep -noE 'innerHTML[[:space:]]*\+?=[[:space:]]*`[^`]*`' "$page")
done

if [ "$RC" = "0" ]; then
  echo "PASS — $SINKS interpolating innerHTML sink(s) across $N published page(s), all escaped."
fi
exit $RC
