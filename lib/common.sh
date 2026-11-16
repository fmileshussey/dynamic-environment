# lib/common.sh — shared helpers for env.sh. Sourced, not executed.
# Expects SELF_DIR to be set by the caller before sourcing.

CONFIG="$HOME/.config/dev-env/config.yml"

# config_get <key> [<default>] — an optional setting from config.yml (which
# also holds the Bitbucket credentials), or <default> when it isn't set.
config_get() {
  local value=""
  [[ -f "$CONFIG" ]] && value=$(sed -n "s/^$1:[[:space:]]*//p" "$CONFIG" | head -1)
  value="${value%\"}" value="${value#\"}" value="${value%\'}" value="${value#\'}"
  printf '%s\n' "${value:-${2:-}}"
}

# Settings. Each one can be set in config.yml or by its DEV_ENV_* variable
# (the variable wins). See README "Settings".
REPO_ROOT="${DEV_ENV_REPO_ROOT:-$(config_get repo_root "$HOME/repositories")}"
REPO_ROOT="${REPO_ROOT/#\~/$HOME}"
# Branches a new feature branch may start from (globs, matched case-insensitively)
BASE_BRANCHES="${DEV_ENV_BASE_BRANCHES:-$(config_get base_branches "main master")}"
# Clones discovery ignores (globs on the folder name), besides this repo
SKIP_REPOS="${DEV_ENV_SKIP_REPOS:-$(config_get skip_repos "*-development-environment")}"
# Local setup notes for the Claude that builds repo kits (Keycloak, databases, ...)
SETUP_NOTES="$HOME/.config/dev-env/setup-notes.md"
CACHE_FILE="$HOME/.cache/dev-env/repos.txt"
CACHE_TTL_MINS=1440  # 24h

WORKTREES_ROOT="$HOME/.local/share/dev-env/worktrees"
TMUXINATOR_DIR="$HOME/.config/tmux/tmuxinator"

ACTIVE_MD="$SELF_DIR/ACTIVE.md"
PRESETS_DIR="$SELF_DIR/presets"
# The slot holding shared tools (./env.sh shared); not a work-in-progress slot
SHARED_SLOT="shared"
# Per-repo kits: local files and run commands every new worktree of a repo gets
REPO_KITS_DIR="$HOME/.config/dev-env/repos"
# Repos in this category are only there to read: detached at the latest base,
# with no tmux window, kit, hostname or setup checks (./env.sh ref)
REFERENCE_CATEGORY="reference"

# ─── colours ──────────────────────────────────────────────────────────────────

if [[ -t 2 ]]; then
  BOLD=$(tput bold)
  DIM=$(tput dim 2>/dev/null || printf '')
  CYAN=$(tput setaf 6)
  YELLOW=$(tput setaf 3)
  GREEN=$(tput setaf 2)
  RED=$(tput setaf 1)
  RESET=$(tput sgr0)
else
  BOLD='' DIM='' CYAN='' YELLOW='' GREEN='' RED='' RESET=''
fi

# editor_command — what a repo window's left pane runs ('' for a plain shell).
# Setting 'editor' (a command, run with '.'; 'none' for a shell); by default
# nvim if it's installed, else $EDITOR.
editor_command() {
  local editor="${DEV_ENV_EDITOR:-$(config_get editor)}"
  if [[ -z "$editor" ]]; then
    if command -v nvim >/dev/null 2>&1; then editor=nvim; else editor="${EDITOR:-}"; fi
  fi
  [[ -z "$editor" || "$editor" == none ]] && return 0
  printf '%s .\n' "$editor"
}

# claude_enabled — whether a slot's environment window runs Claude Code.
# Setting 'claude': on, off, or auto (the default: on if 'claude' is installed).
claude_enabled() {
  case "${DEV_ENV_CLAUDE:-$(config_get claude auto)}" in
    on|yes|true)   return 0 ;;
    off|no|false)  return 1 ;;
    *) command -v claude >/dev/null 2>&1 ;;
  esac
}

# browser_mode — how 'open' shows a slot's apps. Setting 'browser':
#   chrome   a Chrome tab group (needs chrome-extension/ loaded)
#   default  a plain tab per app in the default browser
#   none     don't open anything
#   auto     (the default) chrome if Chrome is installed, else default
browser_mode() {
  local mode="${DEV_ENV_BROWSER:-$(config_get browser auto)}"
  if [[ "$mode" == auto ]]; then
    if [[ -d "/Applications/Google Chrome.app" || -d "$HOME/Applications/Google Chrome.app" ]]; then
      mode=chrome
    else
      mode=default
    fi
  fi
  printf '%s\n' "$mode"
}

# ─── helpers ──────────────────────────────────────────────────────────────────

die()     { printf '%sError: %s%s\n' "$RED$BOLD" "$*" "$RESET" >&2; exit 1; }
section() { printf '\n%s── %s ──%s\n' "$BOLD$CYAN" "$*" "$RESET"; }
ok()      { printf '%s✓ %s%s\n' "$GREEN" "$*" "$RESET"; }
warn()    { printf '%s! %s%s\n' "$YELLOW" "$*" "$RESET" >&2; }

# Discard input already waiting on the terminal (e.g. the tail of a multi-line
# paste) so it can't be taken as the answer to the next prompt.
drain_stdin() {
  [[ -t 0 ]] || return 0
  local _discard
  while read -r -t 0.05 _discard; do :; done
}

prompt() {
  local msg="$1" default="${2:-}" answer
  drain_stdin
  if [[ -n "$default" ]]; then
    printf '%s%s%s %s[%s]%s: ' "$BOLD$YELLOW" "$msg" "$RESET" "$DIM" "$default" "$RESET" >&2
  else
    printf '%s%s%s: ' "$BOLD$YELLOW" "$msg" "$RESET" >&2
  fi
  read -r answer
  echo "${answer:-${default}}"
}

confirm() {
  local answer
  drain_stdin
  printf '%s%s%s [Y/n]: ' "$BOLD$YELLOW" "$*" "$RESET" >&2
  read -r answer
  case "$answer" in
    [nN]|[nN][oO]) return 1 ;;
    *) return 0 ;;
  esac
}

# confirm_no <question> — like confirm, but defaults to no
confirm_no() {
  local answer
  drain_stdin
  printf '%s%s%s [y/N]: ' "$BOLD$YELLOW" "$*" "$RESET" >&2
  read -r answer
  case "$answer" in
    [yY]|[yY][eE][sS]) return 0 ;;
    *) return 1 ;;
  esac
}

# Run a command in the background with a spinner. Stdout/stderr captured to
# /tmp/dev-env-spinner-{out,err}.txt; returns the command's exit status.
run_with_spinner() {
  local msg="$1"; shift
  local frames=('⠋' '⠙' '⠹' '⠸' '⠼' '⠴' '⠦' '⠧' '⠇' '⠏')
  "$@" >/tmp/dev-env-spinner-out.txt 2>/tmp/dev-env-spinner-err.txt &
  local pid=$! i=0
  while kill -0 "$pid" 2>/dev/null; do
    printf '\r  %s%s%s %s' "$CYAN" "${frames[$((i % 10))]}" "$RESET" "$msg" >&2
    sleep 0.1
    i=$((i + 1))
  done
  printf '\033[2K\r' >&2
  wait "$pid"
}

# ─── Bitbucket credentials ────────────────────────────────────────────────────

BB_WORKSPACE="" BB_EMAIL="" BB_TOKEN=""

load_credentials() {
  [[ -f "$CONFIG" ]] || return 1
  BB_WORKSPACE=$(grep '^workspace:' "$CONFIG" | awk '{print $2}')
  BB_EMAIL=$(grep '^email:'     "$CONFIG" | awk '{print $2}')
  BB_TOKEN=$(grep '^api_token:' "$CONFIG" | awk '{print $2}')
  [[ -n "$BB_WORKSPACE" && -n "$BB_EMAIL" && -n "$BB_TOKEN" ]]
}

ensure_credentials() {
  load_credentials && return 0
  section "Bitbucket Credentials"
  echo "Note: Use an API token (not an app password)."
  echo "Generate one at: https://id.atlassian.com/manage-profile/security/api-tokens"
  echo ""
  local default_email
  default_email=$(git config user.email 2>/dev/null || echo "")
  BB_WORKSPACE=$(prompt "Workspace slug")
  BB_EMAIL=$(prompt "Atlassian account email" "$default_email")
  BB_TOKEN=$(prompt "API token")
  echo ""
  echo "  workspace: $BB_WORKSPACE"
  echo "  email:     $BB_EMAIL"
  echo "  token:     ${BB_TOKEN:0:6}…"
  confirm "Save to $CONFIG?" || die "Aborted."
  mkdir -p "$(dirname "$CONFIG")"
  printf 'workspace: %s\nemail: %s\napi_token: %s\n' \
    "$BB_WORKSPACE" "$BB_EMAIL" "$BB_TOKEN" > "$CONFIG"
  ok "Saved to $CONFIG"
}

get_workspace() {
  local ws=""
  [[ -f "$CONFIG" ]] && ws=$(grep '^workspace:' "$CONFIG" | awk '{print $2}')
  [[ -n "$ws" ]] || die "No Bitbucket workspace set: add 'workspace: <slug>' to $CONFIG"
  echo "$ws"
}

# ─── repo list cache ──────────────────────────────────────────────────────────

fetch_repo_list() {
  local refresh="${1:-0}"
  mkdir -p "$(dirname "$CACHE_FILE")"
  if [[ "$refresh" -eq 0 && -f "$CACHE_FILE" && -s "$CACHE_FILE" \
        && -n $(find "$CACHE_FILE" -mmin "-$CACHE_TTL_MINS" 2>/dev/null) ]]; then
    ok "Using cached repo list ($(grep -c . "$CACHE_FILE") repos, refresh with --refresh)"
    return 0
  fi
  ensure_credentials
  if ! run_with_spinner "Fetching repos…" \
      "$SELF_DIR/scripts/fetch-repos.sh" "$BB_WORKSPACE" "$BB_EMAIL" "$BB_TOKEN"; then
    cat /tmp/dev-env-spinner-err.txt >&2
    die "API request failed — check credentials in $CONFIG"
  fi
  cp /tmp/dev-env-spinner-out.txt "$CACHE_FILE"
  ok "Found $(grep -c . "$CACHE_FILE") repos."
}

# ─── clone discovery ──────────────────────────────────────────────────────────

declare -A CLONE_INDEX=()

slug_from_path() {
  local dir="$1" url
  if url=$(git -C "$dir" remote get-url origin 2>/dev/null) && [[ -n "$url" ]]; then
    url="${url%/}"
    url="${url%.git}"
    basename "$url"
  else
    basename "$dir"
  fi
}

# is_skipped_repo <folder name> — whether discovery ignores it (SKIP_REPOS)
is_skipped_repo() {
  local pattern
  for pattern in $SKIP_REPOS; do
    # shellcheck disable=SC2053  # the pattern is a glob on purpose
    [[ "$1" == $pattern ]] && return 0
  done
  return 1
}

build_clone_index() {
  CLONE_INDEX=()
  local gitdir dir base slug
  while IFS= read -r gitdir; do
    dir="${gitdir%/.git}"
    [[ "$dir" == "$SELF_DIR" || "$dir" == "$SELF_DIR"/* ]] && continue
    base=$(basename "$dir")
    is_skipped_repo "$base" && continue
    slug=$(slug_from_path "$dir")
    [[ -z "$slug" ]] && continue
    if [[ -n "${CLONE_INDEX[$slug]:-}" ]]; then
      CLONE_INDEX[$slug]+=$'\n'"$dir"
    else
      CLONE_INDEX[$slug]="$dir"
    fi
  done < <(find "$REPO_ROOT" -maxdepth 4 -name .git -type d -prune -print 2>/dev/null)
}

choose_clone_path() {
  local slug="$1"; shift
  local -a paths=("$@")
  warn "Multiple clones found for '$slug':"
  local -a display=()
  local p branch dirty
  for p in "${paths[@]}"; do
    branch=$(git -C "$p" rev-parse --abbrev-ref HEAD 2>/dev/null || echo '?')
    if [[ -n $(git -C "$p" status --porcelain 2>/dev/null) ]]; then
      dirty="dirty"
    else
      dirty="clean"
    fi
    display+=("$p"$'\t'"[$branch, $dirty]")
  done
  local choice
  if command -v fzf &>/dev/null; then
    choice=$(printf '%s\n' "${display[@]}" | fzf --no-multi \
      --prompt="[$slug] Choose the clone to link: " \
      --height="$((${#display[@]} + 3))" \
      --layout=reverse) || return 1
    printf '%s\n' "${choice%%$'\t'*}"
  else
    local i=1 d
    for d in "${display[@]}"; do
      printf '  %d) %s  %s\n' "$i" "${d%%$'\t'*}" "${d#*$'\t'}" >&2
      i=$((i + 1))
    done
    local n
    n=$(prompt "Which clone for '$slug'?" "1")
    if [[ ! "$n" =~ ^[0-9]+$ || "$n" -lt 1 || "$n" -gt ${#paths[@]} ]]; then
      warn "Invalid choice for '$slug'."
      return 1
    fi
    printf '%s\n' "${paths[$((n - 1))]}"
  fi
}

resolve_clone() {
  local slug="$1"
  local -a paths=()
  if [[ -n "${CLONE_INDEX[$slug]:-}" ]]; then
    local p
    while IFS= read -r p; do paths+=("$p"); done <<< "${CLONE_INDEX[$slug]}"
  fi
  case ${#paths[@]} in
    0)
      local dest="$REPO_ROOT/$slug"
      echo "  Cloning $slug -> $dest" >&2
      if ! git clone "git@bitbucket.org:$(get_workspace)/${slug}.git" "$dest" >&2; then
        warn "Clone failed: $slug"
        confirm "Skip $slug and continue?" || die "Aborted."
        return 1
      fi
      printf '%s\n' "$dest"
      ;;
    1)
      printf '%s\n' "${paths[0]}"
      ;;
    *)
      choose_clone_path "$slug" "${paths[@]}"
      ;;
  esac
}

# ─── slot path helpers ────────────────────────────────────────────────────────

slot_dir()      { printf '%s/slots/%s\n' "$SELF_DIR" "$1"; }
state_file()    { printf '%s/.active-env-%s\n' "$SELF_DIR" "$1"; }
worktree_path() { printf '%s/%s/%s\n' "$WORKTREES_ROOT" "$1" "$2"; }

# Print active slot names, one per line. The shared slot isn't one: it holds
# tools rather than the work a slot is for.
list_active_slots() {
  local f slot
  shopt -s nullglob
  for f in "$SELF_DIR"/.active-env-*; do
    slot="${f##*/.active-env-}"
    [[ "$slot" == "$SHARED_SLOT" ]] || printf '%s\n' "$slot"
  done
}

# ─── worktree management ──────────────────────────────────────────────────────

# feature_branch_name <feature> — the branch every worktree in a slot uses.
feature_branch_name() { printf 'feature/%s/feature\n' "$1"; }

# is_base_branch <branch> — whether <branch> matches a BASE_BRANCHES glob
# (case-insensitive; '*/devready' matches 'candidate/DevReady')
is_base_branch() {
  local pattern rc=1
  shopt -s nocasematch
  for pattern in $BASE_BRANCHES; do
    # shellcheck disable=SC2053  # the pattern is a glob on purpose
    [[ "$1" == $pattern ]] && { rc=0; break; }
  done
  shopt -u nocasematch
  return $rc
}

# find_base_ref <clone>
# Prints the ref a new feature branch should start from: whichever branch
# matching BASE_BRANCHES (setting 'base_branches', default 'main master') was
# committed to most recently. Remote branches are preferred; local ones are used
# when the remote has none. Falls back to the clone's current branch.
find_base_ref() {
  local clone="$1" ref
  while IFS= read -r ref; do
    [[ "$ref" == origin/HEAD ]] && continue
    is_base_branch "${ref#origin/}" && { printf '%s\n' "$ref"; return 0; }
  done < <(git -C "$clone" for-each-ref --sort=-committerdate \
             --format='%(refname:short)' refs/remotes/origin 2>/dev/null)
  while IFS= read -r ref; do
    is_base_branch "$ref" && { printf '%s\n' "$ref"; return 0; }
  done < <(git -C "$clone" for-each-ref --sort=-committerdate \
             --format='%(refname:short)' refs/heads 2>/dev/null)
  git -C "$clone" rev-parse --abbrev-ref HEAD 2>/dev/null || printf 'HEAD\n'
}

# Create a git worktree for <slug> in <slot>, sourced from <clone>, on
# <branch> (normally feature/<name>/feature). An existing local branch is
# reused; one that exists only on origin is checked out tracking it; otherwise
# it is created from find_base_ref without tracking, so a push can never land on
# the base branch. Prompts for another name only if that fails. Prints the
# worktree path on success; returns 1 on failure.
create_worktree() {
  local slot="$1" slug="$2" clone="$3" new_branch="$4"
  local wt_path base real_clone err
  wt_path=$(worktree_path "$slot" "$slug")

  # Resolve through symlinks so git worktree operates on the real repo root.
  real_clone=$(git -C "$clone" rev-parse --show-toplevel 2>/dev/null || printf '%s' "$clone")

  if [[ -e "$wt_path" ]]; then
    warn "Worktree path already exists: $wt_path"
    confirm "Remove and recreate?" || { warn "Skipped: $slug"; return 1; }
    git -C "$real_clone" worktree remove --force "$wt_path" 2>/dev/null || rm -rf "$wt_path"
  fi

  mkdir -p "$(dirname "$wt_path")"

  git -C "$real_clone" fetch --quiet --prune origin 2>/dev/null ||
    warn "Could not fetch origin for '$slug' — using local refs"

  if git -C "$real_clone" show-ref --verify --quiet "refs/heads/$new_branch"; then
    base="$new_branch"
  elif git -C "$real_clone" show-ref --verify --quiet "refs/remotes/origin/$new_branch"; then
    base="origin/$new_branch"
  else
    base=$(find_base_ref "$real_clone")
  fi

  while true; do
    if err=$(_worktree_add "$real_clone" "$wt_path" "$new_branch" "$base" 2>&1); then
      ok "$slug: $new_branch (from $base)" >&2
      printf '%s\n' "$wt_path"
      return 0
    fi
    warn "Could not create worktree for '$slug' on branch '$new_branch':"
    printf '%s\n' "$err" | sed 's/^/    /' >&2
    new_branch=$(prompt "Branch name for '$slug' (branching from '$base'; empty to skip)" "")
    [[ -z "$new_branch" ]] && { warn "Skipped: $slug"; return 1; }
    until git check-ref-format --branch "$new_branch" &>/dev/null; do
      warn "'$new_branch' is not a valid branch name."
      new_branch=$(prompt "Branch name for '$slug' (empty to skip)" "")
      [[ -z "$new_branch" ]] && { warn "Skipped: $slug"; return 1; }
    done
  done
}

# create_shared_worktree <slug> <clone> — a worktree for a shared tool, detached
# at the latest base (find_base_ref) so it never holds a branch another worktree
# needs. Prints the worktree path on success.
create_shared_worktree() { create_detached_worktree "$SHARED_SLOT" "$1" "$2"; }

# create_detached_worktree <slot> <slug> <clone> — a worktree detached at the
# latest base (shared tools, and reference repos in a slot). Prints its path.
create_detached_worktree() {
  local slot="$1" slug="$2" clone="$3" wt_path real_clone base
  wt_path=$(worktree_path "$slot" "$slug")
  real_clone=$(git -C "$clone" rev-parse --show-toplevel 2>/dev/null || printf '%s' "$clone")
  [[ -e "$wt_path" ]] && { warn "Already exists: $wt_path"; return 1; }
  mkdir -p "$(dirname "$wt_path")"
  git -C "$real_clone" fetch --quiet --prune origin 2>/dev/null ||
    warn "Could not fetch origin for '$slug' — using local refs"
  base=$(find_base_ref "$real_clone")
  git -C "$real_clone" worktree add --quiet --detach "$wt_path" "$base" >&2 || return 1
  ok "$slug: $base ($(git -C "$wt_path" rev-parse --short HEAD))" >&2
  printf '%s\n' "$wt_path"
}

# _worktree_add <clone> <path> <branch> [<start-point>]
# Checks out <branch> at <path>. With <start-point>, creates <branch> from it
# if it doesn't exist yet — tracking it only when the start point is the same
# branch on origin. Git's error output goes to stderr.
_worktree_add() {
  local clone="$1" path="$2" branch="$3" start="${4:-}" out track="--no-track"
  [[ "$start" == "origin/$branch" ]] && track="--track"
  if [[ -n "$start" ]] && ! git -C "$clone" show-ref --verify --quiet "refs/heads/$branch"; then
    out=$(git -C "$clone" worktree add "$track" -b "$branch" "$path" "$start" 2>&1)
  else
    out=$(git -C "$clone" worktree add "$path" "$branch" 2>&1)
  fi || { printf '%s\n' "$out" | grep -E '^(fatal|error):' >&2; return 1; }
}

# ─── repo type detection ──────────────────────────────────────────────────────

# Prints one of: java | expo | react-web | npm | unknown
detect_repo_type() {
  local path="$1"
  if [[ -f "$path/package.json" ]]; then
    if grep -q '"expo"' "$path/package.json" 2>/dev/null; then
      printf 'expo\n'
    elif grep -qE '"react-scripts"|"vite"' "$path/package.json" 2>/dev/null; then
      printf 'react-web\n'
    else
      printf 'npm\n'
    fi
  elif [[ -f "$path/gradlew" || -f "$path/build.gradle" ]]; then
    printf 'java\n'
  else
    printf 'unknown\n'
  fi
}

# ─── tmuxinator ───────────────────────────────────────────────────────────────

# Optional per-slot tmux customisations, kept outside the repo so they survive
# regeneration of the tmuxinator config. Tab-separated lines:
#   pane<TAB><window><TAB><2|3><TAB><command>   replace a repo window's top (2)
#                                               or bottom (3) pane; '-' = empty
#   window<TAB><name><TAB><dir><TAB><command>   add a window before 'environment'
# Lines starting with '#' are ignored.
tmux_overrides_file() { printf '%s/.config/dev-env/tmux-overrides/%s.tsv\n' "$HOME" "$1"; }

# yaml_quote <string> — single-quoted YAML scalar.
yaml_quote() { printf "'%s'" "${1//\'/\'\'}"; }

# npm_dev_command <path> — 'npm start' when package.json has a start script,
# otherwise 'npm run dev' (e.g. Vite apps that only define dev).
npm_dev_command() {
  if grep -qE '"start"[[:space:]]*:' "$1/package.json" 2>/dev/null; then
    printf 'npm start\n'
  else
    printf 'npm run dev\n'
  fi
}

# ─── repo kits ────────────────────────────────────────────────────────────────
#
# ~/.config/dev-env/repos/<repo>/ holds what a fresh worktree of <repo> needs to
# run locally, for every slot:
#   panes.tsv    '2<TAB>command' / '3<TAB>command' — the window's run and test
#                panes, replacing the repo-type defaults ('-' = empty)
#   files/...    gitignored local files (config.yml, public/keycloak.json, ...).
#                Each is symlinked into the worktree at the same path, so one
#                copy serves every slot; a file ending .tmpl is rendered instead,
#                with {{slot}}, {{worktree}} and {{url:<repo>|<default>}}
#                (<repo>'s hostname in the slot, else in the shared tools, else
#                <default>) filled in.

# kit_url <slot> <repo> <default> — where another app is reachable from <slot>
kit_url() {
  local slot="$1" repo="$2" default="$3"
  if slot_has_repo "$slot" "$repo"; then
    printf 'http://%s\n' "$(slot_hostname "$slot" "$repo")"
  elif [[ "$slot" != "$SHARED_SLOT" ]] && slot_has_repo "$SHARED_SLOT" "$repo"; then
    printf 'http://%s\n' "$(slot_hostname "$SHARED_SLOT" "$repo")"
  else
    printf '%s\n' "$default"
  fi
}

slot_has_repo() {
  local sf
  sf=$(state_file "$1")
  [[ -f "$sf" ]] && awk -F'\t' -v r="$2" 'NF >= 6 && $2 == r && $5 != "reference" { found = 1 } END { exit !found }' "$sf"
}

# render_kit_template <slot> <worktree> <src> <dest>
render_kit_template() {
  local slot="$1" wt_path="$2" src="$3" dest="$4" content token spec repo default
  content=$(<"$src")
  content="${content//\{\{slot\}\}/$slot}"
  content="${content//\{\{worktree\}\}/$wt_path}"
  while IFS= read -r token; do
    [[ -n "$token" ]] || continue
    spec="${token#\{\{url:}" spec="${spec%\}\}}"
    repo="${spec%%|*}" default=""
    [[ "$spec" == *"|"* ]] && default="${spec#*|}"
    content="${content//"$token"/$(kit_url "$slot" "$repo" "$default")}"
  done < <(grep -o '{{url:[^}]*}}' "$src" | sort -u)
  printf '%s\n' "$content" > "$dest"
}

# apply_repo_kit <slot> <slug> <worktree> — puts the repo kit's files in place.
# Files the worktree already has are left alone, except committed placeholders
# that were never filled in.
apply_repo_kit() {
  local slot="$1" slug="$2" wt_path="$3" files rel dest
  files="$REPO_KITS_DIR/$slug/files"
  [[ -d "$files" ]] || return 0
  while IFS= read -r rel; do
    rel="${rel#./}"
    dest="$wt_path/${rel%.tmpl}"
    local replace_tracked=0
    if [[ -e "$dest" || -L "$dest" ]]; then
      # A committed placeholder (blank values) is replaced, and git told to
      # ignore the local change so it never gets committed. Anything else is
      # the worktree's own and stays.
      if git -C "$wt_path" ls-files --error-unmatch "${rel%.tmpl}" &>/dev/null &&
         config_looks_unfilled "$dest"; then
        rm -f "$dest"
        replace_tracked=1
      else
        warn "$slug: ${rel%.tmpl} already exists, leaving it"
        continue
      fi
    fi
    mkdir -p "$(dirname "$dest")"
    if [[ "$rel" == *.tmpl ]]; then
      render_kit_template "$slot" "$wt_path" "$files/$rel" "$dest"
    else
      ln -s "$files/$rel" "$dest"
    fi
    [[ "$replace_tracked" -eq 1 ]] && git -C "$wt_path" update-index --skip-worktree "${rel%.tmpl}"
    ok "$slug: ${rel%.tmpl} from its kit" >&2
  done < <(cd "$files" && find . \( -type f -o -type l \) | sort)
}

# config_looks_unfilled <file> — true for a local config that exists but was
# never filled in: placeholder markers (GOES-HERE, CHANGE-ME, ...), or a JSON
# file whose values are mostly empty. Some repos commit blank placeholders for
# the files their templates describe.
config_looks_unfilled() {
  local file="$1"
  [[ -f "$file" ]] || return 1
  grep -q -i -E '(GOES|GO)[-_ ]HERE|CHANGE[-_ ]?ME|REPLACE[-_ ]?ME|FILL[-_ ]?ME' "$file" && return 0
  [[ "$file" == *.json ]] || return 1
  python3 -I - "$file" << 'PY'
import json, sys
try:
    data = json.load(open(sys.argv[1]))
except Exception:
    sys.exit(1)
leaves = []
def walk(node):
    if isinstance(node, dict):
        for value in node.values():
            walk(value)
    elif isinstance(node, list):
        for value in node:
            walk(value)
    else:
        leaves.append(node)
walk(data)
strings = [leaf for leaf in leaves if isinstance(leaf, str)]
empty = [leaf for leaf in strings if not leaf.strip()]
# Unfilled when most of its text values are blank
sys.exit(0 if strings and len(empty) * 2 >= len(strings) else 1)
PY
}

# repo_setup_gaps <slug> <worktree> <category> — prints why a repo without a kit
# probably can't run from a fresh worktree yet, one reason per line; nothing if
# it has a kit (even an empty one: that marks it as needing nothing).
repo_setup_gaps() {
  local slug="$1" wt_path="$2" category="$3" template target
  [[ -d "$REPO_KITS_DIR/$slug" ]] && return 0
  # Committed config templates whose local copy doesn't exist (template_config.yml,
  # public/config-template.json, example-config.json, config.yml.sample, ...)
  while IFS= read -r template; do
    target=$(printf '%s' "$template" | sed -E 's#(^|/)(template|example|sample)[_-]#\1#; s#[-_.](template|example|sample)(\.)#\2#; s#\.(sample|dist|example)$##')
    if [[ ! -e "$wt_path/$target" ]]; then
      printf 'no local %s (template: %s)\n' "$target" "$template"
    elif config_looks_unfilled "$wt_path/$target"; then
      printf '%s has no real values yet (template: %s)\n' "$target" "$template"
    fi
  done < <(git -C "$wt_path" ls-files 2>/dev/null |
    grep -v -E 'node_modules|(^|/)(src|test|tests|e2e|docs?)/' |
    grep -E '\.(json|ya?ml|properties|env|config|conf|xml|ini)(\.(sample|dist|example))?$|\.(sample|dist|example)$' |
    grep -i -E '(^|/)(template|example|sample)[_-]|[-_.](template|example|sample)[._]|\.(sample|dist|example)$')
  # A server only builds with the Java defaults; something has to say how to run it
  if [[ "$category" == "servers" && "$(detect_repo_type "$wt_path")" == "java" ]]; then
    printf 'no run command (the default only runs ./gradlew build)\n'
  fi
}

# slot_setup_gaps <slot> — "<slug>\t<reason>" for each reason each of the slot's
# repos isn't set up to run
slot_setup_gaps() {
  local slot="$1" cat slug link wt_path link_type canonical reason
  [[ -f "$(state_file "$slot")" ]] || return 0
  while IFS=$'\t' read -r cat slug link wt_path link_type canonical; do
    [[ "$cat" == *=* || -z "$link" || -z "$wt_path" || "$link_type" == reference ]] && continue
    while IFS= read -r reason; do
      [[ -n "$reason" ]] && printf '%s\t%s\n' "$slug" "$reason"
    done < <(repo_setup_gaps "$slug" "$wt_path" "$cat")
  done < "$(state_file "$slot")"
}

# setup_prompt <slot> — the first message for the slot's Claude when some of its
# repos, or the shared tools, aren't set up; empty when they all are
setup_prompt() {
  local slot="$1" repos shared=""
  repos=$(slot_setup_gaps "$slot" | cut -f1 | awk '!seen[$0]++' | paste -sd, - | sed 's/,/, /g')
  [[ "$slot" != "$SHARED_SLOT" ]] &&
    shared=$(slot_setup_gaps "$SHARED_SLOT" | cut -f1 | awk '!seen[$0]++' | paste -sd, - | sed 's/,/, /g')
  [[ -n "$repos" || -n "$shared" ]] || return 0
  printf 'Some repos are not set up to run locally yet'
  [[ -n "$repos" ]] && printf ' (in this dev-env slot: %s)' "$repos"
  [[ -n "$shared" ]] && printf '%s(in the shared tools: %s)' "${repos:+ }" "$shared"
  printf '. Help me set them up as repo kits, one repo at a time, following "Repos that need setting up" in CLAUDE.md. '
  printf 'Start by telling me what each one is missing and what you need from me.'
}

# apply_repo_kits <slot> — applies every repo's kit in the slot (once the slot's
# state is written, so {{url:...}} can see the whole slot)
apply_repo_kits() {
  local slot="$1" cat slug link wt_path link_type canonical
  while IFS=$'\t' read -r cat slug link wt_path link_type canonical; do
    [[ "$cat" == *=* || -z "$link" || -z "$wt_path" || "$link_type" == reference ]] && continue
    apply_repo_kit "$slot" "$slug" "$wt_path"
  done < "$(state_file "$slot")"
}

# repo_pane_commands <slot> <slug> <path> — sets PANE_TOP and PANE_BOTTOM to the
# commands for a repo window's right-hand panes: the defaults for its repo type,
# replaced by any 'pane' lines in the slot's tmux overrides.
repo_pane_commands() {
  local slot="$1" slug="$2" wt_path="$3" overrides
  case "$(detect_repo_type "$wt_path")" in
    java)
      PANE_TOP='./gradlew build'
      PANE_BOTTOM='./gradlew test --continuous'
      ;;
    expo)
      PANE_TOP='npm install && npx expo start'
      PANE_BOTTOM='npx jest --watchAll'
      ;;
    react-web)
      PANE_TOP="npm install && $(npm_dev_command "$wt_path")"
      PANE_BOTTOM='npm test'
      ;;
    npm)
      PANE_TOP='npm install'
      PANE_BOTTOM='npm test -- --watch'
      ;;
    *)
      PANE_TOP=''
      PANE_BOTTOM=''
      ;;
  esac
  # The repo's kit says how to run it anywhere; a slot's overrides win over that
  local kit_panes="$REPO_KITS_DIR/$slug/panes.tsv" k_pane k_cmd
  if [[ -f "$kit_panes" ]]; then
    while IFS=$'\t' read -r k_pane k_cmd; do
      [[ "$k_cmd" == "-" ]] && k_cmd=''
      case "$k_pane" in
        2) PANE_TOP="$k_cmd" ;;
        3) PANE_BOTTOM="$k_cmd" ;;
      esac
    done < <(grep -v '^#' "$kit_panes")
  fi
  overrides=$(tmux_overrides_file "$slot")
  if [[ -f "$overrides" ]]; then
    local o_type o_name o_arg o_cmd
    while IFS=$'\t' read -r o_type o_name o_arg o_cmd; do
      [[ "$o_type" == "pane" && "$o_name" == "$slug" ]] || continue
      [[ "$o_cmd" == "-" ]] && o_cmd=''
      case "$o_arg" in
        2) PANE_TOP="$o_cmd" ;;
        3) PANE_BOTTOM="$o_cmd" ;;
      esac
    done < <(grep -v '^#' "$overrides")
  fi
}

# ensure_hosts_window <slot> — adds the hostname watcher window to the slot's
# running session if it has none (sessions started before it existed)
ensure_hosts_window() {
  local slot="$1"
  tmux has-session -t "$slot" 2>/dev/null || return 0
  tmux list-windows -t "$slot" -F '#W' | grep -qx hosts && return 0
  if tmux list-windows -t "$slot" -F '#W' | grep -qx environment; then
    tmux new-window -d -b -t "$slot:environment" -n hosts -c "$SELF_DIR"
  else
    tmux new-window -d -t "$slot:" -n hosts -c "$SELF_DIR"
  fi
  tmux send-keys -t "$slot:hosts" "$SELF_DIR/env.sh hosts $slot --watch --open" Enter
}

# tmux_send_if_idle <target-pane> <command> — runs the command in a pane only if
# the pane is sitting at a shell prompt, so a running app is never disturbed
tmux_send_if_idle() {
  local target="$1" command="$2" current
  [[ -n "$command" ]] || return 0
  current=$(tmux display-message -p -t "$target" '#{pane_current_command}' 2>/dev/null) || return 0
  case "$current" in
    zsh|bash|sh|fish|-zsh|-bash) tmux send-keys -t "$target" "$command" Enter ;;
  esac
}

# tmux_run_slot_apps <slot> — in the slot's running session, starts each
# window's run and test commands and the hostname watcher wherever the pane is
# idle (e.g. a session opened with --idle).
tmux_run_slot_apps() {
  local slot="$1" base cat slug link wt_path link_type canonical overrides
  local o_type o_name o_arg o_cmd
  base=$(tmux show-options -gv pane-base-index 2>/dev/null || echo 0)
  while IFS=$'\t' read -r cat slug link wt_path link_type canonical; do
    [[ "$cat" == *=* || -z "$link" || -z "$wt_path" || "$link_type" == reference ]] && continue
    repo_pane_commands "$slot" "$slug" "$wt_path"
    tmux_send_if_idle "$slot:$slug.$((base + 1))" "$PANE_TOP"
    tmux_send_if_idle "$slot:$slug.$((base + 2))" "$PANE_BOTTOM"
  done < "$(state_file "$slot")"
  overrides=$(tmux_overrides_file "$slot")
  if [[ -f "$overrides" ]]; then
    while IFS=$'\t' read -r o_type o_name o_arg o_cmd; do
      [[ "$o_type" == "window" && -n "$o_name" && "$o_cmd" != "-" ]] || continue
      tmux_send_if_idle "$slot:$o_name.$base" "$o_cmd"
    done < <(grep -v '^#' "$overrides")
  fi
  # A new hosts window starts its watcher itself; an existing idle one needs it sent
  if tmux list-windows -t "$slot" -F '#W' | grep -qx hosts; then
    tmux_send_if_idle "$slot:hosts.$base" "$SELF_DIR/env.sh hosts $slot --watch --open"
  else
    ensure_hosts_window "$slot"
  fi
}

# tmux_add_repo_window <session> <slot> <slug> <path> — adds a repo window to a
# running session, laid out and started like the tmuxinator one.
tmux_add_repo_window() {
  local session="$1" slot="$2" slug="$3" wt_path="$4" base
  repo_pane_commands "$slot" "$slug" "$wt_path"
  # Before the environment window when there is one, so it stays last
  if tmux list-windows -t "$session" -F '#W' | grep -qx environment; then
    tmux new-window -b -t "$session:environment" -n "$slug" -c "$wt_path"
  else
    tmux new-window -t "$session:" -n "$slug" -c "$wt_path"
  fi
  base=$(tmux show-options -gv pane-base-index 2>/dev/null || echo 0)
  local editor
  editor=$(editor_command)
  [[ -n "$editor" ]] && tmux send-keys -t "$session:$slug.$base" "$editor" Enter
  tmux split-window -h -t "$session:$slug" -c "$wt_path"
  [[ -n "$PANE_TOP" ]] && tmux send-keys -t "$session:$slug.$((base + 1))" "$PANE_TOP" Enter
  tmux split-window -v -t "$session:$slug.$((base + 1))" -c "$wt_path"
  [[ -n "$PANE_BOTTOM" ]] && tmux send-keys -t "$session:$slug.$((base + 2))" "$PANE_BOTTOM" Enter
  tmux select-layout -t "$session:$slug" main-vertical >/dev/null
}

# ensure_slot_plans <slot> — plans/<slot>/ in this repo (gitignored, kept when
# the slot is deactivated), linked into the slot as slots/<slot>/plans
ensure_slot_plans() {
  local slot="$1" link
  [[ "$slot" != "$SHARED_SLOT" ]] || return 0
  mkdir -p "$SELF_DIR/plans/$slot"
  link="$(slot_dir "$slot")/plans"
  if [[ -d "$link" && ! -L "$link" ]]; then
    # An older slot with its own plans folder: move its notes across first
    mv -n "$link"/* "$link"/.[!.]* "$SELF_DIR/plans/$slot/" 2>/dev/null
    rmdir "$link" 2>/dev/null || { warn "Couldn't move everything out of $link; left it in place"; return 0; }
  fi
  ln -sfn "../../plans/$slot" "$link"
}

# write_slot_claude_md <slot> — slots/<slot>/CLAUDE.md, telling the Claude in
# the slot's environment window which slot it's in and how to run it (the repo's
# own CLAUDE.md, loaded too, explains dev-env in general)
write_slot_claude_md() {
  local slot="$1" sf feature env cat slug link wt_path link_type canonical
  sf=$(state_file "$slot")
  [[ -f "$sf" && "$slot" != "$SHARED_SLOT" ]] || return 0
  feature=$(grep '^feature=' "$sf" | cut -d= -f2-)
  env="$SELF_DIR/env.sh"
  ensure_slot_plans "$slot"
  {
    printf '# Slot: %s\n\n' "$slot"
    printf 'You are in dev-env slot **%s**' "$slot"
    [[ -n "$feature" ]] && printf ', on branch `%s` in every repo it works on' "$(feature_branch_name "$feature")"
    printf '. Its section in ACTIVE.md says what the work is.\n\n'
    printf 'Generated by env.sh; edits are overwritten.\n\n'
    printf '## Commands\n\n'
    printf -- '- Start everything (apps, hostnames, browser tabs): `%s start %s`\n' "$env" "$slot"
    printf -- '- Status, branches and hostnames: `%s status %s`\n' "$env" "$slot"
    printf -- '- Open the apps in the browser again: `%s open %s` (add `--all` for servers)\n' "$env" "$slot"
    printf -- '- Refresh hostnames now: `%s hosts %s`\n' "$env" "$slot"
    printf -- '- Shared tools (outside any slot): `%s shared`\n' "$env"
    printf -- '- Add a repo to read, not change: `%s ref add %s <repo>...` (see Reference repos)\n\n' "$env" "$slot"
    printf '## tmux session `%s`\n\n' "$slot"
    printf 'One window per repo (editor | run pane top right | test pane bottom right),\n'
    printf 'then `hosts` (the hostname watcher) and `environment` (you).\n'
    printf 'Target panes as `%s:<window>.<pane>`; in zsh, write `"${var}:<window>"`, never `"$var:<window>"`.\n\n' "$slot"
    printf '| Window | Worktree | Run pane | Test pane |\n|---|---|---|---|\n'
    while IFS=$'\t' read -r cat slug link wt_path link_type canonical; do
      [[ "$cat" == *=* || -z "$link" || -z "$wt_path" || "$link_type" == reference ]] && continue
      repo_pane_commands "$slot" "$slug" "$wt_path"
      printf '| %s | `%s` | %s | %s |\n' "$slug" "$wt_path" \
        "${PANE_TOP:+\`${PANE_TOP//|/\\|}\`}" "${PANE_BOTTOM:+\`${PANE_BOTTOM//|/\\|}\`}"
    done < "$sf"
    local gaps shared_gaps
    gaps=$(slot_setup_gaps "$slot")
    shared_gaps=$(slot_setup_gaps "$SHARED_SLOT")
    if [[ -n "$gaps" || -n "$shared_gaps" ]]; then
      printf '\n## Repos that need setting up\n\n'
      printf 'These repos have no repo kit and look like they can'"'"'t run from a fresh\n'
      printf 'worktree yet. `%s kits %s` (or `kits %s`) rechecks.\n\n' "$env" "$slot" "$SHARED_SLOT"
      local g_slug g_reason
      if [[ -n "$gaps" ]]; then
        printf 'In this slot:\n\n'
        while IFS=$'\t' read -r g_slug g_reason; do
          printf -- '- **%s**: %s\n' "$g_slug" "$g_reason"
        done <<< "$gaps"
        printf '\n'
      fi
      if [[ -n "$shared_gaps" ]]; then
        printf 'In the shared tools (worktrees in `%s/%s/`, tmux session `%s`):\n\n' "$WORKTREES_ROOT" "$SHARED_SLOT" "$SHARED_SLOT"
        while IFS=$'\t' read -r g_slug g_reason; do
          printf -- '- **%s**: %s\n' "$g_slug" "$g_reason"
        done <<< "$shared_gaps"
        printf '\n'
      fi
      printf '\nFor each repo, one at a time:\n\n'
      printf '1. Work out what it needs to run locally: its README, the templates above,\n'
      printf '   how its config is loaded, and what it talks to. Check its build file or\n'
      printf '   scripts for how it'"'"'s started. A template may be optional; check whether\n'
      printf '   the code requires it before asking for values.\n'
      printf '2. Fill in what you can from the local environment:\n'
      printf '   - other repos'"'"' kits are in `%s/` and show how they connect;\n' "$REPO_KITS_DIR"
      if [[ -s "$SETUP_NOTES" ]]; then
        printf '   - the user'"'"'s notes on their local setup (`%s`):\n\n' "$SETUP_NOTES"
        sed 's/^/     /' "$SETUP_NOTES"
        printf '\n'
      else
        printf '   - local services (auth servers, databases): ask the user, then offer to\n'
        printf '     save what they tell you in `%s` for next time.\n\n' "$SETUP_NOTES"
      fi
      printf '   Ask the user for anything only they can know, such as client ids,\n'
      printf '   secrets, or which database to use. Don'"'"'t invent credentials.\n'
      printf '3. Write the kit in `%s/<repo>/`:\n' "$REPO_KITS_DIR"
      printf '   - `files/<path>`: a local file to put in every worktree. Add `.tmpl` to\n'
      printf '     fill in `{{slot}}`, `{{worktree}}` or `{{url:<repo>|<default>}}`.\n'
      printf '   - `panes.tsv`: `2<TAB>run command` and `3<TAB>test command`.\n'
      printf '   - A repo that needs nothing gets an empty kit directory.\n'
      printf '4. Apply it with `%s kits apply %s` (for a shared tool: `kits apply %s`),\n' "$env" "$slot" "$SHARED_SLOT"
      printf '   then run the repo'"'"'s window panes in that session (or `%s start %s`).\n' "$env" "$slot"
      printf '   A config file the repo commits as a blank placeholder is replaced by\n'
      printf '   the kit'"'"'s and hidden from git (skip-worktree), so it can'"'"'t be committed.\n' 
    fi

    local -a refs=()
    local entry
    while IFS=$'\t' read -r cat slug link wt_path link_type canonical; do
      [[ "$link_type" == reference ]] && refs+=("$slug"$'\t'"$wt_path")
    done < "$sf"
    printf '\n## Reference repos\n\n'
    printf 'Repos that are here to read, not to change: how another service calls an\n'
    printf 'API, what a shared library does, an older implementation to follow. They'"'"'re\n'
    printf 'detached at the latest base branch (not the feature branch) and have no tmux\n'
    printf 'window, kit or hostname. Don'"'"'t edit or commit in them; if one needs changing,\n'
    printf 'tell the user so it can become a working repo of the slot.\n\n'
    if [[ ${#refs[@]} -gt 0 ]]; then
      local r_slug r_path
      for entry in "${refs[@]}"; do
        IFS=$'\t' read -r r_slug r_path <<< "$entry"
        printf -- '- **%s**: `%s` (`slots/%s/%s/%s`)\n' "$r_slug" "$r_path" "$slot" "$REFERENCE_CATEGORY" "$r_slug"
      done
      printf '\n'
    else
      printf 'None yet.\n\n'
    fi
    printf 'When the work needs a repo that isn'"'"'t in the slot, add it yourself; it runs\n'
    printf 'without prompts when the repo has one local clone (or none, so it'"'"'s cloned):\n\n'
    printf -- '- `%s ref add %s <repo>...` adds one (its Bitbucket slug, e.g. `api-server`)\n' "$env" "$slot"
    printf -- '- `%s ref update %s` moves them to the latest base branch\n' "$env" "$slot"
    printf -- '- `%s ref remove %s <repo>...` removes one\n' "$env" "$slot"
    printf '\nA clone you only need for a quick look can also just be read from `~/repositories`.\n'

    printf '\n## Plans\n\n'
    printf 'Save plans, findings and other working notes for this slot in `plans/` here\n'
    printf '(a link to `%s/plans/%s/`), with descriptive file names. They'"'"'re gitignored\n' "$SELF_DIR" "$slot"
    printf 'and kept when the slot is deactivated.\n'

    printf '\n## Hostnames\n\n'
    printf 'Each running app is at `http://<repo>.%s.localhost` (the `hosts` window keeps\n' "$slot"
    printf 'them current); `%s status %s` lists the ones that are up.\n' "$env" "$slot"
  } > "$(slot_dir "$slot")/CLAUDE.md"
}

# generate_tmuxinator <slot> [--idle] — with --idle, the session opens with its
# editors and Claude but leaves the run, test and hosts panes as plain shells
# (./env.sh start runs them later).
generate_tmuxinator() {
  local slot="$1" idle=0
  [[ "${2:-}" == "--idle" ]] && idle=1
  local sf config_file overrides
  sf=$(state_file "$slot")
  [[ -f "$sf" ]] || { warn "No active state for slot '$slot'"; return 1; }

  mkdir -p "$TMUXINATOR_DIR"
  config_file="$TMUXINATOR_DIR/${slot}.yml"
  overrides=$(tmux_overrides_file "$slot")

  local editor
  editor=$(editor_command)
  {
    printf 'name: %s\n' "$slot"
    printf 'root: %s\n\n' "$(slot_dir "$slot")"
    printf 'windows:\n'

    local cat slug link wt_path link_type canonical top bottom
    local o_type o_name o_arg o_cmd
    while IFS=$'\t' read -r cat slug link wt_path link_type canonical; do
      [[ "$cat" == *=* || -z "$link" || -z "$wt_path" || "$link_type" == reference ]] && continue
      repo_pane_commands "$slot" "$slug" "$wt_path"
      top="$PANE_TOP" bottom="$PANE_BOTTOM"
      [[ "$idle" -eq 1 ]] && top='' bottom=''
      printf '  - %s:\n' "$slug"
      printf '      layout: main-vertical\n'
      printf '      root: %s\n' "$wt_path"
      printf '      panes:\n'
      if [[ -n "$editor" ]]; then
        printf '        - %s\n' "$(yaml_quote "$editor")"
      else
        printf '        -\n'
      fi
      if [[ -n "$top" ]]; then
        printf '        - %s\n' "$(yaml_quote "$top")"
      else
        printf '        -\n'
      fi
      if [[ -n "$bottom" ]]; then
        printf '        - %s\n' "$(yaml_quote "$bottom")"
      else
        printf '        -\n'
      fi
    done < "$sf"

    if [[ -f "$overrides" ]]; then
      while IFS=$'\t' read -r o_type o_name o_arg o_cmd; do
        [[ "$o_type" == "window" && -n "$o_name" ]] || continue
        printf '  - %s:\n' "$o_name"
        printf '      root: %s\n' "${o_arg/#\~/$HOME}"
        printf '      panes:\n'
        if [[ "$idle" -eq 0 && -n "$o_cmd" && "$o_cmd" != "-" ]]; then
          printf '        - %s\n' "$(yaml_quote "$o_cmd")"
        else
          printf '        -\n'
        fi
      done < <(grep -v '^#' "$overrides")
    fi

    # Keeps the slot's hostnames current and opens its tab group once it's up
    printf '  - hosts:\n'
    printf '      root: %s\n' "$SELF_DIR"
    printf '      panes:\n'
    if [[ "$idle" -eq 1 ]]; then
      printf '        - %s\n' "$(yaml_quote "$SELF_DIR/env.sh hosts $slot --explain-idle")"
    else
      printf '        - %s\n' "$(yaml_quote "$SELF_DIR/env.sh hosts $slot --watch --open")"
    fi

    # The shared session holds tools, not work in progress, so it has no Claude window
    if [[ "$slot" != "$SHARED_SLOT" ]]; then
      local first_prompt
      first_prompt=$(setup_prompt "$slot")
      printf '  - environment:\n'
      printf '      layout: main-vertical\n'
      printf '      root: %s\n' "$(slot_dir "$slot")"
      printf '      panes:\n'
      if ! claude_enabled; then
        printf '        -\n'
      elif [[ -n "$first_prompt" ]]; then
        # Claude starts by helping set up the repos that can't run yet
        printf '        - %s\n' "$(yaml_quote "claude $(printf '%q' "$first_prompt")")"
      else
        printf '        - claude\n'
      fi
      printf '        -\n'
    fi
  } > "$config_file"

  write_slot_claude_md "$slot"
  ok "Tmuxinator config: $config_file"
}

# ─── Local hostnames (Caddy) ──────────────────────────────────────────────────
#
# Each slot's running apps get <name>.<slot>.localhost, and shared tools
# <name>.localhost. Browsers resolve
# *.localhost to loopback, and Caddy (brew services) proxies each name to the
# port the app is actually listening on, found by matching listening
# processes' working directories to the slot's worktrees. The main Caddyfile
# imports every slot's file from CADDY_SITES_DIR.

CADDY_SITES_DIR="$HOME/.config/dev-env/caddy"
caddy_sites_file() { printf '%s/%s.caddy\n' "$CADDY_SITES_DIR" "$1"; }

# caddy_main_config — the Caddyfile brew services runs
caddy_main_config() { printf '%s/etc/Caddyfile\n' "$(brew --prefix 2>/dev/null || printf /opt/homebrew)"; }

# slot_app_dirs <slot> — "<name>\t<dir>\t<category>" for each repo worktree in
# the slot and each extra window ("window") from the slot's tmux overrides.
slot_app_dirs() {
  local slot="$1" sf overrides
  sf=$(state_file "$slot")
  overrides=$(tmux_overrides_file "$slot")
  local cat slug link wt_path link_type canonical
  while IFS=$'\t' read -r cat slug link wt_path link_type canonical; do
    [[ "$cat" == *=* || -z "$link" || -z "$wt_path" || "$link_type" == reference ]] && continue
    printf '%s\t%s\t%s\n' "$slug" "$wt_path" "$cat"
  done < "$sf"
  if [[ -f "$overrides" ]]; then
    local o_type o_name o_arg o_cmd
    while IFS=$'\t' read -r o_type o_name o_arg o_cmd; do
      [[ "$o_type" == "window" && -n "$o_name" ]] || continue
      printf '%s\t%s\twindow\n' "$o_name" "${o_arg/#\~/$HOME}"
    done < <(grep -v '^#' "$overrides")
  fi
}

# listening_ports_by_cwd — "<port>\t<cwd>" for every TCP port listened on by one
# of this user's processes.
listening_ports_by_cwd() {
  local -A pid_ports=()
  local line pid=""
  while IFS= read -r line; do
    case "$line" in
      p*) pid="${line#p}" ;;
      n*) pid_ports[$pid]+="${line##*:} " ;;
    esac
  done < <(lsof -nP -iTCP -sTCP:LISTEN -a -u "$(id -u)" -Fpn 2>/dev/null)
  [[ ${#pid_ports[@]} -gt 0 ]] || return 0

  local pids cwd port
  pids=$(IFS=,; printf '%s' "${!pid_ports[*]}")
  pid=""
  while IFS= read -r line; do
    case "$line" in
      p*) pid="${line#p}" ;;
      n*)
        cwd="${line#n}"
        for port in ${pid_ports[$pid]}; do
          printf '%s\t%s\n' "$port" "$cwd"
        done
        ;;
    esac
  done < <(lsof -a -d cwd -p "$pids" -Fpn 2>/dev/null)
}

# speaks_http <port> — true if something answers HTTP on the port. Rules out
# debugger and build-daemon ports that share an app's working directory.
speaks_http() {
  local code
  code=$(curl -s -o /dev/null --max-time 2 -w '%{http_code}' "http://localhost:$1/" 2>/dev/null)
  [[ -n "$code" && "$code" != "000" ]]
}

# slot_hostname <slot> <name> — shared tools get the short name; slots say
# which slot an app belongs to.
slot_hostname() {
  if [[ "$1" == "$SHARED_SLOT" ]]; then
    printf '%s.localhost\n' "$2"
  else
    printf '%s.%s.localhost\n' "$2" "$1"
  fi
}

# generate_hosts <slot> — writes the slot's Caddy sites for the apps that are
# running and reloads Caddy. A 'host <name> <port>' line in the slot's tmux
# overrides pins an app's port, or '-' leaves it out. A host line whose name
# isn't one of the slot's apps adds a name for something that isn't a repo,
# e.g. 'host keycloak 8080' for a Docker container.
generate_hosts() {
  local slot="$1" if_changed=0 sites
  [[ "${2:-}" == "--if-changed" ]] && if_changed=1
  [[ -f "$(state_file "$slot")" ]] || { warn "No active state for slot '$slot'"; return 1; }
  command -v caddy >/dev/null || { warn "caddy isn't installed (brew install caddy); skipping local hostnames"; return 1; }

  local -A pinned=()
  local overrides o_type o_name o_arg o_cmd
  overrides=$(tmux_overrides_file "$slot")
  if [[ -f "$overrides" ]]; then
    while IFS=$'\t' read -r o_type o_name o_arg o_cmd; do
      [[ "$o_type" == "host" && -n "$o_name" ]] && pinned[$o_name]="$o_arg"
    done < <(grep -v '^#' "$overrides")
  fi

  local listening
  listening=$(listening_ports_by_cwd)

  mkdir -p "$CADDY_SITES_DIR"
  sites=$(caddy_sites_file "$slot")
  local name dir category port host
  local -a missing=() lines=()
  local -A seen=()
  HOSTS_APPS=()
  {
    printf '# Generated by ./env.sh hosts %s; pin or skip apps with host lines in\n' "$slot"
    printf '# %s\n' "$overrides"
    while IFS=$'\t' read -r name dir category; do
      seen[$name]=1
      port="${pinned[$name]:-}"
      if [[ -z "$port" ]]; then
        # Lowest port served from the app's directory that answers HTTP
        while IFS= read -r port; do
          speaks_http "$port" && break
          port=""
        done < <(awk -F'\t' -v d="$dir" '$2 == d || index($2, d "/") == 1 { print $1 }' <<< "$listening" | sort -n -u)
      fi
      if [[ -z "$port" || "$port" == "-" ]]; then
        # Libraries never serve anything, so only an app that should be up is worth mentioning
        [[ "$port" == "-" || "$category" == "libraries" ]] || missing+=("$name")
        continue
      fi
      host=$(slot_hostname "$slot" "$name")
      printf 'http://%s {\n\treverse_proxy localhost:%s\n}\n' "$host" "$port"
      lines+=("$(printf '  %s%-52s%s → localhost:%s' "$BOLD" "http://$host" "$RESET" "$port")")
      HOSTS_APPS+=("$name"$'\t'"http://$host"$'\t'"$category")
    done < <(slot_app_dirs "$slot")

    # Names for things that aren't repos, e.g. Docker containers
    while IFS= read -r name; do
      [[ -n "$name" ]] || continue
      port="${pinned[$name]}"
      [[ -n "${seen[$name]:-}" || -z "$port" || "$port" == "-" ]] && continue
      host=$(slot_hostname "$slot" "$name")
      printf 'http://%s {\n\treverse_proxy localhost:%s\n}\n' "$host" "$port"
      lines+=("$(printf '  %s%-52s%s → localhost:%s' "$BOLD" "http://$host" "$RESET" "$port")")
      HOSTS_APPS+=("$name"$'\t'"http://$host"$'\t'"other")
    done < <(printf '%s\n' "${!pinned[@]}" | sort)
  } > "$sites.new"

  if [[ "$if_changed" -eq 1 ]] && cmp -s "$sites.new" "$sites"; then
    rm -f "$sites.new"
    return 2
  fi
  mv "$sites.new" "$sites"
  write_slot_apps_json "$slot" "${HOSTS_APPS[@]}"

  [[ ${#lines[@]} -gt 0 ]] && printf '%s\n' "${lines[@]}" >&2
  [[ ${#missing[@]} -gt 0 ]] && printf '  %snot running: %s%s\n' "$DIM" "${missing[*]}" "$RESET" >&2
  reload_caddy
  ok "Local hostnames for '$slot': ${#HOSTS_APPS[@]} ($sites)"
}

# hosts_window_banner <slot> — what the slot's 'hosts' window is for
hosts_window_banner() {
  local slot="$1" pattern
  pattern=$(slot_hostname "$slot" '<repo>')
  printf '%s── %s: local hostnames ──%s\n' "$BOLD$CYAN" "$slot" "$RESET"
  printf 'This window gives each of the slot'"'"'s running apps a name, http://%s,\n' "$pattern"
  printf 'and follows them if they move port or stop. Once the apps you open in a\n'
  printf 'browser are up, it opens them as a Chrome tab group named %s.\n' "$slot"
  printf 'Leave it running; closing it only stops names updating.\n\n'
}

# watch_hosts <slot> [--open] — keeps the slot's hostnames current as its apps
# come up, move port or stop, checking every few seconds. With --open, opens the
# slot's tab group once every client is up, or after a few minutes once any is.
watch_hosts() {
  local slot="$1" open=0 opened=0 started now expected up name dir category
  [[ "${2:-}" == "--open" ]] && open=1
  started=$(date +%s)
  hosts_window_banner "$slot"
  printf '%sWatching (Ctrl-C to stop)…%s\n' "$DIM" "$RESET"
  while true; do
    [[ -f "$(state_file "$slot")" ]] || { echo "Slot '$slot' is no longer active."; return 0; }
    if generate_hosts "$slot" --if-changed; then
      printf '%s%s%s\n' "$DIM" "$(date +%H:%M:%S)" "$RESET"
    fi

    if [[ "$open" -eq 1 && "$opened" -eq 0 ]]; then
      # The apps worth a tab: clients and extra windows
      expected=0 up=0
      while IFS=$'\t' read -r name dir category; do
        [[ "$category" == "clients" || "$category" == "window" ]] || continue
        expected=$((expected + 1))
        grep -q "\"name\":\"$name\"" "$(slot_apps_json "$slot")" 2>/dev/null && up=$((up + 1))
      done < <(slot_app_dirs "$slot")
      now=$(date +%s)
      if [[ "$up" -gt 0 && ( "$up" -eq "$expected" || $((now - started)) -ge 180 ) ]]; then
        open_tab_group "$slot" "" && opened=1
      fi
    fi
    sleep 5
  done
}

# open_tab_group <slot> [<all>] — opens the slot's apps (clients and extra
# windows; with <all>, servers too) as browser_mode says: a Chrome tab group via
# the dev-env extension (chrome-extension/), a tab each in the default browser,
# or nothing. Returns 1 only when the slot has no hostnames yet.
open_tab_group() {
  local slot="$1" all="${2:-}" json entry url category
  json=$(slot_apps_json "$slot")
  [[ -f "$json" ]] || return 1
  case "$(browser_mode)" in
    none)
      ok "Not opening '$slot': browser is set to none"
      ;;
    chrome)
      open -a "Google Chrome" "http://dev-env.localhost/open?slot=$slot${all:+&all=1}"
      ok "Opening '$slot' in Chrome"
      ;;
    *)
      while IFS= read -r entry; do
        url=$(sed -n 's/.*"url":"\([^"]*\)".*/\1/p' <<< "$entry")
        category=$(sed -n 's/.*"category":"\([^"]*\)".*/\1/p' <<< "$entry")
        [[ -n "$all" || "$category" == clients || "$category" == window ]] || continue
        open "$url"
      done < <(grep -o '{"name":"[^}]*}' "$json")
      ok "Opening '$slot' in the default browser"
      ;;
  esac
}

# remove_hosts <slot> — drops the slot's Caddy sites
remove_hosts() {
  local sites
  sites=$(caddy_sites_file "$1")
  rm -f "$(slot_apps_json "$1")"
  [[ -f "$sites" ]] || return 0
  rm -f "$sites"
  reload_caddy
}

# ─── dev-env.localhost: slot app lists for the Chrome extension ──────────────
#
# Caddy serves CADDY_WWW_DIR at http://dev-env.localhost: slots/<slot>.json
# lists a slot's named apps, and /open is the page the extension turns into a
# tab group (it explains how to install the extension if nothing happens).

CADDY_WWW_DIR="$CADDY_SITES_DIR/www"
slot_apps_json() { printf '%s/slots/%s.json\n' "$CADDY_WWW_DIR" "$1"; }

# write_slot_apps_json <slot> [<name>\t<url>\t<category> ...]
write_slot_apps_json() {
  local slot="$1" file entry name url category sep=""
  shift
  file=$(slot_apps_json "$slot")
  mkdir -p "$(dirname "$file")"
  {
    printf '{"slot":"%s","apps":[' "$slot"
    for entry in "$@"; do
      IFS=$'\t' read -r name url category <<< "$entry"
      printf '%s{"name":"%s","url":"%s","category":"%s"}' "$sep" "$name" "$url" "$category"
      sep=","
    done
    printf ']}\n'
  } > "$file"
}

# ensure_dev_env_site — the Caddy site for dev-env.localhost and its open page
ensure_dev_env_site() {
  mkdir -p "$CADDY_WWW_DIR/slots"
  sed "s#__EXTENSION_DIR__#$SELF_DIR/chrome-extension#" "$SELF_DIR/chrome-extension/open.html" \
    > "$CADDY_WWW_DIR/open.html"
  cat > "$CADDY_SITES_DIR/_dev-env.caddy" << EOF
# Generated by env.sh: slot app lists for the dev-env Chrome extension
http://dev-env.localhost {
	root * $CADDY_WWW_DIR
	header Access-Control-Allow-Origin *
	header Cache-Control no-store
	try_files {path} {path}.html
	file_server
}
EOF
}

reload_caddy() {
  local main
  main=$(caddy_main_config)
  ensure_dev_env_site
  if ! grep -qF "$CADDY_SITES_DIR/" "$main" 2>/dev/null; then
    warn "$main doesn't import $CADDY_SITES_DIR/*.caddy; see README (Local hostnames)"
    return 1
  fi
  caddy reload --config "$main" >/dev/null 2>&1 \
    || warn "caddy reload failed; is it running? (brew services start caddy)"
}

# ─── ACTIVE.md generation ─────────────────────────────────────────────────────

write_neutral_active_md() {
  cat > "$ACTIVE_MD" << 'EOF'
## Active Environment

No environment is currently active. Run `./env.sh activate <preset>` or `./env.sh adhoc`.
EOF
}

context_from_file() {
  awk '/^@context$/{f=1;next} /^@end$/{f=0} f{print}' "$1"
}

# Blank lines are kept so multi-paragraph pastes survive intact; input ends
# with Ctrl-D or a line containing only ".".
read_context_block() {
  echo "Enter context (paste freely; finish with Ctrl-D or a line with just '.'):" >&2
  drain_stdin
  local line
  local -a lines=()
  while IFS= read -r line || [[ -n "$line" ]]; do
    [[ "$line" == "." ]] && break
    lines+=("$line")
  done
  # Trim trailing blank lines
  while [[ ${#lines[@]} -gt 0 && -z "${lines[-1]//[[:space:]]/}" ]]; do
    unset 'lines[-1]'
  done
  [[ ${#lines[@]} -gt 0 ]] && printf '%s\n' "${lines[@]}" || true
}

_write_slot_section() {
  local slot="$1"
  local sf created_at preset context
  sf=$(state_file "$slot")
  [[ -f "$sf" ]] || return
  created_at=$(grep '^created_at=' "$sf" | cut -d= -f2)
  preset=$(grep '^active_preset=' "$sf" | cut -d= -f2)
  context=$(context_from_file "$sf")

  local -A seen_cats=()
  local -a cats=()
  local cat slug link wt_path link_type canonical
  while IFS=$'\t' read -r cat slug link wt_path link_type canonical; do
    [[ "$cat" == *=* || -z "$link" ]] && continue
    if [[ -z "${seen_cats[$cat]:-}" ]]; then
      seen_cats[$cat]=1
      cats+=("$cat")
    fi
  done < "$sf"

  printf '## Active Environment: %s\n\n' "$preset"
  printf 'Activated: %s\n\n' "$created_at"
  printf 'The folders below are **symlinks to git worktrees** — changes inside\n'
  printf 'them affect only this slot'\''s working trees.\n'

  local c
  for c in "${cats[@]}"; do
    printf '\n### %s\n\n' "$c"
    while IFS=$'\t' read -r cat slug link wt_path link_type canonical; do
      [[ "$cat" == "$c" && -n "$link" ]] || continue
      printf -- '- **%s** → `%s`\n' "$slug" "$wt_path"
    done < "$sf"
    if [[ "$c" == "$REFERENCE_CATEGORY" ]]; then
      printf '\n_Read-only references, detached at the latest base branch: not part of the\n'
      printf 'change, not run. Add more with `./env.sh ref add <slot> <repo>`._\n'
    fi
  done

  printf '\n## Context\n\n'
  if [[ -n "$context" ]]; then
    printf '%s\n' "$context"
  else
    printf '_No context set — add one via the preset'\''s `@context` block or when saving (`./env.sh save <name>`)._\n'
  fi
}

write_active_md() {
  local -a slots=()
  local slot
  while IFS= read -r slot; do slots+=("$slot"); done < <(list_active_slots)

  local has_legacy=0
  [[ -f "$SELF_DIR/.active-env" ]] && has_legacy=1

  if [[ ${#slots[@]} -eq 0 && "$has_legacy" -eq 0 ]]; then
    write_neutral_active_md
    return
  fi

  {
    if [[ ${#slots[@]} -eq 1 && "$has_legacy" -eq 0 ]]; then
      _write_slot_section "${slots[0]}"
    else
      if [[ "$has_legacy" -eq 1 ]]; then
        printf '## Active Environment: (legacy)\n\n'
        printf '_This environment uses the old format. Run `./env.sh deactivate` to clean it up,_\n'
        printf '_then re-activate with `./env.sh activate <preset>` or `./env.sh adhoc`._\n'
        if [[ ${#slots[@]} -gt 0 ]]; then printf '\n---\n\n'; fi
      fi
      local i=0
      for slot in "${slots[@]}"; do
        _write_slot_section "$slot"
        i=$((i + 1))
        if [[ "$i" -lt "${#slots[@]}" ]]; then printf '\n---\n\n'; fi
      done
    fi
  } > "$ACTIVE_MD"
}

# ─── preset parsing ───────────────────────────────────────────────────────────

parse_preset_file() {
  local file="$1"
  ENTRIES=()
  CONTEXT_BLOCK=""
  FEATURE=""
  local line in_context=0 cat slug branch
  while IFS= read -r line || [[ -n "$line" ]]; do
    if (( in_context )); then
      if [[ "$line" == "@end" ]]; then
        in_context=0
      else
        CONTEXT_BLOCK+="$line"$'\n'
      fi
      continue
    fi
    [[ "$line" == "@context" ]] && { in_context=1; continue; }
    if [[ "$line" == "@feature "* ]]; then
      FEATURE="${line#@feature }"
      FEATURE="${FEATURE// /}"
      continue
    fi
    line="${line// /}"
    [[ -z "$line" || "$line" == \#* ]] && continue
    IFS=',' read -r cat slug branch <<< "$line"
    if [[ -z "$cat" || -z "$slug" ]]; then
      warn "Skipping malformed preset line: $line"
      continue
    fi
    ENTRIES+=("$cat"$'\t'"$slug"$'\t'"${branch:-}")
  done < "$file"
}
