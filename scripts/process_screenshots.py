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
# The composition is roughly "1/3 copy on top, 2/3 framed device on bottom",
# with a clear gap between the headline block and the device so the two
# read as distinct sections rather than crowding each other. The device
# dominates — it's the hero of every screenshot.
HEADLINE_AREA_FRAC = 0.25           # top 25% — headline lives here
HEADLINE_TOP_PAD_FRAC = 0.06        # space above the headline
HEADLINE_BOTTOM_GAP_FRAC = 0.04     # breathing room between text and device
HEADLINE_HORIZONTAL_PAD_FRAC = 0.09 # 9% margin on each side of the headline
DEVICE_HORIZONTAL_PAD_FRAC = 0.04   # 4% margin on each side of the device
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
# consuming fastlane frameit's framed PNG. Frameit ships device frames with
# a baked-in metallic side reflection that reads as a white sliver against
# a dark canvas; we get cleaner, brand-friendlier results by drawing a
# matte-black rounded rectangle in code.
FRAME_COLOR = (18, 20, 22, 255)     # near-black with a faint cool tint
# Per-device tuning. ``screen_radius_frac`` and ``bezel_frac`` are expressed
# relative to the screenshot's *width* so the frame scales correctly across
# device sizes. The radii match Apple's display corner radii closely enough
# to read as native; tighter than that and the bezel looks computer-drawn.
IPHONE_SCREEN_RADIUS_FRAC = 0.046   # ≈61 px on a 1320 px-wide capture
IPHONE_BEZEL_FRAC = 0.018           # ≈24 px frame thickness
IPAD_SCREEN_RADIUS_FRAC = 0.022     # ≈45 px on a 2064 px-wide capture
IPAD_BEZEL_FRAC = 0.024             # ≈50 px frame thickness

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
    acronyms ``GPS. EXIF. TIFF.`` mixed into Arabic headlines) pass through
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
    "02_PrivacyImpact":   "GPS. EXIF. TIFF.\nAll stripped automatically.",
    "03_About":           "Four steps.\nTotal privacy.",
    "04_PhotoLoaded":     "Sensitive data\ncaught instantly.",
    "05_RedactionEditor": "Draw to hide\nanything sensitive.",
    "06_SensitiveData":   "Review what's\nbeing protected.",
    "07_ReviewAndSave":   "Export clean.\nShare confidently.",
}

DEFAULT_HEADLINE = "Share the photo.\nNot the story behind it."


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


def _text_height(draw: ImageDraw.ImageDraw, text: str, font: ImageFont.ImageFont) -> int:
    bbox = draw.textbbox((0, 0), text, font=font)
    return bbox[3] - bbox[1]


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
            line_h = _text_height(draw, "Ag", font)
            block_h = int(line_h * HEADLINE_LINE_SPACING * len(lines))
            widest = max((_text_width(draw, line, font) for line in lines), default=0)
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

    line_h = _text_height(measure_draw, "Ag", font)
    spaced_h = int(line_h * HEADLINE_LINE_SPACING)
    block_h = spaced_h * len(lines)
    cursor_y = y0 + max(0, (box_h - block_h) // 2)

    # Draw the shadow first on its own layer, blur it, then composite.
    # The shadow inherits the stroke so the diffused silhouette includes
    # the full stroked letter shape — keeps the lift effect uniform.
    if _HAS_GAUSSIAN_BLUR and HEADLINE_SHADOW_OPACITY > 0:
        shadow_layer = Image.new("RGBA", canvas.size, (0, 0, 0, 0))
        shadow_draw = ImageDraw.Draw(shadow_layer)
        sy = cursor_y
        for line in lines:
            line_w = _text_width(shadow_draw, line, font)
            x = x0 + (box_w - line_w) // 2
            shadow_draw.text(
                (x, sy + HEADLINE_SHADOW_Y_OFFSET),
                line,
                fill=(0, 0, 0, HEADLINE_SHADOW_OPACITY),
                font=font,
                stroke_width=stroke_w,
                stroke_fill=(0, 0, 0, HEADLINE_SHADOW_OPACITY),
            )
            sy += spaced_h
        shadow_layer = shadow_layer.filter(
            ImageFilter.GaussianBlur(radius=HEADLINE_SHADOW_BLUR)
        )
        canvas.alpha_composite(shadow_layer)

    # Draw the crisp white text with a near-black stroke on top.
    text_layer = Image.new("RGBA", canvas.size, (0, 0, 0, 0))
    text_draw = ImageDraw.Draw(text_layer)
    for line in lines:
        line_w = _text_width(text_draw, line, font)
        x = x0 + (box_w - line_w) // 2
        text_draw.text(
            (x, cursor_y),
            line,
            fill=(*HEADLINE_COLOR, 255),
            font=font,
            stroke_width=stroke_w,
            stroke_fill=(*HEADLINE_STROKE_COLOR, 255),
        )
        cursor_y += spaced_h
    canvas.alpha_composite(text_layer)


# ── Device placement ───────────────────────────────────────────────────────
def _device_layout(canvas_w: int, canvas_h: int) -> Layout:
    headline_bottom = int(canvas_h * HEADLINE_AREA_FRAC)
    gap_h = int(canvas_h * HEADLINE_BOTTOM_GAP_FRAC)
    headline_pad_x = int(canvas_w * HEADLINE_HORIZONTAL_PAD_FRAC)
    device_pad_x = int(canvas_w * DEVICE_HORIZONTAL_PAD_FRAC)

    headline_box = (
        headline_pad_x,
        int(canvas_h * HEADLINE_TOP_PAD_FRAC),
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
) -> tuple[Image.Image, tuple[int, int]]:
    """Resize ``device_img`` to fit inside ``box`` preserving aspect ratio.

    Returns the resized image and the ``(x, y)`` paste origin for centering.
    """
    x0, y0, x1, y1 = box
    box_w = max(1, x1 - x0)
    box_h = max(1, y1 - y0)

    src_w, src_h = device_img.size
    scale = min(box_w / src_w, box_h / src_h)
    new_w = max(1, int(src_w * scale))
    new_h = max(1, int(src_h * scale))

    resized = device_img.resize((new_w, new_h), Image.LANCZOS)
    paste_x = x0 + (box_w - new_w) // 2
    paste_y = y0 + (box_h - new_h) // 2
    return resized, (paste_x, paste_y)


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


def _build_device_frame(screenshot: Image.Image, is_ipad: bool) -> Image.Image:
    """Wrap ``screenshot`` in a minimal matte-black device frame.

    The frame is a rounded rectangle ``bezel`` pixels wider on every side
    than the screenshot, with rounded corners that match the device's
    physical display radius. The screenshot's own corners are rounded so
    they fit cleanly inside the frame's inner aperture.
    """
    sw, sh = screenshot.size

    if is_ipad:
        screen_radius = max(1, int(sw * IPAD_SCREEN_RADIUS_FRAC))
        bezel = max(1, int(sw * IPAD_BEZEL_FRAC))
    else:
        screen_radius = max(1, int(sw * IPHONE_SCREEN_RADIUS_FRAC))
        bezel = max(1, int(sw * IPHONE_BEZEL_FRAC))

    fw, fh = sw + 2 * bezel, sh + 2 * bezel
    outer_radius = screen_radius + bezel

    framed = Image.new("RGBA", (fw, fh), (0, 0, 0, 0))
    frame_draw = ImageDraw.Draw(framed)
    frame_draw.rounded_rectangle(
        [0, 0, fw - 1, fh - 1],
        radius=outer_radius,
        fill=FRAME_COLOR,
    )

    rounded = _round_corners(screenshot, screen_radius)
    framed.alpha_composite(rounded, dest=(bezel, bezel))
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
    ambient.paste(
        _build_silhouette(device, AMBIENT_OPACITY),
        (px, py + AMBIENT_Y_OFFSET),
        _build_silhouette(device, AMBIENT_OPACITY),
    )
    ambient = ambient.filter(ImageFilter.GaussianBlur(radius=AMBIENT_BLUR_RADIUS))
    canvas.alpha_composite(ambient)

    # Contact shadow — small, sharp, sits closer to the device.
    contact = Image.new("RGBA", canvas.size, (0, 0, 0, 0))
    contact.paste(
        _build_silhouette(device, CONTACT_OPACITY),
        (px, py + CONTACT_Y_OFFSET),
        _build_silhouette(device, CONTACT_OPACITY),
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

    framed_device = _build_device_frame(screenshot, _is_ipad_capture(src.name))

    # The output canvas matches the original screenshot's dimensions so
    # App Store Connect accepts it for the corresponding device class.
    canvas = Image.new("RGBA", screenshot.size, (0, 0, 0, 255))
    _draw_gradient_on(canvas, BRAND_TOP, BRAND_BOTTOM)
    _paint_top_highlight(canvas)

    layout = _device_layout(canvas.width, canvas.height)

    resized, origin = _fit_device(framed_device, layout.device_box)
    _composite_device_shadows(canvas, resized, origin)
    canvas.alpha_composite(resized, dest=origin)

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
        dest = output_dir / raw.name
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
