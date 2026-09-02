#!/usr/bin/env bash
# otauploader.sh — push a finished AxionOS lemonade build + recovery images to
# SourceForge over sftp. Run from the build root (the dir containing `out/`).
#
# Usage:
#   ./otauploader.sh              # fetch, show summary, ask before uploading
#   ./otauploader.sh -au          # same, but skip the summary prompt
#                                  #   (a brand-new version folder still prompts)
#   ./otauploader.sh --dry-run    # parse + build the upload batch, print it,
#                                  #   never connect to SourceForge
set -euo pipefail

SF_USER="varakumar01"
SF_HOST="frs.sourceforge.net"
SF_BASE="/home/frs/project/Axion-os/lemonade"
DEVICE="lemonade"
IMAGES=(boot.img vendor_boot.img vbmeta.img dtbo.img vendor_dlkm.img super_empty.img)
FIRMWARE_SRC="$(dirname "$(readlink -f "$0")")/scripts/firmware"

AUTO=0
DRY_RUN=0
for arg in "$@"; do
    case "$arg" in
        --auto-upload|-au) AUTO=1 ;;
        --dry-run) DRY_RUN=1 ;;
        --help|-h)
            sed -n '2,10p' "$0"; exit 0 ;;
        *) echo "unknown argument: $arg" >&2; exit 1 ;;
    esac
done

abort() { echo "error: $*" >&2; exit 1; }

[[ -d out/target/product/$DEVICE ]] || abort "out/target/product/$DEVICE not found — run this from the build root"

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
    command -v sshpass >/dev/null || abort "sshpass not installed — install it, or fall back to plain sftp"
    [[ -n "${SSHPASS:-}" ]] || { read -rs -p "SourceForge password for $SF_USER: " SSHPASS; echo; export SSHPASS; }
    trap 'unset SSHPASS' EXIT

    listing=$(sshpass -e sftp -o BatchMode=no -b <(echo "ls $SF_BASE") "$SF_USER@$SF_HOST" 2>/dev/null || true)
    grep -q "$verdir\$\|$verdir/" <<<"$listing" || NEW_FOLDER=1
fi

# --- 5. build the sftp batch -------------------------------------------------
BATCH=$(mktemp)
trap 'rm -f "$BATCH"; unset SSHPASS' EXIT

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
    exit 0
fi

if [[ $NEW_FOLDER -eq 1 || $AUTO -eq 0 ]]; then
    read -rp "Proceed with upload? [y/N] " reply
    [[ $reply =~ ^[Yy]$ ]] || { echo "aborted."; exit 1; }
fi

# --- 7. upload ----------------------------------------------------------------
echo "uploading..."
sshpass -e sftp -o BatchMode=no -b "$BATCH" "$SF_USER@$SF_HOST"
echo "done."
