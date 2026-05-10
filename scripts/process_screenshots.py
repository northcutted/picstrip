#!/usr/bin/env python3
"""Compose App Store marketing screenshots.

Pipeline:
  1. ``fastlane snapshot`` writes raw screen captures into
     ``fastlane/screenshots/<locale>/<device>-<screen>.png``.
  2. This script wraps each capture in a custom matte-black device frame
     drawn in code (we deliberately ignore frameit's framed PNGs because
     they bake in a metallic side reflection that fights any non-white
     marketing background) and composes the final marketing PNG: a brand
     gradient canvas with a soft top highlight, a localized headline at
     the top, and the framed device floated below with a two-layer shadow.

The output canvas matches the input capture's dimensions so App Store
Connect accepts them for the corresponding device class.

Usage:
    python3 scripts/process_screenshots.py --locale en-US

Outputs land in ``fastlane/screenshots/processed/<locale>/<filename>.png``.
"""

from __future__ import annotations

import argparse
import json
import sys
from dataclasses import dataclass
from pathlib import Path
from typing import Iterable

from PIL import Image, ImageChops, ImageDraw, ImageFont

try:  # ``ImageFilter`` ships with Pillow but guard against minimal builds.
    from PIL import ImageFilter

    _HAS_GAUSSIAN_BLUR = hasattr(ImageFilter, "GaussianBlur")
except ImportError:  # pragma: no cover - extremely rare
    ImageFilter = None  # type: ignore[assignment]
    _HAS_GAUSSIAN_BLUR = False

# Optional Arabic shaping. PIL renders Arabic letters in input order without
# joining isolated forms into cursive ligatures or reversing for RTL display
# — the result is unreadable. ``arabic_reshaper`` joins the letters; the bidi
# algorithm reorders the result for visual (LTR) order so PIL draws the
# correct sequence. Both are pure-Python; if not installed we degrade
# gracefully and Arabic renders unshaped (still better than tofu).
try:
    import arabic_reshaper
    from bidi.algorithm import get_display

    _HAS_ARABIC_SHAPING = True
except ImportError:  # pragma: no cover - optional dependency
    arabic_reshaper = None  # type: ignore[assignment]
    get_display = None  # type: ignore[assignment]
    _HAS_ARABIC_SHAPING = False


# ── Brand palette ──────────────────────────────────────────────────────────
# Vertical gradient: lighter teal at top → darker teal at bottom for depth.
# Values match the app's accent color family (teal/green privacy theme).
BRAND_TOP = (32, 120, 90)         # medium teal — top of the gradient
BRAND_BOTTOM = (10, 56, 42)       # rich dark teal — anchors the bottom
HEADLINE_COLOR = (255, 255, 255)
HEADLINE_STROKE_COLOR = (4, 30, 22)  # near-black teal — defines letter edges
HIGHLIGHT_COLOR = (110, 200, 160) # soft top-center glow

# ── Layout ratios ──────────────────────────────────────────────────────────
# The composition is roughly "copy on top, oversized device on bottom",
# with a clear gap between the headline block and the device so the two
# read as distinct sections rather than crowding each other. The device
# dominates — it's the hero of every screenshot.
HEADLINE_AREA_FRAC = 0.25           # top 25% — headline lives here
HEADLINE_TOP_PAD_FRAC = 0.06        # space above the headline
HEADLINE_BOTTOM_GAP_FRAC = 0.04     # breathing room between text and device
PHONE_HEADLINE_AREA_FRAC = 0.11     # phone shots prioritize the oversized device
PHONE_HEADLINE_TOP_PAD_FRAC = 0.018 # copy shifts upward to make room for the app
PHONE_HEADLINE_BOTTOM_GAP_FRAC = 0.012
HEADLINE_HORIZONTAL_PAD_FRAC = 0.09 # 9% margin on each side of the headline
DEVICE_HORIZONTAL_PAD_FRAC = 0.04   # 4% margin on each side of the device
PHONE_DEVICE_HORIZONTAL_PAD_FRAC = 0.012  # almost edge-to-edge, like App Store cards
DEVICE_BOTTOM_PAD_FRAC = 0.02       # bottom breathing room under the device
HEADLINE_MAX_LINES = 3
HEADLINE_LINE_SPACING = 1.08        # tight tracking for display headlines
HEADLINE_STROKE_WIDTH_FRAC = 0.020  # stroke width as a fraction of font size

# ── Top radial highlight ───────────────────────────────────────────────────
HIGHLIGHT_RADIUS_FRAC = 0.85        # of canvas width
HIGHLIGHT_CENTER_Y_FRAC = 0.06      # near the top edge
HIGHLIGHT_OPACITY = 70              # 0–255

# ── Device drop shadow (two-layer for realism) ─────────────────────────────
# Ambient halo: large, soft, far — gives the device a sense of place.
AMBIENT_BLUR_RADIUS = 80
AMBIENT_OPACITY = 75
AMBIENT_Y_OFFSET = 44
# Contact shadow: small, sharp, close — anchors the device to the surface.
CONTACT_BLUR_RADIUS = 10
CONTACT_OPACITY = 130
CONTACT_Y_OFFSET = 8

# ── Headline drop shadow (soft Gaussian blur) ──────────────────────────────
# Deep + soft — gives the white text a "lifted off the page" look without
# the hard-stamp feeling of a small offset shadow.
HEADLINE_SHADOW_BLUR = 18
HEADLINE_SHADOW_OPACITY = 150
HEADLINE_SHADOW_Y_OFFSET = 10

# ── Custom device frame ────────────────────────────────────────────────────
# We render our own minimal frame around the raw screenshot rather than
# consuming fastlane frameit's framed PNG (which shipped a metallic side
# reflection that read as white slivers against a dark canvas). The goal is
# unambiguously "this is an iPhone / iPad" without going full skeuomorphic:
# a matte titanium-ish body, a faint inner rim suggesting the display
# bezel, and stylized side buttons that read as iOS-native at a glance.
FRAME_COLOR = (11, 12, 13, 255)     # near-black titanium body
FRAME_EDGE_HIGHLIGHT = (50, 55, 58, 125)
FRAME_RIM_COLOR = (1, 2, 3, 255)    # black glass bevel around the display
FRAME_RIM_HIGHLIGHT = (58, 65, 68, 80)
FRAME_BUTTON_COLOR = (28, 31, 33, 255)  # slightly lighter than body — bare metal feel
IPHONE_FRAME_COLOR = (13, 14, 15, 255)     # near-black titanium side rail
IPHONE_FRAME_GLASS_COLOR = (1, 2, 3, 255)  # black front glass around the display
IPHONE_FRAME_EDGE_HIGHLIGHT = (70, 76, 78, 95)
IPHONE_FRAME_EDGE_SHADOW = (0, 0, 0, 170)
IPHONE_FRAME_RIM_COLOR = (0, 0, 0, 255)    # black display gasket
IPHONE_FRAME_RIM_HIGHLIGHT = (48, 55, 58, 80)
IPHONE_FRAME_BUTTON_COLOR = (24, 27, 29, 255)
DYNAMIC_ISLAND_COLOR = (0, 0, 0, 255)
CAMERA_GLASS_COLOR = (3, 5, 7, 255)
CAMERA_LENS_COLOR = (13, 25, 36, 255)

# Per-device tuning. ``screen_radius_frac`` and ``bezel_frac`` are expressed
# relative to the screenshot's *width* so the frame scales correctly across
# device sizes. The radii match Apple's display corner radii closely enough
# to read as native; tighter than that and the bezel looks computer-drawn.
IPHONE_OUTER_RADIUS_FRAC = 0.132    # iPhone-style continuous hardware corners
IPHONE_BEZEL_FRAC = 0.036           # ≈48 px frame thickness — keeps display inside shell
IPAD_SCREEN_RADIUS_FRAC = 0.022     # ≈45 px on a 2064 px-wide capture
IPAD_BEZEL_FRAC = 0.030             # ≈62 px frame thickness
IPHONE_CONTROL_GUTTER_FRAC = 0.009
IPAD_CONTROL_GUTTER_FRAC = 0.009
IPHONE_ISLAND_WIDTH_FRAC = 0.292
IPHONE_ISLAND_HEIGHT_FRAC = 0.082
IPHONE_ISLAND_CENTER_Y_FRAC = 0.070
IPAD_CAMERA_RADIUS_FRAC = 0.006

# ── Font lookup ────────────────────────────────────────────────────────────
# Each entry is ``(path, ttc_index, named_variation, axis_weight)``. We try
# the named instance first (most reliable on macOS), then fall back to the
# axis-based API, then accept whatever the font ships at by default. We
# target **Bold (700)** rather than Heavy (800) so the headlines feel
# native to iOS rather than overly stylized.
#
# The compositor picks a candidate list per headline based on the dominant
# script in the text — SF Pro doesn't have CJK or Arabic glyphs, and PIL
# renders missing glyphs as empty rectangles ("tofu") rather than falling
# back. For each non-Latin script we use the macOS system font that iOS
# itself uses for that locale.
_FONT_CANDIDATES_LATIN: list[tuple[str, int, str | None, int | None]] = [
    ("/System/Library/Fonts/SFNS.ttf", 0, "Bold", 700),                  # SF Pro
    ("/System/Library/Fonts/SFNSDisplay.ttf", 0, "Bold", 700),           # SF Pro Display
    ("/System/Library/Fonts/HelveticaNeue.ttc", 8, None, None),          # Helvetica Neue Bold
    ("/System/Library/Fonts/Helvetica.ttc", 1, None, None),              # Helvetica Bold
    ("/System/Library/Fonts/Supplemental/Arial Bold.ttf", 0, None, None),
    ("/usr/share/fonts/truetype/dejavu/DejaVuSans-Bold.ttf", 0, None, None),
]

# Chinese + Japanese (Han ideographs + Hiragana/Katakana). Hiragino Sans GB
# W6 is the iOS-native bold weight for Chinese, and covers Japanese kana
# well enough for marketing headlines.
_FONT_CANDIDATES_CJK: list[tuple[str, int, str | None, int | None]] = [
    ("/System/Library/Fonts/Hiragino Sans GB.ttc", 2, None, None),       # W6 (≈ Semibold)
    ("/System/Library/Fonts/AppleSDGothicNeo.ttc", 6, None, None),       # Bold (CJK fallback)
    ("/System/Library/Fonts/STHeiti Medium.ttc", 1, None, None),         # Heiti SC Medium
    ("/System/Library/Fonts/Supplemental/Songti.ttc", 1, None, None),    # Songti SC Bold
]

# Korean (Hangul). Hiragino Sans GB is Chinese-only and ships no Hangul, so
# Korean needs a dedicated list anchored on Apple SD Gothic Neo — the
# iOS-native Korean font.
_FONT_CANDIDATES_KOREAN: list[tuple[str, int, str | None, int | None]] = [
    ("/System/Library/Fonts/AppleSDGothicNeo.ttc", 6, None, None),       # Bold
    ("/System/Library/Fonts/AppleSDGothicNeo.ttc", 4, None, None),       # SemiBold fallback
]

# Arabic.
_FONT_CANDIDATES_ARABIC: list[tuple[str, int, str | None, int | None]] = [
    ("/System/Library/Fonts/GeezaPro.ttc", 1, None, None),               # Bold
]


def _font_candidates_for_text(
    text: str,
) -> list[tuple[str, int, str | None, int | None]]:
    """Pick the best font candidate list based on the dominant script in ``text``.

    Hangul takes priority because the font sets for Chinese/Japanese vs
    Korean don't overlap on macOS — picking the wrong one produces tofu.
    Otherwise: Han ideographs / kana → CJK list, Arabic → Arabic list,
    everything else → Latin (covers ASCII, Cyrillic, Greek, etc.).
    """
    for ch in text:
        cp = ord(ch)
        if 0xAC00 <= cp <= 0xD7AF or 0x1100 <= cp <= 0x11FF:
            return _FONT_CANDIDATES_KOREAN
        if (
            0x3000 <= cp <= 0x303F   # CJK Symbols and Punctuation (。、 etc.)
            or 0x3040 <= cp <= 0x309F   # Hiragana
            or 0x30A0 <= cp <= 0x30FF   # Katakana
            or 0x3400 <= cp <= 0x4DBF   # CJK Unified Ideographs Extension A
            or 0x4E00 <= cp <= 0x9FFF   # CJK Unified Ideographs
            or 0xF900 <= cp <= 0xFAFF   # CJK Compatibility Ideographs
            or 0xFF00 <= cp <= 0xFFEF   # Halfwidth and Fullwidth Forms
        ):
            return _FONT_CANDIDATES_CJK
        if (
            0x0600 <= cp <= 0x06FF   # Arabic
            or 0x0750 <= cp <= 0x077F   # Arabic Supplement
            or 0xFB50 <= cp <= 0xFDFF   # Arabic Presentation Forms-A
            or 0xFE70 <= cp <= 0xFEFF   # Arabic Presentation Forms-B
        ):
            return _FONT_CANDIDATES_ARABIC
    return _FONT_CANDIDATES_LATIN


def _line_has_arabic(line: str) -> bool:
    return any(
        0x0600 <= ord(c) <= 0x06FF
        or 0x0750 <= ord(c) <= 0x077F
        or 0xFB50 <= ord(c) <= 0xFDFF
        or 0xFE70 <= ord(c) <= 0xFEFF
        for c in line
    )


def _shape_for_display(
    text: str,
    candidates: list[tuple[str, int, str | None, int | None]],
) -> str:
    """Pre-process ``text`` for correct PIL rendering when needed.

    Arabic strings in logical (input) order render as disconnected isolated
    forms left-to-right when PIL lacks libraqm. Running them through
    ``arabic_reshaper`` joins the letters into cursive ligatures, then the
    bidi algorithm reorders the result so PIL — which always draws LTR —
    produces the correct visual sequence. We shape per-line and only touch
    lines that actually contain Arabic — pure-Latin lines (e.g. brand
    acronyms ``GPS. EXIF. IPTC.`` mixed into Arabic headlines) pass through
    untouched so bidi neutrals don't get misclassified.
    """
    if candidates is _FONT_CANDIDATES_ARABIC and _HAS_ARABIC_SHAPING:
        out: list[str] = []
        for line in text.split("\n"):
            if _line_has_arabic(line):
                out.append(get_display(arabic_reshaper.reshape(line)))
            else:
                out.append(line)
        return "\n".join(out)
    return text


# ── Embedded fallback headlines ────────────────────────────────────────────
# Lookup key is the screen suffix (everything after the trailing ``-`` in the
# filename, minus the ``.png`` extension and any ``_framed`` qualifier). These
# strings keep the script working standalone if
# ``fastlane/MarketingHeadlines.xcstrings`` is missing. Kept in sync with the
# canonical English values in that file.
HEADLINES: dict[str, str] = {
    "01_Home":            "Share the photo.\nNot the story behind it.",
    "02_PrivacyImpact":   "GPS. Time. Camera ID.\nAll stripped automatically.",
    "03_About":           "Open source.\nAuditable privacy.",
    "04_PhotoLoaded":     "Sensitive data\ncaught instantly.",
    "05_RedactionEditor": "Draw to hide\nanything sensitive.",
    "06_SensitiveData":   "See exactly\nwhat gets hidden.",
    "07_ReviewAndSave":   "Export clean.\nShare confidently.",
}

DEFAULT_HEADLINE = "Share the photo.\nNot the story behind it."

# Output filenames control App Store screenshot order. The first 1–3 slots
# drive the bulk of conversion, so the lead with the strongest emotional hook
# (Home — "Share the photo. Not the story behind it."), prove the product
# works (PhotoLoaded — sensitive data caught), then close the loop
# (ReviewAndSave — clean export). Slots 4–7 reinforce: the redaction power
# feature, transparency, breadth of metadata stripped, and the brand close.
SCREENSHOT_DISPLAY_ORDER: dict[str, str] = {
    "01_Home":            "01_Home",
    "04_PhotoLoaded":     "02_PhotoLoaded",
    "07_ReviewAndSave":   "03_ReviewAndSave",
    "05_RedactionEditor": "04_RedactionEditor",
    "06_SensitiveData":   "05_SensitiveData",
    "02_PrivacyImpact":   "06_PrivacyImpact",
    "03_About":           "07_About",
}


@dataclass(frozen=True)
class Layout:
    canvas_w: int
    canvas_h: int
    headline_box: tuple[int, int, int, int]   # x0, y0, x1, y1
    device_box: tuple[int, int, int, int]


# ── Font loading ───────────────────────────────────────────────────────────
def _find_font(
    size: int,
    candidates: list[tuple[str, int, str | None, int | None]] | None = None,
) -> ImageFont.ImageFont:
    """Return the best available display font at ``size`` points, in Bold.

    ``candidates`` selects which family list to walk — Latin (default), CJK,
    or Arabic. For variable fonts (SF Pro / SFNS) we try the named "Bold"
    instance first, then the weight axis (700), so it works across Pillow
    versions with or without libraqm. For TrueType Collections we pick the
    Bold sub-font by index.
    """
    chain = candidates if candidates is not None else _FONT_CANDIDATES_LATIN
    for path, index, name, axis_weight in chain:
        if not Path(path).exists():
            continue
        try:
            font = ImageFont.truetype(path, size=size, index=index)
        except OSError:
            continue
        if name is not None:
            try:
                font.set_variation_by_name(name)
                return font
            except (AttributeError, OSError, ValueError):
                pass
        if axis_weight is not None:
            try:
                font.set_variation_by_axes([axis_weight])
                return font
            except (AttributeError, OSError, ValueError):
                pass
        return font
    return ImageFont.load_default()


# ── Background painting ────────────────────────────────────────────────────
def _draw_gradient_on(
    img: Image.Image,
    top: tuple[int, int, int],
    bottom: tuple[int, int, int],
) -> None:
    """Paint a vertical RGB gradient onto ``img`` in-place."""
    draw = ImageDraw.Draw(img)
    h = max(img.height, 1)
    for y in range(h):
        t = y / (h - 1) if h > 1 else 0.0
        r = round(top[0] + (bottom[0] - top[0]) * t)
        g = round(top[1] + (bottom[1] - top[1]) * t)
        b = round(top[2] + (bottom[2] - top[2]) * t)
        draw.line([(0, y), (img.width, y)], fill=(r, g, b))


def _paint_top_highlight(canvas: Image.Image) -> None:
    """Add a soft circular glow near the top of the canvas for depth.

    Implemented as a heavily-blurred filled ellipse — looks like a light
    source above the device. No-op if Gaussian blur isn't available.
    """
    if not _HAS_GAUSSIAN_BLUR:
        return

    radius = int(canvas.width * HIGHLIGHT_RADIUS_FRAC)
    cx = canvas.width // 2
    cy = int(canvas.height * HIGHLIGHT_CENTER_Y_FRAC)

    # Allocate just enough room for the ellipse so the blur doesn't have to
    # process the whole canvas — meaningful speedup on iPad-sized images.
    layer = Image.new("RGBA", canvas.size, (0, 0, 0, 0))
    draw = ImageDraw.Draw(layer)
    draw.ellipse(
        [cx - radius, cy - radius, cx + radius, cy + radius],
        fill=(*HIGHLIGHT_COLOR, HIGHLIGHT_OPACITY),
    )
    layer = layer.filter(ImageFilter.GaussianBlur(radius=radius // 4))
    canvas.alpha_composite(layer)


# ── Filename / locale helpers ──────────────────────────────────────────────
def _screen_key_from_filename(name: str) -> str:
    """``iPhone 17 Pro Max-04_PhotoLoaded.png`` → ``04_PhotoLoaded``."""
    stem = Path(name).stem
    if stem.endswith("_framed"):
        stem = stem[: -len("_framed")]
    if "-" not in stem:
        return stem
    return stem.rsplit("-", 1)[1]


def _ordered_output_name(name: str) -> str:
    """Return the processed filename with its App Store display-order prefix."""
    screen_key = _screen_key_from_filename(name)
    ordered_key = SCREENSHOT_DISPLAY_ORDER.get(screen_key)
    if ordered_key is None:
        return name

    path = Path(name)
    stem = path.stem
    if "-" not in stem:
        return name
    device_name = stem.rsplit("-", 1)[0]
    return f"{device_name}-{ordered_key}{path.suffix}"


def _load_headlines_xcstrings(xcstrings_path: Path) -> dict[str, dict[str, str]]:
    """Parse an ``.xcstrings`` JSON file into ``{screen_key: {locale: value}}``.

    Returns an empty dict if the file is missing or malformed; the caller
    falls back to the embedded ``HEADLINES`` map in that case.
    """
    try:
        raw = xcstrings_path.read_text(encoding="utf-8")
    except (FileNotFoundError, OSError):
        return {}

    try:
        data = json.loads(raw)
    except json.JSONDecodeError:
        return {}

    out: dict[str, dict[str, str]] = {}
    for key, entry in (data.get("strings") or {}).items():
        localizations = (entry or {}).get("localizations") or {}
        per_locale: dict[str, str] = {}
        for locale, payload in localizations.items():
            value = ((payload or {}).get("stringUnit") or {}).get("value")
            if isinstance(value, str):
                per_locale[locale] = value
        if per_locale:
            out[key] = per_locale
    return out


def _resolve_headline(
    screen_key: str,
    locale: str,
    xcstrings_map: dict[str, dict[str, str]],
) -> str:
    """Pick the best headline for ``screen_key`` in ``locale``.

    Lookup order: requested locale, base language (``de-DE`` → ``de``), ``en``,
    embedded ``HEADLINES`` map, then ``DEFAULT_HEADLINE``.
    """
    base_locale = locale.split("-", 1)[0] if "-" in locale else locale
    candidates = (locale, base_locale, "en")

    per_locale = xcstrings_map.get(screen_key) or {}
    for candidate in candidates:
        value = per_locale.get(candidate)
        if value:
            return value

    return HEADLINES.get(screen_key, DEFAULT_HEADLINE)


# ── Headline typography ────────────────────────────────────────────────────
def _wrap_headline(
    text: str,
    font: ImageFont.ImageFont,
    max_width: int,
    draw: ImageDraw.ImageDraw,
) -> list[str]:
    """Wrap ``text`` to fit ``max_width``, honoring explicit ``\n`` breaks."""
    lines: list[str] = []
    for paragraph in text.split("\n"):
        words = paragraph.split()
        if not words:
            lines.append("")
            continue
        current = words[0]
        for word in words[1:]:
            candidate = f"{current} {word}"
            if _text_width(draw, candidate, font) <= max_width:
                current = candidate
            else:
                lines.append(current)
                current = word
        lines.append(current)
    return lines


def _text_width(draw: ImageDraw.ImageDraw, text: str, font: ImageFont.ImageFont) -> int:
    bbox = draw.textbbox((0, 0), text, font=font)
    return bbox[2] - bbox[0]


def _line_bbox(
    draw: ImageDraw.ImageDraw,
    text: str,
    font: ImageFont.ImageFont,
    stroke_width: int = 0,
) -> tuple[int, int, int, int]:
    return draw.textbbox((0, 0), text, font=font, stroke_width=stroke_width)


def _headline_block_size(
    draw: ImageDraw.ImageDraw,
    lines: list[str],
    font: ImageFont.ImageFont,
    stroke_width: int = 0,
) -> tuple[int, int, int]:
    """Return ``(width, height, line_gap)`` for real glyph bounds.

    Arabic ascenders/descenders can be much taller than the Latin "Ag" probe.
    Measuring the actual rendered lines prevents stacked headline lines from
    colliding in RTL locales while preserving tight Latin display type.
    """
    if not lines:
        return 0, 0, 0

    bboxes = [_line_bbox(draw, line, font, stroke_width) for line in lines]
    heights = [bbox[3] - bbox[1] for bbox in bboxes]
    widths = [bbox[2] - bbox[0] for bbox in bboxes]
    em_h = max(1, _line_bbox(draw, "Ag", font, stroke_width)[3] - _line_bbox(draw, "Ag", font, stroke_width)[1])
    line_gap = max(2, int(em_h * (HEADLINE_LINE_SPACING - 1)))
    return max(widths, default=0), sum(heights) + line_gap * max(0, len(lines) - 1), line_gap


def _fit_headline_font(
    text: str,
    max_width: int,
    max_height: int,
    draw: ImageDraw.ImageDraw,
) -> tuple[ImageFont.ImageFont, list[str]]:
    """Return the largest font (and wrapped lines) that fits the headline box.

    Returned ``lines`` are the *display-ready* strings — Arabic has been
    shaped + bidi-reordered if applicable, so callers can hand each line
    directly to ``draw.text`` without further transformation.

    The algorithm prefers cleanly-broken layouts over the largest possible
    font: it first tries to fit each explicit ``\\n`` paragraph on a single
    line (no algorithmic wrapping), and only falls back to allowing one
    extra wrap, then more, when no readable size fits otherwise. Without
    this, long compound words in DE/PL/TR force orphan-word layouts like
    ``Sensible / Daten / sofort erkannt.`` even when ``Sensible Daten /
    sofort erkannt.`` would fit at a smaller-but-still-readable size.
    """
    candidates = _font_candidates_for_text(text)
    shaped = _shape_for_display(text, candidates)
    n_paragraphs = shaped.count("\n") + 1

    # Start large — display headlines look richer at scale. Cap at 220pt so
    # very tall canvases (iPad portrait) don't produce absurd letter heights.
    start = max(64, min(220, max_height // 3))

    # Outer loop: how many lines we're willing to accept. Try the cleanest
    # layout (one paragraph per line) first, escalate only if no font fits.
    for max_lines in range(n_paragraphs, HEADLINE_MAX_LINES + 1):
        for size in range(start, 31, -2):
            font = _find_font(size, candidates)
            lines = _wrap_headline(shaped, font, max_width, draw)
            if len(lines) > max_lines:
                continue
            stroke_w = max(1, int(size * HEADLINE_STROKE_WIDTH_FRAC))
            widest, block_h, _ = _headline_block_size(draw, lines, font, stroke_w)
            if widest <= max_width and block_h <= max_height:
                return font, lines

    # Last-resort fallback: smallest font, accept whatever wrapping happens.
    font = _find_font(32, candidates)
    return font, _wrap_headline(shaped, font, max_width, draw)


def _draw_headline(
    canvas: Image.Image,
    text: str,
    box: tuple[int, int, int, int],
) -> None:
    """Render ``text`` centered in ``box`` with a stroke and a soft drop shadow.

    The white letters get a thin near-black stroke (defines edges against
    any portion of the gradient) and a deep Gaussian-blurred shadow (lifts
    the text off the page). Together they keep the headline crisp without
    relying on perfect background contrast.
    """
    x0, y0, x1, y1 = box
    box_w = x1 - x0
    box_h = y1 - y0

    # Probe layer just for measuring text — discarded after font is picked.
    measure = Image.new("RGBA", (1, 1), (0, 0, 0, 0))
    measure_draw = ImageDraw.Draw(measure)
    font, lines = _fit_headline_font(text, box_w, box_h, measure_draw)

    font_size = getattr(font, "size", 0) or 0
    stroke_w = max(1, int(font_size * HEADLINE_STROKE_WIDTH_FRAC))

    _, block_h, line_gap = _headline_block_size(measure_draw, lines, font, stroke_w)
    line_bboxes = [_line_bbox(measure_draw, line, font, stroke_w) for line in lines]
    cursor_y = y0 + max(0, (box_h - block_h) // 2)

    # Draw the shadow first on its own layer, blur it, then composite.
    # The shadow inherits the stroke so the diffused silhouette includes
    # the full stroked letter shape — keeps the lift effect uniform.
    if _HAS_GAUSSIAN_BLUR and HEADLINE_SHADOW_OPACITY > 0:
        shadow_layer = Image.new("RGBA", canvas.size, (0, 0, 0, 0))
        shadow_draw = ImageDraw.Draw(shadow_layer)
        sy = cursor_y
        for line, bbox in zip(lines, line_bboxes):
            line_w = bbox[2] - bbox[0]
            line_h = bbox[3] - bbox[1]
            x = x0 + (box_w - line_w) // 2
            shadow_draw.text(
                (x - bbox[0], sy - bbox[1] + HEADLINE_SHADOW_Y_OFFSET),
                line,
                fill=(0, 0, 0, HEADLINE_SHADOW_OPACITY),
                font=font,
                stroke_width=stroke_w,
                stroke_fill=(0, 0, 0, HEADLINE_SHADOW_OPACITY),
            )
            sy += line_h + line_gap
        shadow_layer = shadow_layer.filter(
            ImageFilter.GaussianBlur(radius=HEADLINE_SHADOW_BLUR)
        )
        canvas.alpha_composite(shadow_layer)

    # Draw the crisp white text with a near-black stroke on top.
    text_layer = Image.new("RGBA", canvas.size, (0, 0, 0, 0))
    text_draw = ImageDraw.Draw(text_layer)
    for line, bbox in zip(lines, line_bboxes):
        line_w = bbox[2] - bbox[0]
        line_h = bbox[3] - bbox[1]
        x = x0 + (box_w - line_w) // 2
        text_draw.text(
            (x - bbox[0], cursor_y - bbox[1]),
            line,
            fill=(*HEADLINE_COLOR, 255),
            font=font,
            stroke_width=stroke_w,
            stroke_fill=(*HEADLINE_STROKE_COLOR, 255),
        )
        cursor_y += line_h + line_gap
    canvas.alpha_composite(text_layer)


# ── Device placement ───────────────────────────────────────────────────────
def _device_layout(canvas_w: int, canvas_h: int, is_ipad: bool) -> Layout:
    headline_area_frac = HEADLINE_AREA_FRAC if is_ipad else PHONE_HEADLINE_AREA_FRAC
    headline_top_pad_frac = HEADLINE_TOP_PAD_FRAC if is_ipad else PHONE_HEADLINE_TOP_PAD_FRAC
    headline_gap_frac = HEADLINE_BOTTOM_GAP_FRAC if is_ipad else PHONE_HEADLINE_BOTTOM_GAP_FRAC

    headline_bottom = int(canvas_h * headline_area_frac)
    gap_h = int(canvas_h * headline_gap_frac)
    headline_pad_x = int(canvas_w * HEADLINE_HORIZONTAL_PAD_FRAC)
    device_pad_frac = DEVICE_HORIZONTAL_PAD_FRAC if is_ipad else PHONE_DEVICE_HORIZONTAL_PAD_FRAC
    device_pad_x = int(canvas_w * device_pad_frac)

    headline_box = (
        headline_pad_x,
        int(canvas_h * headline_top_pad_frac),
        canvas_w - headline_pad_x,
        headline_bottom,
    )
    device_box = (
        device_pad_x,
        headline_bottom + gap_h,
        canvas_w - device_pad_x,
        canvas_h - int(canvas_h * DEVICE_BOTTOM_PAD_FRAC),
    )
    return Layout(canvas_w, canvas_h, headline_box, device_box)


def _fit_device(
    device_img: Image.Image,
    box: tuple[int, int, int, int],
    *,
    fill_width: bool = False,
    align_top: bool = False,
) -> tuple[Image.Image, tuple[int, int]]:
    """Resize ``device_img`` to fit inside ``box`` preserving aspect ratio.

    Returns the resized image and the ``(x, y)`` paste origin for centering.
    """
    x0, y0, x1, y1 = box
    box_w = max(1, x1 - x0)
    box_h = max(1, y1 - y0)

    src_w, src_h = device_img.size
    scale = box_w / src_w if fill_width else min(box_w / src_w, box_h / src_h)
    new_w = max(1, int(src_w * scale))
    new_h = max(1, int(src_h * scale))

    resized = device_img.resize((new_w, new_h), Image.LANCZOS)
    paste_x = x0 + (box_w - new_w) // 2
    paste_y = y0 if align_top else y0 + (box_h - new_h) // 2
    return resized, (paste_x, paste_y)


def _alpha_composite_clipped(
    canvas: Image.Image,
    overlay: Image.Image,
    origin: tuple[int, int],
) -> None:
    """Composite ``overlay`` onto ``canvas``, cropping overflow at canvas edges."""
    px, py = origin
    x0 = max(px, 0)
    y0 = max(py, 0)
    x1 = min(px + overlay.width, canvas.width)
    y1 = min(py + overlay.height, canvas.height)
    if x1 <= x0 or y1 <= y0:
        return

    crop = overlay.crop((x0 - px, y0 - py, x1 - px, y1 - py))
    canvas.alpha_composite(crop, dest=(x0, y0))


def _round_corners(img: Image.Image, radius: int) -> Image.Image:
    """Return ``img`` with corners rounded to ``radius`` pixels (transparent
    outside the rounded shape). The original alpha channel is preserved
    inside the rounded region.
    """
    if radius <= 0:
        return img.convert("RGBA")
    rgba = img.convert("RGBA")
    mask = Image.new("L", rgba.size, 0)
    mask_draw = ImageDraw.Draw(mask)
    mask_draw.rounded_rectangle(
        [0, 0, rgba.size[0] - 1, rgba.size[1] - 1],
        radius=radius,
        fill=255,
    )
    new_alpha = ImageChops.multiply(rgba.split()[-1], mask)
    rgba.putalpha(new_alpha)
    return rgba


def _is_ipad_capture(name: str) -> bool:
    """Heuristic: device-name prefix in the filename tells us iPad vs iPhone."""
    return "ipad" in name.lower()


def _draw_side_controls(
    draw: ImageDraw.ImageDraw,
    body_box: tuple[int, int, int, int],
    gutter: int,
    is_ipad: bool,
) -> None:
    """Draw subtle protruding side controls around the device body."""
    if gutter <= 0:
        return

    x0, y0, x1, y1 = body_box
    body_w = x1 - x0 + 1
    body_h = y1 - y0 + 1
    radius = max(2, gutter // 2)

    button_color = FRAME_BUTTON_COLOR if is_ipad else IPHONE_FRAME_BUTTON_COLOR

    def button(box: tuple[int, int, int, int]) -> None:
        draw.rounded_rectangle(
            box,
            radius=radius,
            fill=button_color,
        )

    if is_ipad:
        button_len = max(36, int(body_w * 0.10))
        button_thick = max(5, gutter)
        top_y = max(0, y0 - button_thick // 2)
        left_button_x = x0 + int(body_w * 0.11)
        right_button_x = x1 - int(body_w * 0.20)
        button((left_button_x, top_y, left_button_x + button_len, y0 + button_thick))
        button((right_button_x, top_y, right_button_x + button_len, y0 + button_thick))
        return

    button_thick = max(4, gutter // 2)
    long_len = max(44, int(body_h * 0.070))
    short_len = max(24, int(body_h * 0.038))
    left_x0 = x0 - button_thick
    left_x1 = x0 + max(1, button_thick // 4)
    right_x0 = x1 - max(1, button_thick // 4)
    right_x1 = x1 + button_thick

    action_y = y0 + int(body_h * 0.15)
    volume_up_y = y0 + int(body_h * 0.245)
    volume_down_y = y0 + int(body_h * 0.325)
    sleep_y = y0 + int(body_h * 0.245)
    button((left_x0, action_y, left_x1, action_y + short_len))
    button((left_x0, volume_up_y, left_x1, volume_up_y + long_len))
    button((left_x0, volume_down_y, left_x1, volume_down_y + long_len))
    button((right_x0, sleep_y, right_x1, sleep_y + int(long_len * 1.35)))


def _draw_dynamic_island(
    framed: Image.Image,
    screen_box: tuple[int, int, int, int],
) -> None:
    """Overlay an iPhone Dynamic Island inside the captured display."""
    sx0, sy0, sx1, sy1 = screen_box
    screen_w = sx1 - sx0 + 1
    island_w = max(96, int(screen_w * IPHONE_ISLAND_WIDTH_FRAC))
    island_h = max(28, int(screen_w * IPHONE_ISLAND_HEIGHT_FRAC))
    island_x0 = sx0 + (screen_w - island_w) // 2
    island_center_y = sy0 + int(screen_w * IPHONE_ISLAND_CENTER_Y_FRAC)
    island_y0 = island_center_y - island_h // 2
    scale = 4
    pad = max(6, island_h // 8)
    layer_w = (island_w + 2 * pad) * scale
    layer_h = (island_h + 2 * pad) * scale
    layer = Image.new("RGBA", (layer_w, layer_h), (0, 0, 0, 0))
    draw = ImageDraw.Draw(layer)

    pill = (
        pad * scale,
        pad * scale,
        (pad + island_w) * scale,
        (pad + island_h) * scale,
    )

    # A tiny soft edge keeps the cutout from looking like a flat decal while
    # still reading as the black glass/sensor area on recent iPhones.
    if _HAS_GAUSSIAN_BLUR:
        shadow = Image.new("RGBA", layer.size, (0, 0, 0, 0))
        shadow_draw = ImageDraw.Draw(shadow)
        shadow_draw.rounded_rectangle(
            pill,
            radius=(island_h * scale) // 2,
            fill=(0, 0, 0, 115),
        )
        shadow = shadow.filter(ImageFilter.GaussianBlur(radius=max(2, island_h // 18) * scale))
        layer.alpha_composite(shadow)

    draw.rounded_rectangle(
        pill,
        radius=(island_h * scale) // 2,
        fill=DYNAMIC_ISLAND_COLOR,
    )

    lens_r = max(4, int(island_h * 0.105)) * scale
    lens_cx = (pad + int(island_w * 0.775)) * scale
    lens_cy = (pad + island_h // 2) * scale
    draw.ellipse(
        [lens_cx - lens_r, lens_cy - lens_r, lens_cx + lens_r, lens_cy + lens_r],
        fill=CAMERA_GLASS_COLOR,
    )
    inner_r = max(2, lens_r // 2)
    draw.ellipse(
        [lens_cx - inner_r, lens_cy - inner_r, lens_cx + inner_r, lens_cy + inner_r],
        fill=CAMERA_LENS_COLOR,
    )
    glint_r = max(1, lens_r // 5)
    draw.ellipse(
        [
            lens_cx - lens_r // 3,
            lens_cy - lens_r // 3,
            lens_cx - lens_r // 3 + glint_r,
            lens_cy - lens_r // 3 + glint_r,
        ],
        fill=(42, 62, 76, 150),
    )

    layer = layer.resize((layer_w // scale, layer_h // scale), Image.Resampling.LANCZOS)
    framed.alpha_composite(layer, dest=(island_x0 - pad, island_y0 - pad))


def _draw_iphone_hardware_frame(
    draw: ImageDraw.ImageDraw,
    body_box: tuple[int, int, int, int],
    screen_box: tuple[int, int, int, int],
    outer_radius: int,
    screen_radius: int,
    bezel: int,
) -> None:
    """Draw a more iPhone-like shell: thin side rail, black glass, display gasket."""
    x0, y0, x1, y1 = body_box
    rail_w = max(5, bezel // 5)
    glass_inset = max(3, bezel // 7)
    glass_box = (
        x0 + glass_inset,
        y0 + glass_inset,
        x1 - glass_inset,
        y1 - glass_inset,
    )
    glass_radius = max(1, outer_radius - glass_inset)

    draw.rounded_rectangle(
        body_box,
        radius=outer_radius,
        fill=IPHONE_FRAME_COLOR,
        outline=IPHONE_FRAME_EDGE_SHADOW,
        width=max(1, rail_w),
    )
    draw.rounded_rectangle(
        [
            x0 + max(1, rail_w // 2),
            y0 + max(1, rail_w // 2),
            x1 - max(1, rail_w // 2),
            y1 - max(1, rail_w // 2),
        ],
        radius=max(1, outer_radius - rail_w // 2),
        outline=IPHONE_FRAME_EDGE_HIGHLIGHT,
        width=max(1, rail_w // 2),
    )
    draw.rounded_rectangle(
        glass_box,
        radius=glass_radius,
        fill=IPHONE_FRAME_GLASS_COLOR,
    )

    gasket_outer = max(1, bezel // 4)
    draw.rounded_rectangle(
        [
            screen_box[0] - gasket_outer,
            screen_box[1] - gasket_outer,
            screen_box[2] + gasket_outer,
            screen_box[3] + gasket_outer,
        ],
        radius=screen_radius + gasket_outer,
        outline=IPHONE_FRAME_RIM_COLOR,
        width=max(2, bezel // 3),
    )
    highlight_outer = max(1, bezel // 2)
    draw.rounded_rectangle(
        [
            screen_box[0] - highlight_outer,
            screen_box[1] - highlight_outer,
            screen_box[2] + highlight_outer,
            screen_box[3] + highlight_outer,
        ],
        radius=screen_radius + highlight_outer,
        outline=IPHONE_FRAME_RIM_HIGHLIGHT,
        width=max(1, bezel // 10),
    )


def _draw_ipad_camera(
    framed: Image.Image,
    screen_box: tuple[int, int, int, int],
    bezel: int,
) -> None:
    """Draw the centered FaceTime camera in the iPad bezel."""
    sx0, sy0, sx1, _ = screen_box
    camera_r = max(4, int((sx1 - sx0 + 1) * IPAD_CAMERA_RADIUS_FRAC))
    cx = sx0 + (sx1 - sx0 + 1) // 2
    cy = max(camera_r + 2, sy0 - bezel // 2)

    draw = ImageDraw.Draw(framed)
    draw.ellipse(
        [cx - camera_r, cy - camera_r, cx + camera_r, cy + camera_r],
        fill=CAMERA_GLASS_COLOR,
    )
    glint_r = max(1, camera_r // 3)
    draw.ellipse(
        [cx - glint_r, cy - glint_r, cx, cy],
        fill=CAMERA_LENS_COLOR,
    )


def _build_device_frame(screenshot: Image.Image, is_ipad: bool) -> Image.Image:
    """Wrap ``screenshot`` in a recognizable black iPhone / iPad frame.

    The hardware is rendered procedurally instead of using frameit PNGs so the
    output stays crisp against PicStrip's dark teal gradient. iPhone captures
    get a Dynamic Island overlay; iPad captures get a tablet bezel with the
    centered camera detail.
    """
    sw, sh = screenshot.size

    if is_ipad:
        screen_radius = max(1, int(sw * IPAD_SCREEN_RADIUS_FRAC))
        bezel = max(1, int(sw * IPAD_BEZEL_FRAC))
        gutter = max(1, int(sw * IPAD_CONTROL_GUTTER_FRAC))
        outer_radius = screen_radius + bezel
    else:
        bezel = max(1, int(sw * IPHONE_BEZEL_FRAC))
        gutter = max(1, int(sw * IPHONE_CONTROL_GUTTER_FRAC))
        outer_radius = max(1, int(sw * IPHONE_OUTER_RADIUS_FRAC))
        screen_radius = max(1, outer_radius - bezel)

    body_w, body_h = sw + 2 * bezel, sh + 2 * bezel
    fw, fh = body_w + 2 * gutter, body_h + gutter
    body_x0 = gutter
    body_y0 = gutter // 2
    body_box = (body_x0, body_y0, body_x0 + body_w - 1, body_y0 + body_h - 1)
    screen_box = (
        body_x0 + bezel,
        body_y0 + bezel,
        body_x0 + bezel + sw - 1,
        body_y0 + bezel + sh - 1,
    )

    framed = Image.new("RGBA", (fw, fh), (0, 0, 0, 0))
    frame_draw = ImageDraw.Draw(framed)
    _draw_side_controls(frame_draw, body_box, gutter, is_ipad)
    if is_ipad:
        frame_draw.rounded_rectangle(
            body_box,
            radius=outer_radius,
            fill=FRAME_COLOR,
            outline=FRAME_EDGE_HIGHLIGHT,
            width=max(1, bezel // 7),
        )
        frame_draw.rounded_rectangle(
            [
                screen_box[0] - max(1, bezel // 3),
                screen_box[1] - max(1, bezel // 3),
                screen_box[2] + max(1, bezel // 3),
                screen_box[3] + max(1, bezel // 3),
            ],
            radius=screen_radius + max(1, bezel // 3),
            outline=FRAME_RIM_HIGHLIGHT,
            width=max(1, bezel // 8),
        )
        frame_draw.rounded_rectangle(
            [
                screen_box[0] - max(1, bezel // 5),
                screen_box[1] - max(1, bezel // 5),
                screen_box[2] + max(1, bezel // 5),
                screen_box[3] + max(1, bezel // 5),
            ],
            radius=screen_radius + max(1, bezel // 5),
            outline=FRAME_RIM_COLOR,
            width=max(2, bezel // 4),
        )
    else:
        _draw_iphone_hardware_frame(
            frame_draw,
            body_box,
            screen_box,
            outer_radius,
            screen_radius,
            bezel,
        )

    rounded = _round_corners(screenshot, screen_radius)
    framed.alpha_composite(rounded, dest=(screen_box[0], screen_box[1]))

    if is_ipad:
        _draw_ipad_camera(framed, screen_box, bezel)
    else:
        _draw_dynamic_island(framed, screen_box)

    return framed


def _build_silhouette(device: Image.Image, opacity: int) -> Image.Image:
    """Return an opaque-black silhouette of ``device``'s alpha shape."""
    if device.mode == "RGBA":
        alpha = device.split()[-1]
        sil = Image.new("RGBA", device.size, (0, 0, 0, 0))
        sil.putalpha(alpha.point(lambda a: opacity if a > 8 else 0))
        return sil
    return Image.new("RGBA", device.size, (0, 0, 0, opacity))


def _composite_device_shadows(
    canvas: Image.Image,
    device: Image.Image,
    origin: tuple[int, int],
) -> None:
    """Paint a two-layer drop shadow underneath the framed device.

    Layer 1 (ambient): large blur, low opacity, big offset — soft halo.
    Layer 2 (contact): small blur, higher opacity, small offset — anchor.
    """
    px, py = origin

    if not _HAS_GAUSSIAN_BLUR:
        # Fallback: a single translucent silhouette a few pixels offset.
        rect = _build_silhouette(device, 110)
        canvas.alpha_composite(rect, dest=(px, py + CONTACT_Y_OFFSET))
        return

    # Ambient halo — large, soft.
    ambient = Image.new("RGBA", canvas.size, (0, 0, 0, 0))
    ambient_silhouette = _build_silhouette(device, AMBIENT_OPACITY)
    _alpha_composite_clipped(
        ambient,
        ambient_silhouette,
        (px, py + AMBIENT_Y_OFFSET),
    )
    ambient = ambient.filter(ImageFilter.GaussianBlur(radius=AMBIENT_BLUR_RADIUS))
    canvas.alpha_composite(ambient)

    # Contact shadow — small, sharp, sits closer to the device.
    contact = Image.new("RGBA", canvas.size, (0, 0, 0, 0))
    contact_silhouette = _build_silhouette(device, CONTACT_OPACITY)
    _alpha_composite_clipped(
        contact,
        contact_silhouette,
        (px, py + CONTACT_Y_OFFSET),
    )
    contact = contact.filter(ImageFilter.GaussianBlur(radius=CONTACT_BLUR_RADIUS))
    canvas.alpha_composite(contact)


def _iter_inputs(input_dir: Path) -> Iterable[Path]:
    """Yield raw screenshots, skipping any ``*_framed.png`` siblings.

    We deliberately ignore frameit's framed output and build our own clean
    device frame in code from the raw capture.
    """
    for path in sorted(input_dir.glob("*.png")):
        if path.stem.endswith("_framed"):
            continue
        yield path


def _compose_one(
    src: Path,
    dest: Path,
    headline_text: str,
) -> None:
    with Image.open(src) as opened:
        screenshot = opened.convert("RGBA")

    is_ipad = _is_ipad_capture(src.name)
    framed_device = _build_device_frame(screenshot, is_ipad)

    # The output canvas matches the original screenshot's dimensions so
    # App Store Connect accepts it for the corresponding device class.
    canvas = Image.new("RGBA", screenshot.size, (0, 0, 0, 255))
    _draw_gradient_on(canvas, BRAND_TOP, BRAND_BOTTOM)
    _paint_top_highlight(canvas)

    layout = _device_layout(canvas.width, canvas.height, is_ipad)

    resized, origin = _fit_device(
        framed_device,
        layout.device_box,
        fill_width=not is_ipad,
        align_top=not is_ipad,
    )
    _composite_device_shadows(canvas, resized, origin)
    _alpha_composite_clipped(canvas, resized, origin)

    _draw_headline(canvas, headline_text, layout.headline_box)

    dest.parent.mkdir(parents=True, exist_ok=True)
    canvas.convert("RGB").save(dest, format="PNG", optimize=True)


def process_directory(
    input_dir: Path,
    output_dir: Path,
    locale: str,
    xcstrings_path: Path,
) -> int:
    if not input_dir.is_dir():
        print(f"error: input dir not found: {input_dir}", file=sys.stderr)
        return 1

    xcstrings_map = _load_headlines_xcstrings(xcstrings_path)

    count = 0
    for raw in _iter_inputs(input_dir):
        screen_key = _screen_key_from_filename(raw.name)
        headline = _resolve_headline(screen_key, locale, xcstrings_map)
        dest = output_dir / _ordered_output_name(raw.name)
        old_dest = output_dir / raw.name
        if old_dest != dest and old_dest.exists():
            old_dest.unlink()
        _compose_one(raw, dest, headline)
        print(f"composed {dest}")
        count += 1

    if count == 0:
        print(f"warning: no screenshots found under {input_dir}", file=sys.stderr)
    return 0


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--locale",
        default="en-US",
        help="Locale folder under fastlane/screenshots (default: en-US).",
    )
    parser.add_argument(
        "--input-dir",
        default="fastlane/screenshots",
        help="Root directory containing per-locale screenshot folders.",
    )
    parser.add_argument(
        "--output-dir",
        default=None,
        help=(
            "Override the output root. Defaults to <input-dir>/processed, "
            "with a per-locale subfolder."
        ),
    )
    parser.add_argument(
        "--headlines",
        default="fastlane/MarketingHeadlines.xcstrings",
        help="Path to the xcstrings file with localized headlines.",
    )
    args = parser.parse_args(argv)

    input_root = Path(args.input_dir)
    locale_dir = input_root / args.locale

    output_root = Path(args.output_dir) if args.output_dir else input_root / "processed"
    output_dir = output_root / args.locale

    return process_directory(
        input_dir=locale_dir,
        output_dir=output_dir,
        locale=args.locale,
        xcstrings_path=Path(args.headlines),
    )


if __name__ == "__main__":
    raise SystemExit(main())
