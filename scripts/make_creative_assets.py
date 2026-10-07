#!/usr/bin/env python3
"""Render PicStrip's App Store universal creative asset.

iOS and iPadOS 27 show one 16:9 picture in two places: cropped wide as the
product page header and cropped to 3:2 for the search results.  This script
draws that picture for every store locale, plus a copy with no words at all.

The idea is the 1.7 story in one frame: the street video from the store
screenshots, open in PicStrip's video editor.  One walker's face is blurred,
the other wears a 😎, the phone number on the lost-cat flyer is blacked out,
a slim timeline with a red "Bleep" clip sits under the frame, and the photo's
hidden location, device and date lift off the card and fade away.  The
headline is line 1 of the ``01_VideoEditor`` screenshot headline, with line 1
of ``02_Location`` under it, so the asset says what the screenshots say.

Everything is drawn in code at full size: the street, the walkers and the
flyer come from ``make_store_fixtures.py`` (scaled up rather than taken from a
phone screenshot), and the fonts, headline catalog and Arabic handling from
``process_screenshots.py``.

Safe area.  The canvas is 5244 × 2950.  The header crop keeps the full width
and loses about 351 px at the top and bottom; the search crop keeps the full
height and loses about 410 px at each side.  Exact crops vary by device and
the App Store draws the icon, name and Get button over the bottom of the
header, so the words and the faces stay inside x 700–4544, y 500–2200, and
only the timeline and background reach lower.

Outputs (in ``~/Desktop/PicStrip Creative Assets/`` unless ``--out`` is given):

* ``PicStrip-universal-<store locale>.png`` for the 17 store locales and
  ``PicStrip-universal-textless.png`` — 5244 × 2950 sRGB PNGs, no alpha.
* ``previews/`` — the header and search crops for a few locales and a
  montage of every locale, for review only (not for upload).

Usage (needs Pillow with libraqm, and the NumPy and qrcode that
``make_store_fixtures.py`` imports)::

    python3 -m venv build/creative-venv
    build/creative-venv/bin/pip install pillow numpy "qrcode[pil]"
    build/creative-venv/bin/python scripts/make_creative_assets.py
    build/creative-venv/bin/python scripts/make_creative_assets.py --locale en-US --locale ar-SA
"""

from __future__ import annotations

import argparse
import json
import math
import random
import sys
from pathlib import Path

import numpy as np
from PIL import Image, ImageCms, ImageDraw, ImageFilter, ImageFont, features

SCRIPTS = Path(__file__).resolve().parent
ROOT = SCRIPTS.parent
sys.path.insert(0, str(SCRIPTS))

import make_store_fixtures as fixtures  # noqa: E402  (the street, the walkers, the flyer)
import process_screenshots as shots  # noqa: E402  (palette, headline catalog, font fallbacks)

OUT = Path.home() / "Desktop" / "PicStrip Creative Assets"
HEADLINES = ROOT / "fastlane" / "MarketingHeadlines.xcstrings"
APP_STRINGS = ROOT / "PicStrip" / "Localizable.xcstrings"
APP_ICON = ROOT / "docs" / "icons" / "PicStrip Exports" / "PicStrip-iOS-Default-1024x1024@1x.png"

# ── Canvas and crops ───────────────────────────────────────────────────────
CANVAS = (5244, 2950)
HEADER_CROP = (3840, 1646)   # wide product page header (scale to 3840 wide)
SEARCH_CROP = (3840, 2560)   # search results (scale to 2560 high)
SAFE = (700, 500, 4544, 2450)  # inside both crops, whatever the device
WORDS_BOTTOM = 2200            # the header's icon / name / Get row may cover what is lower

# Store locale → catalog code in the .xcstrings files.
STORE_LOCALES: dict[str, str] = {
    "ar-SA": "ar", "de-DE": "de", "en-US": "en", "es-ES": "es", "es-MX": "es-419",
    "fr-FR": "fr", "it": "it", "ja": "ja", "ko": "ko", "nl-NL": "nl", "pl": "pl",
    "pt-BR": "pt-BR", "pt-PT": "pt-PT", "sv": "sv", "tr": "tr",
    "zh-Hans": "zh-Hans", "zh-Hant": "zh-Hant",
}
RTL_LOCALES = {"ar-SA"}

# What a phone writes into a photo (the same values as the café fixture's
# EXIF): where, on what, and when — the date written the way each locale
# writes it, in digits so every chip renders in SF Pro.
CHIP_LOCATION = "37.7596° N, 122.4269° W"
CHIP_DEVICE = "iPhone 17 Pro"
CHIP_DATE: dict[str, str] = {
    "ar-SA": "19/09/2026 10:42", "de-DE": "19.09.2026, 10:42", "en-US": "9/19/2026, 10:42 AM",
    "es-ES": "19/9/2026, 10:42", "es-MX": "19/9/2026, 10:42", "fr-FR": "19/09/2026 10:42",
    "it": "19/9/2026, 10:42", "ja": "2026/09/19 10:42", "ko": "2026. 9. 19. 10:42",
    "nl-NL": "19-09-2026 10:42", "pl": "19.09.2026, 10:42", "pt-BR": "19/09/2026, 10:42",
    "pt-PT": "19/09/2026, 10:42", "sv": "2026-09-19 10:42", "tr": "19.09.2026 10:42",
    "zh-Hans": "2026/9/19 10:42", "zh-Hant": "2026/9/19 10:42",
}

# ── Palette ────────────────────────────────────────────────────────────────
# The screenshots' teal gradient, run corner to corner, with the screenshots'
# mint highlight as a glow behind the card.
BG_LIGHT = (38, 130, 98)
BG_DARK = (7, 46, 35)
GLOW = shots.HIGHLIGHT_COLOR
WHITE = (255, 255, 255)
SUBHEAD = (198, 240, 220)          # pale mint: secondary to the white headline
CARD = (255, 255, 255)
LANE = (242, 242, 247)             # iOS secondarySystemBackground
LANE_INK = (178, 178, 186)
SYSTEM_RED = (255, 59, 48)
CLIP_RED = (252, 66, 66)
HANDLE_YELLOW = (255, 204, 0)
CHIP_INK = (28, 28, 30)
CHIP_COLORS = {"location": (255, 59, 48), "device": (0, 122, 255), "date": (255, 149, 0)}

# ── Layout (left-to-right; right-to-left mirrors it) ───────────────────────
TEXT_BOX = (740, 2380)             # x range of the words
CARD_W = 1960
CARD_RIGHT = 4480
CARD_TOP = 800
CARD_PAD = 34
CARD_RADIUS = 76
VIDEO_RADIUS = CARD_RADIUS - CARD_PAD
FILM_H = 128
AUDIO_H = 104
LANE_GAP = 22
TIMELINE_GAP = 46
CARD_BOTTOM_PAD = 38
PLAYHEAD_T = 0.667                 # 0:04 of the six-second clip, as in the screenshot

HEADLINE_MAX = 300                 # px; CJK and Hangul run 0.86× (denser glyphs)
HEADLINE_MIN = 170
HEADLINE_THREE_LINES = 250        # cap when a headline needs three lines
SUBHEAD_MAX = 150
SUBHEAD_MIN = 112
ICON_SIZE = 170
BRAND_NAME_SIZE = 112

SS = 2                             # supersampling for drawn shapes (PIL draws without anti-aliasing)


# ── Small helpers ──────────────────────────────────────────────────────────
def sf(size: int, weight: int = 700) -> ImageFont.FreeTypeFont:
    """SF Pro at ``size`` px.  Display sizes get the display optical size (tighter spacing)."""
    face = ImageFont.truetype("/System/Library/Fonts/SFNS.ttf", size)
    try:
        # Axes, in the font's order: width, optical size, GRAD, weight.
        face.set_variation_by_axes([100, max(17, min(96, size)), 400, weight])
    except (OSError, ValueError):
        face = shots._find_font(size)
    return face


def script_of(text: str) -> str:
    """'ko', 'ja', 'zh', 'ar' or 'latin' — which font family ``text`` needs."""
    has_kana = any(0x3040 <= ord(c) <= 0x30FF for c in text)
    candidates = shots._font_candidates_for_text(text)
    if candidates is shots._FONT_CANDIDATES_KOREAN:
        return "ko"
    if candidates is shots._FONT_CANDIDATES_CJK:
        return "ja" if has_kana else "zh"
    if candidates is shots._FONT_CANDIDATES_ARABIC:
        return "ar"
    return "latin"


def display_font(text: str, size: int, bold: bool = True) -> ImageFont.FreeTypeFont:
    """The iOS system font for ``text``'s script, falling back to the screenshot compositor's lists."""
    script = script_of(text)
    try:
        if script == "latin":
            return sf(size, 700 if bold else 600)
        if script == "ja":  # Hiragino Sans, the Japanese system font
            path = "/System/Library/Fonts/ヒラギノ角ゴシック W7.ttc" if bold else "/System/Library/Fonts/ヒラギノ角ゴシック W6.ttc"
            return ImageFont.truetype(path, size, index=0)
        if script == "zh":  # Hiragino Sans GB W6, as in the screenshots
            return ImageFont.truetype("/System/Library/Fonts/Hiragino Sans GB.ttc", size, index=2)
        if script == "ko":  # Apple SD Gothic Neo Bold / SemiBold
            return ImageFont.truetype("/System/Library/Fonts/AppleSDGothicNeo.ttc", size, index=6 if bold else 4)
        if script == "ar":  # SF Arabic, the Arabic system font
            face = ImageFont.truetype("/System/Library/Fonts/SFArabic.ttf", size)
            face.set_variation_by_name("Bold" if bold else "Semibold")
            return face
    except (OSError, ValueError):
        pass
    return shots._find_font(size, shots._font_candidates_for_text(text))


def _render_probe(face: ImageFont.FreeTypeFont, ch: str) -> bytes:
    probe = Image.new("L", (int(face.size * 2), int(face.size * 2)), 0)
    ImageDraw.Draw(probe).text((face.size // 4, face.size // 4), ch, font=face, fill=255)
    return probe.tobytes()


def assert_no_tofu(text: str, face: ImageFont.FreeTypeFont) -> None:
    """Fail loudly if any character of ``text`` would draw as the font's missing-glyph box."""
    small = face.font_variant(size=48)
    missing = {_render_probe(small, "\U0010FFFD"), _render_probe(small, "\uFFFF")}
    bad = sorted({ch for ch in text if not ch.isspace() and _render_probe(small, ch) in missing})
    if bad:
        raise SystemExit(f"{face.getname()} has no glyph for {bad!r} in {text!r}")


def shaped(text: str) -> str:
    """Arabic joined and reordered when Pillow lacks libraqm (with raqm this is a no-op)."""
    return shots._shape_for_display(text, shots._font_candidates_for_text(text))


def text_width(face: ImageFont.FreeTypeFont, text: str) -> float:
    return face.getlength(text)


def rounded_mask(size: tuple[int, int], radius: float, ss: int = 4) -> Image.Image:
    """An anti-aliased rounded-rectangle mask."""
    w, h = size
    big = Image.new("L", (w * ss, h * ss), 0)
    ImageDraw.Draw(big).rounded_rectangle([0, 0, w * ss - 1, h * ss - 1], radius=radius * ss, fill=255)
    return big.resize(size, Image.LANCZOS)


def drop_shadow(canvas: Image.Image, alpha: Image.Image, origin: tuple[int, int], *,
                blur: float, opacity: float, offset: tuple[int, int] = (0, 0),
                color: tuple = (2, 26, 19)) -> None:
    """Composite a soft shadow of ``alpha`` (placed at ``origin``) onto ``canvas``, blurring only the patch it covers."""
    pad = int(blur * 3) + max(abs(offset[0]), abs(offset[1]))
    w, h = alpha.size
    patch = Image.new("L", (w + 2 * pad, h + 2 * pad), 0)
    patch.paste(alpha.point(lambda v: int(v * opacity)), (pad, pad))
    patch = patch.filter(ImageFilter.GaussianBlur(blur))
    x, y = origin[0] - pad + offset[0], origin[1] - pad + offset[1]
    layer = Image.new("RGBA", patch.size, color + (0,))
    layer.putalpha(patch)
    shots._alpha_composite_clipped(canvas, layer, (x, y))


# ── The street, drawn at any size ──────────────────────────────────────────
GEORGIA_BOLD = fixtures.FONT_DIR / "Supplemental" / "Georgia Bold.ttf"
FLYER_NUMBER = "415-555-0172"


def street_scene(width: int, t: float = PLAYHEAD_T) -> tuple[Image.Image, dict[str, tuple[float, float, float, float]]]:
    """The ``store_street.mov`` frame at time ``t`` (0–1), ``width`` px wide.

    This is ``make_store_fixtures.street_background`` and ``street_frames``
    with every length multiplied by ``k`` (the fixture is drawn 1280 wide), so
    the picture matches the screenshots but is drawn sharp at poster size.
    Returns the frame and the boxes PicStrip covers: each walker's face and the
    flyer's phone number.
    """
    k = width / 1280
    W, H = width, round(width * 9 / 16)

    def s(v: float) -> float:
        return v * k

    img = fixtures.vertical_gradient((W, H), (170, 206, 232), (214, 230, 238))
    d = ImageDraw.Draw(img)
    # Buildings across the back: brick, cream (the bakery), slate.
    d.rectangle([0, s(40), W * 0.46, H * 0.70], fill=(196, 120, 92))
    d.rectangle([W * 0.46, s(10), W * 0.78, H * 0.70], fill=(232, 220, 196))
    d.rectangle([W * 0.78, s(70), W, H * 0.70], fill=(110, 134, 150))
    d.rectangle([W * 0.48, H * 0.30, W * 0.76, H * 0.70], fill=(60, 52, 48))
    d.rectangle([W * 0.495, H * 0.33, W * 0.745, H * 0.68], fill=(214, 176, 120))
    d.text((W * 0.62, H * 0.24), "GOLDEN CRUMB", font=fixtures.font(GEORGIA_BOLD, round(s(34))),
           fill=(120, 70, 40), anchor="mm")
    for i in range(8):  # striped awning
        x0 = W * 0.47 + i * (W * 0.30 / 8)
        d.polygon([(x0, H * 0.27), (x0 + W * 0.30 / 8, H * 0.27), (x0 + W * 0.30 / 8 + s(6), H * 0.33), (x0 + s(6), H * 0.33)],
                  fill=(200, 64, 52) if i % 2 == 0 else (248, 240, 228))
    for row in range(3):  # windows
        for col in range(4):
            x, y = s(30 + col * 140), s(70 + row * 110)
            d.rectangle([x, y, x + s(90), y + s(80)], fill=(150, 186, 210))
            d.rectangle([x, y + s(80), x + s(90), y + s(88)], fill=(236, 226, 214))
        for col in range(2):
            x, y = W * 0.80 + s(col * 120), s(100 + row * 110)
            d.rectangle([x, y, x + s(80), y + s(76)], fill=(196, 216, 230))
    # Tree on the left, behind the lamppost.
    d.rectangle([W * 0.045, H * 0.30, W * 0.06, H * 0.80], fill=(96, 72, 54))
    rng = random.Random(5)
    for _ in range(40):
        r = s(rng.uniform(40, 80))
        x = W * 0.05 + s(rng.uniform(-110, 110))
        y = H * 0.20 + s(rng.uniform(-110, 70))
        d.ellipse([x - r, y - r, x + r, y + r], fill=rng.choice([(70, 132, 70), (92, 154, 84), (56, 112, 62)]))
    # Pavement and kerb.
    d.rectangle([0, H * 0.70, W, H], fill=(196, 192, 186))
    d.rectangle([0, H * 0.70, W, H * 0.72], fill=(170, 166, 160))
    # Parked car on the right, behind the walkers.
    car_y, cx0 = H * 0.70, W * 0.70
    blue, glass = (52, 110, 160), (190, 216, 232)
    d.rounded_rectangle([cx0, car_y - s(120), cx0 + s(360), car_y - s(30)], radius=s(30), fill=blue)
    d.polygon([(cx0 + s(60), car_y - s(120)), (cx0 + s(110), car_y - s(185)), (cx0 + s(260), car_y - s(185)), (cx0 + s(320), car_y - s(120))], fill=blue)
    d.polygon([(cx0 + s(80), car_y - s(122)), (cx0 + s(120), car_y - s(172)), (cx0 + s(180), car_y - s(172)), (cx0 + s(180), car_y - s(122))], fill=glass)
    d.polygon([(cx0 + s(192), car_y - s(122)), (cx0 + s(192), car_y - s(172)), (cx0 + s(252), car_y - s(172)), (cx0 + s(300), car_y - s(122))], fill=glass)
    for wx in (cx0 + s(80), cx0 + s(290)):
        d.ellipse([wx - s(38), car_y - s(70), wx + s(38), car_y + s(6)], fill=(34, 34, 38))
        d.ellipse([wx - s(18), car_y - s(50), wx + s(18), car_y - s(14)], fill=(170, 170, 176))
    # Lamppost with the lost-cat flyer.
    lx = W * 0.20
    d.rectangle([lx - s(7), H * 0.08, lx + s(7), H * 0.80], fill=(46, 52, 58))
    d.ellipse([lx - s(28), H * 0.05, lx + s(28), H * 0.12], fill=(46, 52, 58))
    flyer_lines = [
        ("LOST CAT", fixtures.avenir(round(s(34)), "heavy"), (200, 60, 50)),
        ("Grey tabby, \"Miso\"", fixtures.avenir(round(s(18)), "demi"), (60, 50, 44)),
        ("", fixtures.avenir(round(s(12))), (0, 0, 0)),
        ("Please call", fixtures.avenir(round(s(18)), "medium"), (60, 50, 44)),
        ("", fixtures.avenir(round(s(10))), (0, 0, 0)),
        (FLYER_NUMBER, fixtures.avenir(round(s(24)), "bold"), (30, 26, 24)),
    ]
    fw, fh = round(s(210)), round(s(240))
    flyer = fixtures.paper_poster((fw, fh), flyer_lines, accent=(200, 60, 50))
    fx, fy = int(lx - s(105)), int(H * 0.29)
    img.paste(flyer, (fx, fy), flyer)
    # Where paper_poster put the number: it advances 1.28 × size per line, 0.6 × size per gap.
    y = fh * 0.12
    for text, face, _ in flyer_lines[:-1]:
        y += face.size * (1.28 if text else 0.6)
    nb = ImageDraw.Draw(flyer).textbbox((fw / 2, y), FLYER_NUMBER, font=flyer_lines[-1][1], anchor="ma")
    boxes = {"number": (fx + nb[0], fy + nb[1], fx + nb[2], fy + nb[3])}
    img = img.filter(ImageFilter.GaussianBlur(1.2 * k))

    # The two walkers, where street_frames has them at time t.
    walkers = [
        ("emoji", dict(skin=fixtures.SKIN["deep"], hair=(30, 22, 18), shirt=(240, 196, 76), hair_style="curly",
                       collar="crew", length=4.0), (0.56, 0.40), (0.40, 0.42)),
        ("blur", dict(skin=fixtures.SKIN["light"], hair=(200, 160, 100), shirt=(64, 130, 120), hair_style="bob",
                      collar="v", jacket=(150, 80, 70), length=4.0), (0.79, 0.41), (0.63, 0.43)),
    ]
    seconds = 6.0
    grow = 1.0 + 0.10 * t
    hh = round(150 * k * grow)
    for index, (name, spec, start, end) in enumerate(walkers):
        bust, (bx, by) = fixtures.draw_bust(hh, **spec)
        bob = math.sin((t * seconds * 2 + index * 0.5) * math.pi) * 5 * k
        hx = (start[0] + (end[0] - start[0]) * t) * W
        hy = (start[1] + (end[1] - start[1]) * t) * H + bob
        img.paste(bust, (int(hx - bx), int(hy - by)), bust)
        # PicStrip's face box, measured off the composed screenshot: a little
        # wider than the face and reaching from the hairline to under the chin.
        bw, bh = 0.86 * hh, 0.98 * hh
        cy = hy + 0.03 * hh
        boxes[name] = (hx - bw / 2, cy - bh / 2, hx + bw / 2, cy + bh / 2)
    return img, boxes


_SCENE_CACHE: dict[tuple[int, float], tuple[Image.Image, dict]] = {}


def scene_at(width: int, t: float = PLAYHEAD_T, ss: int = 2) -> tuple[Image.Image, dict]:
    """``street_scene`` drawn at ``ss``× and scaled down, for clean edges.  Cached."""
    key = (width, round(t, 4))
    if key not in _SCENE_CACHE:
        big, boxes = street_scene(width * ss, t)
        img = big.resize((width, round(width * 9 / 16)), Image.LANCZOS)
        _SCENE_CACHE[key] = (img, {name: tuple(v / ss for v in box) for name, box in boxes.items()})
    return _SCENE_CACHE[key]


# ── PicStrip's covers ──────────────────────────────────────────────────────
def emoji_image(char: str, size: int) -> Image.Image:
    """An Apple Color Emoji glyph, ``size`` px across (the font is a 160 px bitmap strike)."""
    face = ImageFont.truetype("/System/Library/Fonts/Apple Color Emoji.ttc", 160)
    tile = Image.new("RGBA", (200, 200), (0, 0, 0, 0))
    ImageDraw.Draw(tile).text((100, 100), char, font=face, embedded_color=True, anchor="mm")
    tile = tile.crop(tile.getbbox())
    return tile.resize((size, round(size * tile.height / tile.width)), Image.LANCZOS)


def blur_box(frame: Image.Image, box: tuple[float, float, float, float]) -> None:
    """PicStrip's Blur cover: the box, blurred until nothing of the face is left."""
    x0, y0, x1, y1 = (round(v) for v in box)
    w, h = x1 - x0, y1 - y0
    margin = w // 2
    patch = frame.crop((x0 - margin, y0 - margin, x1 + margin, y1 + margin))
    patch = patch.filter(ImageFilter.GaussianBlur(w * 0.16)).filter(ImageFilter.GaussianBlur(w * 0.10))
    patch = patch.crop((margin, margin, margin + w, margin + h))
    frame.paste(patch, (x0, y0), rounded_mask((w, h), w * 0.06))


def apply_covers(frame: Image.Image, boxes: dict) -> Image.Image:
    """The three covers from the screenshot: blur, 😎 over a blur, and a black bar over the number."""
    frame = frame.copy()
    blur_box(frame, boxes["blur"])
    blur_box(frame, boxes["emoji"])
    x0, y0, x1, y1 = boxes["emoji"]
    size = round((x1 - x0) * 1.02)
    face = emoji_image("😎", size)
    frame.paste(face, (round((x0 + x1) / 2 - face.width / 2), round((y0 + y1) / 2 - face.height / 2)), face)
    nx0, ny0, nx1, ny1 = boxes["number"]
    th = ny1 - ny0
    bar = (round(nx0 - th * 0.45), round(ny0 - th * 0.35), round(nx1 + th * 0.45), round(ny1 + th * 0.35))
    frame.paste((12, 12, 14), bar[:2], rounded_mask((bar[2] - bar[0], bar[3] - bar[1]), th * 0.12))
    return frame


# ── The editor card ────────────────────────────────────────────────────────
def video_size(width: int = CARD_W) -> tuple[int, int]:
    """The video's size in a card ``width`` px wide (the layout constants are for CARD_W)."""
    w = round(width - 2 * CARD_PAD * width / CARD_W)
    return w, round(w * 9 / 16)


def card_height(width: int = CARD_W) -> int:
    u = width / CARD_W
    _, vh = video_size(width)
    return round(CARD_PAD * u + vh + (TIMELINE_GAP + FILM_H + LANE_GAP + AUDIO_H + CARD_BOTTOM_PAD) * u)


def waveform_bars(width: int, height: int, seed: int = 4) -> list[tuple[float, float]]:
    """(x, half-height) pairs for a speech-like waveform: phrases of syllables with pauses."""
    rng = random.Random(seed)
    bars, x, step = [], 0.0, height * 0.16
    while x < width:
        phrase = rng.randint(5, 11)
        for _ in range(phrase):
            if x >= width:
                break
            bars.append((x, height * rng.uniform(0.12, 0.42)))
            x += step
        for _ in range(rng.randint(2, 4)):
            if x >= width:
                break
            bars.append((x, height * 0.03))
            x += step
    return bars


def draw_bleep_icon(d: ImageDraw.ImageDraw, x: float, cy: float, h: float, color) -> float:
    """A small waveform glyph, like the one on PicStrip's Bleep clip.  Returns its width."""
    heights = (0.35, 0.7, 1.0, 0.55, 0.85, 0.4)
    bar_w, gap = h * 0.09, h * 0.08
    for i, f in enumerate(heights):
        bx = x + i * (bar_w + gap)
        d.rounded_rectangle([bx, cy - h * f / 2, bx + bar_w, cy + h * f / 2], radius=bar_w / 2, fill=color)
    return len(heights) * (bar_w + gap) - gap


def editor_card(bleep_label: str | None, rtl: bool = False, width: int = CARD_W) -> Image.Image:
    """The video with PicStrip's covers, framed as a card with a slim editor timeline under it.

    ``bleep_label`` None draws the Bleep clip with its icon only.  Lengths are
    in layout units (px at CARD_W); ``S`` turns them into px on the 2× canvas.
    """
    vw, vh = video_size(width)
    ch = card_height(width)
    u = width / CARD_W
    S = SS * u
    card = Image.new("RGBA", (width * SS, ch * SS), (0, 0, 0, 0))
    card.paste(CARD + (255,), (0, 0), rounded_mask(card.size, CARD_RADIUS * S, ss=2))
    d = ImageDraw.Draw(card)

    lane_x0 = round(CARD_PAD * S)
    lane_w = vw * SS
    lane_x1 = lane_x0 + lane_w
    film_y0 = round(CARD_PAD * S + vh * SS + TIMELINE_GAP * S)
    film_y1 = film_y0 + round(FILM_H * S)
    audio_y0 = film_y1 + round(LANE_GAP * S)
    audio_y1 = audio_y0 + round(AUDIO_H * S)

    # Filmstrip: frames across the clip, edge to edge in a rounded lane.
    thumb_h = film_y1 - film_y0
    thumb_w = round(thumb_h * 16 / 9)
    count = math.ceil(lane_w / thumb_w)
    strip = Image.new("RGB", (count * thumb_w, thumb_h))
    for i in range(count):
        frame, _ = scene_at(480, t=min(1.0, (i + 0.5) / count), ss=1)
        strip.paste(frame.resize((thumb_w, thumb_h), Image.LANCZOS), (i * thumb_w, 0))
    strip = strip.crop((0, 0, lane_w, thumb_h))
    card.paste(strip, (lane_x0, film_y0), rounded_mask((lane_w, thumb_h), 16 * S))
    d.rounded_rectangle([lane_x0, film_y0, lane_x1, film_y1], radius=16 * S, outline=(150, 150, 156), width=max(1, round(2 * S)))

    # Audio lane: a speech waveform with the red Bleep clip, selected (yellow handles).
    d.rounded_rectangle([lane_x0, audio_y0, lane_x1, audio_y1], radius=18 * S, fill=LANE)
    mid = (audio_y0 + audio_y1) / 2
    clip_x0 = lane_x0 + lane_w * 0.415
    clip_x1 = lane_x0 + lane_w * PLAYHEAD_T + 6 * S
    for bx, half in waveform_bars(lane_w - 40 * S, audio_y1 - audio_y0):
        x = lane_x0 + 20 * S + bx
        if clip_x0 - 4 * S <= x <= clip_x1 + 4 * S:
            continue
        d.rounded_rectangle([x, mid - half, x + 4 * S, mid + half], radius=2 * S, fill=LANE_INK)
    handle = 14 * S
    d.rounded_rectangle([clip_x0 - handle, audio_y0 + 6 * S, clip_x1 + handle, audio_y1 - 6 * S], radius=12 * S, fill=HANDLE_YELLOW)
    d.rectangle([clip_x0, audio_y0 + 12 * S, clip_x1, audio_y1 - 12 * S], fill=CLIP_RED)
    for hx in (clip_x0 - handle / 2, clip_x1 + handle / 2):  # grip lines on the handles
        d.rounded_rectangle([hx - 2 * S, mid - 16 * S, hx + 2 * S, mid + 16 * S], radius=2 * S, fill=(120, 96, 0))
    icon_h = 40 * S
    label = shaped(bleep_label) if bleep_label else None
    label_face = display_font(bleep_label, round(42 * S)) if label else None
    label_w = text_width(label_face, label) if label else 0
    gap = 14 * S if label else 0
    icon_w = 6 * icon_h * 0.17
    content_w = icon_w + gap + label_w
    if content_w > (clip_x1 - clip_x0) - 24 * S:  # a long translation: icon only
        label, gap, content_w = None, 0, icon_w
    start = (clip_x0 + clip_x1) / 2 - content_w / 2
    if rtl and label:
        d.text((start, mid), label, font=label_face, fill=WHITE, anchor="lm")
        draw_bleep_icon(d, start + label_w + gap, mid, icon_h, WHITE)
    else:
        draw_bleep_icon(d, start, mid, icon_h, WHITE)
        if label:
            d.text((start + icon_w + gap, mid), label, font=label_face, fill=WHITE, anchor="lm")

    # Playhead at the frame on show: a red line and a rounded knob.
    px = lane_x0 + lane_w * PLAYHEAD_T
    d.rounded_rectangle([px - 3 * S, film_y0 - 20 * S, px + 3 * S, audio_y1 + 8 * S], radius=3 * S, fill=SYSTEM_RED)
    d.rounded_rectangle([px - 15 * S, film_y0 - 38 * S, px + 15 * S, film_y0 - 8 * S], radius=8 * S, fill=SYSTEM_RED)

    card = card.resize((width, ch), Image.LANCZOS)

    # The video, covered, with rounded corners.
    frame, boxes = scene_at(vw)
    frame = apply_covers(frame, boxes)
    inset = round(CARD_PAD * u)
    card.paste(frame, (inset, inset), rounded_mask((vw, vh), VIDEO_RADIUS * u))
    return card


# ── Metadata chips ─────────────────────────────────────────────────────────
def draw_icon(kind: str, size: int, color) -> Image.Image:
    """SF Symbol–style glyphs, white on a coloured circle: location.fill, iphone, calendar."""
    S = 4
    n = size * S
    img = Image.new("RGBA", (n, n), (0, 0, 0, 0))
    d = ImageDraw.Draw(img)
    d.ellipse([0, 0, n - 1, n - 1], fill=color + (255,))
    w = WHITE + (255,)

    def p(x: float, y: float) -> tuple[float, float]:
        return x * n, y * n

    if kind == "location":
        d.polygon([p(0.75, 0.25), p(0.22, 0.48), p(0.48, 0.53), p(0.53, 0.79)], fill=w)
    elif kind == "device":
        d.rounded_rectangle([*p(0.355, 0.22), *p(0.645, 0.78)], radius=0.07 * n, outline=w, width=round(0.045 * n))
        d.rounded_rectangle([*p(0.455, 0.275), *p(0.545, 0.305)], radius=0.015 * n, fill=w)
    elif kind == "date":
        d.rounded_rectangle([*p(0.27, 0.29), *p(0.73, 0.73)], radius=0.07 * n, outline=w, width=round(0.045 * n))
        d.rectangle([*p(0.27, 0.32), *p(0.73, 0.41)], fill=w)
        for x in (0.38, 0.62):
            d.rounded_rectangle([*p(x - 0.022, 0.23), *p(x + 0.022, 0.34)], radius=0.02 * n, fill=w)
        for row, y in enumerate((0.50, 0.62)):
            for col, x in enumerate((0.37, 0.50, 0.63)):
                if row == 1 and col == 2:
                    continue
                d.rounded_rectangle([*p(x - 0.035, y - 0.03), *p(x + 0.035, y + 0.03)], radius=0.01 * n, fill=w)
    return img.resize((size, size), Image.LANCZOS)


CHIP_H = 118
CHIP_ICON = 82
CHIP_TEXT = 52


def metadata_chip(kind: str, text: str, rtl: bool = False, words: bool = True) -> Image.Image:
    """A white pill with a coloured icon and the value PicStrip strips.

    With ``words`` False the value is a grey placeholder bar of the same
    length (the textless version)."""
    face = sf(CHIP_TEXT, 600)
    pad = (CHIP_H - CHIP_ICON) // 2
    tw = math.ceil(text_width(face, text))
    width = pad + CHIP_ICON + 26 + tw + 40
    S = 3
    pill = Image.new("RGBA", (width * S, CHIP_H * S), (0, 0, 0, 0))
    pill.paste(WHITE + (255,), (0, 0), rounded_mask((width * S, CHIP_H * S), CHIP_H * S / 2, ss=2))
    pill = pill.resize((width, CHIP_H), Image.LANCZOS)
    icon = draw_icon(kind, CHIP_ICON, CHIP_COLORS[kind])
    # Icon leading: on the left, or on the right for RTL (the value stays left-to-right).
    icon_x = width - pad - CHIP_ICON if rtl else pad
    text_x = 40 if rtl else pad + CHIP_ICON + 26
    pill.alpha_composite(icon, (icon_x, pad))
    if words:
        ImageDraw.Draw(pill).text((text_x, CHIP_H / 2), text, font=face, fill=CHIP_INK, anchor="lm")
    else:
        bar_h = round(CHIP_H * 0.30)
        bar = Image.new("RGBA", (tw, bar_h), (208, 208, 214, 255))
        bar.putalpha(rounded_mask((tw, bar_h), bar_h / 2))
        pill.alpha_composite(bar, (text_x, (CHIP_H - bar_h) // 2))
    return pill


def float_away(chip: Image.Image, *, opacity: float, blur: float, angle: float, scale: float) -> Image.Image:
    """The chip partway through lifting off: tilted, smaller, softer and fading."""
    if scale != 1:
        chip = chip.resize((round(chip.width * scale), round(chip.height * scale)), Image.LANCZOS)
    pad = int(blur * 3) + 8
    canvas = Image.new("RGBA", (chip.width + 2 * pad, chip.height + 2 * pad), (0, 0, 0, 0))
    canvas.alpha_composite(chip, (pad, pad))
    if angle:
        canvas = canvas.rotate(angle, resample=Image.BICUBIC, expand=True)
    if blur:
        canvas = canvas.filter(ImageFilter.GaussianBlur(blur))
    alpha = canvas.split()[3].point(lambda v: int(v * opacity))
    canvas.putalpha(alpha)
    return canvas


# ── Background ─────────────────────────────────────────────────────────────
def background(glow_center: tuple[float, float]) -> Image.Image:
    """Brand teal, light at the top left to deep at the bottom right, a mint glow behind the card, dithered."""
    w, h = CANVAS
    y, x = np.mgrid[0:h, 0:w].astype(np.float32)
    # Diagonal ramp, eased so the middle stays rich rather than muddy.
    t = np.clip((x / w) * 0.45 + (y / h) * 0.75, 0, 1.2) / 1.2
    t = t * t * (3 - 2 * t)
    light, dark = np.array(BG_LIGHT, np.float32), np.array(BG_DARK, np.float32)
    rgb = light + (dark - light) * t[:, :, None]
    # Soft glow behind the card, and a fainter one over the words.
    for (cx, cy), radius, strength in ((glow_center, 1900, 0.30), ((1500, 700), 1700, 0.10)):
        r2 = ((x - cx) ** 2 + (y - cy) ** 2) / radius ** 2
        g = np.exp(-r2 * 1.6)[:, :, None] * strength
        rgb = rgb + (np.array(GLOW, np.float32) - rgb) * g
    # Dither so the 8-bit gradient doesn't band.
    rng = np.random.default_rng(27)
    rgb += rng.uniform(-1.2, 1.2, rgb.shape[:2])[:, :, None]
    return Image.fromarray(np.clip(rgb + 0.5, 0, 255).astype(np.uint8), "RGB").convert("RGBA")


# ── Words ──────────────────────────────────────────────────────────────────
JA_BREAK_AFTER = set("のをはがにでともへや、")
NO_LINE_START = set("ゃゅょっャュョッー、。，．・」』）")


def break_points(text: str) -> list[int]:
    """Indexes where a line may end.  Spaces for most scripts; for CJK between characters,
    and for Japanese only after a particle so phrases stay together."""
    if " " in text:
        return [i for i, c in enumerate(text) if c == " "]
    script = script_of(text)
    if script == "ja":
        return [i + 1 for i, c in enumerate(text[:-1]) if c in JA_BREAK_AFTER]
    if script in ("zh", "ko"):
        return [i for i in range(1, len(text)) if text[i] not in NO_LINE_START]
    return []


def balanced_lines(text: str, face: ImageFont.FreeTypeFont, max_width: float, max_lines: int) -> list[str] | None:
    """Fewest lines that fit ``max_width``, with the breaks chosen to even out line lengths."""
    points = break_points(text)
    spaced = " " in text
    best: tuple[float, list[str]] | None = None
    for n in range(1, max_lines + 1):
        best = None
        for combo in _combinations(points, n - 1):
            lines, last = [], 0
            for cut in combo:
                lines.append(text[last:cut].strip())
                last = cut + (1 if spaced else 0)
            lines.append(text[last:].strip())
            widths = [text_width(face, shaped(line)) for line in lines]
            if max(widths) > max_width:
                continue
            # Even lines first; then prefer a longer first line (reads as a phrase, not a stub).
            score = max(widths) - 0.02 * widths[0]
            if best is None or score < best[0]:
                best = (score, lines)
        if best:
            return best[1]
    return None


def _combinations(points: list[int], k: int):
    if k == 0:
        yield ()
        return
    for i, p in enumerate(points):
        for rest in _combinations(points[i + 1:], k - 1):
            yield (p,) + rest


def fit_text(text: str, max_width: float, largest: int, smallest: int, max_lines: int,
             bold: bool = True, fewer_lines_first: bool = False) -> tuple[ImageFont.FreeTypeFont, list[str]]:
    """The largest size (``largest`` down to ``smallest``) at which ``text`` fits in ``max_lines``.

    By default size wins (a big two-line headline beats a small one-line one);
    ``fewer_lines_first`` shrinks to keep one line before it wraps.
    """
    if script_of(text) in ("ja", "zh", "ko"):
        largest, smallest = round(largest * 0.86), round(smallest * 0.86)
    line_budgets = range(1, max_lines + 1) if fewer_lines_first else [max_lines]
    for lines_allowed in line_budgets:
        for size in range(largest, smallest - 1, -4):
            face = display_font(text, size, bold)
            lines = balanced_lines(text, face, max_width, lines_allowed)
            if lines:
                return face, lines
    face = display_font(text, smallest, bold)
    return face, balanced_lines(text, face, 10 ** 9, max_lines) or [text]


class Typeset:
    """Lines placed on baselines: line advance from the font size, opened up where tall
    glyphs (Arabic marks, CJK) would otherwise touch the line above."""

    def __init__(self, lines: list[str], face: ImageFont.FreeTypeFont, leading: float):
        self.face = face
        self.lines = [shaped(line) for line in lines]
        self.boxes = [face.getbbox(line, anchor="ls") for line in self.lines]
        self.baselines = [0.0]
        for above, below in zip(self.boxes, self.boxes[1:]):
            clear = above[3] - below[1] + face.size * 0.10
            self.baselines.append(self.baselines[-1] + max(face.size * leading, clear))
        self.ink_top = self.boxes[0][1]                              # above the first baseline (< 0)
        self.ink_bottom = self.baselines[-1] + max(0, self.boxes[-1][3])

    @property
    def height(self) -> float:
        return self.ink_bottom - self.ink_top

    def draw(self, canvas: Image.Image, x0: float, x1: float, top: float, color, rtl: bool) -> None:
        """Flush left from ``x0`` (flush right to ``x1`` for RTL), ink starting at ``top``."""
        d = ImageDraw.Draw(canvas)
        for line, baseline in zip(self.lines, self.baselines):
            y = top - self.ink_top + baseline
            if rtl:
                d.text((x1, y), line, font=self.face, fill=color, anchor="rs")
            else:
                d.text((x0, y), line, font=self.face, fill=color, anchor="ls")


# ── Composition ────────────────────────────────────────────────────────────
def load_copy(code: str) -> tuple[str, str, str]:
    """Headline line 1 of 01_VideoEditor and of 02_Location, and the app's word for Bleep."""
    headlines = shots._load_headlines_xcstrings(HEADLINES)
    title = shots._resolve_headline("01_VideoEditor", code, headlines).split("\n")[0]
    subtitle = shots._resolve_headline("02_Location", code, headlines).split("\n")[0]
    app = json.loads(APP_STRINGS.read_text(encoding="utf-8"))
    bleep = (((app["strings"].get("Bleep") or {}).get("localizations") or {}).get(code) or {})
    bleep = (bleep.get("stringUnit") or {}).get("value") or "Bleep"
    return title, subtitle, bleep


# How far along each chip is (further = smaller, softer, fainter) and where its
# centre sits, as fractions of the card's width and height from the card's
# top-left corner (mirrored for RTL).
CHIP_LOOKS = {
    "location": dict(opacity=1.0, blur=0, angle=-3, scale=1.0),
    "device": dict(opacity=0.86, blur=1.5, angle=4, scale=0.92),
    "date": dict(opacity=0.55, blur=4.5, angle=-6, scale=0.84),
}
CHIPS_ABOVE = {"location": (0.80, 0.035), "device": (0.62, -0.085), "date": (0.90, -0.14)}    # beside the words
CHIPS_BESIDE = {"location": (1.02, 0.33), "device": (1.20, 0.19), "date": (1.36, 0.07)}     # textless
TEXTLESS_CARD_W = 2240
TEXTLESS_CARD_X = 1060


def keep_inside(x: int, y: int, size: tuple[int, int]) -> tuple[int, int]:
    """Nudge a box at (x, y) back inside the safe area (long dates make wide chips)."""
    x = min(max(x, SAFE[0]), SAFE[2] - size[0])
    y = min(max(y, SAFE[1]), WORDS_BOTTOM - size[1])
    return x, y


def assert_safe(what: str, box: tuple[float, float, float, float]) -> None:
    x0, y0, x1, y1 = box
    if x0 < SAFE[0] or y0 < SAFE[1] or x1 > SAFE[2] or y1 > WORDS_BOTTOM:
        raise SystemExit(f"{what} {tuple(round(v) for v in box)} is outside the safe area {SAFE[:3] + (WORDS_BOTTOM,)}")


def compose(locale: str | None) -> Image.Image:
    """One universal asset: ``locale`` a store locale, or None for the textless version."""
    rtl = locale in RTL_LOCALES
    words = locale is not None
    title, subtitle, bleep = load_copy(STORE_LOCALES[locale]) if words else (None, None, None)

    width = CARD_W if words else TEXTLESS_CARD_W
    ch = card_height(width)
    if words:
        card_x0, card_y0 = CARD_RIGHT - CARD_W, CARD_TOP
    else:  # no words beside it: a larger card, with the chips lifting off its side
        card_x0, card_y0 = TEXTLESS_CARD_X, round(1390 - ch / 2)
    if rtl:
        card_x0 = CANVAS[0] - card_x0 - width

    canvas = background((card_x0 + width / 2, card_y0 + ch * 0.45))
    card = editor_card(bleep, rtl, width)

    # Card shadow: a wide ambient one and a tight contact one.
    alpha = card.split()[3]
    drop_shadow(canvas, alpha, (card_x0, card_y0), blur=90, opacity=0.42, offset=(0, 60))
    drop_shadow(canvas, alpha, (card_x0, card_y0), blur=18, opacity=0.28, offset=(0, 12))
    canvas.alpha_composite(card, (card_x0, card_y0))
    vw, vh = video_size(width)
    inset = round(CARD_PAD * width / CARD_W)
    assert_safe("the video", (card_x0 + inset, card_y0 + inset, card_x0 + inset + vw, card_y0 + inset + vh))

    # The photo's hidden location, device and date lifting off and fading away.
    values = {"location": CHIP_LOCATION, "device": CHIP_DEVICE, "date": CHIP_DATE.get(locale or "", CHIP_DATE["en-US"])}
    places = CHIPS_ABOVE if words else CHIPS_BESIDE
    for kind in ("date", "device", "location"):  # farthest first, so the nearest sits on top
        lifted = float_away(metadata_chip(kind, values[kind], rtl, words), **CHIP_LOOKS[kind])
        fx, fy = places[kind]
        cx = card_x0 + width * (1 - fx if rtl else fx)
        cy = card_y0 + ch * fy
        origin = keep_inside(round(cx - lifted.width / 2), round(cy - lifted.height / 2), lifted.size)
        drop_shadow(canvas, lifted.split()[3], origin, blur=26, opacity=0.35 * CHIP_LOOKS[kind]["opacity"], offset=(0, 18))
        canvas.alpha_composite(lifted, origin)

    if words:
        draw_words(canvas, title, subtitle, rtl, card_y0)
    return canvas.convert("RGB")


def draw_words(canvas: Image.Image, title: str, subtitle: str, rtl: bool, card_y0: int) -> None:
    """App icon and name, then the headline and the line under it, beside the card."""
    x0, x1 = TEXT_BOX
    if rtl:
        x0, x1 = CANVAS[0] - x1, CANVAS[0] - x0
    width = x1 - x0
    title_face, title_lines = fit_text(title, width, HEADLINE_MAX, HEADLINE_MIN, 2)
    if title_face.size < HEADLINE_MAX * 0.72:
        # A long first word pair (Dutch "Vervaag gezichten") shrinks two lines too
        # far; three shorter lines read better, at a capped size.
        face3, lines3 = fit_text(title, width, HEADLINE_THREE_LINES, HEADLINE_MIN, 3)
        if face3.size >= title_face.size * 1.15:
            title_face, title_lines = face3, lines3
    # The line under the headline is about half its size.  fit_text scales CJK and
    # Hangul down itself, so work from the headline's Latin-equivalent size.
    title_size = title_face.size / (0.86 if script_of(title) in ("ja", "zh", "ko") else 1)
    sub_size_cap = max(SUBHEAD_MIN, min(SUBHEAD_MAX, round(title_size * 0.56)))
    sub_face, sub_lines = fit_text(subtitle, width, sub_size_cap, SUBHEAD_MIN, 2, fewer_lines_first=True)
    for text, face in ((title, title_face), (subtitle, sub_face)):
        assert_no_tofu(text, face)
    brand_face = sf(BRAND_NAME_SIZE, 600)

    latin = script_of(title) == "latin"
    title_set = Typeset(title_lines, title_face, 1.06 if latin else 1.22)
    sub_set = Typeset(sub_lines, sub_face, 1.14 if script_of(subtitle) == "latin" else 1.28)
    gap_brand = 130                               # icon row to the headline's ink
    gap_sub = round(title_face.size * 0.36)      # headline to the line under it
    block_h = ICON_SIZE + gap_brand + title_set.height + gap_sub + sub_set.height
    _, vh = video_size()
    centre = card_y0 + CARD_PAD + vh * 0.50
    top = round(centre - block_h / 2)
    widest = max(text_width(title_set.face, line) for line in title_set.lines)
    assert_safe("the words", (x0, top, x1, top + block_h))
    if widest > width:
        raise SystemExit(f"headline {title!r} is wider than its column")

    # Brand row: the app icon and name.
    icon = Image.open(APP_ICON).convert("RGBA").resize((ICON_SIZE, ICON_SIZE), Image.LANCZOS)
    icon_x = x1 - ICON_SIZE if rtl else x0
    drop_shadow(canvas, icon.split()[3], (icon_x, top), blur=22, opacity=0.35, offset=(0, 10))
    canvas.alpha_composite(icon, (icon_x, top))
    d = ImageDraw.Draw(canvas)
    name_y = top + ICON_SIZE / 2
    if rtl:
        d.text((icon_x - 40, name_y), "PicStrip", font=brand_face, fill=WHITE + (240,), anchor="rm")
    else:
        d.text((icon_x + ICON_SIZE + 40, name_y), "PicStrip", font=brand_face, fill=WHITE + (240,), anchor="lm")

    y = top + ICON_SIZE + gap_brand
    title_set.draw(canvas, x0, x1, y, WHITE, rtl)
    sub_set.draw(canvas, x0, x1, y + title_set.height + gap_sub, SUBHEAD, rtl)


# ── Previews ───────────────────────────────────────────────────────────────
def header_crop(img: Image.Image) -> Image.Image:
    w, h = HEADER_CROP
    scaled = img.resize((w, round(img.height * w / img.width)), Image.LANCZOS)
    top = (scaled.height - h) // 2
    return scaled.crop((0, top, w, top + h))


def search_crop(img: Image.Image) -> Image.Image:
    w, h = SEARCH_CROP
    scaled = img.resize((round(img.width * h / img.height), h), Image.LANCZOS)
    left = (scaled.width - w) // 2
    return scaled.crop((left, 0, left + w, h))


def montage(images: dict[str, Image.Image], columns: int = 4, thumb_w: int = 1000) -> Image.Image:
    """Every rendered locale on one sheet, labelled."""
    thumb_h = round(thumb_w * CANVAS[1] / CANVAS[0])
    label_h, gap = 70, 30
    rows = math.ceil(len(images) / columns)
    sheet = Image.new("RGB", (columns * (thumb_w + gap) + gap, rows * (thumb_h + label_h + gap) + gap), (30, 30, 32))
    d = ImageDraw.Draw(sheet)
    face = sf(40, 600)
    for i, (name, img) in enumerate(images.items()):
        x = gap + (i % columns) * (thumb_w + gap)
        y = gap + (i // columns) * (thumb_h + label_h + gap)
        sheet.paste(img if img.size == (thumb_w, thumb_h) else img.resize((thumb_w, thumb_h), Image.LANCZOS), (x, y + label_h))
        d.text((x, y + label_h / 2), name, font=face, fill=(235, 235, 240), anchor="lm")
    return sheet


SRGB = ImageCms.ImageCmsProfile(ImageCms.createProfile("sRGB")).tobytes()


def check(path: Path) -> None:
    """Re-open the saved file: exactly the canvas size, 8-bit RGB, no alpha."""
    with Image.open(path) as saved:
        if saved.size != CANVAS or saved.mode != "RGB" or "transparency" in saved.info:
            raise SystemExit(f"{path.name}: {saved.size} {saved.mode} is not a {CANVAS[0]}×{CANVAS[1]} RGB PNG")


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--out", type=Path, default=OUT)
    parser.add_argument("--locale", action="append", choices=sorted(STORE_LOCALES),
                        help="only these store locales (default: all, plus the textless version)")
    parser.add_argument("--no-previews", action="store_true")
    args = parser.parse_args()
    if not features.check("raqm"):
        print("warning: Pillow has no libraqm; Arabic falls back to arabic_reshaper + python-bidi", file=sys.stderr)

    args.out.mkdir(parents=True, exist_ok=True)
    previews = args.out / "previews"
    if not args.no_previews:
        previews.mkdir(exist_ok=True)
    locales: list[str | None] = list(args.locale) if args.locale else [*STORE_LOCALES, None]
    thumbs: dict[str, Image.Image] = {}
    for locale in locales:
        name = locale or "textless"
        img = compose(locale)
        path = args.out / f"PicStrip-universal-{name}.png"
        img.save(path, format="PNG", icc_profile=SRGB)
        check(path)
        print(f"{path}  {img.width}×{img.height} RGB")
        if args.no_previews:
            continue
        # The two crops as the App Store makes them, for a few scripts.
        if name in ("en-US", "ja", "ar-SA", "textless"):
            header_crop(img).save(previews / f"{name}-header-3840x1646.png")
            search_crop(img).save(previews / f"{name}-search-3840x2560.png")
        thumbs[name] = img.resize((1000, round(1000 * CANVAS[1] / CANVAS[0])), Image.LANCZOS)

    if len(thumbs) > 1:
        montage(thumbs).save(previews / "all-locales.png")
    if not args.no_previews:
        print(f"previews in {previews}")


if __name__ == "__main__":
    main()
