#!/usr/bin/env python3
"""
make_fixture.py — generate a polished marketing fixture image for PicStrip.

The fixture simulates a photographed "contact information" card with clearly
readable PII (email, phone, address) that Vision OCR can detect.  It also
copies the EXIF + XMP metadata blocks from an existing reference PNG so the
app's metadata-strip pipeline still shows EXIF/TIFF/IPTC badge counts.

Usage:
    python3 scripts/make_fixture.py \
        --reference PicStripUITests/test_list.png \
        --out PicStripUITests/test_list.png
"""

import argparse
import struct
import zlib
from pathlib import Path
from PIL import Image, ImageDraw, ImageFont

# ── Colours ──────────────────────────────────────────────────────────────────
BG          = (250, 248, 244)       # warm off-white, like photographed paper
CARD_BG     = (255, 255, 255)       # pure white card face
CARD_BORDER = (225, 218, 208)
ACCENT      = (0, 102, 82)          # PicStrip brand green (dark teal)
ACCENT_LITE = (224, 244, 240)
LABEL_COLOR = (130, 120, 110)       # muted warm grey for labels
TEXT_COLOR  = (30,  25,  22)        # near-black body text
RULE_COLOR  = (235, 228, 218)       # thin divider lines
HIGHLIGHT   = (255, 230, 100)       # yellow highlight to make email/phone pop


# ── Font helpers ──────────────────────────────────────────────────────────────
HELVETICA_PATH  = "/System/Library/Fonts/HelveticaNeue.ttc"
ARIAL_BOLD_PATH = "/System/Library/Fonts/Supplemental/Arial Bold.ttf"
ARIAL_PATH      = "/System/Library/Fonts/Supplemental/Arial.ttf"

def _font(path: str, size: int, fallback_path: str = ARIAL_PATH) -> ImageFont.FreeTypeFont:
    try:
        return ImageFont.truetype(path, size)
    except OSError:
        return ImageFont.truetype(fallback_path, size)

def _label_font(size: int) -> ImageFont.FreeTypeFont:
    return _font(HELVETICA_PATH, size)

def _bold_font(size: int) -> ImageFont.FreeTypeFont:
    return _font(ARIAL_BOLD_PATH, size)


# ── Drawing helpers ────────────────────────────────────────────────────────────
def _rounded_rect(
    draw: ImageDraw.ImageDraw,
    bbox: tuple,
    radius: int = 16,
    fill=None,
    outline=None,
    width: int = 1,
) -> None:
    draw.rounded_rectangle(bbox, radius=radius, fill=fill, outline=outline, width=width)


def _highlight_text(
    draw: ImageDraw.ImageDraw,
    xy: tuple,
    text: str,
    font: ImageFont.FreeTypeFont,
    highlight_color=HIGHLIGHT,
    text_color=TEXT_COLOR,
    padding: int = 6,
) -> None:
    """Draw text with a coloured highlight bar behind it (like a marker)."""
    x, y = xy
    bb = font.getbbox(text)
    tw, th = bb[2] - bb[0], bb[3] - bb[1]
    draw.rounded_rectangle(
        [x - padding, y + bb[1] - padding // 2,
         x + tw + padding, y + bb[1] + th + padding // 2],
        radius=4,
        fill=highlight_color,
    )
    draw.text(xy, text, font=font, fill=text_color)


# ── Metadata helpers ───────────────────────────────────────────────────────────
def _extract_png_chunks(data: bytes) -> list:
    """Return list of (chunk_type, chunk_data) from raw PNG bytes."""
    assert data[:8] == b'\x89PNG\r\n\x1a\n', "Not a valid PNG"
    chunks = []
    pos = 8
    while pos < len(data):
        length = struct.unpack('>I', data[pos:pos+4])[0]
        chunk_type = data[pos+4:pos+8]
        chunk_data = data[pos+8:pos+8+length]
        chunks.append((chunk_type, chunk_data))
        pos += 12 + length
    return chunks


def _build_png_chunk(chunk_type: bytes, data: bytes) -> bytes:
    crc = zlib.crc32(chunk_type + data) & 0xFFFFFFFF
    return struct.pack('>I', len(data)) + chunk_type + data + struct.pack('>I', crc)


def _inject_metadata_from_reference(new_img: Image.Image, reference_path: Path) -> Image.Image:
    """
    Copy the raw EXIF and XMP/iTXt blocks from reference_path into new_img's
    info dict so that Pillow writes them into the saved PNG.
    """
    ref = Image.open(reference_path)
    if "exif" in ref.info:
        new_img.info["exif"] = ref.info["exif"]
    if "xmp" in ref.info:
        new_img.info["xmp"] = ref.info["xmp"]
    if "XML:com.adobe.xmp" in ref.info:
        new_img.info["XML:com.adobe.xmp"] = ref.info["XML:com.adobe.xmp"]
    return new_img


def _save_png_with_metadata(img: Image.Image, out_path: Path, reference_path: Path) -> None:
    """
    Save img as PNG then inject metadata chunks from the reference file.
    Pillow 11 does not write PNG EXIF reliably for RGB images, so we do it
    at the raw-bytes level: parse both PNGs and insert the metadata chunks
    (eXIf, iTXt/tEXt for XMP) from the reference immediately after IHDR.
    """
    import io

    # 1. Save the visual content to an in-memory buffer
    buf = io.BytesIO()
    img.save(buf, format="PNG", optimize=False)
    new_png = buf.getvalue()

    # 2. Parse reference for metadata chunks we want to preserve
    ref_data = reference_path.read_bytes()
    ref_chunks = _extract_png_chunks(ref_data)
    meta_types = {b'eXIf', b'iTXt', b'tEXt', b'zTXt'}
    meta_chunks_raw = b""
    for chunk_type, chunk_data in ref_chunks:
        if chunk_type in meta_types:
            meta_chunks_raw += _build_png_chunk(chunk_type, chunk_data)

    # 3. Parse new PNG; inject metadata right after IHDR
    new_chunks = _extract_png_chunks(new_png)
    out = bytearray(b'\x89PNG\r\n\x1a\n')
    ihdr_written = False
    for chunk_type, chunk_data in new_chunks:
        out += _build_png_chunk(chunk_type, chunk_data)
        if chunk_type == b'IHDR' and not ihdr_written:
            out += meta_chunks_raw
            ihdr_written = True

    out_path.write_bytes(bytes(out))
    print(f"  Wrote {len(out):,} bytes → {out_path}")


# ── Main drawing routine ───────────────────────────────────────────────────────
def make_fixture(width: int = 1320, height: int = 2340) -> Image.Image:
    """
    Render a realistic 'contact information card' photograph.

    The image intentionally contains:
      • An email address      → triggers Email Address detection
      • A US phone number     → triggers Phone Number detection
      • A US street address   → triggers Address/Location detection

    Layout (top → bottom):
      ┌─────────────────────────────────┐
      │  [company logo bar]             │
      │  Name + title block             │
      │  ──────────────────────────     │
      │  📧 Email    [highlighted]      │
      │  📞 Phone    [highlighted]      │
      │  📍 Address  [highlighted]      │
      │  ──────────────────────────     │
      │  Meeting notes section          │
      │    Date / time / attendees      │
      │  ──────────────────────────     │
      │  To-do items                    │
      └─────────────────────────────────┘
    """
    img = Image.new("RGB", (width, height), BG)
    draw = ImageDraw.Draw(img)

    # ── Background texture: very faint dot grid ───────────────────────────────
    for gx in range(0, width, 40):
        for gy in range(0, height, 40):
            draw.ellipse([gx-1, gy-1, gx+1, gy+1], fill=(240, 235, 228))

    pad = 64  # horizontal margin

    # ── Company logo / header bar ─────────────────────────────────────────────
    header_h = 180
    _rounded_rect(draw, [pad, 80, width-pad, 80+header_h], radius=20, fill=ACCENT)
    logo_font = _bold_font(62)
    sub_font  = _label_font(34)
    draw.text((pad+44, 108), "Northwood Capital Group", font=logo_font, fill=(255,255,255))
    draw.text((pad+44, 182), "Investment · Advisory · Technology", font=sub_font, fill=(180,230,220))

    # ── Name block ────────────────────────────────────────────────────────────
    y = 310
    name_font  = _bold_font(78)
    title_font = _label_font(42)
    draw.text((pad, y), "Alexandra J. Thornton", font=name_font, fill=TEXT_COLOR)
    y += 96
    draw.text((pad, y), "Senior Director, Client Relations", font=title_font, fill=LABEL_COLOR)
    y += 70

    # ── Divider ───────────────────────────────────────────────────────────────
    draw.line([(pad, y), (width-pad, y)], fill=RULE_COLOR, width=2)
    y += 40

    # ── Contact details ───────────────────────────────────────────────────────
    icon_font   = _label_font(38)
    detail_font = _bold_font(46)
    label_font2 = _label_font(34)

    def _contact_row(icon: str, label: str, value: str, highlight: bool = False) -> int:
        nonlocal y
        # Icon + label
        draw.text((pad, y + 6), icon, font=icon_font, fill=LABEL_COLOR)
        draw.text((pad + 54, y), label, font=label_font2, fill=LABEL_COLOR)
        y += 48
        # Value (optionally highlighted)
        if highlight:
            _highlight_text(draw, (pad + 8, y), value, detail_font,
                            highlight_color=HIGHLIGHT, text_color=TEXT_COLOR)
        else:
            draw.text((pad + 8, y), value, font=detail_font, fill=TEXT_COLOR)
        y += 68
        return y

    _contact_row("✉", "EMAIL", "alex.thornton@northwoodcg.com", highlight=True)
    _contact_row("✆", "MOBILE", "(415) 555-0147", highlight=True)
    _contact_row("⌂", "OFFICE", "1 Market St, Suite 2400", highlight=True)
    draw.text((pad + 8, y), "San Francisco, CA 94105", font=detail_font, fill=TEXT_COLOR)
    y += 68

    # ── Divider ───────────────────────────────────────────────────────────────
    draw.line([(pad, y), (width-pad, y)], fill=RULE_COLOR, width=2)
    y += 50

    # ── Meeting notes section ─────────────────────────────────────────────────
    section_font = _bold_font(50)
    body_font    = _label_font(40)
    draw.text((pad, y), "Meeting Notes", font=section_font, fill=TEXT_COLOR)
    y += 68

    notes = [
        ("Date",      "Thursday, April 17, 2025 · 2:00 PM"),
        ("Location",  "Conference Rm B, 12th Floor"),
        ("Attendees", "Alex, Jordan Kim, Marcus Webb"),
    ]
    for lbl, val in notes:
        draw.text((pad, y), lbl + ":", font=label_font2, fill=LABEL_COLOR)
        draw.text((pad + 200, y), val, font=body_font, fill=TEXT_COLOR)
        y += 56

    y += 18
    draw.line([(pad, y), (width-pad, y)], fill=RULE_COLOR, width=2)
    y += 50

    # ── Action items ──────────────────────────────────────────────────────────
    draw.text((pad, y), "Action Items", font=section_font, fill=TEXT_COLOR)
    y += 68

    items = [
        "Follow up with legal re: NDA by Fri 4/18",
        "Send Q1 report deck → jordan.kim@northwoodcg.com",
        "Book travel: Chicago, IL — week of May 5",
        "Call Marcus: (312) 555-8820 re: fund allocation",
        "Update CRM contact for Alex Thornton",
    ]
    checkbox_font = _label_font(38)
    for item in items:
        # Draw an open checkbox
        cx, cy = pad + 2, y + 6
        draw.rectangle([cx, cy, cx+30, cy+30], outline=ACCENT, width=3)
        draw.text((pad + 52, y), item, font=checkbox_font, fill=TEXT_COLOR)
        y += 58

    y += 30
    draw.line([(pad, y), (width-pad, y)], fill=RULE_COLOR, width=2)
    y += 40

    # ── Footer ────────────────────────────────────────────────────────────────
    footer_font = _label_font(30)
    draw.text(
        (pad, y),
        "CONFIDENTIAL — Northwood Capital Group  ·  www.northwoodcg.com",
        font=footer_font,
        fill=(180, 170, 158),
    )

    return img


# ── Entry point ────────────────────────────────────────────────────────────────
def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--reference",
                        default="PicStripUITests/test_list.png",
                        help="Reference PNG whose EXIF/XMP blocks to copy.")
    parser.add_argument("--out",
                        default="PicStripUITests/test_list.png",
                        help="Output path for the new fixture PNG.")
    parser.add_argument("--width",  type=int, default=1320)
    parser.add_argument("--height", type=int, default=1860)  # snug fit around content
    args = parser.parse_args()

    reference = Path(args.reference)
    out       = Path(args.out)

    print(f"Generating fixture ({args.width}×{args.height}) …")
    img = make_fixture(args.width, args.height)

    print(f"Injecting metadata from {reference} …")
    _save_png_with_metadata(img, out, reference)
    print("Done.")


if __name__ == "__main__":
    main()
