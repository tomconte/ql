#!/usr/bin/env python3
"""genfont - the vector font: stroke tables and HUD digits for lib/.

One definition, two forms (docs/engine-spec.md section 5.7):

- strokes, for lib/draw_text.asm (draw_text): every character is a set
  of polylines on a 4 x 6 grid (x right 0..4, y down 0..6), Atari
  vector style, drawn with draw_line at any size;
- HUD digits, for draw_bcd: the digits' strokes rasterized here at one
  small size into one byte per row (bit 7 = the left pixel), blitted
  into the green plane like lib/draw_dec.asm -- the same look for a
  fraction of the cost of drawing lines.

    python tools/genfont.py -o lib/vfont.inc     # the tables
    python tools/genfont.py --png font.png       # a preview sheet

The preview draws the strokes with a plain Bresenham (draw_line's
pixel placement may differ by a pixel along a slope) at the sizes
draw_text gets: a grid unit is 3k px across by 2k rows down, which
keeps the letters' shape on mode 4's pixels (1.5x taller than wide).
Rows are doubled, as in qlshot's PNGs. Stdlib only.
"""

import argparse
import struct
import sys
import zlib

GRID_W, GRID_H = 4, 6
ADV = 6                     # cell advance in grid units: 4 + a gap of 2
FIRST, LAST = 32, 90        # ' ' .. 'Z'

# Polylines per character: lists of (x, y) grid points, y down.
# Digits are axis-aligned (crisp at any size, and the HUD raster); O and
# 0 share the rectangle, S and 5 the 7-segment shape -- context tells
# them apart, as on the arcade machines. Q's tail is the one stroke
# outside the 4 x 6 box: a unit into the gap and a unit below, so text
# needs a unit of room under it.
GLYPHS = {
    " ": [],
    "A": [[(0, 6), (0, 2), (2, 0), (4, 2), (4, 6)], [(0, 4), (4, 4)]],
    "B": [[(0, 0), (0, 6), (4, 6), (4, 3), (0, 3)], [(0, 0), (3, 0), (3, 3)]],
    "C": [[(4, 0), (0, 0), (0, 6), (4, 6)]],
    "D": [[(0, 0), (2, 0), (4, 2), (4, 4), (2, 6), (0, 6), (0, 0)]],
    "E": [[(4, 0), (0, 0), (0, 6), (4, 6)], [(0, 3), (3, 3)]],
    "F": [[(4, 0), (0, 0), (0, 6)], [(0, 3), (3, 3)]],
    "G": [[(4, 0), (0, 0), (0, 6), (4, 6), (4, 3), (2, 3)]],
    "H": [[(0, 0), (0, 6)], [(4, 0), (4, 6)], [(0, 3), (4, 3)]],
    "I": [[(1, 0), (3, 0)], [(2, 0), (2, 6)], [(1, 6), (3, 6)]],
    "J": [[(4, 0), (4, 6), (0, 6), (0, 4)]],
    "K": [[(0, 0), (0, 6)], [(4, 0), (0, 3), (4, 6)]],
    "L": [[(0, 0), (0, 6), (4, 6)]],
    "M": [[(0, 6), (0, 0), (2, 2), (4, 0), (4, 6)]],
    "N": [[(0, 6), (0, 0), (4, 6), (4, 0)]],
    "O": [[(0, 0), (4, 0), (4, 6), (0, 6), (0, 0)]],
    "P": [[(0, 6), (0, 0), (4, 0), (4, 3), (0, 3)]],
    "Q": [[(0, 0), (4, 0), (4, 6), (0, 6), (0, 0)], [(3, 5), (5, 7)]],
    "R": [[(0, 6), (0, 0), (4, 0), (4, 3), (0, 3)], [(1, 3), (4, 6)]],
    "S": [[(4, 0), (0, 0), (0, 3), (4, 3), (4, 6), (0, 6)]],
    "T": [[(0, 0), (4, 0)], [(2, 0), (2, 6)]],
    "U": [[(0, 0), (0, 6), (4, 6), (4, 0)]],
    "V": [[(0, 0), (2, 6), (4, 0)]],
    "W": [[(0, 0), (0, 6), (2, 4), (4, 6), (4, 0)]],
    "X": [[(0, 0), (4, 6)], [(4, 0), (0, 6)]],
    "Y": [[(0, 0), (2, 3), (4, 0)], [(2, 3), (2, 6)]],
    "Z": [[(0, 0), (4, 0), (0, 6), (4, 6)]],
    "0": [[(0, 0), (4, 0), (4, 6), (0, 6), (0, 0)]],
    "1": [[(2, 0), (2, 6)]],
    "2": [[(0, 0), (4, 0), (4, 3), (0, 3), (0, 6), (4, 6)]],
    "3": [[(0, 0), (4, 0), (4, 6), (0, 6)], [(0, 3), (4, 3)]],
    "4": [[(0, 0), (0, 3), (4, 3)], [(4, 0), (4, 6)]],
    "5": [[(4, 0), (0, 0), (0, 3), (4, 3), (4, 6), (0, 6)]],
    "6": [[(4, 0), (0, 0), (0, 6), (4, 6), (4, 3), (0, 3)]],
    "7": [[(0, 0), (4, 0), (4, 6)]],
    "8": [[(0, 0), (4, 0), (4, 6), (0, 6), (0, 0)], [(0, 3), (4, 3)]],
    "9": [[(4, 3), (0, 3), (0, 0), (4, 0), (4, 6), (0, 6)]],
    "-": [[(1, 3), (3, 3)]],
    ".": [[(2, 5), (2, 6)]],
    ":": [[(2, 1), (2, 2)], [(2, 4), (2, 5)]],
    "/": [[(4, 0), (0, 6)]],
}

# The HUD digits: grid x -> pixel column, grid y -> row. 6 px by 7 rows
# in an 8-px screen group (one green byte per row, 2 px of gap), about
# the k = 1/2 size of the strokes.
HUD_X = {0: 0, 1: 1, 2: 2, 3: 4, 4: 5}
HUD_Y = {y: y for y in range(GRID_H + 1)}
HUD_ROWS = GRID_H + 1


def check():
    """Every point in the cell (a unit of descender allowed), every
    polyline a line at least."""
    for ch, polys in GLYPHS.items():
        assert FIRST <= ord(ch) <= LAST, f"{ch!r}: outside ' '..'Z'"
        for poly in polys:
            assert len(poly) >= 2, f"{ch!r}: a polyline of one point"
            for x, y in poly:
                assert 0 <= x < ADV and 0 <= y <= GRID_H + 1, f"{ch!r}: {x},{y}"
            for a, b in zip(poly, poly[1:]):
                assert a != b, f"{ch!r}: a zero-length stroke"


def line_px(x0, y0, x1, y1):
    """The pixels of a line, both ends included (plain Bresenham)."""
    dx, dy = abs(x1 - x0), -abs(y1 - y0)
    sx, sy = (1 if x1 >= x0 else -1), (1 if y1 >= y0 else -1)
    err = dx + dy
    while True:
        yield x0, y0
        if (x0, y0) == (x1, y1):
            return
        e2 = 2 * err
        if e2 >= dy:
            err += dy
            x0 += sx
        if e2 <= dx:
            err += dx
            y0 += sy


def hud_digit(ch):
    """One digit's rows as bytes, bit 7 = the left pixel."""
    rows = [0] * HUD_ROWS
    for poly in GLYPHS[ch]:
        for (ax, ay), (bx, by) in zip(poly, poly[1:]):
            for x, y in line_px(HUD_X[ax], HUD_Y[ay], HUD_X[bx], HUD_Y[by]):
                rows[y] |= 0x80 >> x
    return rows


def label(code):
    return f"vf_g{code:02x}"


def emit(out):
    w = out.write
    w("; vfont.inc -- the vector font (generated by tools/genfont.py: edit\n")
    w("; the glyphs there). See lib/draw_text.asm.\n")
    w(";\n")
    w("; Strokes: vf_tab holds, for each character from vf_first, a word\n")
    w("; offset from vf_tab to its polylines: a count of points, then the\n")
    w("; points (x << 4 | y on the 4 x 6 grid, y down); a count of 0 ends\n")
    w("; the character. Characters without a glyph point to the space.\n")
    w("; HUD digits: vf_dig, the digits 0-9 then a blank (vf_blank), each\n")
    w("; vf_dh rows of one byte, bit 7 = the left pixel: the digits' strokes\n")
    w("; rasterized at 6 px by 7 rows.\n")
    w(";\n")
    w("; No \"end\" directive -- meant to be included.\n\n")
    w(f"vf_first    equ     {FIRST}\n")
    w(f"vf_n        equ     {LAST - FIRST + 1}              ; ' ' .. 'Z'\n")
    w(f"vf_adv      equ     {ADV}               ; cell advance, grid units\n")
    w(f"vf_dh       equ     {HUD_ROWS}               ; HUD digit rows\n")
    w("vf_blank    equ     10              ; the blank HUD digit\n\n")
    w("        even\nvf_tab:\n")
    for code in range(FIRST, LAST + 1):
        ch = chr(code)
        tgt = label(code) if ch in GLYPHS else label(ord(" "))
        w(f"        dc.w    {tgt}-vf_tab".ljust(40) + f"; {ch!r}\n")
    for code in range(FIRST, LAST + 1):
        ch = chr(code)
        if ch not in GLYPHS:
            continue
        data = []
        for poly in GLYPHS[ch]:
            data.append(str(len(poly)))
            data += [f"${x << 4 | y:02x}" for x, y in poly]
        data.append("0")
        w(f"{label(code)}:".ljust(8) + f"dc.b    {','.join(data)}".ljust(52)
          + f"; {ch!r}\n")
    w("\n        even\nvf_dig:\n")
    for ch in "0123456789":
        rows = hud_digit(ch)
        w(f"        dc.b    {','.join(f'${r:02x}' for r in rows)}".ljust(48)
          + f"; {ch}\n")
    w(f"        dc.b    {','.join(['0'] * HUD_ROWS)}".ljust(48) + "; blank\n")
    w("        even\n")


# ---------------------------------------------------------------- preview
GREEN = (0, 255, 0)


def png(path, pix, width, height):
    raw = b"".join(b"\0" + bytes(c for x in range(width) for c in pix[y][x])
                   for y in range(height))

    def chunk(kind, data):
        c = struct.pack(">I", len(data)) + kind + data
        return c + struct.pack(">I", zlib.crc32(kind + data) & 0xffffffff)

    with open(path, "wb") as f:
        f.write(b"\x89PNG\r\n\x1a\n")
        f.write(chunk(b"IHDR", struct.pack(">IIBBBBB", width, height, 8, 2, 0, 0, 0)))
        f.write(chunk(b"IDAT", zlib.compress(raw, 9)))
        f.write(chunk(b"IEND", b""))


def preview(path):
    w, h = 512, 256
    pix = [[(0, 0, 0)] * w for _ in range(h)]

    def plot(x, y):
        if 0 <= x < w and 0 <= y < h:
            pix[y][x] = GREEN

    def text(s, x, y, k):
        xu, yu = 3 * k, 2 * k
        for ch in s:
            for poly in GLYPHS.get(ch, []):
                for (ax, ay), (bx, by) in zip(poly, poly[1:]):
                    for px, py in line_px(x + ax * xu, y + ay * yu,
                                          x + bx * xu, y + by * yu):
                        plot(px, py)
            x += ADV * xu

    def hud(s, x, y):
        for ch in s:
            rows = hud_digit(ch) if ch != " " else [0] * HUD_ROWS
            for r, bits in enumerate(rows):
                for b in range(8):
                    if bits & (0x80 >> b):
                        plot(x + b, y + r)
            x += 8

    hud("0123456789", 16, 8)
    hud("  2500", 120, 8)
    text("ABCDEFGHIJKLM", 8, 28, 1)
    text("NOPQRSTUVWXYZ", 8, 48, 1)
    text("0123456789-.:/", 8, 68, 1)
    text("STARQLIDER", 8, 96, 2)
    text("ABCDEFGHIJKLM", 8, 136, 2)
    text("NOPQRSTUVWXYZ", 8, 172, 2)
    text("0123456789", 8, 208, 2)
    png(path, [row for row in pix for _ in (0, 1)], w, 2 * h)


def main():
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("-o", "--out", help="write the tables here (LF)")
    ap.add_argument("--png", help="write a preview sheet")
    args = ap.parse_args()
    check()
    if args.png:
        preview(args.png)
    if args.out:
        with open(args.out, "w", newline="\n") as f:
            emit(f)
    elif not args.png:
        emit(sys.stdout)


if __name__ == "__main__":
    main()
