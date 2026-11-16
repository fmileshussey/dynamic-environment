#!/usr/bin/env bash
# env.sh — compose a development environment from symlinks to existing clones.
#
# Usage: ./env.sh <command>
#   activate <preset> [--as <slot>] [--feature <name>] [--checkout]
#                                                  activate a preset from presets/
#   adhoc [--as <slot>] [--feature <name>] [--refresh]
#                                                  pick repos via Bitbucket + fzf, then activate
#   deactivate [<slot>]                            remove a slot's symlinks and worktrees
#   status [<slot>]                                show active slot(s)
#   slots                                          list active slot names
#   save <name> [--slot <slot>]                    save a slot's selection as a preset
#   list                                           list available presets
#
# Requires bash 4+. macOS ships with 3.2; install via: brew install bash

if ((BASH_VERSINFO[0] < 4)); then
  for _bash in /opt/homebrew/bin/bash /usr/local/bin/bash; do
    [[ -x "$_bash" ]] && exec "$_bash" "$0" "$@"
  done
  echo "Error: bash 4+ required. Install with: brew install bash" >&2
  exit 1
fi

set -euo pipefail

_script="${BASH_SOURCE[0]}"
while [[ -L "$_script" ]]; do
  _dir="$(cd "$(dirname "$_script")" && pwd)"
  _script="$(readlink "$_script")"
  [[ "$_script" != /* ]] && _script="$_dir/$_script"
done
SELF_DIR="$(cd "$(dirname "$_script")" && pwd)"
unset _script _dir
# shellcheck source=lib/common.sh
source "$SELF_DIR/lib/common.sh"

# ─── activation core ──────────────────────────────────────────────────────────

# Activate from globals: ENTRIES (category<TAB>slug<TAB>branch), CONTEXT_BLOCK,
# PRESET_LABEL, CHECKOUT, SLOT, FEATURE. Shared by `activate` and `adhoc`.
# Every worktree goes on feature/<FEATURE>/feature, except preset entries with
# a pinned branch when --checkout is given.
activate_from_selection() {
  local slot="$SLOT"
  local sf
  sf=$(state_file "$slot")

  [[ "$slot" != "$SHARED_SLOT" ]] ||
    die "'$SHARED_SLOT' is reserved for shared tools (./env.sh shared); pick another slot name."
  if [[ -f "$sf" ]]; then
    die "Slot '$slot' is already active. Deactivate it first: ./env.sh deactivate $slot"
  fi

  local feature_branch
  feature_branch=$(feature_branch_name "$FEATURE")
  git check-ref-format --branch "$feature_branch" &>/dev/null ||
    die "'$feature_branch' is not a valid branch name — pick another feature name."

  section "Resolving repositories"
  build_clone_index

  local -a state_rows=() skipped=()
  local entry cat slug branch target wt_path

  for entry in "${ENTRIES[@]}"; do
    IFS=$'\t' read -r cat slug branch <<< "$entry"

    if ! target=$(resolve_clone "$slug"); then
      warn "Skipped: $slug"
      skipped+=("$cat/$slug")
      continue
    fi

    local link_type=worktree
    if [[ "$cat" == "$REFERENCE_CATEGORY" ]]; then
      # Only there to read: detached at the latest base, never the feature branch
      link_type=reference
      if ! wt_path=$(create_detached_worktree "$slot" "$slug" "$target"); then
        skipped+=("$cat/$slug")
        continue
      fi
    else
      if [[ "${CHECKOUT:-0}" -ne 1 || -z "$branch" ]]; then
        branch="$feature_branch"
      fi
      if ! wt_path=$(create_worktree "$slot" "$slug" "$target" "$branch"); then
        skipped+=("$cat/$slug")
        continue
      fi
    fi

    local link
    link="$(slot_dir "$slot")/$cat/$slug"
    mkdir -p "$(slot_dir "$slot")/$cat"
    ln -s "$wt_path" "$link"
    state_rows+=("$cat"$'\t'"$slug"$'\t'"$link"$'\t'"$wt_path"$'\t'"$link_type"$'\t'"$target")
    ok "$cat/$slug → $wt_path"
  done

  if [[ ${#state_rows[@]} -eq 0 ]]; then
    write_active_md
    die "Nothing was linked — environment not activated."
  fi

  {
    echo "active_preset=$PRESET_LABEL"
    echo "slot=$slot"
    echo "feature=$FEATURE"
    echo "created_at=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    printf '%s\n' "${state_rows[@]}"
    if [[ -n "${CONTEXT_BLOCK:-}" ]]; then
      echo "@context"
      printf '%s' "$CONTEXT_BLOCK"
      [[ "$CONTEXT_BLOCK" == *$'\n' ]] || echo
      echo "@end"
    fi
  } > "$sf"

  write_active_md

  section "Local files from repo kits"
  apply_repo_kits "$slot"

  # Before the session is generated, so its Claude also hears about shared
  # tools added here that aren't set up
  offer_shared_tools

  section "Generating tmux session"
  generate_tmuxinator "$slot"

  section "Active: $PRESET_LABEL (slot: $slot)"
  echo "  ${#state_rows[@]} repo(s) linked. See ACTIVE.md, or run: ./env.sh status $slot"
  if [[ ${#skipped[@]} -gt 0 ]]; then
    warn "${#skipped[@]} repo(s) NOT linked: ${skipped[*]}"
  fi

  local gaps shared_gaps
  gaps=$(slot_setup_gaps "$slot")
  shared_gaps=$(slot_setup_gaps "$SHARED_SLOT")
  if [[ -n "$gaps" || -n "$shared_gaps" ]]; then
    section "Not set up to run yet"
    [[ -n "$gaps" ]] && print_setup_gaps "$gaps"
    if [[ -n "$shared_gaps" ]]; then
      echo "  Shared tools:"
      print_setup_gaps "$shared_gaps"
    fi
    if claude_enabled; then
      echo "  Claude in the session's environment window will start by helping set these up."
    else
      echo "  Set them up as repo kits in ~/.config/dev-env/repos/ (see README \"Repo kits\")."
    fi
  fi

  # The session always opens; --start / --no-start decide whether its apps run,
  # otherwise ask
  local start="${START:-}"
  if [[ -z "$start" ]]; then
    if confirm "Start the apps too? (servers, dev servers, hostnames and the Chrome tab group)"; then
      start=1
    else
      start=0
    fi
  fi

  if [[ "$start" -eq 0 ]]; then
    echo "  Opening the session with idle run panes. Start the apps later with: ./env.sh start $slot"
  fi
  start_slot_session "$slot" "$((1 - start))"
}

# ─── commands ─────────────────────────────────────────────────────────────────

cmd_activate() {
  local usage="Usage: ./env.sh activate <preset> [--as <slot>] [--feature <name>] [--checkout] [--start|--no-start]"
  local preset="" checkout=0 slot="" feature=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --checkout) checkout=1; shift ;;
      --as)
        shift
        slot="${1:-}"
        [[ -n "$slot" ]] || die "--as requires a slot name"
        shift
        ;;
      --as=*) slot="${1#--as=}"; shift ;;
      --feature)
        shift
        feature="${1:-}"
        [[ -n "$feature" ]] || die "--feature requires a name"
        shift
        ;;
      --start)    START=1; shift ;;
      --no-start) START=0; shift ;;
      --feature=*) feature="${1#--feature=}"; shift ;;
      -*)     die "Unknown flag: $1" ;;
      *)
        [[ -z "$preset" ]] || die "$usage"
        preset="$1"; shift
        ;;
    esac
  done
  [[ -n "$preset" ]] || die "$usage"

  local file="$PRESETS_DIR/${preset}.env"
  [[ -f "$file" ]] || die "Preset not found: presets/${preset}.env (see: ./env.sh list)"

  parse_preset_file "$file"
  [[ ${#ENTRIES[@]} -gt 0 ]] || die "Preset '$preset' has no repo entries."

  PRESET_LABEL="$preset"
  SLOT="${slot:-$preset}"
  CHECKOUT=$checkout
  # --feature wins, then the preset's @feature line, then ask (default: slot).
  FEATURE="${feature:-$FEATURE}"
  [[ -n "$FEATURE" ]] || FEATURE=$(prompt_feature "$SLOT")
  activate_from_selection
}

# prompt_feature <default> — ask for the feature name used in
# feature/<name>/feature, defaulting to <default>.
prompt_feature() {
  local name
  name=$(prompt "Feature name (branches: feature/<name>/feature)" "$1")
  name="${name// /-}"
  [[ -n "$name" ]] || die "A feature name is required."
  printf '%s\n' "$name"
}

cmd_adhoc() {
  local refresh=0 slot="adhoc" feature=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --refresh) refresh=1; shift ;;
      --as)
        shift
        slot="${1:-}"
        [[ -n "$slot" ]] || die "--as requires a slot name"
        shift
        ;;
      --as=*) slot="${1#--as=}"; shift ;;
      --feature)
        shift
        feature="${1:-}"
        [[ -n "$feature" ]] || die "--feature requires a name"
        shift
        ;;
      --start)    START=1; shift ;;
      --no-start) START=0; shift ;;
      --feature=*) feature="${1#--feature=}"; shift ;;
      -*)     die "Unknown flag: $1" ;;
      *)      die "Unexpected argument: $1" ;;
    esac
  done

  local sf
  sf=$(state_file "$slot")
  if [[ -f "$sf" ]]; then
    die "Slot '$slot' is already active. Use --as <name> to pick a different name, or deactivate it first."
  fi

  section "Fetching Bitbucket repos"
  fetch_repo_list "$refresh"

  section "Categories"
  echo "Repos are organised into category folders. Repos in '$REFERENCE_CATEGORY' are only"
  echo "there to read: on the latest base branch, not run (add more later: ./env.sh ref add)."
  local cats_raw
  cats_raw=$(prompt "Categories (comma-separated)" "clients,servers,libraries,$REFERENCE_CATEGORY")
  IFS=',' read -ra CATEGORIES <<< "$cats_raw"
  local -a trimmed=()
  local c
  for c in "${CATEGORIES[@]}"; do trimmed+=("${c// /}"); done
  CATEGORIES=("${trimmed[@]}")

  section "Repo Selection"
  local use_fzf=1
  if ! command -v fzf &>/dev/null; then
    echo "fzf not found."
    if confirm "Install fzf with 'brew install fzf'?"; then
      brew install fzf || die "brew install fzf failed"
    else
      use_fzf=0
    fi
  fi

  local cat sel_file
  for cat in "${CATEGORIES[@]}"; do
    sel_file="/tmp/dev-env-selected-${cat}.txt"
    if [[ "$use_fzf" -eq 1 ]]; then
      echo ""
      echo "Selecting repos for '$cat' (Tab=mark, Enter=confirm)..."
      "$SELF_DIR/scripts/select-repos.sh" "$cat" "$CACHE_FILE"
    else
      select_numbered "$cat" "$sel_file"
    fi
  done

  section "Review Selection"
  show_selection_summary
  while ! confirm "Activate this selection?"; do
    local add_cat
    if [[ "$use_fzf" -eq 1 ]]; then
      add_cat=$(printf '%s\n' "${CATEGORIES[@]}" | fzf \
        --prompt="Category to add to: " \
        --height="$((${#CATEGORIES[@]} + 3))" \
        --layout=reverse \
        --no-multi) || true
    else
      add_cat=$(prompt "Category to add to (${CATEGORIES[*]})")
      add_cat="${add_cat// /}"
    fi
    [[ -z "$add_cat" ]] && continue
    if [[ " ${CATEGORIES[*]} " != *" ${add_cat} "* ]]; then
      echo "Unknown category '$add_cat'. Options: ${CATEGORIES[*]}"
      continue
    fi
    append_to_category "$add_cat" "$use_fzf"
    show_selection_summary
  done

  ENTRIES=()
  for cat in "${CATEGORIES[@]}"; do
    sel_file="/tmp/dev-env-selected-${cat}.txt"
    [[ -f "$sel_file" ]] || continue
    local slug
    while IFS= read -r slug; do
      [[ -z "$slug" ]] && continue
      ENTRIES+=("$cat"$'\t'"$slug"$'\t')
    done < <(awk '!seen[$0]++' "$sel_file")
  done
  [[ ${#ENTRIES[@]} -gt 0 ]] || die "No repos selected — environment not activated."

  CONTEXT_BLOCK=""
  if confirm "Add a context block? (describes this environment in ACTIVE.md)"; then
    CONTEXT_BLOCK=$(read_context_block)
  fi

  PRESET_LABEL="adhoc"
  SLOT="$slot"
  CHECKOUT=0
  FEATURE="$feature"
  [[ -n "$FEATURE" ]] || FEATURE=$(prompt_feature "$slot")
  activate_from_selection
  echo "  Save this selection with: ./env.sh save <name>"
}

show_selection_summary() {
  local cat sel_file repos_inline count
  for cat in "${CATEGORIES[@]}"; do
    sel_file="/tmp/dev-env-selected-${cat}.txt"
    if [[ -f "$sel_file" && -s "$sel_file" ]]; then
      repos_inline=$(awk '!seen[$0]++' "$sel_file" | paste -sd, - | sed 's/,/, /g')
      count=$(awk '!seen[$0]++' "$sel_file" | grep -c .)
      printf '  %s%-12s%s (%s): %s\n' "$BOLD" "$cat" "$RESET" "$count" "$repos_inline"
    else
      printf '  %s%-12s%s (0): %snone%s\n' "$BOLD" "$cat" "$RESET" "$DIM" "$RESET"
    fi
  done
}

append_to_category() {
  local cat="$1" use_fzf="$2"
  local sel_file="/tmp/dev-env-selected-${cat}.txt"
  if [[ "$use_fzf" -eq 1 ]]; then
    fzf --multi \
      --prompt="[$cat] Tab=mark, Enter=confirm marked: " \
      --header="Adding to: $cat  |  Tab=mark  Enter=confirm marked  (no marks = add nothing)" \
      --bind 'enter:transform([ "$FZF_SELECT_COUNT" -gt 0 ] && echo accept || echo abort)' \
      < "$CACHE_FILE" >> "$sel_file" || true
  else
    local extra
    extra=$(prompt "Repos to add to '$cat' (comma-separated slugs)")
    local -a parts=()
    IFS=',' read -ra parts <<< "$extra"
    local part
    for part in "${parts[@]}"; do
      part="${part// /}"
      [[ -z "$part" ]] && continue
      echo "$part" >> "$sel_file"
    done
  fi
}

select_numbered() {
  local cat="$1" out="$2"
  local -a repo_array=()
  local line
  while IFS= read -r line; do repo_array+=("$line"); done < "$CACHE_FILE"

  echo ""
  echo "=== Repos for '$cat' ==="
  local idx=1 repo
  for repo in "${repo_array[@]}"; do
    printf '  %3d) %s\n' "$idx" "$repo"
    idx=$((idx + 1))
  done
  echo ""
  printf 'Enter numbers or slugs (comma-separated, Enter to skip): '
  local selection
  read -r selection
  : > "$out"
  if [[ -n "$selection" ]]; then
    local -a parts=()
    IFS=',' read -ra parts <<< "$selection"
    local part
    for part in "${parts[@]}"; do
      part="${part// /}"
      [[ -z "$part" ]] && continue
      if [[ "$part" =~ ^[0-9]+$ ]]; then
        echo "${repo_array[$((part - 1))]}" >> "$out"
      else
        echo "$part" >> "$out"
      fi
    done
  fi
  echo "  $(grep -c . "$out" || true) selected for $cat."
}

# Remove a slot's symlinks and worktrees. Handles the old single-env format too.
do_deactivate() {
  local slot="${1:-}"

  # Legacy: old single .active-env file with top-level symlinks
  if [[ -z "$slot" && -f "$SELF_DIR/.active-env" ]]; then
    _deactivate_legacy
    return
  fi

  if [[ -z "$slot" ]]; then
    local -a active=()
    while IFS= read -r s; do active+=("$s"); done < <(list_active_slots)
    case ${#active[@]} in
      0)
        write_active_md
        echo "No active slots."
        return 0
        ;;
      1) slot="${active[0]}" ;;
      *)
        die "Multiple slots active (${active[*]}). Specify one: ./env.sh deactivate <slot>"
        ;;
    esac
  fi

  local sf
  sf=$(state_file "$slot")
  if [[ ! -f "$sf" ]]; then
    echo "Slot '$slot' is not active."
    return 0
  fi

  local removed=0 wt_removed=0
  local cat slug link wt_path link_type canonical
  while IFS=$'\t' read -r cat slug link wt_path link_type canonical; do
    [[ "$cat" == *=* || -z "$link" ]] && continue

    if [[ -L "$link" ]]; then
      rm "$link"
      removed=$((removed + 1))
    elif [[ -e "$link" ]]; then
      warn "Skip (not a symlink): $link"
    fi

    if [[ ( "$link_type" == worktree || "$link_type" == reference ) && -n "$canonical" && -n "$wt_path" && -d "$wt_path" ]]; then
      local real_clone
      real_clone=$(git -C "$canonical" rev-parse --show-toplevel 2>/dev/null || printf '%s' "$canonical")
      if git -C "$real_clone" worktree remove "$wt_path" 2>/dev/null || \
         git -C "$real_clone" worktree remove --force "$wt_path" 2>/dev/null; then
        wt_removed=$((wt_removed + 1))
      else
        warn "Could not remove worktree: $wt_path (may need manual cleanup)"
      fi
    fi
  done < "$sf"

  # Remove the generated CLAUDE.md, the plans link (plans/<slot>/ itself is
  # kept), empty slot category dirs and the slot dir itself
  rm -f "$(slot_dir "$slot")/CLAUDE.md"
  [[ -L "$(slot_dir "$slot")/plans" ]] && rm -f "$(slot_dir "$slot")/plans"
  local cat_dir
  shopt -s nullglob
  for cat_dir in "$(slot_dir "$slot")"/*; do
    [[ -d "$cat_dir" ]] && rmdir "$cat_dir" 2>/dev/null || true
  done
  rmdir "$(slot_dir "$slot")" 2>/dev/null || true
  rmdir "$WORKTREES_ROOT/$slot" 2>/dev/null || true

  rm -f "$sf"
  rm -f "$TMUXINATOR_DIR/${slot}.yml"
  remove_hosts "$slot"
  write_active_md

  ok "Deactivated slot '$slot'. Removed $removed symlink(s), $wt_removed worktree(s)."
}

_deactivate_legacy() {
  local sf="$SELF_DIR/.active-env"
  local removed=0
  local -A link_dirs=()
  local cat slug link target
  while IFS=$'\t' read -r cat slug link target; do
    [[ "$cat" == *=* || -z "$cat" || -z "$link" ]] && continue
    if [[ -L "$link" ]]; then
      rm "$link"
      removed=$((removed + 1))
      link_dirs["$(dirname "$link")"]=1
    elif [[ -e "$link" ]]; then
      warn "Skip (not a symlink, leaving in place): $link"
    fi
  done < "$sf"
  local d
  for d in "${!link_dirs[@]}"; do
    rmdir "$d" 2>/dev/null || true
  done
  rm -f "$sf"
  write_active_md
  ok "Deactivated legacy environment. Removed $removed symlink(s)."
  echo "  Re-activate with: ./env.sh activate <preset>  or  ./env.sh adhoc"
}

cmd_slots() {
  local -a active=()
  while IFS= read -r s; do active+=("$s"); done < <(list_active_slots)

  if [[ -f "$SELF_DIR/.active-env" ]]; then
    printf '  %s(legacy)%s  run: ./env.sh deactivate\n' "$YELLOW$BOLD" "$RESET"
  fi

  if [[ ${#active[@]} -eq 0 && ! -f "$SELF_DIR/.active-env" ]]; then
    echo "No active slots."
    echo "Activate one with: ./env.sh activate <preset>  or  ./env.sh adhoc"
    return
  fi

  local slot sf preset created_at count
  for slot in "${active[@]}"; do
    sf=$(state_file "$slot")
    preset=$(grep '^active_preset=' "$sf" | cut -d= -f2)
    created_at=$(grep '^created_at=' "$sf" | cut -d= -f2)
    count=$(grep -cvE '^[^	]*=|^@|^[[:space:]]*$' "$sf" 2>/dev/null || true)
    printf '  %s%-24s%s %-20s %s%s%s\n' \
      "$BOLD" "$slot" "$RESET" "$preset" "$DIM" "$created_at" "$RESET"
  done
}

cmd_status() {
  local slot="${1:-}"

  if [[ -n "$slot" ]]; then
    _status_one "$slot"
    return
  fi

  local -a active=()
  while IFS= read -r s; do active+=("$s"); done < <(list_active_slots)

  if [[ -f "$SELF_DIR/.active-env" ]]; then
    printf '%s── Legacy environment (run: ./env.sh deactivate) ──%s\n' "$YELLOW$BOLD" "$RESET"
    echo ""
  fi

  if [[ ${#active[@]} -eq 0 && ! -f "$SELF_DIR/.active-env" ]]; then
    echo "No active slots."
    echo "Activate one with: ./env.sh activate <preset>  or  ./env.sh adhoc"
    return
  fi

  local i=0
  for slot in "${active[@]}"; do
    _status_one "$slot"
    i=$((i + 1))
    [[ "$i" -lt "${#active[@]}" ]] && echo ""
  done
}

_status_one() {
  local slot="$1"
  local sf
  sf=$(state_file "$slot")
  if [[ ! -f "$sf" ]]; then
    echo "Slot '$slot' is not active."
    return 1
  fi
  local preset created_at feature
  preset=$(grep '^active_preset=' "$sf" | cut -d= -f2)
  created_at=$(grep '^created_at=' "$sf" | cut -d= -f2)
  feature=$(grep '^feature=' "$sf" | cut -d= -f2-)
  section "Slot: $slot ($preset)"
  echo "  Activated: $created_at"
  [[ -n "$feature" ]] && echo "  Feature:   $(feature_branch_name "$feature")"
  echo ""
  local cat slug link wt_path link_type canonical branch state
  while IFS=$'\t' read -r cat slug link wt_path link_type canonical; do
    [[ "$cat" == *=* || -z "$link" ]] && continue
    if [[ -L "$link" && -e "$link" ]]; then
      branch=$(git -C "$wt_path" rev-parse --abbrev-ref HEAD 2>/dev/null || echo '?')
      [[ "$link_type" == reference ]] &&
        branch="reference @ $(git -C "$wt_path" rev-parse --short HEAD 2>/dev/null || echo '?')"
      if [[ -n $(git -C "$wt_path" status --porcelain 2>/dev/null) ]]; then
        state="$branch, dirty"
      else
        state="$branch, clean"
      fi
      printf '  %s%-12s%s %-30s %s[%s]%s\n' \
        "$BOLD" "$cat" "$RESET" "$slug" "$DIM" "$state" "$RESET"
    else
      printf '  %s%-12s%s %-30s %s[BROKEN]%s\n' \
        "$BOLD" "$cat" "$RESET" "$slug" "$RED" "$RESET"
    fi
  done < "$sf"

  local sites
  sites=$(caddy_sites_file "$slot")
  if [[ -f "$sites" ]] && grep -q '^http://' "$sites"; then
    echo ""
    echo "  Hostnames (refresh: ./env.sh hosts $slot):"
    sed -n 's#^\(http://[^ ]*\) {#    \1#p' "$sites"
  fi
}

# hosts [<slot>] [--watch [--open]] — map each running app in the slot to
# <name>.<slot>.localhost; --watch keeps doing so as apps come and go, and --open
# then opens the slot's tab group once its clients are up
cmd_hosts() {
  local slot="" watch=0 open="" explain_idle=0
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --watch) watch=1; shift ;;
      --open)  open="--open"; shift ;;
      --explain-idle) explain_idle=1; shift ;;
      -*)      die "Unknown flag: $1" ;;
      *)       slot="$1"; shift ;;
    esac
  done
  if [[ -z "$slot" ]]; then
    local -a active=()
    while IFS= read -r s; do active+=("$s"); done < <(list_active_slots)
    case ${#active[@]} in
      0) die "No active slots." ;;
      1) slot="${active[0]}" ;;
      *) die "Multiple slots active (${active[*]}). Specify one: ./env.sh hosts <slot>" ;;
    esac
  fi
  if [[ "$explain_idle" -eq 1 ]]; then
    # What an idle session's hosts window shows until the apps are started
    hosts_window_banner "$slot"
    printf 'The apps aren'"'"'t running yet. Start them, with this window, by running:\n\n'
    printf '  %s start %s\n\n' "$SELF_DIR/env.sh" "$slot"
  elif [[ "$watch" -eq 1 ]]; then
    watch_hosts "$slot" $open
  else
    section "Local hostnames: $slot"
    generate_hosts "$slot"
  fi
}

cmd_save() {
  local name="${1:-}"
  [[ -n "$name" ]] || die "Usage: ./env.sh save <name> [--slot <slot>]"
  shift

  local slot=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --slot)
        shift
        slot="${1:-}"
        [[ -n "$slot" ]] || die "--slot requires a name"
        shift
        ;;
      --slot=*) slot="${1#--slot=}"; shift ;;
      *) die "Unknown argument: $1" ;;
    esac
  done

  if [[ -z "$slot" ]]; then
    local -a active=()
    while IFS= read -r s; do active+=("$s"); done < <(list_active_slots)
    case ${#active[@]} in
      0) die "No active slots to save." ;;
      1) slot="${active[0]}" ;;
      *)
        if command -v fzf &>/dev/null; then
          slot=$(printf '%s\n' "${active[@]}" | fzf --no-multi \
            --prompt="Save which slot? " \
            --layout=reverse \
            --height="$((${#active[@]} + 3))") || die "Aborted."
        else
          die "Multiple slots active (${active[*]}). Specify with: --slot <name>"
        fi
        ;;
    esac
  fi

  local sf
  sf=$(state_file "$slot")
  [[ -f "$sf" ]] || die "Slot '$slot' is not active."

  local dest="$PRESETS_DIR/${name}.env"
  if [[ -f "$dest" ]]; then
    confirm "Overwrite presets/${name}.env?" || die "Aborted."
  fi

  local context
  context=$(context_from_file "$sf")
  if [[ -z "$context" ]] && confirm "No context block — add one?"; then
    context=$(read_context_block)
  fi

  local feature
  feature=$(grep '^feature=' "$sf" | cut -d= -f2-)

  {
    echo "# Preset: $name"
    echo "# category,slug[,branch]  (branch is used with: ./env.sh activate $name --checkout)"
    [[ -n "$feature" ]] && echo "@feature $feature"
    local cat slug link wt_path link_type canonical branch
    while IFS=$'\t' read -r cat slug link wt_path link_type canonical; do
      [[ "$cat" == *=* || -z "$link" ]] && continue
      branch=$(git -C "$wt_path" rev-parse --abbrev-ref HEAD 2>/dev/null || echo '')
      [[ "$link_type" == reference || "$branch" == HEAD ]] && branch=''
      echo "$cat,$slug${branch:+,$branch}"
    done < "$sf"
    if [[ -n "$context" ]]; then
      echo ""
      echo "@context"
      printf '%s\n' "$context"
      echo "@end"
    fi
  } > "$dest"
  ok "Saved presets/${name}.env — activate with: ./env.sh activate $name"

  # Backfill context into the live state file if it was just written
  if [[ -n "$context" ]] && ! grep -q '^@context$' "$sf"; then
    {
      echo "@context"
      printf '%s\n' "$context"
      echo "@end"
    } >> "$sf"
    write_active_md
    ok "Context added to ACTIVE.md"
  fi
}

cmd_list() {
  shopt -s nullglob
  local f name count found=0
  for f in "$PRESETS_DIR"/*.env; do
    found=1
    name=$(basename "$f" .env)
    count=$(grep -cE '^[^#@[:space:]][^,]*,' "$f" || true)
    printf '  %s%-24s%s %s repo(s)\n' "$BOLD" "$name" "$RESET" "$count"
  done
  if [[ "$found" -eq 0 ]]; then
    echo "No presets yet. Run ./env.sh adhoc, then ./env.sh save <name>."
  fi
}

cmd_help() {
  cat << EOF
${BOLD}env.sh${RESET} — compose a development environment from symlinks to git worktrees

${BOLD}Usage:${RESET} ./env.sh <command>

  ${BOLD}activate <preset>${RESET} [--as <slot>] [--feature <name>] [--checkout]
                    [--start|--no-start]
                              activate a preset; slot defaults to preset name
  ${BOLD}adhoc${RESET} [--as <slot>] [--feature <name>] [--refresh] [--start|--no-start]
                              pick repos interactively; slot defaults to "adhoc"
  ${BOLD}start${RESET} [<slot>]           run a slot's apps, hostname watcher and tab group,
                              in its open session's idle panes or a new session
  ${BOLD}deactivate${RESET} [<slot>]      remove symlinks and worktrees for a slot
  ${BOLD}status${RESET} [<slot>]          show active slot(s)
  ${BOLD}slots${RESET}                    list active slot names
  ${BOLD}save <name>${RESET} [--slot <s>] save a slot's selection as a preset
  ${BOLD}list${RESET}                     list available presets
  ${BOLD}hosts${RESET} [<slot>] [--watch [--open]]
                              give the slot's running apps <name>.<slot>.localhost
                              names via Caddy; --watch keeps them current (each
                              slot's 'hosts' tmux window runs it with --open)
  ${BOLD}kits${RESET} [apply] [<slot>]    which repos have repo kits and which aren't set up;
                              apply puts new kits into the slot's worktrees
  ${BOLD}open${RESET} [<slot>] [--all]     open the slot's apps in the browser: a Chrome tab group
                              (needs chrome-extension/ loaded) or plain tabs, per the
                              'browser' setting; --all adds servers
  ${BOLD}ref${RESET} [add|remove|update] [<slot>] [<repo>...]
                              reference repos: in the slot to read, not change
                              (latest base branch, no window, kit or hostname);
                              add with no repos picks from Bitbucket with fzf
  ${BOLD}shared${RESET} [add|remove|update|start]
                              tools kept running outside any slot (e.g. an admin
                              console): latest base branch, 'shared' tmux session,
                              <repo>.localhost names via 'hosts shared'
  ${BOLD}doctor${RESET}                   check what's installed and set up, and what each
                              missing piece turns off

Each slot gets its own directory tree (slots/<name>/) and git worktrees for
every repo, so multiple slots can include the same repo on different branches
without interfering. Activating a slot sets up a tmuxinator session and asks
whether to start its apps too (--start / --no-start answer up front).

Every worktree is put on feature/<name>/feature. An existing branch with that
name is reused; otherwise it is created (untracked) from whichever base branch
(setting base_branches: $BASE_BRANCHES) was committed to most recently. The name
comes from --feature, a preset's '@feature <name>' line, or a prompt that
defaults to the slot name.

Clones are discovered anywhere under $REPO_ROOT (a few levels deep).
Worktrees are stored under ~/.local/share/dev-env/worktrees/.
EOF
}

# start_slot_session <slot> [<idle>] — starts the slot's tmuxinator session and
# attaches to it. With idle=1 the run, test and hosts panes are left as shells;
# the config is then rewritten in full, so a later restart runs everything.
start_slot_session() {
  local slot="$1" idle="${2:-0}"
  command -v tmuxinator &>/dev/null || {
    warn "tmuxinator not found — install it to start sessions (gem install tmuxinator)"
    return 1
  }
  if [[ "$idle" -eq 1 ]]; then
    generate_tmuxinator "$slot" --idle >/dev/null
    tmuxinator start "$slot" --no-attach
    # Marks the session for ./env.sh start, which only fills in panes of idle sessions
    tmux set-option -t "$slot" @dev_env_idle 1
    generate_tmuxinator "$slot" >/dev/null
    attach_session "$slot"
  else
    tmuxinator start "$slot"
  fi
}

attach_session() {
  if [[ -n "${TMUX:-}" ]]; then
    tmux switch-client -t "$1"
  else
    tmux attach -t "$1"
  fi
}

# start [<slot>] — runs a slot's apps: in its session's idle panes if it's open
# (e.g. set up with --no-start), otherwise by starting the session
cmd_start() {
  local slot="${1:-}"
  [[ "$slot" == "$SHARED_SLOT" ]] && { shared_start; return; }
  if [[ -z "$slot" ]]; then
    local -a active=()
    while IFS= read -r s; do active+=("$s"); done < <(list_active_slots)
    case ${#active[@]} in
      0) die "No active slots." ;;
      1) slot="${active[0]}" ;;
      *) die "Multiple slots active (${active[*]}). Specify one: ./env.sh start <slot>" ;;
    esac
  fi
  [[ -f "$(state_file "$slot")" ]] || die "Slot '$slot' is not active."
  generate_tmuxinator "$slot"
  if tmux has-session -t "$slot" 2>/dev/null; then
    # Only a session opened with idle panes gets its commands run. In a session
    # started normally, a finished build or test pane is done, not waiting.
    if [[ "$(tmux show-options -v -t "$slot" @dev_env_idle 2>/dev/null)" == "1" ]]; then
      tmux_run_slot_apps "$slot"
      tmux set-option -u -t "$slot" @dev_env_idle
      ok "Started the apps in the '$slot' session (tmux attach -t $slot)"
    else
      echo "  The '$slot' session is already running: tmux attach -t $slot"
    fi
  else
    start_slot_session "$slot"
  fi
}

# print_setup_gaps <slot_setup_gaps output> — grouped by repo
print_setup_gaps() {
  local slug reason last=""
  while IFS=$'\t' read -r slug reason; do
    [[ "$slug" != "$last" ]] && printf '  %s%s%s\n' "$BOLD" "$slug" "$RESET"
    printf '    %s\n' "$reason"
    last="$slug"
  done <<< "$1"
}

# kits [apply] [<slot>] — which of the slot's repos have repo kits and which look
# unset; 'apply' puts newly made kits into the slot's existing worktrees
cmd_kits() {
  local apply=0 slot=""
  [[ "${1:-}" == "apply" ]] && { apply=1; shift; }
  slot="${1:-}"
  if [[ -z "$slot" ]]; then
    local -a active=()
    while IFS= read -r s; do active+=("$s"); done < <(list_active_slots)
    case ${#active[@]} in
      0) die "No active slots." ;;
      1) slot="${active[0]}" ;;
      *) die "Multiple slots active (${active[*]}). Specify one: ./env.sh kits [apply] <slot>" ;;
    esac
  fi
  [[ -f "$(state_file "$slot")" ]] || die "Slot '$slot' is not active."

  if [[ "$apply" -eq 1 ]]; then
    section "Applying repo kits: $slot"
    apply_repo_kits "$slot"
    generate_tmuxinator "$slot"
    echo "  Restart a repo's run pane to pick up a new run command."
  fi

  section "Repo kits: $slot"
  local cat slug link wt_path link_type canonical
  while IFS=$'\t' read -r cat slug link wt_path link_type canonical; do
    [[ "$cat" == *=* || -z "$link" || -z "$wt_path" || "$link_type" == reference ]] && continue
    if [[ -d "$REPO_KITS_DIR/$slug" ]]; then
      printf '  %-34s %skit%s\n' "$slug" "$GREEN" "$RESET"
    elif [[ -n "$(repo_setup_gaps "$slug" "$wt_path" "$cat")" ]]; then
      printf '  %-34s %snot set up%s\n' "$slug" "$YELLOW" "$RESET"
    else
      printf '  %-34s %sno kit (nothing obviously needed)%s\n' "$slug" "$DIM" "$RESET"
    fi
  done < "$(state_file "$slot")"
  local gaps
  gaps=$(slot_setup_gaps "$slot")
  if [[ -n "$gaps" ]]; then
    echo ""
    print_setup_gaps "$gaps"
    echo ""
    echo "  Kits live in $REPO_KITS_DIR/<repo>/ (see README: Repo kits)."
  fi
}

# open [<slot>] [--all] — opens the slot's named apps as a Chrome tab group, via
# the dev-env extension (chrome-extension/). Clients and extra windows by
# default; --all adds servers too.
cmd_open() {
  local slot="" all=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --all) all=1; shift ;;
      -*)    die "Unknown flag: $1" ;;
      *)     slot="$1"; shift ;;
    esac
  done
  if [[ -z "$slot" ]]; then
    local -a active=()
    while IFS= read -r s; do active+=("$s"); done < <(list_active_slots)
    case ${#active[@]} in
      0) die "No active slots." ;;
      1) slot="${active[0]}" ;;
      *) die "Multiple slots active (${active[*]}). Specify one: ./env.sh open <slot>" ;;
    esac
  fi
  open_tab_group "$slot" "$all" ||
    die "No hostnames for '$slot' yet. Run ./env.sh hosts $slot once its apps are up."
}

# ─── doctor ───────────────────────────────────────────────────────────────────

# cmd_doctor — report what's installed and set up. Required pieces fail the
# check; optional ones say which feature they turn off.
cmd_doctor() {
  local missing=0 editor caddyfile
  _have()   { printf '  %s✓%s %s\n' "$GREEN" "$RESET" "$*"; }
  _lack()   { printf '  %s✗%s %s\n' "$RED" "$RESET" "$*"; missing=$((missing + 1)); }
  _option() { printf '  %s–%s %s\n' "$YELLOW" "$RESET" "$*"; }
  _tool() { # _tool <command> <install hint> [<what it turns off, if optional>]
    if command -v "$1" >/dev/null 2>&1; then _have "$1"
    elif [[ -n "${3:-}" ]]; then _option "$1 not installed ($2): $3"
    else _lack "$1 not installed ($2)"
    fi
  }

  section "Required"
  _have "bash ${BASH_VERSION%%(*}"
  _tool git "xcode-select --install"
  _tool tmux "brew install tmux"
  _tool tmuxinator "gem install tmuxinator"
  _tool fzf "brew install fzf"
  if [[ -d "$REPO_ROOT" ]]; then _have "repo root $REPO_ROOT"
  else _lack "repo root $REPO_ROOT doesn't exist (set repo_root in $CONFIG)"
  fi

  section "Optional"
  if load_credentials; then _have "Bitbucket credentials ($CONFIG)"
  else _option "no Bitbucket credentials: adhoc, ref add and shared add ask for them on first use"
  fi
  editor=$(editor_command)
  if [[ -z "$editor" ]]; then _option "no editor: repo windows' left pane is a plain shell (set editor in $CONFIG)"
  elif command -v "${editor%% *}" >/dev/null 2>&1; then _have "editor: ${editor% .}"
  else _lack "editor '${editor%% *}' not found (set editor in $CONFIG, or 'none')"
  fi
  if claude_enabled; then
    if command -v claude >/dev/null 2>&1; then _have "Claude Code in each slot's environment window"
    else _lack "claude is on but not installed (set claude: off in $CONFIG)"
    fi
  else _option "Claude Code off: environment windows open a plain shell"
  fi
  _tool lsof "part of macOS" "no local hostnames (can't find app ports)"
  if command -v caddy >/dev/null 2>&1; then
    _have "caddy"
    caddyfile=$(caddy_main_config)
    if grep -q '.config/dev-env/caddy' "$caddyfile" 2>/dev/null; then _have "Caddyfile imports dev-env sites ($caddyfile)"
    else _option "$caddyfile doesn't import ~/.config/dev-env/caddy/*.caddy: no local hostnames (see README \"Local hostnames\")"
    fi
    if curl -fs -o /dev/null --max-time 2 http://localhost:2019/config/ 2>/dev/null; then _have "caddy running"
    else _option "caddy isn't running (brew services start caddy): no local hostnames"
    fi
  else
    _option "caddy not installed (brew install caddy): no <repo>.<slot>.localhost hostnames or browser tabs"
  fi
  case "$(browser_mode)" in
    chrome)  _have "browser: Chrome tab groups (load chrome-extension/ once, see README \"Chrome tab groups\")" ;;
    none)    _option "browser: none, so apps aren't opened" ;;
    *)       _have "browser: a tab per app in the default browser" ;;
  esac
  if [[ -d "$REPO_KITS_DIR" ]]; then _have "repo kits: $(find "$REPO_KITS_DIR" -mindepth 1 -maxdepth 1 -type d | grep -c .) in $REPO_KITS_DIR"
  else _option "no repo kits yet: fresh worktrees may not run until you make some (see README \"Repo kits\")"
  fi

  echo ""
  if [[ "$missing" -gt 0 ]]; then
    warn "$missing problem(s) above."
    return 1
  fi
  ok "Ready."
}

# ─── reference repos ──────────────────────────────────────────────────────────
#
# Repos a slot only needs to read (how another service calls an API, a shared
# library, an older implementation). Category "reference", link type
# "reference": a worktree detached at the latest base, with no tmux window,
# repo kit, hostname or setup check. Non-interactive given repo names, so the
# slot's Claude can add what it needs.

# cmd_ref [add|remove|update|status] [<slot>] [<repo>...] — the first argument
# after the subcommand is the slot when it names an active one; otherwise the
# only active slot is used
cmd_ref() {
  local sub="status"
  case "${1:-}" in
    add|remove|update|status) sub="$1"; shift ;;
  esac
  local slot=""
  if [[ -n "${1:-}" && -f "$(state_file "$1")" && "$1" != "$SHARED_SLOT" ]]; then
    slot="$1"; shift
  else
    local -a active=()
    while IFS= read -r s; do active+=("$s"); done < <(list_active_slots)
    case ${#active[@]} in
      0) die "No active slots." ;;
      1) slot="${active[0]}" ;;
      *) die "Multiple slots active (${active[*]}). Specify one: ./env.sh ref $sub <slot> [<repo>...]" ;;
    esac
  fi
  case "$sub" in
    add)    ref_add "$slot" "$@" ;;
    remove) ref_remove "$slot" "$@" ;;
    update) ref_update "$slot" ;;
    status) ref_status "$slot" ;;
  esac
}

# ref_rows <slot> — the slot's reference rows from its state file
ref_rows() {
  awk -F'\t' 'NF >= 6 && $1 !~ /=/ && $5 == "reference"' "$(state_file "$1")"
}

ref_add() {
  local slot="$1"; shift
  local sf
  sf=$(state_file "$slot")
  local -a repos=("$@")
  if [[ ${#repos[@]} -eq 0 ]]; then
    command -v fzf &>/dev/null || die "fzf is required to pick repos; or name them: ./env.sh ref add $slot <repo>..."
    section "Fetching Bitbucket repos"
    fetch_repo_list 0
    local available picked
    available=$(mktemp)
    grep -vxF -f <(awk -F'\t' 'NF >= 6 && $1 !~ /=/ {print $2}' "$sf"; printf '\n') "$CACHE_FILE" > "$available" || true
    picked=$(fzf --multi \
      --prompt="[$slot reference] Tab=mark, Enter=confirm marked: " \
      --header="Reference repos to add to $slot  |  Tab=mark  Enter=confirm marked  (no marks = cancel)" \
      --bind 'enter:transform([ "$FZF_SELECT_COUNT" -gt 0 ] && echo accept || echo abort)' \
      < "$available") || true
    rm -f "$available"
    [[ -n "$picked" ]] || { echo "Nothing selected."; return 0; }
    mapfile -t repos <<< "$picked"
  fi

  section "Adding reference repos: $slot"
  build_clone_index
  local slug target wt_path link existing added=0
  for slug in "${repos[@]}"; do
    [[ -n "$slug" ]] || continue
    existing=$(awk -F'\t' -v s="$slug" 'NF >= 6 && $1 !~ /=/ && $2 == s {print $5}' "$sf")
    if [[ "$existing" == reference ]]; then
      ok "$slug: already a reference repo"
      continue
    elif [[ -n "$existing" ]]; then
      warn "$slug: already a working repo of $slot, left as it is"
      continue
    fi
    target=$(resolve_clone "$slug") || { warn "Skipped: $slug"; continue; }
    wt_path=$(create_detached_worktree "$slot" "$slug" "$target") || { warn "Skipped: $slug"; continue; }
    link="$(slot_dir "$slot")/$REFERENCE_CATEGORY/$slug"
    mkdir -p "$(dirname "$link")"
    ln -s "$wt_path" "$link"
    # Repo rows go before the @context block, which runs to the end of the file
    awk -v row="$REFERENCE_CATEGORY"$'\t'"$slug"$'\t'"$link"$'\t'"$wt_path"$'\t'"reference"$'\t'"$target" '
      /^@context$/ && !done { print row; done = 1 }
      { print }
      END { if (!done) print row }' "$sf" > "$sf.tmp" && mv "$sf.tmp" "$sf"
    ok "$REFERENCE_CATEGORY/$slug → $wt_path"
    added=$((added + 1))
  done
  [[ "$added" -gt 0 ]] || return 0
  write_active_md
  write_slot_claude_md "$slot"
  echo "  Read them at slots/$slot/$REFERENCE_CATEGORY/<repo>. ACTIVE.md and the slot's CLAUDE.md list them."
}

ref_remove() {
  local slot="$1"; shift
  local sf rows
  sf=$(state_file "$slot")
  rows=$(ref_rows "$slot")
  [[ -n "$rows" ]] || { echo "No reference repos in $slot."; return 0; }
  local -a repos=("$@")
  if [[ ${#repos[@]} -eq 0 ]]; then
    command -v fzf &>/dev/null || die "Name the repos: ./env.sh ref remove $slot <repo>..."
    local chosen
    chosen=$(cut -f2 <<< "$rows" | fzf --multi \
      --prompt="[$slot reference] Tab to mark, Enter to remove: " \
      --bind 'enter:transform([ "$FZF_SELECT_COUNT" -gt 0 ] && echo accept || echo abort)') || true
    [[ -n "$chosen" ]] || { echo "Nothing removed."; return 0; }
    mapfile -t repos <<< "$chosen"
  fi
  local want slug cat link wt_path link_type canonical removed=0
  for want in "${repos[@]}"; do
    slug="$want" link=""
    IFS=$'\t' read -r cat slug link wt_path link_type canonical \
      < <(awk -F'\t' -v s="$want" '$2 == s' <<< "$rows") || true
    slug="$want"
    if [[ -z "${link:-}" ]]; then
      warn "$slug: not a reference repo of $slot"
      continue
    fi
    if [[ -n $(git -C "$wt_path" status --porcelain 2>/dev/null) ]] &&
       ! confirm "$slug has uncommitted changes. Remove anyway?"; then
      continue
    fi
    [[ -L "$link" ]] && rm "$link"
    git -C "$canonical" worktree remove --force "$wt_path" 2>/dev/null ||
      warn "Could not remove worktree: $wt_path"
    awk -F'\t' -v s="$slug" '!($5 == "reference" && $2 == s)' "$sf" > "$sf.tmp" && mv "$sf.tmp" "$sf"
    ok "Removed $slug"
    removed=$((removed + 1))
  done
  rmdir "$(slot_dir "$slot")/$REFERENCE_CATEGORY" 2>/dev/null || true
  [[ "$removed" -gt 0 ]] || return 0
  write_active_md
  write_slot_claude_md "$slot"
}

# ref_update <slot> — moves each clean reference worktree to the latest base
ref_update() {
  local slot="$1" cat slug link wt_path link_type canonical base before after
  while IFS=$'\t' read -r cat slug link wt_path link_type canonical; do
    if [[ -n $(git -C "$wt_path" status --porcelain 2>/dev/null) ]]; then
      warn "$slug: uncommitted changes, not updated"
      continue
    fi
    git -C "$canonical" fetch --quiet --prune origin 2>/dev/null || warn "$slug: could not fetch origin"
    base=$(find_base_ref "$canonical")
    before=$(git -C "$wt_path" rev-parse --short HEAD)
    git -C "$wt_path" checkout --quiet --detach "$base" || { warn "$slug: could not check out $base"; continue; }
    after=$(git -C "$wt_path" rev-parse --short HEAD)
    if [[ "$before" == "$after" ]]; then
      ok "$slug: up to date ($base, $after)"
    else
      ok "$slug: $before → $after ($base)"
    fi
  done < <(ref_rows "$slot")
}

ref_status() {
  local slot="$1" rows
  rows=$(ref_rows "$slot")
  section "Reference repos: $slot"
  if [[ -z "$rows" ]]; then
    echo "  None. Add some with: ./env.sh ref add $slot [<repo>...]"
    return 0
  fi
  local cat slug link wt_path link_type canonical state
  while IFS=$'\t' read -r cat slug link wt_path link_type canonical; do
    state="$(git -C "$wt_path" rev-parse --short HEAD 2>/dev/null || echo '?')"
    [[ -n $(git -C "$wt_path" status --porcelain 2>/dev/null) ]] && state+=", dirty"
    printf '  %-34s %s[%s]%s  %s\n' "$slug" "$DIM" "$state" "$RESET" "$wt_path"
  done <<< "$rows"
}

# ─── shared tools ─────────────────────────────────────────────────────────────
#
# Tools you want running regardless of the work in hand (e.g. the internal
# admin console). They live in the reserved slot "shared": worktrees detached at
# the latest base branch rather than on a feature branch, a 'shared' tmux
# session, and <repo>.localhost names. Not listed with the work slots or in
# ACTIVE.md.

# offer_shared_tools — during slot setup: offer to add shared tools, and to
# start them if their session isn't running
offer_shared_tools() {
  section "Shared tools"
  local names
  names=$(shared_rows | cut -f2 | paste -sd, - | sed 's/,/, /g')
  if [[ -n "$names" ]]; then
    echo "  In the shared set: $names (http://<repo>.localhost)"
  else
    echo "  None yet. Shared tools run outside any slot, e.g. an admin console you want whatever you're working on."
  fi
  if confirm_no "Add tools to the shared set?"; then
    shared_add
    return
  fi
  [[ -n "$names" ]] || return 0
  if shared_session_running; then
    echo "  Their session is running (tmux attach -t $SHARED_SLOT)."
  elif confirm "Start the shared tools?"; then
    shared_start
  fi
}

cmd_shared() {
  local sub="${1:-status}"
  [[ $# -gt 0 ]] && shift
  case "$sub" in
    add)    shared_add "$@" ;;
    remove) shared_remove ;;
    update) shared_update ;;
    start)  shared_start ;;
    status) shared_status ;;
    *) die "Usage: ./env.sh shared [status|add [--refresh]|remove|update|start]" ;;
  esac
}

# shared_rows — the shared slot's repo rows from its state file
shared_rows() {
  local sf
  sf=$(state_file "$SHARED_SLOT")
  [[ -f "$sf" ]] || return 0
  awk -F'\t' 'NF >= 6 && $1 !~ /=/' "$sf"
}

shared_session_running() { tmux has-session -t "$SHARED_SLOT" 2>/dev/null; }

shared_add() {
  local refresh=0
  [[ "${1:-}" == "--refresh" ]] && refresh=1
  command -v fzf &>/dev/null || die "fzf is required: brew install fzf"

  section "Fetching Bitbucket repos"
  fetch_repo_list "$refresh"

  # Offer only repos that aren't shared yet
  local available
  available=$(mktemp)
  grep -vxF -f <(shared_rows | cut -f2; printf '\n') "$CACHE_FILE" > "$available" || true

  section "Categories"
  local cats_raw c
  cats_raw=$(prompt "Categories (comma-separated)" "clients,servers,libraries")
  IFS=',' read -ra CATEGORIES <<< "$cats_raw"
  local -a trimmed=()
  for c in "${CATEGORIES[@]}"; do trimmed+=("${c// /}"); done
  CATEGORIES=("${trimmed[@]}")

  section "Repo Selection"
  for c in "${CATEGORIES[@]}"; do
    echo ""
    echo "Selecting shared repos for '$c' (Tab=mark, Enter=confirm)..."
    "$SELF_DIR/scripts/select-repos.sh" "$c" "$available"
  done
  rm -f "$available"

  local -a picked=()
  local sel_file slug
  for c in "${CATEGORIES[@]}"; do
    sel_file="/tmp/dev-env-selected-${c}.txt"
    [[ -f "$sel_file" ]] || continue
    while IFS= read -r slug; do
      [[ -n "$slug" ]] && picked+=("$c"$'\t'"$slug")
    done < <(awk '!seen[$0]++' "$sel_file")
  done
  [[ ${#picked[@]} -gt 0 ]] || { echo "Nothing selected."; return 0; }

  section "Resolving repositories"
  build_clone_index
  local sf entry cat target wt_path link
  sf=$(state_file "$SHARED_SLOT")
  if [[ ! -f "$sf" ]]; then
    {
      echo "active_preset=$SHARED_SLOT"
      echo "slot=$SHARED_SLOT"
      echo "created_at=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    } > "$sf"
  fi

  local -a added=()
  for entry in "${picked[@]}"; do
    IFS=$'\t' read -r cat slug <<< "$entry"
    target=$(resolve_clone "$slug") || { warn "Skipped: $slug"; continue; }
    wt_path=$(create_shared_worktree "$slug" "$target") || { warn "Skipped: $slug"; continue; }
    link="$(slot_dir "$SHARED_SLOT")/$cat/$slug"
    mkdir -p "$(dirname "$link")"
    ln -s "$wt_path" "$link"
    printf '%s\t%s\t%s\t%s\tworktree\t%s\n' "$cat" "$slug" "$link" "$wt_path" "$target" >> "$sf"
    added+=("$slug"$'\t'"$wt_path")
  done
  [[ ${#added[@]} -gt 0 ]] || die "Nothing was added."

  local name path
  for entry in "${added[@]}"; do
    IFS=$'\t' read -r name path <<< "$entry"
    apply_repo_kit "$SHARED_SLOT" "$name" "$path"
  done

  section "tmux session: $SHARED_SLOT"
  if shared_session_running; then
    generate_tmuxinator "$SHARED_SLOT"
    for entry in "${added[@]}"; do
      IFS=$'\t' read -r name path <<< "$entry"
      tmux_add_repo_window "$SHARED_SLOT" "$SHARED_SLOT" "$name" "$path"
      ok "Started $name in the running '$SHARED_SLOT' session"
    done
    ensure_hosts_window "$SHARED_SLOT"
  else
    shared_start
  fi
  echo "  Hostnames (http://<repo>.localhost) appear as they come up, from the session's 'hosts' window"
  local gaps
  gaps=$(slot_setup_gaps "$SHARED_SLOT")
  if [[ -n "$gaps" ]]; then
    section "Shared tools not set up to run yet"
    print_setup_gaps "$gaps"
    if claude_enabled; then
      echo "  The Claude in any slot's environment window can set them up (see its CLAUDE.md),"
      echo "  or check again with: ./env.sh kits $SHARED_SLOT"
    else
      echo "  Set them up as repo kits (see README \"Repo kits\"), then check with: ./env.sh kits $SHARED_SLOT"
    fi
  fi
}

shared_remove() {
  command -v fzf &>/dev/null || die "fzf is required: brew install fzf"
  local rows
  rows=$(shared_rows)
  [[ -n "$rows" ]] || { echo "No shared tools."; return 0; }

  local chosen
  chosen=$(cut -f1,2 <<< "$rows" | tr '\t' '/' | fzf --multi \
    --prompt="[shared] Tab to mark, Enter to remove: " \
    --header="Removing shared tools  |  Tab=mark  Enter=confirm marked  (no marks = cancel)" \
    --bind 'enter:transform([ "$FZF_SELECT_COUNT" -gt 0 ] && echo accept || echo abort)') || true
  [[ -n "$chosen" ]] || { echo "Nothing removed."; return 0; }

  local sf item cat slug link wt_path link_type canonical
  sf=$(state_file "$SHARED_SLOT")
  while IFS= read -r item; do
    cat="${item%%/*}" slug="${item#*/}"
    IFS=$'\t' read -r cat slug link wt_path link_type canonical \
      < <(awk -F'\t' -v c="$cat" -v s="$slug" '$1 == c && $2 == s' "$sf")
    if [[ -n $(git -C "$wt_path" status --porcelain 2>/dev/null) ]] &&
       ! confirm "$slug has uncommitted changes. Remove anyway?"; then
      continue
    fi
    shared_session_running && tmux kill-window -t "$SHARED_SLOT:$slug" 2>/dev/null || true
    [[ -L "$link" ]] && rm "$link"
    git -C "$canonical" worktree remove --force "$wt_path" 2>/dev/null ||
      warn "Could not remove worktree: $wt_path"
    awk -F'\t' -v c="$cat" -v s="$slug" '!($1 == c && $2 == s)' "$sf" > "$sf.tmp" && mv "$sf.tmp" "$sf"
    ok "Removed $slug"
  done <<< "$chosen"

  if [[ -z $(shared_rows) ]]; then
    rm -f "$sf" "$TMUXINATOR_DIR/${SHARED_SLOT}.yml"
    shared_session_running && tmux kill-session -t "$SHARED_SLOT"
    remove_hosts "$SHARED_SLOT"
  else
    generate_tmuxinator "$SHARED_SLOT"
    [[ -f "$(caddy_sites_file "$SHARED_SLOT")" ]] && generate_hosts "$SHARED_SLOT"
  fi
}

# shared_update — moves each clean shared worktree to the latest base. Restart
# a tool's dev server afterwards if it doesn't reload on its own.
shared_update() {
  local cat slug link wt_path link_type canonical base before after
  while IFS=$'\t' read -r cat slug link wt_path link_type canonical; do
    if [[ -n $(git -C "$wt_path" status --porcelain 2>/dev/null) ]]; then
      warn "$slug: uncommitted changes, not updated"
      continue
    fi
    git -C "$canonical" fetch --quiet --prune origin 2>/dev/null || warn "$slug: could not fetch origin"
    base=$(find_base_ref "$canonical")
    before=$(git -C "$wt_path" rev-parse --short HEAD)
    git -C "$wt_path" checkout --quiet --detach "$base" || { warn "$slug: could not check out $base"; continue; }
    after=$(git -C "$wt_path" rev-parse --short HEAD)
    if [[ "$before" == "$after" ]]; then
      ok "$slug: up to date ($base, $after)"
    else
      ok "$slug: $before → $after ($base)"
    fi
  done < <(shared_rows)
}

shared_start() {
  [[ -n $(shared_rows) ]] || { echo "No shared tools. Add some with: ./env.sh shared add"; return 0; }
  if shared_session_running; then
    echo "  The '$SHARED_SLOT' session is already running: tmux attach -t $SHARED_SLOT"
    return 0
  fi
  generate_tmuxinator "$SHARED_SLOT"
  command -v tmuxinator &>/dev/null || die "tmuxinator not found (gem install tmuxinator)"
  tmuxinator start "$SHARED_SLOT" --no-attach
  ok "Started the '$SHARED_SLOT' session: tmux attach -t $SHARED_SLOT"
}

shared_status() {
  local rows
  rows=$(shared_rows)
  section "Shared tools"
  if [[ -z "$rows" ]]; then
    echo "  None. Add some with: ./env.sh shared add"
    return 0
  fi
  local cat slug link wt_path link_type canonical state
  while IFS=$'\t' read -r cat slug link wt_path link_type canonical; do
    state="$(git -C "$wt_path" rev-parse --short HEAD 2>/dev/null || echo '?')"
    [[ -n $(git -C "$wt_path" status --porcelain 2>/dev/null) ]] && state+=", dirty"
    printf '  %s%-12s%s %-30s %s[%s]%s\n' "$BOLD" "$cat" "$RESET" "$slug" "$DIM" "$state" "$RESET"
  done <<< "$rows"
  echo ""
  if shared_session_running; then
    echo "  Session: running (tmux attach -t $SHARED_SLOT)"
  else
    echo "  Session: stopped (./env.sh shared start)"
  fi
  local sites
  sites=$(caddy_sites_file "$SHARED_SLOT")
  if [[ -f "$sites" ]] && grep -q '^http://' "$sites"; then
    echo "  Hostnames (refresh: ./env.sh hosts $SHARED_SLOT):"
    sed -n 's#^\(http://[^ ]*\) {#    \1#p' "$sites"
  fi
}

# ─── dispatch ─────────────────────────────────────────────────────────────────

[[ -f "$ACTIVE_MD" ]] || write_neutral_active_md

case "${1:-help}" in
  activate)   shift; cmd_activate "$@" ;;
  adhoc)      shift; cmd_adhoc "$@" ;;
  deactivate) shift; do_deactivate "${1:-}" ;;
  status)     shift; cmd_status "${1:-}" ;;
  slots)      cmd_slots ;;
  save)       shift; cmd_save "$@" ;;
  list)       cmd_list ;;
  hosts)      shift; cmd_hosts "$@" ;;
  shared)     shift; cmd_shared "$@" ;;
  open)       shift; cmd_open "$@" ;;
  start)      shift; cmd_start "${1:-}" ;;
  kits)       shift; cmd_kits "$@" ;;
  ref)        shift; cmd_ref "$@" ;;
  doctor)     cmd_doctor ;;
  help|--help|-h) cmd_help ;;
  *) die "Unknown command: $1 (see: ./env.sh help)" ;;
esac
