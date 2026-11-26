#!/usr/bin/env python3
"""Generate 12x12 pixel-pet TrueType (.ttf) fonts for iOS Live Activity background animation.

iOS WidgetKit / Live Activity suspends host timers in the background, so pixel-art layers
encoded onto digit glyphs ('0'..'9') allow SwiftUI `Text(timerInterval:)` to drive smooth
1fps background animations natively in SpringBoard with zero battery drain.

Each pet (shiba, cat, bot) uses 3 aligned monochrome .ttf layer fonts stacked in a ZStack:
  - Shiba: VibePetShibaBody.ttf, VibePetShibaDark.ttf, VibePetShibaLight.ttf
  - Cat:   VibePetCatBody.ttf, VibePetCatEyes.ttf, VibePetCatDetail.ttf
  - Bot:   VibePetBotBody.ttf, VibePetBotScreen.ttf, VibePetBotGlow.ttf
"""

from __future__ import annotations

import argparse
import pathlib
import struct
import sys
from typing import Iterable

UNITS_PER_EM = 1200
CELL = 100  # 12 x 100 = 1200 units
ASCENT = 1200
DESCENT = 0


def _shiba_rows(frame: int) -> list[str]:
    f = frame % 10
    facing_right = frame >= 5
    blink = f in {4, 9}
    wag = (f % 4) < 2
    step = f % 2 == 1
    eye = "B" if blink else "E"
    tail6 = "..BBBBBBBB.." if wag else "...BBBBBBBO."
    tail7 = ".BOOOOOOOB.." if wag else "..OOOOOOOOB."
    ear = "..BB....BB.." if step else "..BB....BB.."
    head2 = "..BOOOOOOB.." if not step else "..BOOOOOO..."
    paw = "..C.CCCC.C.." if step else "..CC....CC.."
    rows = [
        "............",
        ear,
        head2 if facing_right and step else "..BOOOOOOB..",
        ".BOOOOOOOOB.",
        f".BOO{eye}OO{eye}OOB.",
        ".BOCECCCOOB.",
        tail6,
        tail7,
        "..OOCCCCOO..",
        "..OOOOOOOO..",
        paw,
        "............",
    ]
    if facing_right:
        return [r[::-1] for r in rows]
    return rows


def _cat_rows(frame: int) -> list[str]:
    f = frame % 10
    facing_right = frame >= 5
    blink = f in {4, 9}
    tail_up = (f % 2) == 0
    step = (f % 2) == 1
    eye = "K" if blink else "E"
    tail_a = "KKKKKKKKKK.K" if tail_up else "KKKKKKKKKK.."
    tail_b = ".KDDDDDDK.K." if tail_up else ".KDDDDDDKKK."
    paw = "..W.KKKK.W.." if step else "..KK....WW.."
    rows = [
        "............",
        "..KP....PK..",
        "..KKKKKKKK..",
        ".KKKKKKKKKK.",
        f".KK{eye}KKKK{eye}KK.",
        ".KKKKPPKKKK.",
        tail_a,
        tail_b,
        "..KKKKKKKK..",
        "..KKKKKKKK..",
        paw,
        "............",
    ]
    if facing_right:
        return [r[::-1] for r in rows]
    return rows


def _bot_rows(frame: int) -> list[str]:
    f = frame % 10
    facing_right = frame >= 5
    blink = f in {4, 9}
    ant_alt = (f % 2) == 0
    step = (f % 2) == 1
    visor = "S" if blink else "C"
    ant = ".....AA....." if ant_alt else ".....MM....."
    foot = "..M......M.." if step else "...MM..MM..."
    chest = "..MAACCAMM.." if step else "..MMCCCCMM.."
    rows = [
        ant,
        ".....MM.....",
        "..LLLLLLLL..",
        ".LMMMMMMMMM.",
        ".LMSSSSSSSM.",
        f".LMS{visor}SSS{visor}SM.",
        ".LMSSSSSSSM.",
        "..LLLLLLLL..",
        "..MMMMMMMM..",
        chest,
        foot,
        "............",
    ]
    if facing_right:
        return [r[::-1] for r in rows]
    return rows


PET_LAYERS: list[tuple[str, str, set[str], callable]] = [
    ("VibePetShibaBody", "VibePetShibaBody.ttf", {"O"}, _shiba_rows),
    ("VibePetShibaDark", "VibePetShibaDark.ttf", {"B", "E"}, _shiba_rows),
    ("VibePetShibaLight", "VibePetShibaLight.ttf", {"C"}, _shiba_rows),
    ("VibePetCatBody", "VibePetCatBody.ttf", {"K", "D"}, _cat_rows),
    ("VibePetCatEyes", "VibePetCatEyes.ttf", {"E"}, _cat_rows),
    ("VibePetCatDetail", "VibePetCatDetail.ttf", {"P", "W"}, _cat_rows),
    ("VibePetBotBody", "VibePetBotBody.ttf", {"L", "M"}, _bot_rows),
    ("VibePetBotScreen", "VibePetBotScreen.ttf", {"S"}, _bot_rows),
    ("VibePetBotGlow", "VibePetBotGlow.ttf", {"C", "A"}, _bot_rows),
]


def _rows_to_rects(rows: list[str], chars: set[str], y_shift_cells: float = 0.0) -> list[tuple[int, int, int, int]]:
    """Convert selected pixel characters in a 12x12 grid into TrueType (x0, y0, x1, y1) rectangles."""
    rects: list[tuple[int, int, int, int]] = []
    dy = int(round(y_shift_cells * CELL))
    for r_idx, row in enumerate(rows[:12]):
        y1 = ASCENT - r_idx * CELL + dy
        y0 = y1 - CELL
        y0 = max(0, min(ASCENT, y0))
        y1 = max(0, min(ASCENT, y1))
        if y1 <= y0:
            continue
        c = 0
        line = row[:12]
        while c < len(line):
            if line[c] in chars:
                start = c
                while c < len(line) and line[c] in chars:
                    c += 1
                rects.append((start * CELL, y0, c * CELL, y1))
            else:
                c += 1
    return rects


def _encode_glyf_rects(rects: list[tuple[int, int, int, int]]) -> tuple[bytes, int, int, int]:
    """Encode a list of axis-aligned rectangles into one TrueType simple glyph record.

    Returns (padded_glyph_bytes, point_count, contour_count, xMin).
    """
    if not rects:
        return b"", 0, 0, 0

    x_min = min(r[0] for r in rects)
    y_min = min(r[1] for r in rects)
    x_max = max(r[2] for r in rects)
    y_max = max(r[3] for r in rects)
    n_contours = len(rects)

    header = struct.pack(">hhhhh", n_contours, x_min, y_min, x_max, y_max)
    end_pts = struct.pack(f">{n_contours}H", *[4 * (i + 1) - 1 for i in range(n_contours)])
    instr_len = struct.pack(">H", 0)

    n_pts = 4 * n_contours
    # flag 0x01 = onCurve, 16-bit signed X/Y deltas
    flags = bytes([0x01] * n_pts)

    xs: list[int] = []
    ys: list[int] = []
    prev_x = 0
    prev_y = 0
    for rx0, ry0, rx1, ry1 in rects:
        # Clockwise outer contour in Y-up coordinate space: (x0,y0) -> (x0,y1) -> (x1,y1) -> (x1,y0)
        for px, py in ((rx0, ry0), (rx0, ry1), (rx1, ry1), (rx1, ry0)):
            xs.append(px - prev_x)
            ys.append(py - prev_y)
            prev_x, prev_y = px, py

    x_bytes = struct.pack(f">{n_pts}h", *xs)
    y_bytes = struct.pack(f">{n_pts}h", *ys)
    raw = header + end_pts + instr_len + flags + x_bytes + y_bytes
    pad = (-len(raw)) % 4
    return raw + (b"\x00" * pad), n_pts, n_contours, x_min


def _build_cmap(mapping: dict[int, int]) -> bytes:
    """Build a valid Windows BMP + Unicode cmap table (format 4)."""
    # Group contiguous codepoints whose (code + delta) keeps GID contiguous
    items = sorted(mapping.items())
    segments: list[tuple[int, int, int]] = []
    for cp, gid in items:
        if segments:
            prev_start, prev_end, prev_delta = segments[-1]
            if cp == prev_end + 1 and ((cp + prev_delta) & 0xFFFF) == gid:
                segments[-1] = (prev_start, cp, prev_delta)
                continue
        segments.append((cp, cp, (gid - cp) & 0xFFFF))
    segments.append((0xFFFF, 0xFFFF, 1))

    seg_count = len(segments)
    seg_count_x2 = seg_count * 2
    search_range = 2 * (1 << (seg_count.bit_length() - 1))
    entry_selector = search_range.bit_length() - 1
    range_shift = seg_count_x2 - search_range

    end_codes = struct.pack(f">{seg_count}H", *[s[1] for s in segments])
    start_codes = struct.pack(f">{seg_count}H", *[s[0] for s in segments])
    id_deltas = struct.pack(f">{seg_count}H", *[s[2] for s in segments])
    id_range_offsets = struct.pack(f">{seg_count}H", *([0] * seg_count))

    sub_len = 16 + seg_count * 8
    subtable = (
        struct.pack(">HHHHHHH", 4, sub_len, 0, seg_count_x2, search_range, entry_selector, range_shift)
        + end_codes
        + struct.pack(">H", 0)  # reservedPad
        + start_codes
        + id_deltas
        + id_range_offsets
    )

    # Header with 2 encoding records (Platform 0 Unicode BMP + Platform 3 Windows Unicode BMP)
    header = struct.pack(">HH", 0, 2)
    sub_offset = 4 + 2 * 8
    rec0 = struct.pack(">HHI", 0, 3, sub_offset)
    rec1 = struct.pack(">HHI", 3, 1, sub_offset)
    return header + rec0 + rec1 + subtable


def _build_name_table(ps_name: str) -> bytes:
    records_spec = [
        (1, ps_name),
        (2, "Regular"),
        (3, f"VibeHelper-{ps_name}-1.0"),
        (4, ps_name),
        (5, "Version 1.0"),
        (6, ps_name),
    ]
    entries: list[tuple[int, int, int, int, bytes]] = []
    # Platform 1 (Mac Roman) + Platform 3 (Windows Unicode BMP)
    for name_id, text in records_spec:
        entries.append((1, 0, 0, name_id, text.encode("ascii", "replace")))
    for name_id, text in records_spec:
        entries.append((3, 1, 0x0409, name_id, text.encode("utf-16-be")))

    entries.sort(key=lambda e: (e[0], e[1], e[2], e[3]))
    count = len(entries)
    str_offset = 6 + count * 12
    storage = bytearray()
    recs = bytearray()
    for pid, eid, lid, nid, data in entries:
        recs.extend(struct.pack(">HHHHHH", pid, eid, lid, nid, len(data), len(storage)))
        storage.extend(data)
    return struct.pack(">HHH", 0, count, str_offset) + bytes(recs) + bytes(storage)


def _table_checksum(data: bytes) -> int:
    padded = data + (b"\x00" * ((-len(data)) % 4))
    words = struct.unpack(f">{len(padded) // 4}I", padded)
    return sum(words) & 0xFFFFFFFF


def build_ttf(ps_name: str, active_chars: set[str], row_fn: callable) -> bytes:
    """Assemble a complete TrueType (.ttf) font binary in memory."""
    # gid 0 = .notdef, gid 1 = zero-width separator, gid 2..11 = digits '0'..'9'
    glyphs: list[tuple[bytes, int, int, int, int]] = []  # (glyf_bytes, pts, contours, xMin, advWidth)
    glyphs.append((b"", 0, 0, 0, UNITS_PER_EM))  # gid 0: .notdef
    glyphs.append((b"", 0, 0, 0, 0))  # gid 1: zero-width separator (':', '.', '-', space)

    all_xmin, all_ymin, all_xmax, all_ymax = 0, 0, UNITS_PER_EM, ASCENT
    for frame in range(10):
        y_shift = -0.45 if (frame % 2 == 1 and ("C" in active_chars or "A" in active_chars or "E" in active_chars)) else 0.0
        rects = _rows_to_rects(row_fn(frame), active_chars, y_shift_cells=y_shift)
        # Fallback tiny pixel if one layer happens to have 0 pixels in a blink frame so bounding boxes stay consistent
        gbytes, pts, cnts, xmin = _encode_glyf_rects(rects)
        glyphs.append((gbytes, pts, cnts, xmin, UNITS_PER_EM))

    num_glyphs = len(glyphs)
    max_pts = max((g[1] for g in glyphs), default=0)
    max_contours = max((g[2] for g in glyphs), default=0)

    glyf_buf = bytearray()
    loca_offsets: list[int] = []
    hmtx_buf = bytearray()
    for gbytes, _pts, _cnts, xmin, adv_w in glyphs:
        loca_offsets.append(len(glyf_buf))
        glyf_buf.extend(gbytes)
        hmtx_buf.extend(struct.pack(">Hh", adv_w, xmin))
    loca_offsets.append(len(glyf_buf))
    if not glyf_buf:
        glyf_buf.extend(b"\x00\x00\x00\x00")

    loca_table = struct.pack(f">{len(loca_offsets)}I", *loca_offsets)
    glyf_table = bytes(glyf_buf)
    hmtx_table = bytes(hmtx_buf)

    cmap_map: dict[int, int] = {
        0x0020: 1,  # space
        0x002C: 1,  # comma
        0x002D: 1,  # hyphen
        0x002E: 1,  # period
        0x003A: 1,  # colon
        0x00A0: 1,  # nbsp
        0x2009: 1,  # thin space
        0x202F: 1,  # narrow nbsp
    }
    for d in range(10):
        cmap_map[0x0030 + d] = 2 + d
    cmap_table = _build_cmap(cmap_map)

    # head (54 bytes); checkSumAdjustment at offset 8 filled after assembly
    head_table = bytearray(
        struct.pack(
            ">IIIIHHQQhhhhHHhhh",
            0x00010000,
            0x00010000,
            0,
            0x5F0F3CF5,
            0x000B,
            UNITS_PER_EM,
            3800000000,
            3800000000,
            all_xmin,
            all_ymin,
            all_xmax,
            all_ymax,
            0,
            8,
            2,
            1,  # indexToLocFormat = 1 (long 32-bit offsets)
            0,  # glyphDataFormat
        )
    )
    assert len(head_table) == 54

    hhea_table = struct.pack(
        ">IhhhHhhhhhhhhhhhH",
        0x00010000,
        ASCENT,
        DESCENT,
        0,  # lineGap
        UNITS_PER_EM,  # advanceWidthMax
        0,  # minLeftSideBearing
        0,  # minRightSideBearing
        UNITS_PER_EM,  # xMaxExtent
        1,  # caretSlopeRise
        0,  # caretSlopeRun
        0,  # caretOffset
        0,
        0,
        0,
        0,  # reserved
        0,  # metricDataFormat
        num_glyphs,
    )
    assert len(hhea_table) == 36

    maxp_table = struct.pack(
        ">IHHHHHHHHHHHHHH",
        0x00010000,
        num_glyphs,
        max_pts,
        max_contours,
        0,
        0,
        2,
        0,
        0,
        0,
        0,
        0,
        0,
        0,
        0,
    )
    assert len(maxp_table) == 32

    os2_table = struct.pack(
        ">HhHHHhhhhhhhhhhh10sIIII4sHHHhhhHHIIhhHHH",
        4,  # version 4
        UNITS_PER_EM,  # xAvgCharWidth
        400,  # usWeightClass
        5,  # usWidthClass
        0,  # fsType (installable)
        600,
        600,
        0,
        0,  # ySubscript
        600,
        600,
        0,
        600,  # ySuperscript
        100,
        500,
        0,  # yStrikeout + sFamilyClass
        b"\x02\x0b\x06\x09\x02\x02\x04\x03\x02\x04",  # panose monospace
        0x00000001,  # ulUnicodeRange1 (Basic Latin)
        0,
        0,
        0,
        b"VIBE",  # achVendID
        0x0040,  # fsSelection (REGULAR)
        0x0020,  # usFirstCharIndex
        0x003A,  # usLastCharIndex
        ASCENT,  # sTypoAscender
        DESCENT,  # sTypoDescender
        0,  # sTypoLineGap
        ASCENT,  # usWinAscent
        0,  # usWinDescent
        1,  # ulCodePageRange1
        0,  # ulCodePageRange2
        700,  # sxHeight
        ASCENT,  # sCapHeight
        0x0020,  # usDefaultChar
        0x0020,  # usBreakChar
        1,  # usMaxContext
    )
    assert len(os2_table) == 96

    name_table = _build_name_table(ps_name)
    post_table = struct.pack(">IihhIIIII", 0x00030000, 0, -100, 100, 1, 0, 0, 0, 0)
    assert len(post_table) == 32

    tables: dict[str, bytes] = {
        "OS/2": os2_table,
        "cmap": cmap_table,
        "glyf": glyf_table,
        "head": bytes(head_table),
        "hhea": hhea_table,
        "hmtx": hmtx_table,
        "loca": loca_table,
        "maxp": maxp_table,
        "name": name_table,
        "post": post_table,
    }
    ordered_tags = sorted(tables.keys())
    num_tables = len(ordered_tags)
    max_pow2 = 1 << (num_tables.bit_length() - 1)
    search_range = max_pow2 * 16
    entry_selector = max_pow2.bit_length() - 1
    range_shift = num_tables * 16 - search_range

    sfnt_header = struct.pack(">IHHHH", 0x00010000, num_tables, search_range, entry_selector, range_shift)
    dir_size = 12 + num_tables * 16
    offset = dir_size
    directory = bytearray()
    body = bytearray()
    head_offset = 0
    for tag in ordered_tags:
        raw = tables[tag]
        if tag == "head":
            head_offset = offset
        checksum = _table_checksum(raw)
        directory.extend(struct.pack(">4sIII", tag.encode("ascii"), checksum, offset, len(raw)))
        padded = raw + (b"\x00" * ((-len(raw)) % 4))
        body.extend(padded)
        offset += len(padded)

    full = bytearray(sfnt_header + bytes(directory) + bytes(body))
    file_sum = _table_checksum(bytes(full))
    adj = (0xB1B0AFBA - file_sum) & 0xFFFFFFFF
    struct.pack_into(">I", full, head_offset + 8, adj)
    return bytes(full)


def verify_fonts(out_dir: pathlib.Path) -> list[str]:
    """Load generated TTF files with PIL.ImageFont and assert digits 0..9 render and ':' has 0 width."""
    from PIL import Image, ImageDraw, ImageFont

    checked: list[str] = []
    for ps_name, filename, _, _ in PET_LAYERS:
        font_path = out_dir / filename
        if not font_path.is_file():
            raise FileNotFoundError(f"Missing generated font: {font_path}")
        font = ImageFont.truetype(str(font_path), 48)
        colon_len = font.getlength(":")
        if colon_len > 0.01:
            raise AssertionError(f"{filename}: expected ':' width 0, got {colon_len}")

        seen_hashes: set[bytes] = set()
        for digit in "0123456789":
            w = font.getlength(digit)
            if abs(w - 48.0) > 1.0:
                raise AssertionError(f"{filename}: expected '{digit}' width ~48, got {w}")
            img = Image.new("L", (48, 48), 0)
            draw = ImageDraw.Draw(img)
            draw.text((0, 0), digit, fill=255, font=font)
            raw = img.tobytes()
            is_cat_blink = ps_name == "VibePetCatEyes" and digit in {"4", "9"}
            if not is_cat_blink and max(raw) == 0:
                raise AssertionError(f"{filename}: digit '{digit}' rendered empty bitmap")
            seen_hashes.add(raw)
        if len(seen_hashes) < 2:
            raise AssertionError(f"{filename}: frames 0..9 look identical")
        checked.append(ps_name)
    return checked


def main(argv: Iterable[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description="Generate iOS Live Activity pixel-pet TTF fonts")
    parser.add_argument(
        "--out-dir",
        type=pathlib.Path,
        default=pathlib.Path(__file__).resolve().parent.parent
        / "client-app"
        / "assets"
        / "ios_live_activity"
        / "fonts",
    )
    parser.add_argument("--verify", action="store_true", help="Verify generated fonts with Pillow")
    args = parser.parse_args(list(argv) if argv is not None else None)

    args.out_dir.mkdir(parents=True, exist_ok=True)
    for ps_name, filename, chars, row_fn in PET_LAYERS:
        ttf_bytes = build_ttf(ps_name, chars, row_fn)
        (args.out_dir / filename).write_bytes(ttf_bytes)
        print(f"Generated {filename} ({len(ttf_bytes)} bytes)")

    if args.verify:
        checked = verify_fonts(args.out_dir)
        print(f"Verified {len(checked)} TTF fonts with Pillow FreeType: {', '.join(checked)}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
