#!/usr/bin/env python3
"""Look up Arch packages in the official repos, then the AUR, so installer
changes use real names instead of guesses.

Usage:
    pkginfo.py NAME...           repo or AUR, version, description, deps
    pkginfo.py --files NAME...   also notable files: binaries (the command
                                 name), .desktop files, systemd units, udev
                                 rules, modules-load, portals, sessions
    pkginfo.py --search WORD     official package named WORD, and AUR
                                 packages matching WORD, most voted first

Reads archlinux.org and aur.archlinux.org (via curl, so proxy settings apply).
"""
import json
import re
import subprocess
import sys

NOTABLE = re.compile(r"(^usr/bin/.|\.desktop$|systemd/(system|user)/.|udev/rules\.d/.|"
                     r"modules-load\.d/.|xdg-desktop-portal/.|bootstrap.*\.tar|wayland-sessions/.)")


def get(url, as_json=True):
    out = subprocess.run(["curl", "-sS", "--max-time", "30", url], capture_output=True, text=True)
    if out.returncode:
        sys.exit(f"request failed: {url}\n{out.stderr.strip()}")
    return json.loads(out.stdout) if as_json else out.stdout


def official(name):
    r = get(f"https://archlinux.org/packages/search/json/?name={name}")["results"]
    return r[0] if r else None


def aur(name):
    r = get(f"https://aur.archlinux.org/rpc/v5/info?arg[]={name}").get("results", [])
    return r[0] if r else None


def show(name, files):
    print(f"== {name}")
    x = official(name)
    if x:
        print(f"  official ({x['repo']}) {x['pkgver']}-{x['pkgrel']}: {x['pkgdesc']}")
        print(f"  depends: {' '.join(x['depends']) or '-'}")
        print(f"  optdepends: {'; '.join(x['optdepends']) or '-'}")
        if files:
            listing = get(f"https://archlinux.org/packages/{x['repo']}/{x['arch']}/{name}/files/json/")["files"]
            for f in listing:
                if NOTABLE.search(f) and not f.endswith("/"):
                    print(f"  file: {f}")
        return
    a = aur(name)
    if not a:
        print(f"  NOT FOUND in the official repos or the AUR. Try: pkginfo.py --search {name.split('-')[0]}")
        return
    ood = "  OUT-OF-DATE" if a.get("OutOfDate") else ""
    print(f"  AUR {a['Version']}  votes {a['NumVotes']}  maintainer {a.get('Maintainer')}{ood}: {a.get('Description')}")
    print(f"  depends: {' '.join(a.get('Depends') or []) or '-'}")
    print(f"  optdepends: {'; '.join(a.get('OptDepends') or []) or '-'}")
    if files:
        print("  (AUR packages have no file list; PKGBUILD lines that name installed files:)")
        pkgbuild = get(f"https://aur.archlinux.org/cgit/aur.git/plain/PKGBUILD?h={name}", as_json=False)
        pat = re.compile(r"install -D|ln -s|\.desktop|/usr/bin|^options=|_binaryname=|_pkgname=")
        for i, line in enumerate(pkgbuild.splitlines(), 1):
            if pat.search(line):
                print(f"  {i:4}: {line.strip()}")


def search(word):
    x = official(word)
    if x:
        print(f"official  {x['repo']:9} {x['pkgname']} {x['pkgver']}-{x['pkgrel']}  {x['pkgdesc'][:70]}")
    hits = get(f"https://aur.archlinux.org/rpc/v5/search/{word}?by=name").get("results", [])
    for a in sorted(hits, key=lambda a: -a["NumVotes"])[:15]:
        ood = "  OUT-OF-DATE" if a.get("OutOfDate") else ""
        print(f"AUR  votes {a['NumVotes']:4}  {a['Name']} {a['Version']}{ood}  {(a.get('Description') or '')[:60]}")


if __name__ == "__main__":
    args = sys.argv[1:]
    if not args or args[0] in ("-h", "--help"):
        sys.exit(__doc__)
    if args[0] == "--search":
        search(args[1])
    else:
        files = args[0] == "--files"
        for n in args[1 if files else 0:]:
            show(n, files)
