#!/usr/bin/env bash
#
# reposcan.sh — multi-repo sync & change tracker
#
# Works on both `repo`-tool trees (AOSP/LineageOS/AxionOS style, has a
# .repo/ dir) and plain nested-git-repo forests (falls back to walking
# for .git dirs and using `git pull` per project).
#
# USAGE:
#   ./reposcan.sh                          -> short usage hint
#   ./reposcan.sh --help                   -> full help
#   ./reposcan.sh --sync [repo] [-f] [-- <args>]
#   ./reposcan.sh -t7 | -t7-9 [-v]          -> commit activity, no sync
#   ./reposcan.sh --date 10/08/26[-DD/MM/YY] [-v]
#   ./reposcan.sh --report [N|list]        -> view a saved sync log
#   ./reposcan.sh --list                   -> list discovered repos
#
set -uo pipefail

# ---------------------------------------------------------------------
# config / colors
# ---------------------------------------------------------------------
LOG_DIR="./repo-sync-logs"
TS="$(date +%Y%m%d_%H%M%S)"
LOG_FILE="${LOG_DIR}/sync_${TS}.log"
SCRIPT_NAME="$(basename "$0")"
SCRIPT_DIR="$(dirname "$(readlink -f "$0")")"

if [[ -t 1 ]]; then
  C_GREEN=$'\e[32m'; C_YELLOW=$'\e[33m'; C_RED=$'\e[31m'; C_CYAN=$'\e[36m'
  C_DIM=$'\e[2m'; C_BOLD=$'\e[1m'; C_RESET=$'\e[0m'
else
  C_GREEN=""; C_YELLOW=""; C_RED=""; C_CYAN=""; C_DIM=""; C_BOLD=""; C_RESET=""
fi

# fd 3 = the real terminal, kept aside so the live progress indicator
# still shows even while stdout is being tee'd into a log file.
exec 3>&2

REPO_MODE=""
REPO_PATHS=()
declare -gA REPO_NAMES=()   # path -> "Org/repo_name" (from `repo list`, or derived from origin URL)

# ---------------------------------------------------------------------
# help
# ---------------------------------------------------------------------
show_short_help() {
  cat <<EOF
${C_BOLD}reposcan.sh${C_RESET} — multi-repo sync & change tracker
Run '${C_BOLD}${SCRIPT_NAME} --help${C_RESET}' for the full command list.
EOF
}

show_full_help() {
  cat <<EOF
${C_BOLD}reposcan.sh${C_RESET} — multi-repo sync & change tracker

USAGE:
  ${SCRIPT_NAME} [command] [options]

COMMANDS:
  ${C_GREEN}--device${C_RESET} <name>
        Symlink .repo/local_manifests/local_manifest.xml to
        ${SCRIPT_DIR}/local_manifests/<name>.xml, then continue with
        whatever command follows (or just switch, if none does). Run
        from the ROM root (needs .repo/).

  ${C_GREEN}-s, --sync${C_RESET} [repo] [-f|--force] [-- <extra 'repo sync'/'git pull' args>]
        With no [repo]: sync every project, then report which repos
        changed and how many commits landed in each. Shows a live
        "scanning N/total" counter and always writes a full log under
        ${LOG_DIR}/.
        With [repo]: sync just that one project. [repo] can be the
        exact path (e.g. device/oneplus/lemonade) or a substring that
        matches one project's path or upstream name (e.g. lemonade).
        With -f / --force: if the sync fails, wipe the local working
        copy AND the matching .repo/projects/<path>.git (and
        .repo/project-objects entry) for the affected project(s), then
        retry the sync once. This is destructive — any uncommitted
        local changes in the wiped project(s) are lost — so it's only
        ever done when you explicitly pass -f.

  ${C_GREEN}-t<N>${C_RESET} [-v]            e.g. -t7    -> commits in the last 7 days
  ${C_GREEN}-t<N>-<M>${C_RESET} [-v]        e.g. -t7-9  -> commits from 9 days ago to 7 days ago
  ${C_GREEN}-d, --date <DD/MM/YY>${C_RESET} [-v]             e.g. --date 10/08/26         (that date -> now)
  ${C_GREEN}-d, --date <DD/MM/YY>-<DD/MM/YY>${C_RESET} [-v]  e.g. --date 05/08/26-10/08/26 (range)
        Report commit activity per repo for a time window, WITHOUT
        syncing anything — reads local git history only. Prints repo
        path, upstream project name, and commit count.
        With -v / --verbose: instead of a summary table, prints the
        full commit log for every repo with activity in the window
        (hash, date, and message per commit) — same style as the
        detailed per-project breakdown shown by --sync.

  ${C_GREEN}-r, --report${C_RESET} [N|list]
        Show a previously saved sync report from ${LOG_DIR}/, printed
        straight to the screen — no new file is written. Default N=1
        shows the most recent log. Use 'list' to see all saved logs.

  ${C_GREEN}-l, --list${C_RESET}
        List every repo/project discovered in the current tree.

  ${C_GREEN}-h, --help${C_RESET}
        Show this help.

  (no arguments)
        Show a short usage hint.

EXAMPLES:
  ${SCRIPT_NAME} --device lemonade -s
  ${SCRIPT_NAME} --device lemonadep -s -f
  ${SCRIPT_NAME} --sync
  ${SCRIPT_NAME} --sync -- -j8 -c --force-sync
  ${SCRIPT_NAME} --sync device/oneplus/lemonade
  ${SCRIPT_NAME} --sync hardware/oplus -f
  ${SCRIPT_NAME} -t7
  ${SCRIPT_NAME} -t7-9
  ${SCRIPT_NAME} -t7 -v
  ${SCRIPT_NAME} --date 10/08/26
  ${SCRIPT_NAME} --date 05/08/26-10/08/26
  ${SCRIPT_NAME} --date 05/08/26-10/08/26 -v
  ${SCRIPT_NAME} --report list
  ${SCRIPT_NAME} --report 2
  ${SCRIPT_NAME} --list
EOF
}

# ---------------------------------------------------------------------
# repo discovery — also builds REPO_NAMES (upstream project name)
# ---------------------------------------------------------------------
discover_repos() {
  REPO_PATHS=()
  REPO_NAMES=()

  if [[ -d .repo ]] && command -v repo >/dev/null 2>&1; then
    REPO_MODE="repo"
    # `repo list` prints "path : name" — name is the manifest project
    # name (e.g. "LineageOS/android_vendor_apn"), which is far more
    # useful for finding the repo online than the local path alone.
    while IFS= read -r line; do
      [[ -z "$line" ]] && continue
      local p="${line%% : *}"
      local n="${line#* : }"
      REPO_PATHS+=("$p")
      REPO_NAMES["$p"]="$n"
    done < <(repo list 2>/dev/null)
  fi

  # fall back to a plain git forest if 'repo' gave us nothing (or isn't
  # a repo-tool tree at all)
  if [[ "${#REPO_PATHS[@]}" -eq 0 ]]; then
    REPO_MODE="git"
    while IFS= read -r p; do
      [[ -n "$p" ]] && REPO_PATHS+=("$p")
    done < <(find . -mindepth 1 -maxdepth 6 -type d -name .git -not -path '*/.repo/*' 2>/dev/null \
              | sed 's#/\.git$##; s#^\./##' | sort)
    if [[ "${#REPO_PATHS[@]}" -eq 0 ]] && git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
      REPO_PATHS+=(".")
    fi
    local p url
    for p in "${REPO_PATHS[@]}"; do
      url="$(git -C "$p" remote get-url origin 2>/dev/null)"
      if [[ -n "$url" ]]; then
        REPO_NAMES["$p"]="$(sed -E 's#^.*[:/]([^/]+/[^/]+?)(\.git)?$#\1#' <<< "$url")"
      else
        REPO_NAMES["$p"]="-"
      fi
    done
  fi
}

project_name_for() {
  echo "${REPO_NAMES[$1]:--}"
}

# resolves a user-given repo query (exact path, or substring of path /
# upstream name) to exactly one path from REPO_PATHS. Prints the path
# on success; prints diagnostics to stderr and returns 1 otherwise.
resolve_target_repo() {
  local query="$1" p n
  for p in "${REPO_PATHS[@]}"; do
    [[ "$p" == "$query" ]] && { echo "$p"; return 0; }
  done
  local -a matches=()
  for p in "${REPO_PATHS[@]}"; do
    n="${REPO_NAMES[$p]:-}"
    if [[ "$p" == *"$query"* || "$n" == *"$query"* ]]; then
      matches+=("$p")
    fi
  done
  if [[ "${#matches[@]}" -eq 1 ]]; then
    echo "${matches[0]}"
    return 0
  elif [[ "${#matches[@]}" -gt 1 ]]; then
    echo "${C_YELLOW}'$query' matches more than one repo — be more specific:${C_RESET}" >&2
    for p in "${matches[@]}"; do
      printf '  %s  (%s)\n' "$p" "$(project_name_for "$p")" >&2
    done
    return 1
  else
    echo "${C_RED}no repo matches '$query'${C_RESET}" >&2
    return 1
  fi
}

# ---------------------------------------------------------------------
# live progress (writes to the real terminal via fd 3, not the log)
# ---------------------------------------------------------------------
progress() {
  local cur="$1" total="$2" path="$3"
  printf '\r%s==> scanning %d/%d:%s %-60s' "$C_CYAN" "$cur" "$total" "$C_RESET" "${path:0:60}" >&3
}
progress_done() {
  printf '\r%80s\r' "" >&3
}

# ---------------------------------------------------------------------
# git helpers
# ---------------------------------------------------------------------
head_sha() {
  git -C "$1" rev-parse HEAD 2>/dev/null || echo NONE
}

take_snapshot() {
  local outfile="$1"
  local total=${#REPO_PATHS[@]}
  local i=0
  : > "$outfile"
  for path in "${REPO_PATHS[@]}"; do
    i=$((i + 1))
    progress "$i" "$total" "$path"
    printf '%s\t%s\n' "$path" "$(head_sha "$path")" >> "$outfile"
  done
  progress_done
}

# Runs a command with output streaming live to the terminal/log AND captured
# into the variable named by $1. The old 'out="$(repo sync ...)"' form
# swallowed every byte until the command exited — a frozen screen for the
# whole sync, with repo's own progress never appearing. The capture is still
# needed because classify_sync_error() inspects the text afterwards.
#
# 'repo sync's own progress bar (and git's) is gated on isatty(stdout) —
# piping into tee (below) makes stdout a pipe, so real output went blank
# until the command finished. 'script' gives the child a real pty so its
# progress renders as if run interactively; that pty output is what gets
# piped into tee.
run_streamed() {
  local __var="$1"; shift
  local __tmp __rc __cmd
  __tmp="$(mktemp)"
  if command -v script >/dev/null 2>&1; then
    __cmd="$(printf '%q ' "$@")"
    script -qec "$__cmd" /dev/null 2>&1 | tee "$__tmp"
  else
    "$@" 2>&1 | tee "$__tmp"
  fi
  __rc="${PIPESTATUS[0]}"
  printf -v "$__var" '%s' "$(<"$__tmp")"
  rm -f "$__tmp"
  return "$__rc"
}

# Reports how a project's HEAD moved, robust to force-sync / rebase / rewind.
# The old 'rev-list --count A..B' (two-dot) counted only commits ADDED and
# reported "1" for a sync that force-synced 2 commits away and added 1 new
# one — the removed commits were invisible. Verified against a synthetic
# rewind: two-dot reports "1", while 'rev-list --left-right --count A...B'
# correctly reports "2 <tab> 1" (removed, added).
#
# Echoes: "+N -M" | "new" | "gone" | "replaced"
count_commits() {
  local path="$1" before="$2" after="$3" counts removed added

  [[ -z "$before" || "$before" == "NONE" ]] && { echo "new";  return; }
  [[ -z "$after"  || "$after"  == "NONE" ]] && { echo "gone"; return; }
  git -C "$path" cat-file -e "${before}^{commit}" 2>/dev/null \
    || { echo "replaced"; return; }

  counts="$(git -C "$path" rev-list --left-right --count "${before}...${after}" 2>/dev/null)"
  [[ -z "$counts" ]] && { echo "replaced"; return; }
  removed="${counts%%[[:space:]]*}"
  added="${counts##*[[:space:]]}"
  echo "+${added} -${removed}"
}

# wipes the local working copy AND the repo-tool internal object dirs
# for one project, so the next sync re-fetches it from scratch.
# DESTRUCTIVE — only ever called when the user passed -f/--force.
clean_project() {
  local path="$1" name
  name="$(project_name_for "$path")"
  echo "${C_YELLOW}==> force: wiping local copy of '$path' (${name}) before resync${C_RESET}"
  rm -rf -- "./${path}"
  if [[ "$REPO_MODE" == "repo" ]]; then
    rm -rf -- ".repo/projects/${path}.git"
    if [[ -n "$name" && "$name" != "-" ]]; then
      rm -rf -- ".repo/project-objects/${name}.git"
    fi
  fi
}

# classifies sync/pull error output as:
#   mismatch - the local repo genuinely doesn't match what the manifest
#              /remote expects (bad ref, unknown revision, corrupt
#              object, unrelated histories, etc.) — the case -f is for.
#   network  - looks like a transient connectivity/host/TLS problem.
#              Wiping and re-cloning won't fix this, just retry.
#   unknown  - anything else (auth failure, disk full, permissions,
#              dirty working tree, etc.) — deliberately NOT auto-cleaned,
#              since guessing wrong here can destroy uncommitted work.
classify_sync_error() {
  local text="$1"
  if grep -qiE \
    "could not resolve host|connection timed out|connection refused|network is unreachable|could not connect to|ssl_error|ssl connect error|empty reply from server|temporary failure in name resolution|the requested url returned error 5[0-9][0-9]|operation timed out|could not read from remote repository.*(timed out|network)" \
    <<< "$text"; then
    echo "network"
    return
  fi
  if grep -qiE \
    "couldn't find remote ref|reference is not a tree|not a valid object name|unadvertised object|fatal: bad object|does not have any commits yet|fatal: bad revision|no such ref|remote ref does not exist|unable to read tree|revision .* not found|manifest.*(mismatch|does not match)|fatal: not a valid ref|refusing to merge unrelated histories|fatal: couldn't find remote ref|error: rpc failed.*curl 22|repository .* not found|fatal: repository .* does not exist|hooks is different in|cannot overwrite a local work tree|force-sync not enabled|is different in .* vs .*project-objects|syncerror" \
    <<< "$text"; then
    echo "mismatch"
    return
  fi
  echo "unknown"
}

# prints a full, human-readable breakdown for one changed project,
# handling pruned/unrelated history gracefully instead of masking it
print_change_details() {
  local path="$1" before_sha="$2" after_sha="$3"
  local name log_output rc
  name="$(project_name_for "$path")"
  log_output="$(git -C "$path" log --oneline --no-decorate "${before_sha}..${after_sha}" 2>&1)"
  rc=$?

  if [[ $rc -eq 0 ]]; then
    # Two-dot (before..after) only shows commits ADDED. Also check the
    # reverse direction (after..before) so a force-sync rewind — which two-
    # dot alone reports as "0 commit(s)" with nothing to show — is visible.
    local added_count removed_count removed_log
    if [[ -z "$log_output" ]]; then
      added_count=0
    else
      added_count="$(printf '%s\n' "$log_output" | grep -c .)"
    fi
    removed_log="$(git -C "$path" log --oneline --no-decorate "${after_sha}..${before_sha}" 2>/dev/null)"
    if [[ -z "$removed_log" ]]; then
      removed_count=0
    else
      removed_count="$(printf '%s\n' "$removed_log" | grep -c .)"
    fi
    echo ""
    echo "${C_GREEN}[CHANGED]${C_RESET} $path  (${name})  (${before_sha:0:12} -> ${after_sha:0:12}, +${added_count} -${removed_count} commit(s))"
    if [[ "$added_count" -gt 0 ]]; then
      printf '%s\n' "$log_output" | sed 's/^/    /'
    fi
    if [[ "$removed_count" -gt 0 ]]; then
      echo "  ${C_RED}removed by force-sync/rebase:${C_RESET}"
      printf '%s\n' "$removed_log" | sed 's/^/    - /'
    fi
  else
    echo ""
    if ! git -C "$path" cat-file -e "${before_sha}^{commit}" 2>/dev/null; then
      echo "${C_YELLOW}[CHANGED — old history pruned]${C_RESET} $path  (${name})  (${before_sha:0:12} -> ${after_sha:0:12})"
      echo "    ${C_DIM}old commit no longer present locally (shallow sync / branch switch / --force-sync).${C_RESET}"
      echo "    ${C_DIM}showing most recent commits on new HEAD instead:${C_RESET}"
      git -C "$path" log --oneline --no-decorate -n 20 "$after_sha" 2>/dev/null | sed 's/^/    /'
    else
      echo "${C_YELLOW}[CHANGED — unrelated history]${C_RESET} $path  (${name})  (${before_sha:0:12} -> ${after_sha:0:12})"
      echo "    ${C_DIM}git error: ${log_output}${C_RESET}"
    fi
  fi

  echo "  ${C_BOLD}files touched:${C_RESET}"
  local diffstat rc2
  diffstat="$(git -C "$path" diff --stat "${before_sha}" "${after_sha}" 2>&1)"
  rc2=$?
  if [[ $rc2 -eq 0 ]]; then
    printf '%s\n' "$diffstat" | sed 's/^/    /'
  else
    echo "    ${C_DIM}unable to diff (objects missing locally): ${diffstat}${C_RESET}"
  fi
}

# prints a full commit-log breakdown for one repo within a time window
# (path, project, hash + date + subject per commit) — the -v/--verbose
# companion to the summary table in run_time_report, styled the same
# way as print_change_details above.
print_time_window_details() {
  local path="$1" name="$2" since="$3" until="$4"
  local log_output count
  log_output="$(git -C "$path" log --since="$since" --until="$until" \
                  --pretty=format:'%h  %ad  %s' --date=short 2>/dev/null)"
  count=0
  [[ -n "$log_output" ]] && count="$(printf '%s\n' "$log_output" | grep -c .)"
  echo ""
  echo "${C_GREEN}[COMMITS]${C_RESET} $path  (${name})  — ${count} commit(s)"
  printf '%s\n' "$log_output" | sed 's/^/    /'
}

# ---------------------------------------------------------------------
# -s / --sync
# ---------------------------------------------------------------------
cmd_sync() {
  local TARGET_QUERY="" FORCE=0
  local SYNC_ARGS=()

  while [[ $# -gt 0 ]]; do
    case "$1" in
      -f|--force) FORCE=1; shift ;;
      --) shift; SYNC_ARGS=("$@"); break ;;
      -*) echo "${C_YELLOW}ignoring unknown sync flag: $1${C_RESET}" >&2; shift ;;
      *)
        if [[ -n "$TARGET_QUERY" ]]; then
          echo "${C_RED}only one target repo is supported at a time${C_RESET}" >&2
          return 2
        fi
        TARGET_QUERY="$1"; shift ;;
    esac
  done

  mkdir -p "$LOG_DIR"

  # From here on, tee everything (stdout+stderr) into the log file.
  # This is a real fix over the old script: previously the report and
  # the "repo sync" output were logged in two separate, easy-to-miss
  # pipelines, and if either one silently produced nothing the log
  # ended up looking empty. Now the whole function's output is one
  # continuous stream into the same file.
  exec > >(tee -a "$LOG_FILE") 2>&1

  discover_repos
  local total=${#REPO_PATHS[@]}
  if [[ "$total" -eq 0 ]]; then
    echo "${C_RED}error: no repositories found (looked for .repo/ or nested .git/ dirs)${C_RESET}"
    return 2
  fi

  local TARGET_REPO=""
  if [[ -n "$TARGET_QUERY" ]]; then
    if ! TARGET_REPO="$(resolve_target_repo "$TARGET_QUERY")"; then
      return 2
    fi
    echo "${C_BOLD}==> Target repo: ${TARGET_REPO}  (${REPO_NAMES[$TARGET_REPO]})${C_RESET}"
    REPO_PATHS=("$TARGET_REPO")
    total=1
  else
    echo "${C_BOLD}==> Found ${total} repositories (mode: ${REPO_MODE})${C_RESET}"
  fi

  local BEFORE_SNAPSHOT AFTER_SNAPSHOT
  BEFORE_SNAPSHOT="$(mktemp)"
  AFTER_SNAPSHOT="$(mktemp)"

  echo "${C_BOLD}==> Snapshotting current HEADs (pre-sync)...${C_RESET}"
  take_snapshot "$BEFORE_SNAPSHOT"

  local sync_rc=0
  if [[ "$REPO_MODE" == "repo" ]]; then
    if [[ -n "$TARGET_REPO" ]]; then
      echo "${C_BOLD}==> Running: repo sync ${SYNC_ARGS[*]} ${TARGET_REPO}${C_RESET}"
      local sync_out
      run_streamed sync_out repo sync "${SYNC_ARGS[@]}" "$TARGET_REPO"
      sync_rc=$?
      if [[ $sync_rc -ne 0 && "$FORCE" -eq 1 ]]; then
        local verdict
        verdict="$(classify_sync_error "$sync_out")"
        case "$verdict" in
          mismatch)
            if [[ " ${SYNC_ARGS[*]-} " == *" --force-sync "* ]]; then
              # already tried --force-sync and it still failed — go straight to a full wipe
              clean_project "$TARGET_REPO"
              echo "${C_BOLD}==> retrying sync for ${TARGET_REPO}${C_RESET}"
              run_streamed sync_out repo sync "${SYNC_ARGS[@]}" "$TARGET_REPO"
              sync_rc=$?
            else
              echo "${C_YELLOW}==> repo/revision mismatch confirmed — retrying with --force-sync first (less destructive than wiping)${C_RESET}"
              run_streamed sync_out repo sync "${SYNC_ARGS[@]}" --force-sync "$TARGET_REPO"
              sync_rc=$?
              if [[ $sync_rc -ne 0 ]]; then
                echo "${C_YELLOW}==> --force-sync wasn't enough — falling back to a full wipe of ${TARGET_REPO}${C_RESET}"
                clean_project "$TARGET_REPO"
                echo "${C_BOLD}==> retrying sync for ${TARGET_REPO}${C_RESET}"
                run_streamed sync_out repo sync "${SYNC_ARGS[@]}" "$TARGET_REPO"
                sync_rc=$?
              fi
            fi
            ;;
          network)
            echo "${C_YELLOW}==> that looks like a network failure, not a repo mismatch — not wiping anything. Check your connection and retry.${C_RESET}"
            ;;
          *)
            echo "${C_YELLOW}==> sync failed for a reason that isn't a confirmed repo/revision mismatch — not auto-wiping. -f only cleans on confirmed mismatches; inspect the error above and retry manually.${C_RESET}"
            ;;
        esac
      fi
    else
      echo "${C_BOLD}==> Running: repo sync ${SYNC_ARGS[*]}${C_RESET}"
      local sync_out
      run_streamed sync_out repo sync "${SYNC_ARGS[@]}"
      sync_rc=$?
      if [[ $sync_rc -ne 0 && "$FORCE" -eq 1 ]]; then
        local verdict
        verdict="$(classify_sync_error "$sync_out")"
        if [[ "$verdict" == "network" ]]; then
          echo "${C_YELLOW}==> that looks like a network failure, not a repo mismatch — not wiping anything. Check your connection and retry.${C_RESET}"
        elif [[ "$verdict" == "mismatch" ]]; then
          echo "${C_YELLOW}==> full sync reported a repo/revision mismatch — looking for affected project(s)${C_RESET}"
          local mismatch_lines
          mismatch_lines="$(grep -iE "couldn't find remote ref|reference is not a tree|not a valid object name|unadvertised object|bad object|does not have any commits yet|bad revision|no such ref|remote ref does not exist|unable to read tree|revision .* not found|manifest.*(mismatch|does not match)|not a valid ref|unrelated histories|repository .* not found|does not exist|hooks is different in|cannot overwrite a local work tree|force-sync not enabled|is different in .* vs .*project-objects" <<< "$sync_out")"
          local -a failed_paths=()
          for path in "${REPO_PATHS[@]}"; do
            if grep -qF "$path" <<< "$mismatch_lines"; then
              failed_paths+=("$path")
            fi
          done
          if [[ "${#failed_paths[@]}" -gt 0 ]]; then
            echo "${C_YELLOW}==> retrying with --force-sync for: ${failed_paths[*]}${C_RESET}"
            local retry_out
            run_streamed retry_out repo sync "${SYNC_ARGS[@]}" --force-sync "${failed_paths[@]}"
            sync_rc=$?
            if [[ $sync_rc -ne 0 ]]; then
              echo "${C_YELLOW}==> --force-sync wasn't enough — falling back to a full wipe of: ${failed_paths[*]}${C_RESET}"
              for path in "${failed_paths[@]}"; do
                clean_project "$path"
              done
              echo "${C_BOLD}==> retrying sync for: ${failed_paths[*]}${C_RESET}"
              repo sync "${SYNC_ARGS[@]}" "${failed_paths[@]}"
              sync_rc=$?
            fi
          else
            echo "${C_YELLOW}mismatch detected but couldn't pin down which project(s) from the output — not auto-wiping. Check the error above.${C_RESET}"
          fi
        else
          echo "${C_YELLOW}==> sync failed for a reason that isn't a confirmed repo/revision mismatch — not auto-wiping. -f only cleans on confirmed mismatches; inspect the error above.${C_RESET}"
        fi
      fi
    fi
  else
    # plain git forest
    if [[ -n "$TARGET_REPO" ]]; then
      echo "${C_BOLD}==> Running: git pull ${SYNC_ARGS[*]} (in ${TARGET_REPO})${C_RESET}"
      local origin_url pull_out
      origin_url="$(git -C "$TARGET_REPO" remote get-url origin 2>/dev/null)"
      run_streamed pull_out git -C "$TARGET_REPO" pull "${SYNC_ARGS[@]}"
      sync_rc=$?
      if [[ $sync_rc -ne 0 && "$FORCE" -eq 1 ]]; then
        local verdict
        verdict="$(classify_sync_error "$pull_out")"
        if [[ "$verdict" == "mismatch" && -n "$origin_url" ]]; then
          echo "${C_YELLOW}==> force: repo/revision mismatch confirmed — wiping '${TARGET_REPO}' and re-cloning from ${origin_url}${C_RESET}"
          rm -rf -- "./${TARGET_REPO}"
          if git clone "$origin_url" "$TARGET_REPO"; then
            sync_rc=0
          fi
        elif [[ "$verdict" == "mismatch" ]]; then
          echo "${C_RED}mismatch confirmed but no 'origin' remote found for ${TARGET_REPO} — can't re-clone${C_RESET}"
        elif [[ "$verdict" == "network" ]]; then
          echo "${C_YELLOW}==> that looks like a network failure, not a repo mismatch — not wiping anything. Check your connection and retry.${C_RESET}"
        else
          echo "${C_YELLOW}==> pull failed for a reason that isn't a confirmed repo mismatch — not auto-wiping. Inspect the error above.${C_RESET}"
        fi
      fi
    else
      echo "${C_BOLD}==> Running: git pull ${SYNC_ARGS[*]} (per project)${C_RESET}"
      local i=0
      for path in "${REPO_PATHS[@]}"; do
        i=$((i + 1))
        progress "$i" "$total" "$path"
        echo "---- $path ----"
        local pull_out
        pull_out="$(git -C "$path" pull "${SYNC_ARGS[@]}" 2>&1)"
        printf '%s\n' "$pull_out"
        if printf '%s' "$pull_out" | grep -qiE "^error:|^fatal:"; then
          echo "${C_YELLOW}  (pull failed for $path)${C_RESET}"
          if [[ "$FORCE" -eq 1 ]]; then
            local verdict origin_url
            verdict="$(classify_sync_error "$pull_out")"
            origin_url="$(git -C "$path" remote get-url origin 2>/dev/null)"
            if [[ "$verdict" == "mismatch" && -n "$origin_url" ]]; then
              echo "${C_YELLOW}==> force: repo/revision mismatch confirmed — wiping '$path' and re-cloning from ${origin_url}${C_RESET}"
              rm -rf -- "./${path}"
              git clone "$origin_url" "$path" || echo "${C_RED}  re-clone failed for $path${C_RESET}"
            elif [[ "$verdict" == "network" ]]; then
              echo "${C_YELLOW}  that looks like a network failure, not a mismatch — not wiping '$path'. Retry once your connection is stable.${C_RESET}"
            else
              echo "${C_YELLOW}  not a confirmed repo mismatch — not wiping '$path'. Inspect the error above.${C_RESET}"
            fi
          fi
        fi
      done
      progress_done
    fi
  fi

  if [[ "$sync_rc" -ne 0 ]]; then
    echo "${C_RED}sync failed — see ${LOG_FILE}${C_RESET}"
    rm -f "$BEFORE_SNAPSHOT" "$AFTER_SNAPSHOT"
    return 1
  fi

  echo "${C_BOLD}==> Snapshotting HEADs (post-sync)...${C_RESET}"
  take_snapshot "$AFTER_SNAPSHOT"

  declare -A BEFORE_MAP AFTER_MAP CHANGED_SUMMARY
  while IFS=$'\t' read -r path sha; do
    [[ -n "$path" ]] && BEFORE_MAP["$path"]="$sha"
  done < "$BEFORE_SNAPSHOT"
  while IFS=$'\t' read -r path sha; do
    [[ -n "$path" ]] && AFTER_MAP["$path"]="$sha"
  done < "$AFTER_SNAPSHOT"
  rm -f "$BEFORE_SNAPSHOT" "$AFTER_SNAPSHOT"

  local ALL_PATHS
  ALL_PATHS="$(printf '%s\n' "${!BEFORE_MAP[@]}" "${!AFTER_MAP[@]}" | sort -u)"

  local changed_count=0 new_count=0 removed_project_count=0
  local commits_added_total=0 commits_removed_total=0

  echo ""
  echo "===================================================================="
  echo " repo sync change report — $(date)"
  echo "===================================================================="

  while IFS= read -r path; do
    [[ -z "$path" ]] && continue
    local before_sha="${BEFORE_MAP[$path]:-}"
    local after_sha="${AFTER_MAP[$path]:-}"

    if [[ -z "$before_sha" && -n "$after_sha" ]]; then
      echo ""
      echo "${C_YELLOW}[NEW PROJECT]${C_RESET} $path  ($(project_name_for "$path"))  (HEAD: ${after_sha:0:12})"
      new_count=$((new_count + 1))
      continue
    fi
    if [[ -n "$before_sha" && -z "$after_sha" ]]; then
      echo ""
      echo "${C_RED}[REMOVED PROJECT]${C_RESET} $path  ($(project_name_for "$path"))  (was: ${before_sha:0:12})"
      removed_project_count=$((removed_project_count + 1))
      continue
    fi
    if [[ "$before_sha" != "$after_sha" ]]; then
      changed_count=$((changed_count + 1))
      print_change_details "$path" "$before_sha" "$after_sha"
      local commits
      commits="$(count_commits "$path" "$before_sha" "$after_sha")"
      CHANGED_SUMMARY["$path"]="$commits"
      # commits is "+N -M" for the normal case; new/gone/replaced don't
      # parse as numbers here and are simply skipped in the tally below.
      if [[ "$commits" =~ ^\+([0-9]+)\ -([0-9]+)$ ]]; then
        commits_added_total=$((commits_added_total + BASH_REMATCH[1]))
        commits_removed_total=$((commits_removed_total + BASH_REMATCH[2]))
      fi
    fi
  done <<< "$ALL_PATHS"

  echo ""
  echo "--------------------------------------------------------------------"
  if [[ "$changed_count" -eq 0 && "$new_count" -eq 0 && "$removed_project_count" -eq 0 ]]; then
    echo "No project changes — tree was already up to date."
  else
    echo "Projects changed: $changed_count   new: $new_count   removed: $removed_project_count   commits: +${commits_added_total} -${commits_removed_total}"
  fi
  echo "--------------------------------------------------------------------"

  echo ""
  echo "${C_BOLD}==> Sync summary${C_RESET}"
  if [[ "$changed_count" -eq 0 ]]; then
    echo "  (nothing changed)"
  else
    printf '  %-40s %-45s %s\n' "PATH" "PROJECT" "COMMITS"
    for path in "${!CHANGED_SUMMARY[@]}"; do
      printf '  %-40s %-45s %s\n' "$path" "$(project_name_for "$path")" "${CHANGED_SUMMARY[$path]}"
    done | sort
  fi

  echo ""
  echo "${C_BOLD}Full log saved to:${C_RESET} $LOG_FILE"
}

# ---------------------------------------------------------------------
# -t / --date  (time-window report, no sync, nothing written to disk)
# ---------------------------------------------------------------------
run_time_report() {
  local since="$1" until="$2" label="$3" verbose="${4:-0}"
  discover_repos
  local total=${#REPO_PATHS[@]}
  if [[ "$total" -eq 0 ]]; then
    echo "${C_RED}error: no repositories found${C_RESET}"
    return 2
  fi
  echo "${C_BOLD}==> Commit activity report — ${label}${C_RESET}"
  echo "${C_DIM}since: ${since}   until: ${until}${C_RESET}"
  echo ""

  local i=0 repos_with_commits=0 total_commits=0
  local -a lines=()
  for path in "${REPO_PATHS[@]}"; do
    i=$((i + 1))
    progress "$i" "$total" "$path"
    local count name
    count="$(git -C "$path" log --since="$since" --until="$until" --oneline 2>/dev/null | grep -c .)"
    if [[ "$count" -gt 0 ]]; then
      repos_with_commits=$((repos_with_commits + 1))
      total_commits=$((total_commits + count))
      name="$(project_name_for "$path")"
      if [[ "$verbose" -eq 1 ]]; then
        lines+=("$(print_time_window_details "$path" "$name" "$since" "$until")")
      else
        lines+=("$(printf '  %-40s %-45s %s commit(s)' "$path" "$name" "$count")")
      fi
    fi
  done
  progress_done

  echo "${C_BOLD}==> ${total} repositories scanned${C_RESET}"
  echo ""
  if [[ "$repos_with_commits" -eq 0 ]]; then
    echo "No commits found in this window."
  else
    if [[ "$verbose" -eq 1 ]]; then
      printf '%s\n' "${lines[@]}"
      echo ""
    else
      printf '  %-40s %-45s %s\n' "PATH" "PROJECT" "COMMITS"
      printf '%s\n' "${lines[@]}"
      echo ""
    fi
    echo "--------------------------------------------------------------------"
    echo "repos with commits: $repos_with_commits   total commits: $total_commits"
    echo "--------------------------------------------------------------------"
  fi
}

parse_days_range() {
  local spec="$1"
  if [[ "$spec" =~ ^([0-9]+)-([0-9]+)$ ]]; then
    local a="${BASH_REMATCH[1]}" b="${BASH_REMATCH[2]}"
    local hi=$a lo=$b
    if (( b > a )); then hi=$b; lo=$a; fi
    SINCE_ARG="${hi} days ago"
    UNTIL_ARG="${lo} days ago"
    TIME_LABEL="${lo}-${hi} days ago"
  elif [[ "$spec" =~ ^[0-9]+$ ]]; then
    SINCE_ARG="${spec} days ago"
    UNTIL_ARG="now"
    TIME_LABEL="last ${spec} day(s)"
  else
    echo "${C_RED}invalid time spec: '$spec' (expected N or N-M, e.g. -t7 or -t7-9)${C_RESET}" >&2
    exit 2
  fi
}

cmd_time_days() {
  local spec="" verbose=0 a
  for a in "$@"; do
    case "$a" in
      -v|--verbose) verbose=1 ;;
      *)
        if [[ -n "$spec" ]]; then
          echo "${C_RED}unexpected argument: $a${C_RESET}" >&2
          return 2
        fi
        spec="$a"
        ;;
    esac
  done
  if [[ -z "$spec" ]]; then
    echo "usage: $SCRIPT_NAME -t<N> | -t<N>-<M> [-v]   e.g. -t7 or -t7-9 -v" >&2
    return 2
  fi
  local SINCE_ARG UNTIL_ARG TIME_LABEL
  parse_days_range "$spec"
  run_time_report "$SINCE_ARG" "$UNTIL_ARG" "$TIME_LABEL" "$verbose"
}

to_iso_date() {
  local d="$1" dd mm yy
  IFS='/' read -r dd mm yy <<< "$d"
  if [[ -z "$dd" || -z "$mm" || -z "$yy" ]]; then
    echo "${C_RED}invalid date: $d (expected DD/MM/YY)${C_RESET}" >&2
    exit 2
  fi
  echo "20${yy}-${mm}-${dd}"
}

cmd_date() {
  local spec="" verbose=0 a
  for a in "$@"; do
    case "$a" in
      -v|--verbose) verbose=1 ;;
      *)
        if [[ -n "$spec" ]]; then
          echo "${C_RED}unexpected argument: $a${C_RESET}" >&2
          return 2
        fi
        spec="$a"
        ;;
    esac
  done
  if [[ -z "$spec" ]]; then
    echo "usage: $SCRIPT_NAME --date DD/MM/YY[-DD/MM/YY] [-v]" >&2
    return 2
  fi
  local since until label
  if [[ "$spec" =~ ^([0-9]{1,2}/[0-9]{1,2}/[0-9]{2})-([0-9]{1,2}/[0-9]{1,2}/[0-9]{2})$ ]]; then
    since="$(to_iso_date "${BASH_REMATCH[1]}")"
    until="$(to_iso_date "${BASH_REMATCH[2]}")"
    label="${BASH_REMATCH[1]} to ${BASH_REMATCH[2]}"
  elif [[ "$spec" =~ ^[0-9]{1,2}/[0-9]{1,2}/[0-9]{2}$ ]]; then
    since="$(to_iso_date "$spec")"
    until="now"
    label="${spec} to now"
  else
    echo "${C_RED}invalid date spec: '$spec' (expected DD/MM/YY or DD/MM/YY-DD/MM/YY)${C_RESET}" >&2
    return 2
  fi
  run_time_report "$since" "$until" "$label" "$verbose"
}

# ---------------------------------------------------------------------
# -r / --report  (reads existing logs, never writes one)
# ---------------------------------------------------------------------
cmd_report() {
  local sel="${1:-1}"
  local -a logs=()
  while IFS= read -r f; do
    logs+=("$f")
  done < <(ls -1t "$LOG_DIR"/sync_*.log 2>/dev/null)

  if [[ "${#logs[@]}" -eq 0 ]]; then
    echo "No saved sync reports yet in ${LOG_DIR}/. Run '${SCRIPT_NAME} --sync' first."
    return 0
  fi

  if [[ "$sel" == "list" ]]; then
    echo "${C_BOLD}Saved sync reports:${C_RESET}"
    local i=0
    for f in "${logs[@]}"; do
      i=$((i + 1))
      printf '  %2d) %s  (%s)\n' "$i" "$(basename "$f")" "$(date -r "$f" 2>/dev/null)"
    done
    return 0
  fi

  if ! [[ "$sel" =~ ^[0-9]+$ ]]; then
    echo "${C_RED}invalid selector: '$sel' (expected a number or 'list')${C_RESET}" >&2
    return 2
  fi

  local idx=$((sel - 1))
  if [[ "$idx" -lt 0 || "$idx" -ge "${#logs[@]}" ]]; then
    echo "${C_RED}no report #$sel (have ${#logs[@]})${C_RESET}" >&2
    return 2
  fi

  echo "${C_BOLD}==> Showing report: $(basename "${logs[$idx]}")${C_RESET}"
  echo ""
  cat "${logs[$idx]}"
}

# ---------------------------------------------------------------------
# -l / --list
# ---------------------------------------------------------------------
cmd_list() {
  discover_repos
  local total=${#REPO_PATHS[@]}
  echo "${C_BOLD}==> ${total} repositories found (mode: ${REPO_MODE})${C_RESET}"
  printf '  %3s  %-40s %-45s %-20s %s\n' "#" "PATH" "PROJECT" "BRANCH" "SHA"
  local i=0
  for path in "${REPO_PATHS[@]}"; do
    i=$((i + 1))
    local sha branch
    sha="$(git -C "$path" rev-parse --short HEAD 2>/dev/null || echo NONE)"
    branch="$(git -C "$path" rev-parse --abbrev-ref HEAD 2>/dev/null || echo '?')"
    printf '  %3d) %-40s %-45s %-20s %s\n' "$i" "$path" "$(project_name_for "$path")" "$branch" "$sha"
  done
}

# ---------------------------------------------------------------------
# --device
# ---------------------------------------------------------------------
switch_manifest() {
  local dev="$1" src="$SCRIPT_DIR/local_manifests/$1.xml"
  [[ -f "$src" ]] || {
    echo "${C_RED}no manifest for '$dev' — have: $(cd "$SCRIPT_DIR/local_manifests" && echo *.xml)${C_RESET}" >&2
    exit 2
  }
  [[ -d .repo ]] || {
    echo "${C_RED}not a repo tree (no .repo/ here) — run from the ROM root${C_RESET}" >&2
    exit 2
  }
  mkdir -p .repo/local_manifests
  local dest=".repo/local_manifests/local_manifest.xml"
  if [[ -e "$dest" && ! -L "$dest" ]]; then
    mv "$dest" "$dest.bak"
    echo "${C_YELLOW}==> existing $dest was a regular file — saved as $dest.bak${C_RESET}"
  fi
  ln -sfn "$src" "$dest"
  echo "${C_GREEN}==> local_manifest.xml -> $src${C_RESET}"
}

# ---------------------------------------------------------------------
# dispatch
# ---------------------------------------------------------------------
main() {
  case "${1:-}" in
    --device) switch_manifest "${2:?--device requires a name}"; shift 2 ;;
    --device=*) switch_manifest "${1#--device=}"; shift ;;
  esac
  [[ $# -eq 0 ]] && exit 0

  local arg="${1:-}"
  case "$arg" in
    "")
      show_short_help
      ;;
    -h|--help)
      show_full_help
      ;;
    -s|--sync)
      shift
      cmd_sync "$@"
      ;;
    -l|--list)
      cmd_list
      ;;
    -r|--report)
      shift
      cmd_report "${1:-1}"
      ;;
    -d|--date)
      shift
      cmd_date "$@"
      ;;
    --date=*)
      shift
      cmd_date "${arg#--date=}" "$@"
      ;;
    -t)
      shift
      cmd_time_days "$@"
      ;;
    -t*)
      shift
      cmd_time_days "${arg#-t}" "$@"
      ;;
    --time)
      shift
      cmd_time_days "$@"
      ;;
    --time=*)
      shift
      cmd_time_days "${arg#--time=}" "$@"
      ;;
    *)
      echo "${C_RED}unknown option: $arg${C_RESET}" >&2
      show_short_help
      exit 2
      ;;
  esac
}

main "$@"
