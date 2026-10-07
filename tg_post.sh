#!/usr/bin/env bash
# tg_post.sh — announce a finished build in a Telegram group with a Download
# button. Reads the OTA manifest otauploader.sh wrote (OTA/<flavor>/<device>.json),
# renders tg_message.txt, shows the exact message + link status, asks, then sends.
#
# Secrets (TG_BOT_TOKEN, TG_CHAT_ID) come from scripts/.env -- see .env.example.
#
# With no --url the build is discovered on pixeldrain (needs PIXELDRAIN_API_KEY):
# the newest <N>.x folder under Axion/<device>/, its newest zip, and that zip's
# .md5. --beta does the same inside Axion/<device>/test/ instead.
#
# Usage:
#   ./tg_post.sh                      # lemonade, GMS, newest N.x folder
#   ./tg_post.sh --beta               # newest build in Axion/<device>/test/
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
# Template placeholders: {device} {version} {date} {filename} {size} {url} {romtype} {notes} {longdate} {hashname} {hash} {variant} {model} {beta}
# Message is parse_mode=HTML (<b> <i> <code> <a href>); values are escaped for you.
set -euo pipefail

SCRIPT_DIR="$(dirname "$(readlink -f "$0")")"
[[ -f "$SCRIPT_DIR/.env" ]] && { set -a; . "$SCRIPT_DIR/.env"; set +a; }

DEVICE=lemonade FLAVOR=GMS URL="" TEMPLATE="$SCRIPT_DIR/tg_message.txt" NOTES="" MD5="" TEXT="" BUTTON="" BETA=0 ROW2=0 CUSTOM=0 EDIT=0 DRY=0 YES=0
while [[ $# -gt 0 ]]; do
    case "$1" in
        --device) DEVICE="$2"; shift 2 ;;
        --vanilla) FLAVOR=VANILLA; shift ;;
        --beta) BETA=1; shift ;;
        --url) URL="$2"; shift 2 ;;
        --md5) MD5="$2"; shift 2 ;;
        -m) TEMPLATE="$2"; shift 2 ;;
        --notes) NOTES="$2"; shift 2 ;;
        -e) EDIT=1; shift ;;
        --text) TEXT="$2"; CUSTOM=1; shift 2 ;;
        --button) BUTTON="$2"; shift 2 ;;
        --dry-run) DRY=1; shift ;;
        -y) YES=1; shift ;;
        -h|--help) sed -n '2,31p' "$0"; exit 0 ;;
        *) echo "unknown argument: $1" >&2; exit 1 ;;
    esac
done

CHANGELOG_URL="https://raw.githubusercontent.com/varakumar01/scripts/aox/OTA/GMS/changelogs_op9.txt"
COMMUNITY_URL="https://t.me/axionos_op9"

abort() { echo "error: $*" >&2; exit 1; }
[[ -n "${TG_BOT_TOKEN:-}" && -n "${TG_CHAT_ID:-}" ]] || abort "set TG_BOT_TOKEN and TG_CHAT_ID in $SCRIPT_DIR/.env (see .env.example)"
JSON="$SCRIPT_DIR/OTA/$FLAVOR/$DEVICE.json"   # only read by the --url branch (MD5 shortcut)
(( CUSTOM )) || {
    [[ -n $URL || -n "${PIXELDRAIN_API_KEY:-}" ]] || abort "set PIXELDRAIN_API_KEY in $SCRIPT_DIR/.env (or pass --url)"
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
    OUT=$(python3 - "$JSON" "$TEMPLATE" "$NOTES" "$URL" "$FLAVOR" "$DEVICE" "$MD5" "$BETA" <<'PY'
import json, sys, html, datetime, re, hashlib, subprocess, email.utils
jf, tf, notes, url, flavor, device, md5, beta = sys.argv[1:9]
if url:  # --url: describe the file the link actually points to, not the manifest
    name = url.rsplit("/", 1)[-1].split("?")[0]
    hn, hv = "MD5", md5
    pd = re.match(r"https?://pixeldrain\.\w+/(?:api/(filesystem)/|(?:u|api/file)/)", url)
    ok = False
    if pd:  # pixeldrain's own API: instant, no download -- but it only knows sha256
        try:
            api = url.replace("/u/", "/api/file/", 1) + ("?stat" if pd[1] else "/info")
            j = json.loads(subprocess.run(["curl", "-sSL", api], capture_output=True, text=True, check=True).stdout)
            if pd[1]: j = j["path"][j["base_index"]]
            name = j.get("name", name)
            size = j.get("file_size", j.get("size"))
            ts = datetime.datetime.fromisoformat((j.get("modified") or j["date_upload"]).replace("Z", "+00:00")).timestamp()
            # the manifest already holds the zip's MD5 when this is the file it describes
            try: m = json.load(open(jf))["response"][-1]
            except Exception: m = {}
            if not md5: hn, hv = ("MD5", m["id"]) if m.get("filename") == name else ("SHA256", j.get("sha256_sum") or j["hash_sha256"])
            ok = True
        except Exception as e:  # private/expired/blocked: fall back to the generic lookup
            print("pixeldrain API failed (%s); falling back to ranged GET" % e, file=sys.stderr)
    if not ok:
        # ranged GET, not HEAD: some hosts (e.g. serverhive) 403 a HEAD
        hd = subprocess.run(["curl", "-sSL", "-D-", "-o", "/dev/null", "-r", "0-0", url],
                            capture_output=True, text=True, check=True).stdout.strip().split("\n\n")[-1]
        h = {k.lower(): v for k, v in (l.split(": ", 1) for l in hd.splitlines() if ": " in l)}
        if "content-range" not in h: sys.exit("error: cannot read size/date from %s (%s)" % (url, hd.splitlines()[0]))
        size = int(h["content-range"].rsplit("/", 1)[1])
        ts = email.utils.parsedate_to_datetime(h["last-modified"]).timestamp()
        if not md5:  # no hash from the host, so hash the stream
            print("hashing %s for MD5 (pass --md5 to skip)..." % name, file=sys.stderr)
            m, f = hashlib.md5(), subprocess.Popen(["curl", "-sSL", url], stdout=subprocess.PIPE)
            while c := f.stdout.read(1 << 20): m.update(c)
            hv = m.hexdigest()
    r = dict(filename=name, id=hv, size=size, url=url, hn=hn, datetime=ts,
             version=(re.search(r"axion-([\d.]+)", name) or [0, "?"])[1],
             romtype="OFFICIAL" if "-OFFICIAL" in name and "UNOFFICIAL" not in name else "UNOFFICIAL")
else:
    import base64, os, urllib.request, urllib.parse
    API = "https://pixeldrain.com/api"
    auth = "Basic " + base64.b64encode((":" + os.environ["PIXELDRAIN_API_KEY"]).encode()).decode()
    def get(path, raw=False):
        q = urllib.parse.quote(path) + ("" if raw else "?stat")
        with urllib.request.urlopen(urllib.request.Request(f"{API}/filesystem/{q}", headers={"Authorization": auth})) as f:
            b = f.read()
        return b.decode() if raw else json.loads(b)
    def node(d): return d["path"][d["base_index"]]
    root = f"me/Axion/{device}"
    bucket = node(get("me/Axion"))["id"]  # shared once by otauploader.sh
    if beta == "1":
        folder = "test"
    else:
        xs = [c["name"] for c in get(root)["children"] if c["type"] == "dir" and re.fullmatch(r"\d+\.x", c["name"])]
        if not xs: sys.exit("error: no N.x folder under /%s" % root)
        folder = max(xs, key=lambda n: int(n.split(".")[0]))
    zp = re.compile(r"axion-.*-%s\.zip" % re.escape(device))
    zs = [c for c in get(f"{root}/{folder}")["children"]
          if c["type"] == "file" and zp.fullmatch(c["name"]) and ("-VANILLA-" in c["name"]) == (flavor == "VANILLA")]
    if not zs: sys.exit("error: no %s %s zip in /%s/%s" % (flavor, device, root, folder))
    key = lambda c: ((re.search(r"-(\d{8,14})-", c["name"]) or [0, ""])[1][:8], c.get("created", ""))
    z = max(zs, key=key)
    name = z["name"]
    try: hn, hv = "MD5", get(f"{root}/{folder}/{name}.md5", raw=True).split()[0]
    except Exception as e:
        print("no .md5 beside %s (%s); using pixeldrain's SHA256" % (name, e), file=sys.stderr)
        hn, hv = "SHA256", z.get("sha256_sum") or z["hash_sha256"]
    url = f"{API}/filesystem/{bucket}/{device}/{folder}/{urllib.parse.quote(name)}"
    r = dict(filename=name, id=hv, size=z["file_size"], url=url, hn=hn,
             datetime=datetime.datetime.fromisoformat((z.get("modified") or z["created"]).replace("Z", "+00:00")).timestamp(),
             version=(re.search(r"axion-([\d.]+)", name) or [0, "?"])[1],
             romtype="OFFICIAL" if "-OFFICIAL" in name and "UNOFFICIAL" not in name else "UNOFFICIAL")
n = r["size"]
for u in ("B", "KB", "MB", "GB"):
    if n < 1024 or u == "GB": break
    n /= 1024
v = dict(device=device, version=r["version"], filename=r["filename"],
         romtype=r["romtype"], notes=notes, url=url or r["url"],
         size=f"{n:.2f} {u}" if u != "B" else f"{n} B",
         date=datetime.datetime.fromtimestamp(r["datetime"], datetime.timezone.utc).strftime("%Y-%m-%d"))
d = datetime.datetime.fromtimestamp(r["datetime"], datetime.timezone.utc)
sfx = "th" if 11 <= d.day <= 13 else {1: "st", 2: "nd", 3: "rd"}.get(d.day % 10, "th")
v["longdate"] = f"{d.day}{sfx} {d:%B %Y}"
v["hashname"], v["hash"] = r.get("hn", "MD5"), r["id"]  # manifest "id" is assumed to be the zip's md5
v["variant"] = "GAPPS (Google Apps Included)" if flavor == "GMS" else "VANILLA (No Google Apps)"
v["beta"] = "BETA " if beta == "1" else ""
v["model"] = "Oneplus 9 Pro" if v["device"] == "lemonadep" else "Oneplus 9"
t = open(tf, encoding="utf-8").read()
for k, val in v.items():
    t = t.replace("{%s}" % k, html.escape(str(val)))
print(v["url"])  # first line = download link, rest = message (split below)
print("\n".join(l.rstrip() for l in t.rstrip().splitlines()))
PY
)
    MSG=${OUT#*$'\n'}
    [[ -n $URL ]] || URL=${OUT%%$'\n'*}
    BTN_LABEL="⬇ Download"
    ROW2=1   # release posts also get Changelog | Community above the Download button
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
[[ -f $SCRIPT_DIR/tg_banner.png ]] && echo "image:   tg_banner.png"
if [[ -n $URL ]]; then
    (( ROW2 )) && { echo "button:  [📝 Changelog] -> $CHANGELOG_URL"; echo "         [💬 Community] -> $COMMUNITY_URL   (same row, above Download)"; }
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
[[ -n $URL ]] && EXTRA=(--form-string "reply_markup=$(python3 -c 'import json,sys; kb=[[{"text":sys.argv[1],"url":sys.argv[2]}]]
if sys.argv[3]=="1": kb.insert(0,[{"text":"📝 Changelog","url":sys.argv[4]},{"text":"💬 Community","url":sys.argv[5]}])
print(json.dumps({"inline_keyboard":kb}))' "$BTN_LABEL" "$URL" "$ROW2" "$CHANGELOG_URL" "$COMMUNITY_URL")")
# Banner goes out as a photo with the message as its caption (1024-char limit,
# so longer messages fall back to plain text). tg_banner.png is a 1920px copy of
# axion.png: sendPhoto rejects files over 10 MB.
BANNER="$SCRIPT_DIR/tg_banner.png"
if [[ -f $BANNER && ${#MSG} -le 1024 ]]; then
    RES=$(tg sendPhoto --form-string "chat_id=$TG_CHAT_ID" -F "photo=@$BANNER" --form-string "caption=$MSG" --form-string parse_mode=HTML "${EXTRA[@]}") || true
else
    RES=$(tg sendMessage --form-string "chat_id=$TG_CHAT_ID" --form-string "text=$MSG" \
            --form-string parse_mode=HTML --form-string disable_web_page_preview=true "${EXTRA[@]}") || true
fi
python3 -c 'import json,sys; d=json.load(sys.stdin); print("sent, message_id", d["result"]["message_id"]) if d.get("ok") else sys.exit("telegram error: "+str(d.get("description")))' <<<"$RES"
