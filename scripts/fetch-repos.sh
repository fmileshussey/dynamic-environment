#!/usr/bin/env bash
# Fetch all repo slugs from a Bitbucket workspace, one per line.
# Usage: fetch-repos.sh <workspace> <email> <api_token>

set -euo pipefail

WORKSPACE="$1"
EMAIL="$2"
API_TOKEN="$3"

URL="https://api.bitbucket.org/2.0/repositories/${WORKSPACE}?pagelen=100&sort=slug"

while [[ -n "$URL" ]]; do
  PAGE=$(curl -sf -u "${EMAIL}:${API_TOKEN}" "$URL") || {
    echo "Error: Bitbucket API request failed. Check your credentials and workspace slug." >&2
    exit 1
  }

  if command -v jq &>/dev/null; then
    echo "$PAGE" | jq -r '.values[].slug'
    URL=$(echo "$PAGE" | jq -r '.next // empty')
  else
    echo "$PAGE" | python3 -c "import sys,json; [print(r['slug']) for r in json.load(sys.stdin)['values']]"
    URL=$(echo "$PAGE" | python3 -c "import sys,json; print(json.load(sys.stdin).get('next',''))")
  fi
done
