#!/bin/bash
# Builds scripts/icon/AppIcon.icns from scripts/icon/AppIcon.svg using only tools that ship with macOS.
# Run it after editing the SVG, and commit the .icns. make-app.sh copies the .icns into the app.
#
# macOS renders the SVG onto a white background, so the rounded-square shape is cut out here
# (transparent corners, smooth edges) before the icon sizes are made.
set -euo pipefail
cd "$(dirname "$0")/icon"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

qlmanage -t -s 1024 -o "$WORK" AppIcon.svg >/dev/null 2>&1
[ -f "$WORK/AppIcon.svg.png" ] || { echo "Could not render AppIcon.svg" >&2; exit 1; }

python3 - "$WORK/AppIcon.svg.png" "$WORK/AppIcon-1024.png" <<'PY'
import struct, sys, zlib

src, dst = sys.argv[1], sys.argv[2]
data = open(src, "rb").read()
pos, idat, width, height = 8, b"", 0, 0
while pos < len(data):
    n, kind = struct.unpack(">I4s", data[pos:pos + 8])
    chunk = data[pos + 8:pos + 8 + n]
    if kind == b"IHDR":
        width, height, depth, ctype = struct.unpack(">IIBB", chunk[:10])
        assert depth == 8 and ctype == 6, "expected 8-bit RGBA"
    elif kind == b"IDAT":
        idat += chunk
    pos += 12 + n

raw = zlib.decompress(idat)
bpp, stride = 4, width * 4
rows, prev = [], bytearray(stride)
for y in range(height):
    ft = raw[y * (stride + 1)]
    line = bytearray(raw[y * (stride + 1) + 1:(y + 1) * (stride + 1)])
    for i in range(stride):
        a = line[i - bpp] if i >= bpp else 0
        b = prev[i]
        c = prev[i - bpp] if i >= bpp else 0
        if ft == 1: line[i] = (line[i] + a) & 255
        elif ft == 2: line[i] = (line[i] + b) & 255
        elif ft == 3: line[i] = (line[i] + ((a + b) >> 1)) & 255
        elif ft == 4:
            p = a + b - c
            pa, pb, pc = abs(p - a), abs(p - b), abs(p - c)
            pr = a if pa <= pb and pa <= pc else (b if pb <= pc else c)
            line[i] = (line[i] + pr) & 255
    rows.append(line)
    prev = line

# Rounded square from the SVG: x,y = 100..924, corner radius 185.
X0, X1, R = 100.0, 924.0, 185.0
def coverage(px, py):
    """1 inside the rounded square, 0 outside, fractional on the 1px edge."""
    cx = min(max(px, X0 + R), X1 - R)
    cy = min(max(py, X0 + R), X1 - R)
    d = ((px - cx) ** 2 + (py - cy) ** 2) ** 0.5 - R   # signed distance, >0 outside
    return max(0.0, min(1.0, 0.5 - d))

edge = (0x1A, 0x73, 0xE8)
out = bytearray()
for y in range(height):
    out.append(0)
    line = rows[y]
    for x in range(width):
        i = x * 4
        cov = coverage(x + 0.5, y + 0.5)
        if cov >= 1.0:
            out += line[i:i + 4]
        elif cov <= 0.0:
            out += b"\x00\x00\x00\x00"
        else:
            out += bytes((*edge, int(round(cov * 255))))

def chunk(kind, body):
    return struct.pack(">I", len(body)) + kind + body + struct.pack(">I", zlib.crc32(kind + body) & 0xFFFFFFFF)

png = b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", width, height, 8, 6, 0, 0, 0))
png += chunk(b"IDAT", zlib.compress(bytes(out), 9)) + chunk(b"IEND", b"")
open(dst, "wb").write(png)
PY

SET="$WORK/AppIcon.iconset"
mkdir -p "$SET"
for size in 16 32 128 256 512; do
  sips -z "$size" "$size" "$WORK/AppIcon-1024.png" --out "$SET/icon_${size}x${size}.png" >/dev/null
  sips -z $((size * 2)) $((size * 2)) "$WORK/AppIcon-1024.png" --out "$SET/icon_${size}x${size}@2x.png" >/dev/null
done
iconutil -c icns "$SET" -o AppIcon.icns
cp "$WORK/AppIcon-1024.png" AppIcon-preview.png
echo "Built scripts/icon/AppIcon.icns"
