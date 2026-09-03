#!/usr/bin/env bash
# otauploader.sh — push a finished AxionOS build + recovery images to
# SourceForge (sftp) and/or pixeldrain (filesystem API), then publish its
# Updater-app OTA manifest to the varakumar01/scripts repo. Run from the
# build root (the dir containing `out/`).
#
# Secrets (PIXELDRAIN_API_KEY, SSHPASS, PIXELDRAIN_RETENTION) are read from
# scripts/.env if it exists -- see .env.example. Never hardcode a key here.
#
# One SSH connection is authenticated (via sshpass, if installed and $SSHPASS
# is set, else ssh's own interactive password prompt) and reused for every
# sftp call via OpenSSH ControlMaster — sshpass is optional, not required.
#
# Usage:
#   ./otauploader.sh                    # SourceForge only (default), autodetect
#                                        #   device from out/, show summary, ask
#   ./otauploader.sh -pd                # pixeldrain only
#   ./otauploader.sh -sf -pd            # both targets
#   ./otauploader.sh --device lemonadep # override autodetection for a specific device
#   ./otauploader.sh -au                # same, but skip the summary prompt
#                                        #   (a brand-new version folder still prompts)
#   ./otauploader.sh --dry-run          # parse + build the upload plan and the
#                                        #   OTA manifest, print both, never connect
set -euo pipefail

SF_USER="varakumar01"
SF_HOST="frs.sourceforge.net"
SF_PROJECT="axion-os"   # SourceForge unix name -- lowercase, frs SFTP paths are case-sensitive
PD_API="https://pixeldrain.com/api"
PD_ROOT="Axion"         # top-level folder under /me on pixeldrain
DEVICE=""   # empty = autodetect from out/target/product/*/ below
IMAGES=(boot.img vendor_boot.img vbmeta.img dtbo.img vendor_dlkm.img super_empty.img)
SCRIPT_DIR="$(dirname "$(readlink -f "$0")")"
FIRMWARE_SRC="$SCRIPT_DIR/firmware"

[[ -f "$SCRIPT_DIR/.env" ]] && { set -a; . "$SCRIPT_DIR/.env"; set +a; }
PIXELDRAIN_RETENTION="${PIXELDRAIN_RETENTION:-3}"

AUTO=0
DRY_RUN=0
DO_SF=0
DO_PD=0
while [[ $# -gt 0 ]]; do
    case "$1" in
        --auto-upload|-au) AUTO=1; shift ;;
        --dry-run) DRY_RUN=1; shift ;;
        --device) DEVICE="$2"; shift 2 ;;
        --sourceforge|-sf) DO_SF=1; shift ;;
        --pixeldrain|-pd) DO_PD=1; shift ;;
        --help|-h)
            sed -n '2,23p' "$0"; exit 0 ;;
        *) echo "unknown argument: $1" >&2; exit 1 ;;
    esac
done
(( DO_SF || DO_PD )) || DO_SF=1   # no target flag = today's default (SourceForge only)

abort() { echo "error: $*" >&2; exit 1; }

if [[ $DO_PD -eq 1 && -z "${PIXELDRAIN_API_KEY:-}" ]]; then
    abort "--pixeldrain requires PIXELDRAIN_API_KEY in $SCRIPT_DIR/.env (see .env.example)"
fi

if [[ -z $DEVICE ]]; then
    newest=$(find out/target/product -mindepth 2 -maxdepth 2 -type f \
               -name 'axion-*.zip' ! -name '*INCREMENTAL*' ! -name '*target_files*' \
               -printf '%T@ %p\n' 2>/dev/null | sort -rn | head -1 | cut -d' ' -f2-)
    [[ -n $newest ]] || abort "no axion-*.zip found under out/target/product/*/ — pass --device"
    DEVICE=$(basename "$(dirname "$newest")")
    echo "device: $DEVICE (autodetected from $(basename "$newest"))"
fi
SF_BASE="/home/frs/project/$SF_PROJECT/$DEVICE"
PD_BASE="me/$PD_ROOT/$DEVICE"   # path under the pixeldrain filesystem API, minus version dir

[[ -d out/target/product/$DEVICE ]] || abort "out/target/product/$DEVICE not found — run this from the build root"

# --- SSH connection: one authenticated session, reused by every sftp call --
# below via OpenSSH's own ControlMaster multiplexing, so nothing here depends
# on sshpass being installed. If SSHPASS is set and sshpass is available it
# authenticates non-interactively (cron/build-automation use); otherwise
# plain `ssh` prompts for the password on the tty itself, once, the same way
# a manual `sftp user@host` would.
SSH_CTL_DIR=$(mktemp -d)
SSH_OPTS=(-o "ControlMaster=auto" -o "ControlPersist=60" -o "ControlPath=$SSH_CTL_DIR/ctl")

cleanup() {
    rm -f "${BATCH:-}" "${PRUNE_LIST:-}"
    [[ $DO_SF -eq 1 ]] && { ssh -O exit "${SSH_OPTS[@]}" "$SF_USER@$SF_HOST" 2>/dev/null || true; }
    rm -rf "$SSH_CTL_DIR"
    unset SSHPASS PIXELDRAIN_API_KEY
}
trap cleanup EXIT

open_master() {
    if command -v sshpass >/dev/null && [[ -n "${SSHPASS:-}" ]]; then
        sshpass -e ssh "${SSH_OPTS[@]}" -fN "$SF_USER@$SF_HOST"
    else
        ssh "${SSH_OPTS[@]}" -fN "$SF_USER@$SF_HOST"
    fi || abort "could not open SSH connection to $SF_HOST"
}

# pd <curl args...> -- authenticated pixeldrain API call. The key is piped in
# via curl's -K config file (stdin) instead of a command-line arg so it never
# shows up in `ps`.
pd() {
    printf 'user = ":%s"\n' "$PIXELDRAIN_API_KEY" | curl -sS --fail-with-body -K - "$@"
}

# urlenc <string> -- percent-encode one path component (no slashes in input).
urlenc() {
    local s="$1" out= c i
    for (( i=0; i<${#s}; i++ )); do
        c=${s:i:1}
        case "$c" in
            [a-zA-Z0-9.~_-]) out+="$c" ;;
            *) out+=$(printf '%%%02X' "'$c") ;;
        esac
    done
    printf '%s' "$out"
}

# pd_urlpath <a/b/c> -- percent-encode each "/"-separated component and
# rejoin with "/", so the path structure survives while special characters
# in individual names (spaces, parens, ...) don't break the URL.
pd_urlpath() {
    local IFS=/ seg out=()
    for seg in $1; do out+=("$(urlenc "$seg")"); done
    IFS=/; printf '%s' "${out[*]}"
}

# --- 1. discover the ROM zip ------------------------------------------------
ROM=$(find "out/target/product/$DEVICE" -maxdepth 1 -type f \
        -name "axion-*-${DEVICE}.zip" \
        ! -name '*INCREMENTAL*' ! -name '*target_files*' \
        -printf '%T@ %p\n' 2>/dev/null | sort -rn | head -1 | cut -d' ' -f2-)
[[ -n "$ROM" ]] || abort "no axion-*-${DEVICE}.zip found under out/target/product/$DEVICE"

# --- 2. parse version + date from the basename ------------------------------
base=${ROM##*/}
ver=${base#axion-}; ver=${ver%%-*}          # 2.8
verdir="${ver%%.*}.x"                       # 2.x

[[ $base =~ -([0-9]{8,14})- ]] || abort "couldn't find an 8-14 digit date segment in $base"
date=${BASH_REMATCH[1]:0:8}                 # truncate the time-of-day variant to YYYYMMDD

# --- 3. collect images (missing = warn + skip, not fatal) ------------------
declare -a LOCAL_FILES=("$ROM")
declare -a REMOTE_NAMES=("$base")
declare -a REMOTE_DIRS=("$verdir")
declare -a MISSING=()

for img in "${IMAGES[@]}"; do
    path="out/target/product/$DEVICE/$img"
    if [[ -f "$path" ]]; then
        LOCAL_FILES+=("$path")
        REMOTE_NAMES+=("${date}_${img}")
        REMOTE_DIRS+=("$verdir/recovery")
    else
        MISSING+=("$img")
    fi
done

# --- 4. probe remotes: does the version folder already exist? --------------
SF_NEW_FOLDER=0
if [[ $DO_SF -eq 1 ]]; then
    if [[ $DRY_RUN -eq 1 ]]; then
        SF_NEW_FOLDER=1   # can't know without connecting; assume worst case for the preview
    else
        open_master
        listing=$(sftp -o BatchMode=no "${SSH_OPTS[@]}" -b <(echo "ls $SF_BASE") "$SF_USER@$SF_HOST" 2>/dev/null || true)
        grep -q "$verdir\$\|$verdir/" <<<"$listing" || SF_NEW_FOLDER=1
    fi
fi

PD_NEW_FOLDER=0
if [[ $DO_PD -eq 1 ]]; then
    if [[ $DRY_RUN -eq 1 ]]; then
        PD_NEW_FOLDER=1   # never connect during --dry-run, same rule as SourceForge above
    else
        pd "$PD_API/filesystem/$(pd_urlpath "$PD_BASE/$verdir")?stat" >/dev/null 2>&1 || PD_NEW_FOLDER=1
    fi
fi

# --- 5. build the sftp batch -------------------------------------------------
BATCH=$(mktemp)
if [[ $DO_SF -eq 1 ]]; then
    {
        echo "-mkdir $SF_BASE/$verdir"
        echo "-mkdir $SF_BASE/$verdir/recovery"
        if [[ $SF_NEW_FOLDER -eq 1 && -d "$FIRMWARE_SRC" ]]; then
            echo "-mkdir $SF_BASE/$verdir/firmware"
            for f in "$FIRMWARE_SRC"/*; do
                [[ -e "$f" ]] || continue
                echo "put \"$f\" \"$SF_BASE/$verdir/firmware/$(basename "$f")\""
            done
        fi
        for i in "${!LOCAL_FILES[@]}"; do
            echo "put \"${LOCAL_FILES[$i]}\" \"$SF_BASE/${REMOTE_DIRS[$i]}/${REMOTE_NAMES[$i]}\""
        done
    } > "$BATCH"
fi

# --- 5b. build the OTA manifest (Updater app JSON) ---------------------------
# generate_json.sh (vendor/lineage/build/tools) already wrote a correct
# manifest next to the zip at build time -- everything in it is right except
# "url", which points at cdn.axionos.org. Rewrite just that field rather than
# regenerating the rest. When both targets are used, pixeldrain's URL wins as
# the one published in the manifest (patched in after its upload in step 7b);
# SourceForge is still fully uploaded, just not the URL the Updater app sees.
case "$base" in *-VANILLA-*) FLAVOR=VANILLA ;; *) FLAVOR=GMS ;; esac
SRC_JSON="out/target/product/$DEVICE/$FLAVOR/$DEVICE.json"
DL_URL="https://downloads.sourceforge.net/project/$SF_PROJECT/$DEVICE/$verdir/$base"
OUT_JSON="$SCRIPT_DIR/OTA/$FLAVOR/$DEVICE.json"

MANIFEST=""
if [[ -f "$SRC_JSON" ]]; then
    MANIFEST=$(sed 's|"url":[[:space:]]*".*"|"url": "'"$DL_URL"'"|' "$SRC_JSON")
else
    echo "warning: $SRC_JSON not found — skipping OTA manifest publish (was this built with 'm bacon'?)" >&2
fi

# --- 6. summary / confirmation ----------------------------------------------
total_bytes=0
for f in "${LOCAL_FILES[@]}"; do total_bytes=$(( total_bytes + $(stat -c%s "$f") )); done
human_total=$(numfmt --to=iec --suffix=B "$total_bytes" 2>/dev/null || echo "${total_bytes}B")

echo
targets=()
[[ $DO_SF -eq 1 ]] && targets+=("SourceForge")
[[ $DO_PD -eq 1 ]] && targets+=("pixeldrain")
echo "OTA upload (${targets[*]}) — Axion $ver ($date)"
echo

if [[ $DO_SF -eq 1 && $SF_NEW_FOLDER -eq 1 ]]; then
    echo "!! NEW SourceForge VERSION FOLDER — will be created:"
    echo "     $SF_BASE/$verdir/"
    echo "     $SF_BASE/$verdir/recovery/"
    if [[ -d "$FIRMWARE_SRC" ]]; then
        fw_count=$(find "$FIRMWARE_SRC" -maxdepth 1 -type f | wc -l)
        echo "     $SF_BASE/$verdir/firmware/   <- copied from $FIRMWARE_SRC ($fw_count files)"
    else
        echo "     (no local firmware/ dir at $FIRMWARE_SRC — skipping firmware copy)"
    fi
    echo
fi
if [[ $DO_PD -eq 1 && $PD_NEW_FOLDER -eq 1 ]]; then
    echo "!! NEW pixeldrain VERSION FOLDER — will be created:"
    echo "     /$PD_BASE/$verdir/"
    echo "     /$PD_BASE/$verdir/recovery/"
    if [[ -d "$FIRMWARE_SRC" ]]; then
        fw_count=$(find "$FIRMWARE_SRC" -maxdepth 1 -type f | wc -l)
        echo "     /$PD_BASE/$verdir/firmware/   <- copied from $FIRMWARE_SRC ($fw_count files)"
    else
        echo "     (no local firmware/ dir at $FIRMWARE_SRC — skipping firmware copy)"
    fi
    echo
fi

printf 'File Name: %s (%s)\n' "$base" "$human_total"
[[ $DO_SF -eq 1 ]] && printf '  -------> %s/\n' "$SF_BASE/$verdir"
[[ $DO_PD -eq 1 ]] && printf '  -------> pixeldrain:/%s/%s/\n' "$PD_BASE" "$verdir"
echo
echo "Updated file names:"
for i in "${!LOCAL_FILES[@]}"; do
    [[ $i -eq 0 ]] && continue   # already shown above as the ROM zip
    printf '  File Name: %-28s\n' "${REMOTE_NAMES[$i]}"
    [[ $DO_SF -eq 1 ]] && printf '    -------> %s/\n' "$SF_BASE/${REMOTE_DIRS[$i]}"
    [[ $DO_PD -eq 1 ]] && printf '    -------> pixeldrain:/%s/%s/\n' "$PD_BASE" "${REMOTE_DIRS[$i]}"
done
for m in "${MISSING[@]:-}"; do
    [[ -n "$m" ]] && printf '  File Name: %-28s [MISSING — skipped]\n' "$m"
done
echo
echo "Total: ${#LOCAL_FILES[@]} files, $human_total"
[[ $DO_PD -eq 1 ]] && echo "pixeldrain retention: keep newest $PIXELDRAIN_RETENTION build(s) per device/version dir"
echo

if [[ $DRY_RUN -eq 1 ]]; then
    if [[ $DO_SF -eq 1 ]]; then
        echo "--dry-run: sftp batch that would run:"
        cat "$BATCH"
    fi
    if [[ $DO_PD -eq 1 ]]; then
        echo "--dry-run: pixeldrain PUTs that would run:"
        for i in "${!LOCAL_FILES[@]}"; do
            echo "  PUT $PD_API/filesystem/$(pd_urlpath "$PD_BASE/${REMOTE_DIRS[$i]}/${REMOTE_NAMES[$i]}")?make_parents=true"
        done
        echo "--dry-run: pixeldrain retention would prune anything beyond the newest $PIXELDRAIN_RETENTION build(s) in /$PD_BASE/$verdir/ (exact list needs a live directory read)"
    fi
    if [[ -n "$MANIFEST" ]]; then
        echo
        if [[ $DO_PD -eq 1 ]]; then
            echo "--dry-run: OTA manifest that would be published to $OUT_JSON (real pixeldrain bucket id resolved at upload time, shown as a placeholder here):"
            sed 's|"url":[[:space:]]*".*"|"url": "https://pixeldrain.com/api/filesystem/<bucket-id>/'"$DEVICE/$verdir/$base"'"|' <<<"$MANIFEST"
        else
            echo "--dry-run: OTA manifest that would be published to $OUT_JSON:"
            echo "$MANIFEST"
        fi
    fi
    exit 0
fi

if [[ $SF_NEW_FOLDER -eq 1 || $PD_NEW_FOLDER -eq 1 || $AUTO -eq 0 ]]; then
    read -rp "Proceed with upload? [y/N] " reply
    [[ $reply =~ ^[Yy]$ ]] || { echo "aborted."; exit 1; }
fi

# --- 7a. upload to SourceForge -----------------------------------------------
if [[ $DO_SF -eq 1 ]]; then
    echo "uploading to SourceForge..."
    sftp -o BatchMode=no "${SSH_OPTS[@]}" -b "$BATCH" "$SF_USER@$SF_HOST"
    echo "done."
fi

# --- 7b. upload to pixeldrain + prune old builds -----------------------------
pd_bucket_id() {
    # /me/$PD_ROOT is shared once, permanently, so its 8-char id (used in the
    # public, unauthenticated download URL) stays stable across runs.
    local info id
    info=$(pd "$PD_API/filesystem/me/$PD_ROOT?stat")
    id=$(python3 -c "import json,sys; n=json.load(sys.stdin); d=n['path'][n['base_index']]; print(d.get('id') or '')" <<<"$info")
    if [[ -z $id ]]; then
        pd -F action=update -F shared=true "$PD_API/filesystem/me/$PD_ROOT" >/dev/null
        info=$(pd "$PD_API/filesystem/me/$PD_ROOT?stat")
        id=$(python3 -c "import json,sys; n=json.load(sys.stdin); print(n['path'][n['base_index']]['id'])" <<<"$info")
    fi
    printf '%s' "$id"
}

pd_prune_old_builds() {
    local dir_path="$PD_BASE/$verdir" listing
    listing=$(pd "$PD_API/filesystem/$(pd_urlpath "$dir_path")?stat")
    PRUNE_LIST=$(mktemp)
    # Only "file" nodes whose name is this exact device's ROM zip pattern can
    # ever be listed here -- recovery/, firmware/, .search_index.gz and any
    # other device's builds never match, so pruning can't touch them.
    python3 -c "
import json, re, sys
d = json.load(sys.stdin)
device, keep = sys.argv[1], int(sys.argv[2])
pat = re.compile(r'^axion-.*-' + re.escape(device) + r'\.zip\$')
datepat = re.compile(r'-(\d{8,14})-')
files = []
for c in d.get('children', []):
    if c.get('type') != 'file':
        continue
    if not pat.match(c['name']):
        continue
    dm = datepat.search(c['name'])
    files.append(((dm.group(1)[:8] if dm else ''), c.get('created', ''), c['name'], c.get('file_size', 0)))
files.sort(reverse=True)  # newest date first
for d_, created, name, size in files[keep:]:
    print(f'{name}\t{d_}\t{size}')
" "$DEVICE" "$PIXELDRAIN_RETENTION" <<<"$listing" > "$PRUNE_LIST"

    [[ -s $PRUNE_LIST ]] || return 0
    echo
    echo "pixeldrain retention — $(wc -l < "$PRUNE_LIST") build(s) beyond the newest $PIXELDRAIN_RETENTION in /$dir_path/:"
    while IFS=$'\t' read -r name pdate size; do
        printf '  will delete: %-60s (%s, %s)\n' "$name" "$pdate" "$(numfmt --to=iec --suffix=B "$size" 2>/dev/null || echo "${size}B")"
    done < "$PRUNE_LIST"

    if [[ $AUTO -eq 0 ]]; then
        read -rp "Delete these old build(s) from pixeldrain? [y/N] " reply
        [[ $reply =~ ^[Yy]$ ]] || { echo "skipped pixeldrain retention."; return 0; }
    fi
    while IFS=$'\t' read -r name pdate size; do
        pd -X DELETE "$PD_API/filesystem/$(pd_urlpath "$dir_path")/$(urlenc "$name")" >/dev/null
        echo "  deleted: $name"
    done < "$PRUNE_LIST"
}

if [[ $DO_PD -eq 1 ]]; then
    echo "uploading to pixeldrain..."
    for i in "${!LOCAL_FILES[@]}"; do
        pd -X PUT --upload-file "${LOCAL_FILES[$i]}" \
            "$PD_API/filesystem/$(pd_urlpath "$PD_BASE/${REMOTE_DIRS[$i]}/${REMOTE_NAMES[$i]}")?make_parents=true" >/dev/null
    done
    if [[ $PD_NEW_FOLDER -eq 1 && -d "$FIRMWARE_SRC" ]]; then
        for f in "$FIRMWARE_SRC"/*; do
            [[ -e "$f" ]] || continue
            pd -X PUT --upload-file "$f" \
                "$PD_API/filesystem/$(pd_urlpath "$PD_BASE/$verdir/firmware")/$(urlenc "$(basename "$f")")?make_parents=true" >/dev/null
        done
    fi
    echo "done."

    pd_prune_old_builds

    if [[ -n "$MANIFEST" ]]; then
        PD_BUCKET=$(pd_bucket_id)
        PD_DL_URL="$PD_API/filesystem/$PD_BUCKET/$DEVICE/$verdir/$base"
        MANIFEST=$(sed 's|"url":[[:space:]]*".*"|"url": "'"$PD_DL_URL"'"|' <<<"$MANIFEST")
    fi
fi

# --- 8. publish the OTA manifest ---------------------------------------------
# Non-fatal: the build server may not hold a push credential for this repo,
# and a 2GB upload that just succeeded shouldn't be reported as a failure
# over a git push.
if [[ -n "$MANIFEST" ]]; then
    mkdir -p "$(dirname "$OUT_JSON")"
    echo "$MANIFEST" > "$OUT_JSON"
    if git -C "$SCRIPT_DIR" add "$OUT_JSON" &&
       git -C "$SCRIPT_DIR" commit -q -m "OTA: $DEVICE $FLAVOR $ver ($date)" &&
       git -C "$SCRIPT_DIR" push -q origin aox; then
        echo "OTA manifest published: $OUT_JSON"
    else
        echo "warning: could not commit/push $OUT_JSON — publish it manually:" >&2
        echo "  git -C \"$SCRIPT_DIR\" add \"$OUT_JSON\" && git -C \"$SCRIPT_DIR\" commit -m 'OTA: $DEVICE $FLAVOR $ver ($date)' && git -C \"$SCRIPT_DIR\" push origin aox" >&2
    fi
fi
