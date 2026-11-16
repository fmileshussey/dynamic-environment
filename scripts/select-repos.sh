#!/usr/bin/env bash
# Interactive repo selector using fzf.
# Selected slugs are written to /tmp/dev-env-selected-<category>.txt
# Usage: select-repos.sh <category> [repos-file]

CATEGORY="${1:?Usage: select-repos.sh <category> [repos-file]}"
REPOS_FILE="${2:-$HOME/.cache/dev-env/repos.txt}"
OUTPUT="/tmp/dev-env-selected-${CATEGORY}.txt"

if [[ ! -f "$REPOS_FILE" ]]; then
  echo "Error: repos file not found: $REPOS_FILE" >&2
  exit 1
fi

rm -f "$OUTPUT"

# Enter only confirms Tab-marked repos; with nothing marked it skips the
# category (otherwise fzf would accept the highlighted, unmarked line).
fzf --multi \
  --prompt="[$CATEGORY] Type to filter, Tab to mark, Enter to confirm: " \
  --header="Selecting repos for: $CATEGORY  |  Tab=mark  Enter=confirm marked  (no marks = skip)" \
  --bind 'enter:transform([ "$FZF_SELECT_COUNT" -gt 0 ] && echo accept || echo abort)' \
  < "$REPOS_FILE" \
  > "$OUTPUT" || true

# grep -c prints 0 itself (and exits 1) when nothing matches
COUNT=$(grep -c . "$OUTPUT" 2>/dev/null)
COUNT=${COUNT:-0}
echo "  $COUNT selected for $CATEGORY."
