#!/bin/bash
#
# Regenerates scripts/dmg/DS_Store, the Finder layout of the Dicavo CLI
# Bridge installer window: window size, no toolbar, icon positions and the
# background drawn by render-background.swift. scripts/make-dmg.sh copies the
# file into every image, so a release build never drives Finder.
#
# Run it by hand, only when the window changes, in a logged-in session:
#
#   scripts/dmg/make-layout.sh
#
# Finder must open folders in new windows while it runs (Finder > Settings >
# General > "Open folders in tabs instead of new windows" off): in a tab the
# window keeps the layout of the window that holds it and the background is
# never stored. The first run also asks to allow this terminal to control
# Finder.
#
# The layout refers to the background by the volume name, so the image must
# be mounted under the same name that make-dmg.sh gives it (VOLUME_NAME).

set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VOLUME_NAME="Dicavo CLI Bridge"
APP_NAME="Dicavo CLI Bridge.app"

WORK="$(mktemp -d /private/tmp/Dicavo-dmg-layout.XXXXXX)"
MOUNTPOINT=""
cleanup() {
    local status=$?
    [ -n "$MOUNTPOINT" ] && hdiutil detach "$MOUNTPOINT" -quiet 2>/dev/null || true
    rm -rf "$WORK"
    exit $status
}
trap cleanup EXIT

if mount | grep -q " on /Volumes/$VOLUME_NAME "; then
    echo "error: a volume named '$VOLUME_NAME' is already mounted; eject it first" >&2
    exit 1
fi

# Same content as a real image; the app is a placeholder folder, Finder only
# needs an item of that name to position.
mkdir -p "$WORK/stage/.background" "$WORK/stage/$APP_NAME"
ln -s /Applications "$WORK/stage/Applications"
swift "$DIR/render-background.swift" "$WORK/background" >/dev/null
tiffutil -cathidpicheck "$WORK/background/background.png" "$WORK/background/background@2x.png" \
    -out "$WORK/background/background.tiff" >/dev/null 2>&1
tiffutil -lzw "$WORK/background/background.tiff" -out "$WORK/stage/.background/background.tiff" >/dev/null 2>&1

hdiutil create -quiet -format UDRW -fs HFS+ -size 20m -volname "$VOLUME_NAME" \
    -srcfolder "$WORK/stage" "$WORK/layout.dmg"
hdiutil attach "$WORK/layout.dmg" -readwrite -noverify -noautoopen -quiet
MOUNTPOINT="/Volumes/$VOLUME_NAME"
[ -d "$MOUNTPOINT" ] || { echo "error: the image did not mount at $MOUNTPOINT" >&2; exit 1; }

osascript - "$MOUNTPOINT" "$APP_NAME" <<'APPLESCRIPT'
on run argv
    set mountPath to item 1 of argv
    set appName to item 2 of argv
    tell application "Finder"
        set volumeFolder to (POSIX file mountPath) as alias
        set theWindow to make new Finder window to volumeFolder
        set current view of theWindow to icon view
        set toolbar visible of theWindow to false
        set statusbar visible of theWindow to false
        -- 660 x 400 points of content; the extra height is the title bar.
        set bounds of theWindow to {200, 120, 860, 548}
        set viewOptions to icon view options of theWindow
        set arrangement of viewOptions to not arranged
        set icon size of viewOptions to 128
        set text size of viewOptions to 13
        set background picture of viewOptions to file ".background:background.tiff" of volumeFolder
        set position of item appName of volumeFolder to {165, 225}
        set position of item "Applications" of volumeFolder to {495, 225}
        update volumeFolder without registering applications
        delay 2
        close theWindow
    end tell
end run
APPLESCRIPT

# Finder writes .DS_Store on its own schedule after the window closes.
for _ in $(seq 1 20); do
    [ -f "$MOUNTPOINT/.DS_Store" ] && grep -q "pBBk\|backgroundImageAlias" "$MOUNTPOINT/.DS_Store" && break
    sleep 0.5
done
grep -q "pBBk\|backgroundImageAlias" "$MOUNTPOINT/.DS_Store" 2>/dev/null \
    || { echo "error: Finder did not store the background picture in .DS_Store" >&2; exit 1; }

cp "$MOUNTPOINT/.DS_Store" "$WORK/DS_Store"

# Finder copies the tab bar from the user's own windows into the layout and
# has no scripting term for it or for the path bar, so the window settings
# record ("bwsp" of the volume) is rewritten here with every bar hidden. The
# record sits in a B-tree leaf block of the .DS_Store; records follow each
# other without an index, so the block is rebuilt record by record and padded
# back to its allocated size.
python3 -I - "$WORK/DS_Store" "$DIR/DS_Store" <<'PYTHON'
import plistlib, struct, sys

source, destination = sys.argv[1], sys.argv[2]
data = bytearray(open(source, "rb").read())
assert data[4:8] == b"Bud1", "not a .DS_Store"
root_offset, root_size = struct.unpack(">II", data[8:16])
root = data[4 + root_offset:4 + root_offset + root_size]
count = struct.unpack(">I", root[:4])[0]
blocks = [(a & ~0x1F, 1 << (a & 0x1F)) for a in struct.unpack(">%dI" % count, root[8:8 + 4 * count])]

VALUE_SIZE = {b"long": 4, b"shor": 4, b"bool": 1, b"type": 4, b"comp": 8, b"dutc": 8}

def records(block):
    pointer, number = struct.unpack(">II", block[:8])
    position, items = 8, []
    for _ in range(number):
        start = position
        name_length = struct.unpack(">I", block[position:position + 4])[0]
        position += 4 + 2 * name_length
        code, kind = block[position:position + 4], block[position + 4:position + 8]
        position += 8
        if kind == b"blob":
            position += 4 + struct.unpack(">I", block[position:position + 4])[0]
        elif kind == b"ustr":
            position += 4 + 2 * struct.unpack(">I", block[position:position + 4])[0]
        else:
            position += VALUE_SIZE[kind]
        items.append((start, position, code, kind))
    return pointer, number, items

patched = False
for offset, size in blocks:
    block = bytes(data[4 + offset:4 + offset + size])
    if b"bwsp" not in block:
        continue
    pointer, number, items = records(block)
    assert pointer == 0, "the window record is not in a leaf block"
    rebuilt = bytearray(block[:8])
    for start, end, code, kind in items:
        record = block[start:end]
        if code == b"bwsp" and kind == b"blob":
            name_length = struct.unpack(">I", record[:4])[0]
            head = record[:4 + 2 * name_length + 8]
            settings = plistlib.loads(record[len(head) + 4:])
            for key in ("ShowTabView", "ShowPathbar", "ShowStatusBar", "ShowToolbar",
                        "ShowSidebar", "ContainerShowSidebar"):
                settings[key] = False
            blob = plistlib.dumps(settings, fmt=plistlib.FMT_BINARY)
            record = head + struct.pack(">I", len(blob)) + blob
            patched = True
        rebuilt += record
    assert len(rebuilt) <= size, "the rewritten window record does not fit its block"
    data[4 + offset:4 + offset + size] = rebuilt + bytes(size - len(rebuilt))
    break

assert patched, "no window record (bwsp) in the layout"
open(destination, "wb").write(bytes(data))
PYTHON
echo "Wrote $DIR/DS_Store"
