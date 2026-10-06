#!/usr/bin/env bash
# tg_post.sh — announce a finished build in a Telegram group with a Download
# button. Reads the OTA manifest otauploader.sh wrote (OTA/<flavor>/<device>.json),
# renders tg_message.txt, shows the exact message + link status, asks, then sends.
#
# Secrets (TG_BOT_TOKEN, TG_CHAT_ID) come from scripts/.env -- see .env.example.
#
# Usage:
#   ./tg_post.sh                      # lemonade, GMS
#   ./tg_post.sh --device lemonadep
#   ./tg_post.sh --vanilla            # OTA/VANILLA/<device>.json
#   ./tg_post.sh --url <link>         # override the button link
#   ./tg_post.sh -m <file>            # message template (default tg_message.txt)
#   ./tg_post.sh -e                   # edit the rendered message in $EDITOR first
#   ./tg_post.sh --notes "text"       # fills {notes}
#   ./tg_post.sh --dry-run            # preview only, never sends
#   Custom message (no manifest needed; HTML allowed, sent as-is):
#   ./tg_post.sh --text "<b>Hi</b> new build soon"   # plain announcement, no button
#   ./tg_post.sh --text -             # read the message from stdin
#   ./tg_post.sh --text "..." --button "Changelog|https://example.com"   # add a button
#   ./tg_post.sh -e --text ""         # write the message in $EDITOR
#   ./tg_post.sh -y                   # skip the confirm prompt
# Template placeholders: {device} {version} {date} {filename} {size} {url} {romtype} {notes} {longdate} {md5} {variant} {model}
# Message is parse_mode=HTML (<b> <i> <code> <a href>); values are escaped for you.
set -euo pipefail

SCRIPT_DIR="$(dirname "$(readlink -f "$0")")"
[[ -f "$SCRIPT_DIR/.env" ]] && { set -a; . "$SCRIPT_DIR/.env"; set +a; }

DEVICE=lemonade FLAVOR=GMS URL="" TEMPLATE="$SCRIPT_DIR/tg_message.txt" NOTES="" TEXT="" BUTTON="" CUSTOM=0 EDIT=0 DRY=0 YES=0
while [[ $# -gt 0 ]]; do
    case "$1" in
        --device) DEVICE="$2"; shift 2 ;;
        --vanilla) FLAVOR=VANILLA; shift ;;
        --url) URL="$2"; shift 2 ;;
        -m) TEMPLATE="$2"; shift 2 ;;
        --notes) NOTES="$2"; shift 2 ;;
        -e) EDIT=1; shift ;;
        --text) TEXT="$2"; CUSTOM=1; shift 2 ;;
        --button) BUTTON="$2"; shift 2 ;;
        --dry-run) DRY=1; shift ;;
        -y) YES=1; shift ;;
        -h|--help) sed -n '2,26p' "$0"; exit 0 ;;
        *) echo "unknown argument: $1" >&2; exit 1 ;;
    esac
done

abort() { echo "error: $*" >&2; exit 1; }
[[ -n "${TG_BOT_TOKEN:-}" && -n "${TG_CHAT_ID:-}" ]] || abort "set TG_BOT_TOKEN and TG_CHAT_ID in $SCRIPT_DIR/.env (see .env.example)"
JSON="$SCRIPT_DIR/OTA/$FLAVOR/$DEVICE.json"
(( CUSTOM )) || {
    [[ -f $JSON ]] || abort "$JSON not found -- run otauploader.sh first"
    [[ -f $TEMPLATE ]] || abort "template $TEMPLATE not found"
}

# tg <method> <curl args...> -- token goes in via curl's -K stdin, never in `ps`.
tg() { local m="$1"; shift; printf 'url = "https://api.telegram.org/bot%s/%s"\n' "$TG_BOT_TOKEN" "$m" | curl -sS -K - "$@"; }

# Render: a custom --text is sent as-is; otherwise one python call parses the
# manifest and fills the template.
if (( CUSTOM )); then
    [[ $TEXT == - ]] && TEXT=$(cat)
    MSG="$TEXT"
    if [[ -n $BUTTON ]]; then BTN_LABEL="${BUTTON%%|*}"; URL="${BUTTON#*|}"; else BTN_LABEL=""; URL=""; fi
else
    MSG=$(python3 - "$JSON" "$TEMPLATE" "$NOTES" "$URL" "$FLAVOR" <<'PY'
import json, sys, html, datetime
jf, tf, notes, url, flavor = sys.argv[1:6]
r = json.load(open(jf))["response"][-1]
n = r["size"]
for u in ("B", "KB", "MB", "GB"):
    if n < 1024 or u == "GB": break
    n /= 1024
v = dict(device=jf.rsplit("/", 1)[-1][:-5], version=r["version"], filename=r["filename"],
         romtype=r["romtype"], notes=notes, url=url or r["url"],
         size=f"{n:.2f} {u}" if u != "B" else f"{n} B",
         date=datetime.datetime.fromtimestamp(r["datetime"], datetime.timezone.utc).strftime("%Y-%m-%d"))
d = datetime.datetime.fromtimestamp(r["datetime"], datetime.timezone.utc)
sfx = "th" if 11 <= d.day <= 13 else {1: "st", 2: "nd", 3: "rd"}.get(d.day % 10, "th")
v["longdate"] = f"{d.day}{sfx} {d:%B %Y}"
v["md5"] = r["id"]  # OTA manifest id is the zip's md5
v["variant"] = "GAPPS (Google Apps Included)" if flavor == "GMS" else "VANILLA (No Google Apps)"
v["model"] = "Oneplus 9 Pro" if v["device"] == "lemonadep" else "Oneplus 9"
t = open(tf, encoding="utf-8").read()
for k, val in v.items():
    t = t.replace("{%s}" % k, html.escape(str(val)))
print("\n".join(l.rstrip() for l in t.rstrip().splitlines()))
PY
)
    BTN_LABEL="⬇ Download"
    [[ -n $URL ]] || URL=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["response"][-1]["url"])' "$JSON")
fi

if (( EDIT )); then
    tmp=$(mktemp); trap 'rm -f "$tmp"' EXIT
    printf '%s\n' "$MSG" > "$tmp"; "${EDITOR:-vi}" "$tmp"; MSG=$(<"$tmp")
fi

BOT=$(tg getMe | python3 -c 'import json,sys; d=json.load(sys.stdin); print("@"+d["result"]["username"] if d.get("ok") else "INVALID TOKEN: "+str(d.get("description")))') || abort "getMe failed"
LINK=""; [[ -n $URL ]] && { LINK=$(curl -sL -o /dev/null -r 0-0 -w '%{http_code}' "$URL" || echo "unreachable"); }

echo "================ Telegram post preview ================"
echo "bot:     $BOT"
echo "chat:    $TG_CHAT_ID"
if [[ -n $URL ]]; then
    echo "button:  [$BTN_LABEL] -> $URL"
    case "$LINK" in 200|206) echo "link:    OK (HTTP $LINK)" ;; *) echo "link:    !! HTTP $LINK -- the button will not work" ;; esac
else
    echo "button:  (none)"
fi
echo "------------------------ message ----------------------"
echo "$MSG"
echo "======================================================="
(( DRY )) && { echo "--dry-run: not sent."; exit 0; }
if (( ! YES )); then read -rp "Send to Telegram? [y/N] " reply; [[ $reply =~ ^[Yy]$ ]] || { echo "aborted."; exit 1; }; fi

[[ -n $MSG ]] || abort "empty message"
EXTRA=()
[[ -n $URL ]] && EXTRA=(--data-urlencode "reply_markup=$(python3 -c 'import json,sys; print(json.dumps({"inline_keyboard":[[{"text":sys.argv[1],"url":sys.argv[2]}]]}))' "$BTN_LABEL" "$URL")")
RES=$(tg sendMessage --data-urlencode "chat_id=$TG_CHAT_ID" --data-urlencode "text=$MSG" \
        --data-urlencode parse_mode=HTML -d disable_web_page_preview=true "${EXTRA[@]}") || true
python3 -c 'import json,sys; d=json.load(sys.stdin); print("sent, message_id", d["result"]["message_id"]) if d.get("ok") else sys.exit("telegram error: "+str(d.get("description")))' <<<"$RES"
