#!/usr/bin/env bash
#
# build.sh — AxionOS OP9 (lemonade) build + publish wrapper
#
# Drives the axion build via Axion's own 'ax -b' wrapper, retries
# automatically when the remote build server kills the compile for memory
# pressure ([MEMGUARD]), and publishes the finished zip to the web root
# ([PUBLISH]). OTA (incremental / target_files) is intentionally never
# touched — only the full zip is published.
#
# This script must live at the ROM root on the build server (copy it there;
# it is not itself part of the ROM tree). Run with --help for usage.

# --------------------------------------------------------------------------
# Config — edit these as needed. DOWNLOAD_BASE_URL in particular is expected
# to change; it's kept at the top on its own so it's easy to find.
# --------------------------------------------------------------------------
DOWNLOAD_BASE_URL="https://ferrari.serverhive.in/tony"   # <- edit if it changes
WEB_ROOT="/var/www/html/tony"                             # nothing outside this is ever touched
LATEST_SUBDIR="latest"

DEVICE="lemonade"
GMS_VARIANT="core"
DEFAULT_BUILD_TYPE="eng"
JOBS="$(nproc)"

# [SEPOLICY] targets. selinux_policy is the one confirmed working; sepolicy
# is left here, commented, to re-enable without touching any logic below.
SEPOLICY_TARGETS=( selinux_policy )
# SEPOLICY_TARGETS=( sepolicy selinux_policy )

# [MEMGUARD] tuning — defaults matched to the current build server
# (251GiB RAM / ~197GiB used by other tenants / ~54GiB available typical,
# 255GiB swap that's ~always free). See plan doc for the reasoning.
MEMGUARD_MIN_AVAIL_GB=24
MEMGUARD_COUNT_SWAP=0
MEMGUARD_POLL_SECS=300
MEMGUARD_COOLDOWN_SECS=600
MEMGUARD_MAX_RETRIES=0   # 0 = unlimited

# Failure signatures that mean "the server killed the build for memory,
# retry" rather than "the code is broken, stop". The first is the actual
# signature observed on this server: soong_build gets SIGTERM'd by
# systemd-oomd / the hypervisor and just prints "Output:Terminated" — no
# "Out of memory" text anywhere, so that has to be matched explicitly.
MEMGUARD_PATTERNS=(
    'Output:Terminated'
    'signal: terminated'
    '^Terminated$'
    'Killed'
    'Out of memory'
    'oom-kill'
    'virtual memory exhausted'
    'Cannot allocate memory'
    'java\.lang\.OutOfMemoryError'
    'Java heap space'
    'GC overhead limit exceeded'
    'Resource temporarily unavailable'
    'posix_spawn failed'
)

# --------------------------------------------------------------------------
# End of user config
# --------------------------------------------------------------------------

ROM_ROOT="$(pwd)"
BUILD_LOG="$ROM_ROOT/build.log"
SCRIPT_NAME="$(basename "$0")"

FORCE_RETRY=0
DO_SEPOLICY=0
SEPOLICY_ONLY=0
CLEAN_MODE="clean"   # clean | installclean
DO_MEMGUARD=1
DO_PUBLISH=1
BUILD_TYPE=""

log() { printf '%s\n' "$*"; }
log_tagged() { printf '[%s] %s\n' "$1" "${*:2}"; }

usage() {
    cat <<EOF
Usage: ./$SCRIPT_NAME [eng|userdebug|user] [options]

  -f, --force         [MEMGUARD] retry on ANY failure, not just memory kills
      --sepolicy      [SEPOLICY] run the sepolicy check before the full build
      --sepolicy-only [SEPOLICY] run only the sepolicy check, then exit
      --clean         'rm -rf out/' before building (default)
  -i, --installclean  skip the 'rm -rf out/'
  -m, --no-memguard   single attempt, no retry loop
      --no-publish    build only, don't touch $WEB_ROOT
  -j N                override job count (default: \$(nproc) = $JOBS)
  -h, --help          this help

Build type is the first positional arg. If omitted you'll be prompted
(default: $DEFAULT_BUILD_TYPE).
EOF
}

# --------------------------------------------------------------------------
# Arg parsing
# --------------------------------------------------------------------------
while [[ $# -gt 0 ]]; do
    case "$1" in
        eng|userdebug|user)
            if [[ -n "$BUILD_TYPE" ]]; then
                log "Error: multiple build types given ('$BUILD_TYPE' and '$1')."
                exit 1
            fi
            BUILD_TYPE="$1"
            shift
            ;;
        -f|--force) FORCE_RETRY=1; shift ;;
        --sepolicy) DO_SEPOLICY=1; shift ;;
        --sepolicy-only) DO_SEPOLICY=1; SEPOLICY_ONLY=1; shift ;;
        --clean) CLEAN_MODE="clean"; shift ;;
        -i|--installclean) CLEAN_MODE="installclean"; shift ;;
        -m|--no-memguard) DO_MEMGUARD=0; shift ;;
        --no-publish) DO_PUBLISH=0; shift ;;
        -j)
            JOBS="$2"
            if ! [[ "$JOBS" =~ ^[0-9]+$ ]]; then
                log "Error: -j requires a number, got '$JOBS'."
                exit 1
            fi
            shift 2
            ;;
        -h|--help) usage; exit 0 ;;
        *)
            log "Error: unrecognized argument '$1'."
            usage
            exit 1
            ;;
    esac
done

if [[ -z "$BUILD_TYPE" && "$SEPOLICY_ONLY" -eq 0 ]]; then
    if [[ -t 0 ]]; then
        read -r -p "Build type [eng|userdebug|user] (default: $DEFAULT_BUILD_TYPE): " BUILD_TYPE
        BUILD_TYPE="${BUILD_TYPE:-$DEFAULT_BUILD_TYPE}"
    else
        log "No build type given and not a TTY; defaulting to $DEFAULT_BUILD_TYPE."
        BUILD_TYPE="$DEFAULT_BUILD_TYPE"
    fi
fi
if [[ -n "$BUILD_TYPE" && ! "$BUILD_TYPE" =~ ^(eng|userdebug|user)$ ]]; then
    log "Error: invalid build type '$BUILD_TYPE'. Must be eng, userdebug, or user."
    exit 1
fi

# --------------------------------------------------------------------------
# Safety guards
# --------------------------------------------------------------------------
case "$ROM_ROOT" in
    /run/media/tony/313b6705-b136-4599-99cd-f228ccafe70c*)
        log "Error: refusing to run from the read-only reference ROM mount:"
        log "  $ROM_ROOT"
        log "That tree must never be modified (rm -rf out/, m, etc). Run this"
        log "script from the actual build server's writable ROM checkout instead."
        exit 1
        ;;
esac

if [[ ! -f "$ROM_ROOT/build/envsetup.sh" ]]; then
    log "Error: $ROM_ROOT/build/envsetup.sh not found."
    log "Run this script from the root of the ROM tree."
    exit 1
fi

if [[ "$DO_PUBLISH" -eq 1 ]]; then
    case "$WEB_ROOT" in
        /var/www/html/*) ;;
        *)
            log "Error: WEB_ROOT ('$WEB_ROOT') is not under /var/www/html/ — refusing to publish."
            exit 1
            ;;
    esac
fi

# --------------------------------------------------------------------------
# Helpers
# --------------------------------------------------------------------------

# MemAvailable (+ optionally SwapFree) in whole GB.
mem_available_gb() {
    awk -v count_swap="$MEMGUARD_COUNT_SWAP" '
        /^MemAvailable:/ { avail_kb = $2 }
        /^SwapFree:/     { swap_kb = $2 }
        END {
            total_kb = avail_kb + (count_swap ? swap_kb : 0)
            printf "%d", total_kb / 1024 / 1024
        }
    ' /proc/meminfo
}

swap_free_gb() {
    awk '/^SwapFree:/ { printf "%d", $2 / 1024 / 1024 }' /proc/meminfo
}

# Blocks until MemAvailable (+ swap, if configured) clears the threshold.
memguard_wait_for_memory() {
    local avail
    avail="$(mem_available_gb)"
    if (( avail >= MEMGUARD_MIN_AVAIL_GB )); then
        log_tagged MEMGUARD "MemAvailable ${avail}GB >= ${MEMGUARD_MIN_AVAIL_GB}GB threshold — proceeding."
        return 0
    fi
    log_tagged MEMGUARD "MemAvailable ${avail}GB < ${MEMGUARD_MIN_AVAIL_GB}GB — waiting (polling every ${MEMGUARD_POLL_SECS}s)..."
    while (( avail < MEMGUARD_MIN_AVAIL_GB )); do
        sleep "$MEMGUARD_POLL_SECS"
        avail="$(mem_available_gb)"
        log_tagged MEMGUARD "poll: MemAvailable ${avail}GB (need ${MEMGUARD_MIN_AVAIL_GB}GB)"
    done
    log_tagged MEMGUARD "MemAvailable ${avail}GB — proceeding."
}

# Scans the tail of build.log for a memory-kill signature. Returns 0 (match)
# or 1 (no match). Also cross-checks dmesg for a recent oom-kill entry if
# passwordless sudo is available.
memguard_is_memory_failure() {
    local tail_lines
    tail_lines="$(tail -n 200 "$BUILD_LOG" 2>/dev/null)"
    local pat
    for pat in "${MEMGUARD_PATTERNS[@]}"; do
        if grep -qE "$pat" <<<"$tail_lines"; then
            log_tagged MEMGUARD "failure matched pattern: $pat"
            return 0
        fi
    done
    if sudo -n true 2>/dev/null; then
        if sudo dmesg -T 2>/dev/null | tail -n 200 | grep -qi "oom-kill\|out of memory"; then
            log_tagged MEMGUARD "failure matched recent dmesg oom-kill entry"
            return 0
        fi
    fi
    return 1
}

human_size() {
    numfmt --to=iec-i --suffix=B "$1" 2>/dev/null || echo "${1}B"
}

# --------------------------------------------------------------------------
# [SEPOLICY]
# --------------------------------------------------------------------------
run_sepolicy() {
    log_tagged SEPOLICY "running: ${SEPOLICY_TARGETS[*]}"
    (
        cd "$ROM_ROOT" || exit 1
        # shellcheck disable=SC1091
        source build/envsetup.sh
        axion "$DEVICE" "$BUILD_TYPE" "$GMS_VARIANT" || exit 1
        for target in "${SEPOLICY_TARGETS[@]}"; do
            log_tagged SEPOLICY "m -j$JOBS $target"
            m "-j$JOBS" "$target" || exit 1
        done
    ) 2>&1 | tee -a "$BUILD_LOG"
    local rc=${PIPESTATUS[0]}
    if [[ $rc -ne 0 ]]; then
        log_tagged SEPOLICY "FAILED (exit $rc). See $BUILD_LOG."
        return $rc
    fi
    log_tagged SEPOLICY "passed."
    return 0
}

# --------------------------------------------------------------------------
# [BUILD] — one attempt. $1 is the clean mode: clean | installclean.
# --------------------------------------------------------------------------
run_build_attempt() {
    local mode="$1"

    if [[ "$mode" == "clean" ]]; then
        log_tagged BUILD "rm -rf out/"
        rm -rf "$ROM_ROOT/out"
    else
        log_tagged BUILD "out/ left intact — ax will still run its own unconditional 'm installclean'"
    fi

    (
        cd "$ROM_ROOT" || exit 1
        # shellcheck disable=SC1091
        source build/envsetup.sh
        axion "$DEVICE" "$BUILD_TYPE" "$GMS_VARIANT" || exit 1
        # -b (bacon), not -br (brunch) — ax's -br re-lunches via
        # brunch/breakfast and drops the job count on the way; -b runs
        # 'm bacon "$jCount"' directly and actually honors -j.
        ax -b "-j$JOBS" "$BUILD_TYPE"
    ) 2>&1 | tee -a "$BUILD_LOG"
    return "${PIPESTATUS[0]}"
}

# --------------------------------------------------------------------------
# [PUBLISH]
# --------------------------------------------------------------------------
find_output_zip() {
    local zip
    zip="$(grep -a 'Package Complete:' "$BUILD_LOG" | tail -n1 | sed -E 's/^Package Complete:[[:space:]]*//')"
    if [[ -n "$zip" && -f "$ROM_ROOT/$zip" ]]; then
        echo "$ROM_ROOT/$zip"
        return 0
    fi
    if [[ -n "$zip" && -f "$zip" ]]; then
        echo "$zip"
        return 0
    fi
    # Fallback: newest full zip, excluding OTA incremental / target_files.
    find "$ROM_ROOT/out/target/product/$DEVICE" -maxdepth 1 -type f \
        -name "axion-*-${DEVICE}.zip" \
        ! -name "*INCREMENTAL*" ! -name "*target_files*" \
        -printf '%T@ %p\n' 2>/dev/null | sort -rn | head -n1 | cut -d' ' -f2-
}

publish_zip() {
    local zip="$1"
    if [[ -z "$zip" || ! -f "$zip" ]]; then
        log_tagged PUBLISH "Error: could not locate an output zip. Nothing published."
        return 1
    fi

    local name size avail_kb needed_kb
    name="$(basename "$zip")"
    size="$(stat -c%s "$zip")"
    log_tagged PUBLISH "found $name ($(human_size "$size"))"

    mkdir -p "$WEB_ROOT/$LATEST_SUBDIR"

    avail_kb="$(df -Pk "$WEB_ROOT" | awk 'NR==2 {print $4}')"
    needed_kb=$(( size / 1024 * 110 / 100 ))
    if (( avail_kb < needed_kb )); then
        log_tagged PUBLISH "Error: not enough free space on $WEB_ROOT (have ${avail_kb}KB, need ~${needed_kb}KB)."
        log_tagged PUBLISH "Leaving $zip in place; nothing auto-deleted."
        return 1
    fi

    # Archive whatever's currently in latest/.
    local f stem dest suffix
    shopt -s nullglob
    for f in "$WEB_ROOT/$LATEST_SUBDIR"/*.zip; do
        stem="$(basename "$f" .zip)"
        dest="$WEB_ROOT/$stem"
        if [[ -e "$dest" ]]; then
            suffix=2
            while [[ -e "${dest}-${suffix}" ]]; do
                suffix=$(( suffix + 1 ))
            done
            dest="${dest}-${suffix}"
        fi
        mkdir -p "$dest"
        log_tagged PUBLISH "archiving previous build: $(basename "$f") -> $dest/"
        mv "$f" "$dest/"
        [[ -f "$f.sha256" ]] && mv "$f.sha256" "$dest/"
    done
    shopt -u nullglob

    log_tagged PUBLISH "copying $name into $WEB_ROOT/$LATEST_SUBDIR/ ..."
    cp "$zip" "$WEB_ROOT/$LATEST_SUBDIR/${name}.part"
    mv "$WEB_ROOT/$LATEST_SUBDIR/${name}.part" "$WEB_ROOT/$LATEST_SUBDIR/${name}"

    local sha
    sha="$(sha256sum "$WEB_ROOT/$LATEST_SUBDIR/${name}" | awk '{print $1}')"
    echo "$sha  ${name}" > "$WEB_ROOT/$LATEST_SUBDIR/${name}.sha256"
    chmod 644 "$WEB_ROOT/$LATEST_SUBDIR/${name}" "$WEB_ROOT/$LATEST_SUBDIR/${name}.sha256"

    PUBLISHED_NAME="$name"
    PUBLISHED_SIZE="$size"
    PUBLISHED_SHA="$sha"
    PUBLISHED_URL="${DOWNLOAD_BASE_URL}/${LATEST_SUBDIR}/${name}"
    return 0
}

# --------------------------------------------------------------------------
# Main
# --------------------------------------------------------------------------

if [[ -f "$BUILD_LOG" ]]; then
    mv "$BUILD_LOG" "$BUILD_LOG.prev"
fi

if [[ "$DO_SEPOLICY" -eq 1 ]]; then
    run_sepolicy
    sepolicy_rc=$?
    if [[ "$SEPOLICY_ONLY" -eq 1 ]]; then
        exit $sepolicy_rc
    fi
    if [[ $sepolicy_rc -ne 0 ]]; then
        log "Aborting: sepolicy check failed, not starting the full build."
        exit $sepolicy_rc
    fi
fi

start_ts=$(date +%s)
attempt=1
clean_mode="$CLEAN_MODE"

while true; do
    if [[ "$DO_MEMGUARD" -eq 1 ]]; then
        memguard_wait_for_memory
    fi

    log_tagged BUILD "attempt $attempt — MemAvailable $(mem_available_gb)GB, SwapFree $(swap_free_gb)GB"
    run_build_attempt "$clean_mode"
    build_rc=$?
    clean_mode="installclean"   # a MEMGUARD retry must never re-clean

    if [[ $build_rc -eq 0 ]]; then
        log_tagged BUILD "succeeded on attempt $attempt."
        break
    fi

    log_tagged BUILD "attempt $attempt failed (exit $build_rc)."

    if [[ "$DO_MEMGUARD" -eq 0 ]]; then
        log "MEMGUARD disabled (--no-memguard); not retrying."
        exit $build_rc
    fi

    should_retry=0
    if memguard_is_memory_failure; then
        should_retry=1
    elif [[ "$FORCE_RETRY" -eq 1 ]]; then
        log_tagged MEMGUARD "no memory-kill signature matched, but --force given — retrying anyway."
        should_retry=1
    fi

    if [[ "$should_retry" -eq 0 ]]; then
        log "Build failed and no memory-kill signature was found in the last 200 lines of $BUILD_LOG."
        log "Not auto-retrying (use -f/--force to retry regardless of cause). Tail of the log:"
        tail -n 40 "$BUILD_LOG"
        exit $build_rc
    fi

    if [[ "$MEMGUARD_MAX_RETRIES" -gt 0 && "$attempt" -ge "$MEMGUARD_MAX_RETRIES" ]]; then
        log_tagged MEMGUARD "reached MEMGUARD_MAX_RETRIES ($MEMGUARD_MAX_RETRIES). Giving up."
        exit $build_rc
    fi

    attempt=$(( attempt + 1 ))
    log_tagged MEMGUARD "cooling down ${MEMGUARD_COOLDOWN_SECS}s before attempt $attempt..."
    sleep "$MEMGUARD_COOLDOWN_SECS"
done

end_ts=$(date +%s)
elapsed=$(( end_ts - start_ts ))

PUBLISHED_NAME=""
PUBLISHED_SIZE=""
PUBLISHED_SHA=""
PUBLISHED_URL=""

if [[ "$DO_PUBLISH" -eq 1 ]]; then
    zip="$(find_output_zip)"
    publish_zip "$zip"
fi

{
    echo "=========================================="
    echo "         build.sh summary"
    echo "=========================================="
    echo "Build type   : $BUILD_TYPE"
    echo "Attempts     : $attempt"
    printf 'Elapsed      : %02d:%02d:%02d\n' $((elapsed/3600)) $((elapsed%3600/60)) $((elapsed%60))
    if [[ -n "$PUBLISHED_NAME" ]]; then
        echo "Zip          : $PUBLISHED_NAME ($(human_size "$PUBLISHED_SIZE"))"
        echo "SHA256       : $PUBLISHED_SHA"
        echo "Download URL : $PUBLISHED_URL"
    else
        echo "Publish      : skipped or failed — see log above"
    fi
    echo "=========================================="
} | tee -a "$BUILD_LOG"
