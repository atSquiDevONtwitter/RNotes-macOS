#!/usr/bin/env python3
# RNotes — Copyright (c) 2026 RTECH OSS. MIT License.
#
# Builds RNotes/Assets.xcassets/AppIcon.appiconset and AppLogo.imageset from the live icon
# in RTools-Resources/iconLive/RNotes/RNotes-Icon-1024.png, and records the source PNG's
# SHA-256 in tools/icon-source.sha256 so a changed live icon can be spotted on every update.
#
#   python3 tools/make_appiconset.py /path/to/RNotes-Icon-1024.png          # rebuild
#   python3 tools/make_appiconset.py --check /path/to/RNotes-Icon-1024.png  # exit 1 if it changed
#
# Needs Pillow (pip3 install Pillow).

import hashlib, json, os, sys
from PIL import Image

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
ICONSET = os.path.join(ROOT, "RNotes", "Assets.xcassets", "AppIcon.appiconset")
LOGOSET = os.path.join(ROOT, "RNotes", "Assets.xcassets", "AppLogo.imageset")
HASHFILE = os.path.join(ROOT, "tools", "icon-source.sha256")
SIZES = [16, 32, 128, 256, 512]


def sha256(path):
    with open(path, "rb") as f:
        return hashlib.sha256(f.read()).hexdigest()


def recorded():
    try:
        with open(HASHFILE) as f:
            return f.read().split()[0]
    except (OSError, IndexError):
        return None


def save(img, px, path):
    img.resize((px, px), Image.LANCZOS).save(path, optimize=True)


def build(src):
    img = Image.open(src).convert("RGBA")
    if img.size != (1024, 1024):
        sys.exit(f"{src} is {img.size[0]}x{img.size[1]}, expected 1024x1024")
    images = []
    for s in SIZES:
        for scale in (1, 2):
            name = f"icon_{s}x{s}{'@2x' if scale == 2 else ''}.png"
            save(img, s * scale, os.path.join(ICONSET, name))
            images.append({"filename": name, "idiom": "mac", "scale": f"{scale}x", "size": f"{s}x{s}"})
    with open(os.path.join(ICONSET, "Contents.json"), "w") as f:
        json.dump({"images": images, "info": {"author": "xcode", "version": 1}}, f, indent=2)
    save(img, 256, os.path.join(LOGOSET, "logo.png"))
    save(img, 512, os.path.join(LOGOSET, "logo@2x.png"))
    with open(HASHFILE, "w") as f:
        f.write(f"{sha256(src)}  RTools-Resources/iconLive/RNotes/RNotes-Icon-1024.png\n")
    print("Rebuilt AppIcon.appiconset and AppLogo.imageset from", src)


def main():
    args = sys.argv[1:]
    check = "--check" in args
    args = [a for a in args if a != "--check"]
    if len(args) != 1:
        sys.exit(__doc__ or "usage: make_appiconset.py [--check] RNotes-Icon-1024.png")
    src = args[0]
    current, old = sha256(src), recorded()
    if check:
        if current == old:
            print("Icon unchanged:", current)
            return
        print(f"Icon changed: recorded {old or 'none'}, live {current}")
        sys.exit(1)
    build(src)


if __name__ == "__main__":
    main()
