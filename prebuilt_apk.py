#!/usr/bin/env python3
"""Helpers for track_changes.sh's prebuilt-APK sync.

Subcommands (all read GitHub JSON from stdin unless noted):
  brave-url   releases list  -> "<tag>\\t<url>" of the newest *stable Release*
                               channel entry carrying Bravearm64Universal.apk
  ksun-url    one release     -> "<url>" of that release's *-spoofed*release.apk
  v2cert <apk>                -> sha256 of the APK's v2-scheme signer cert
                               (what the kernel's apk_sign.c pins)
Each exits non-zero (and prints nothing) when there is no match, so the
caller can treat "no result" as "leave the current APK alone".
"""
import hashlib
import json
import struct
import sys

BRAVE_ASSET = "Bravearm64Universal.apk"


def brave_url():
    rels = json.load(sys.stdin)
    # API returns newest first; take the first stable-Release entry that
    # actually has the arm64 universal APK attached (some entries are
    # published before the asset is uploaded, and Beta/Nightly share the feed).
    for r in rels:
        if r.get("draft") or not (r.get("name") or "").startswith("Release"):
            continue
        for a in r.get("assets", []):
            if a.get("name") == BRAVE_ASSET:
                print("%s\t%s" % (r["tag_name"], a["browser_download_url"]))
                return 0
    return 1


def ksun_url():
    r = json.load(sys.stdin)
    for a in r.get("assets", []):
        n = a.get("name", "")
        if "spoofed" in n and n.endswith("release.apk"):
            print(a["browser_download_url"])
            return 0
    return 1


def v2cert(path):
    """sha256 of the first APK Signature Scheme v2 signer certificate."""
    d = open(path, "rb").read()
    eocd = d.rfind(b"PK\x05\x06")
    if eocd < 0:
        return 1
    cd = struct.unpack_from("<I", d, eocd + 16)[0]
    if d[cd - 16:cd] != b"APK Sig Block 42":
        return 1
    size = struct.unpack_from("<Q", d, cd - 24)[0]
    p, end = cd - size, cd - 24                      # id-value pairs
    while p < end:
        n, ident = struct.unpack_from("<QI", d, p)
        if ident == 0x7109871A:                      # v2 scheme block
            # p+12 value; +4 signers len; +4 first-signer len; +4 signed-data
            # len -> signed-data content (digests seq len) at p+24
            q = p + 12 + 4 + 4 + 4
            dg = struct.unpack_from("<I", d, q)[0]    # digests seq len
            c = q + 4 + dg + 4                        # -> first certificate
            clen = struct.unpack_from("<I", d, c)[0]
            print(hashlib.sha256(d[c + 4:c + 4 + clen]).hexdigest())
            return 0
        p += 8 + n
    return 1


def main():
    if len(sys.argv) < 2:
        return 2
    cmd = sys.argv[1]
    if cmd == "brave-url":
        return brave_url()
    if cmd == "ksun-url":
        return ksun_url()
    if cmd == "v2cert":
        return v2cert(sys.argv[2])
    return 2


if __name__ == "__main__":
    sys.exit(main())
