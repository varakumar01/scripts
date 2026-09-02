#!/usr/bin/env bash
# otauploader.sh — push a finished AxionOS build + recovery images to
# SourceForge over sftp, then publish its Updater-app OTA manifest to the
# varakumar01/scripts repo. Run from the build root (the dir containing `out/`).
#
# One SSH connection is authenticated (via sshpass, if installed and $SSHPASS
# is set, else ssh's own interactive password prompt) and reused for every
# sftp call via OpenSSH ControlMaster — sshpass is optional, not required.
#
# Usage:
#   ./otauploader.sh                    # autodetect device from out/, show summary, ask before uploading
#   ./otauploader.sh --device lemonadep # override autodetection for a specific device
#   ./otauploader.sh -au                # same, but skip the summary prompt
#                                        #   (a brand-new version folder still prompts)
#   ./otauploader.sh --dry-run          # parse + build the upload batch and the
#                                        #   OTA manifest, print both, never connect
set -euo pipefail

SF_USER="varakumar01"
SF_HOST="frs.sourceforge.net"
SF_PROJECT="axion-os"   # SourceForge unix name -- lowercase, frs SFTP paths are case-sensitive
DEVICE=""   # empty = autodetect from out/target/product/*/ below
IMAGES=(boot.img vendor_boot.img vbmeta.img dtbo.img vendor_dlkm.img super_empty.img)
SCRIPT_DIR="$(dirname "$(readlink -f "$0")")"
FIRMWARE_SRC="$SCRIPT_DIR/firmware"

AUTO=0
DRY_RUN=0
while [[ $# -gt 0 ]]; do
    case "$1" in
        --auto-upload|-au) AUTO=1; shift ;;
        --dry-run) DRY_RUN=1; shift ;;
        --device) DEVICE="$2"; shift 2 ;;
        --help|-h)
            sed -n '2,16p' "$0"; exit 0 ;;
        *) echo "unknown argument: $1" >&2; exit 1 ;;
    esac
done

abort() { echo "error: $*" >&2; exit 1; }

if [[ -z $DEVICE ]]; then
    newest=$(find out/target/product -mindepth 2 -maxdepth 2 -type f \
               -name 'axion-*.zip' ! -name '*INCREMENTAL*' ! -name '*target_files*' \
               -printf '%T@ %p\n' 2>/dev/null | sort -rn | head -1 | cut -d' ' -f2-)
    [[ -n $newest ]] || abort "no axion-*.zip found under out/target/product/*/ — pass --device"
    DEVICE=$(basename "$(dirname "$newest")")
    echo "device: $DEVICE (autodetected from $(basename "$newest"))"
fi
SF_BASE="/home/frs/project/$SF_PROJECT/$DEVICE"

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
    rm -f "${BATCH:-}"
    ssh -O exit "${SSH_OPTS[@]}" "$SF_USER@$SF_HOST" 2>/dev/null || true
    rm -rf "$SSH_CTL_DIR"
    unset SSHPASS
}
trap cleanup EXIT

open_master() {
    if command -v sshpass >/dev/null && [[ -n "${SSHPASS:-}" ]]; then
        sshpass -e ssh "${SSH_OPTS[@]}" -fN "$SF_USER@$SF_HOST"
    else
        ssh "${SSH_OPTS[@]}" -fN "$SF_USER@$SF_HOST"
    fi || abort "could not open SSH connection to $SF_HOST"
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

# --- 4. probe remote: does the version folder already exist? ---------------
NEW_FOLDER=0
if [[ $DRY_RUN -eq 1 ]]; then
    NEW_FOLDER=1   # can't know without connecting; assume worst case for the preview
else
    open_master
    listing=$(sftp -o BatchMode=no "${SSH_OPTS[@]}" -b <(echo "ls $SF_BASE") "$SF_USER@$SF_HOST" 2>/dev/null || true)
    grep -q "$verdir\$\|$verdir/" <<<"$listing" || NEW_FOLDER=1
fi

# --- 5. build the sftp batch -------------------------------------------------
BATCH=$(mktemp)

{
    echo "-mkdir $SF_BASE/$verdir"
    echo "-mkdir $SF_BASE/$verdir/recovery"
    if [[ $NEW_FOLDER -eq 1 && -d "$FIRMWARE_SRC" ]]; then
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

# --- 5b. build the OTA manifest (Updater app JSON) ---------------------------
# generate_json.sh (vendor/lineage/build/tools) already wrote a correct
# manifest next to the zip at build time -- everything in it is right except
# "url", which points at cdn.axionos.org. Rewrite just that field rather than
# regenerating the rest.
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
echo "SourceForge OTA upload — Axion $ver ($date)"
echo
if [[ $NEW_FOLDER -eq 1 ]]; then
    echo "!! NEW VERSION FOLDER — will be created:"
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

printf 'File Name: %s\n  -------> %s/\n\n' "$base" "$SF_BASE/$verdir"
echo "Updated file names:"
for i in "${!LOCAL_FILES[@]}"; do
    [[ $i -eq 0 ]] && continue   # already shown above as the ROM zip
    printf '  File Name: %-28s -------> %s/\n' "${REMOTE_NAMES[$i]}" "$SF_BASE/${REMOTE_DIRS[$i]}"
done
for m in "${MISSING[@]:-}"; do
    [[ -n "$m" ]] && printf '  File Name: %-28s [MISSING — skipped]\n' "$m"
done
echo
echo "Total: ${#LOCAL_FILES[@]} files, $human_total"
echo

if [[ $DRY_RUN -eq 1 ]]; then
    echo "--dry-run: sftp batch that would run:"
    cat "$BATCH"
    if [[ -n "$MANIFEST" ]]; then
        echo
        echo "--dry-run: OTA manifest that would be published to $OUT_JSON:"
        echo "$MANIFEST"
    fi
    exit 0
fi

if [[ $NEW_FOLDER -eq 1 || $AUTO -eq 0 ]]; then
    read -rp "Proceed with upload? [y/N] " reply
    [[ $reply =~ ^[Yy]$ ]] || { echo "aborted."; exit 1; }
fi

# --- 7. upload ----------------------------------------------------------------
echo "uploading..."
sftp -o BatchMode=no "${SSH_OPTS[@]}" -b "$BATCH" "$SF_USER@$SF_HOST"
echo "done."

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
