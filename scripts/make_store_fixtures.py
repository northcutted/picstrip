#!/usr/bin/env python3
"""Draw the fictional photos and video the App Store screenshots are taken on.

Everything here is invented: the people are drawn in code, and every name,
number, address and code is fictional (555 phone numbers, example.com and
example.org addresses, a card number from the payment test ranges, and
coordinates in a city park).  The faces are drawn with enough structure —
eyes, brows, nose shading, mouth — that Vision's face detector finds them at
the sizes a phone photo has them, which emoji are not (Vision only finds an
emoji face that fills about half of the frame).

Outputs (in ``PicStripUITests/Fixtures/``, bundled with the UI tests):

* ``store_cafe.jpg`` — two friends at a pavement café, with a phone number on
  the window, a payment card and a QR code on the table, and the location,
  camera and date a phone writes into a photo.  The photo editor, metadata and
  review screenshots.
* ``store_badge.jpg`` — a visitor with a lanyard badge (email, QR code), the
  viewfinder screenshot.
* ``store_street.mov`` — two people walking along a street past a parked car,
  talking, for the video editor screenshot.

Usage (needs Pillow, NumPy and qrcode, and ffmpeg for the movie)::

    python3 -m venv build/fixtures-venv
    build/fixtures-venv/bin/pip install pillow numpy "qrcode[pil]"
    build/fixtures-venv/bin/python scripts/make_store_fixtures.py
"""

from __future__ import annotations

import argparse
import math
import random
import shutil
import subprocess
import tempfile
import wave
from pathlib import Path

import numpy as np
import qrcode
from PIL import Image, ImageChops, ImageDraw, ImageFilter, ImageFont
from PIL.TiffImagePlugin import IFDRational

ROOT = Path(__file__).resolve().parent.parent
OUT = ROOT / "PicStripUITests" / "Fixtures"

FONT_DIR = Path("/System/Library/Fonts")
AVENIR_NEXT = FONT_DIR / "Avenir Next.ttc"
SF = FONT_DIR / "SFNS.ttf"
SF_ROUNDED = FONT_DIR / "SFNSRounded.ttf"
MENLO = FONT_DIR / "Menlo.ttc"
CHALK = FONT_DIR / "Supplemental" / "Chalkboard.ttc"
DIN = FONT_DIR / "Supplemental" / "DIN Alternate Bold.ttf"


# ── Small helpers ──────────────────────────────────────────────────────────
def font(path: Path, size: int, index: int = 0, variation: str | None = None) -> ImageFont.FreeTypeFont:
    face = ImageFont.truetype(str(path), size, index=index)
    if variation:
        try:
            face.set_variation_by_name(variation)
        except (OSError, ValueError):
            pass
    return face


def avenir(size: int, weight: str = "regular") -> ImageFont.FreeTypeFont:
    # Avenir Next.ttc: 0 Bold, 2 Demi Bold, 5 Medium, 7 Regular, 8 Heavy.
    index = {"bold": 0, "demi": 2, "medium": 5, "regular": 7, "heavy": 8}[weight]
    return font(AVENIR_NEXT, size, index=index)


def sf(size: int, weight: str = "Regular") -> ImageFont.FreeTypeFont:
    return font(SF, size, variation=weight)


def mix(a: tuple, b: tuple, t: float) -> tuple:
    return tuple(int(round(a[i] + (b[i] - a[i]) * t)) for i in range(len(a)))


def bezier(points: list, steps: int = 24) -> list:
    """Sample a quadratic or cubic Bézier curve given 3 or 4 control points."""
    out = []
    for i in range(steps + 1):
        t = i / steps
        if len(points) == 3:
            (x0, y0), (x1, y1), (x2, y2) = points
            x = (1 - t) ** 2 * x0 + 2 * (1 - t) * t * x1 + t ** 2 * x2
            y = (1 - t) ** 2 * y0 + 2 * (1 - t) * t * y1 + t ** 2 * y2
        else:
            (x0, y0), (x1, y1), (x2, y2), (x3, y3) = points
            x = (1 - t) ** 3 * x0 + 3 * (1 - t) ** 2 * t * x1 + 3 * (1 - t) * t ** 2 * x2 + t ** 3 * x3
            y = (1 - t) ** 3 * y0 + 3 * (1 - t) ** 2 * t * y1 + 3 * (1 - t) * t ** 2 * y2 + t ** 3 * y3
        out.append((x, y))
    return out


def shade(color: tuple, factor: float) -> tuple:
    return tuple(max(0, min(255, int(round(c * factor)))) for c in color[:3])


def vertical_gradient(size: tuple[int, int], top: tuple, bottom: tuple) -> Image.Image:
    w, h = size
    column = np.linspace(0, 1, h)[:, None]
    top_arr, bottom_arr = np.array(top[:3], float), np.array(bottom[:3], float)
    rows = top_arr + (bottom_arr - top_arr) * column
    arr = np.repeat(rows[:, None, :], w, axis=1)
    return Image.fromarray(arr.astype(np.uint8), "RGB")


def soft_ellipse_mask(size: tuple[int, int], box: tuple, blur: float) -> Image.Image:
    mask = Image.new("L", size, 0)
    ImageDraw.Draw(mask).ellipse(box, fill=255)
    return mask.filter(ImageFilter.GaussianBlur(blur)) if blur else mask


def paste_shadow(canvas: Image.Image, mask: Image.Image, offset: tuple[int, int], blur: float, opacity: int) -> None:
    """Darken ``canvas`` under a blurred copy of ``mask`` (an L image of canvas size)."""
    shifted = Image.new("L", canvas.size, 0)
    shifted.paste(mask, offset)
    shifted = shifted.filter(ImageFilter.GaussianBlur(blur))
    shifted = shifted.point(lambda v: v * opacity // 255)
    dark = Image.new("RGB", canvas.size, (20, 18, 16))
    canvas.paste(dark, (0, 0), shifted)


def add_grain(img: Image.Image, amount: float = 4.0, seed: int = 1) -> Image.Image:
    rng = np.random.default_rng(seed)
    arr = np.asarray(img.convert("RGB"), dtype=np.float32)
    noise = rng.normal(0, amount, arr.shape[:2])[:, :, None]
    return Image.fromarray(np.clip(arr + noise, 0, 255).astype(np.uint8), "RGB")


def vignette(img: Image.Image, strength: float = 0.18) -> Image.Image:
    w, h = img.size
    y, x = np.ogrid[:h, :w]
    d = np.sqrt(((x - w / 2) / (w / 2)) ** 2 + ((y - h / 2) / (h / 2)) ** 2) / math.sqrt(2)
    factor = 1 - strength * np.clip(d, 0, 1) ** 2
    arr = np.asarray(img.convert("RGB"), dtype=np.float32) * factor[:, :, None]
    return Image.fromarray(np.clip(arr, 0, 255).astype(np.uint8), "RGB")


def qr_image(payload: str, box: int, dark=(20, 20, 20), light=(255, 255, 255)) -> Image.Image:
    code = qrcode.QRCode(error_correction=qrcode.constants.ERROR_CORRECT_M, box_size=box, border=2)
    code.add_data(payload)
    code.make(fit=True)
    return code.make_image(fill_color=dark, back_color=light).convert("RGB")


# ── People ─────────────────────────────────────────────────────────────────
SKIN = {
    "deep": (141, 94, 66),
    "brown": (178, 122, 88),
    "tan": (205, 152, 112),
    "light": (236, 196, 170),
}


def draw_head(height: int, skin: tuple, hair: tuple, hair_style: str = "short",
              eye: tuple = (64, 42, 30), lips: tuple | None = None, smile: bool = True,
              beard: bool = False) -> Image.Image:
    """A front-facing head, ``height`` pixels from crown to chin, on a transparent canvas.

    Drawn at 4× and scaled down for clean edges.  Proportions follow a real
    face (eyes half-way down the head, a nose with a shadow side, a mouth a
    third of the way from nose to chin), which is what lets Vision find it.
    """
    s = 4
    H = height * s
    W = int(height * 0.95) * s
    pad_top = int(H * 0.06)
    canvas_h = int(H * 1.12)
    img = Image.new("RGBA", (W, canvas_h), (0, 0, 0, 0))

    cx = W / 2
    face_w = H * 0.62
    face_h = H * 0.80
    top = pad_top + H * 0.10
    cy = top + face_h / 2
    lips = lips or mix(shade(skin, 0.78), (176, 82, 84), 0.55)

    def skin_mask() -> Image.Image:
        mask = Image.new("L", (W, canvas_h), 0)
        d = ImageDraw.Draw(mask)
        d.ellipse([cx - face_w / 2, top, cx + face_w / 2, top + face_h * 0.92], fill=255)
        # jaw and chin
        d.polygon([
            (cx - face_w * 0.49, cy - face_h * 0.02), (cx + face_w * 0.49, cy - face_h * 0.02),
            (cx + face_w * 0.30, cy + face_h * 0.40), (cx + face_w * 0.12, top + face_h),
            (cx - face_w * 0.12, top + face_h), (cx - face_w * 0.30, cy + face_h * 0.40),
        ], fill=255)
        d.ellipse([cx - face_w * 0.17, top + face_h * 0.90, cx + face_w * 0.17, top + face_h * 1.01], fill=255)
        return mask.filter(ImageFilter.GaussianBlur(s * 1.2))

    # Hair behind the head (long styles)
    hair_dark = shade(hair, 0.75)
    back = ImageDraw.Draw(img)
    if hair_style in ("long", "bob"):
        length = 1.18 if hair_style == "long" else 0.92
        back.rounded_rectangle([cx - face_w * 0.64, top - face_h * 0.05, cx + face_w * 0.64, top + face_h * length],
                               radius=int(face_w * 0.35), fill=hair_dark + (255,))
    if hair_style == "bun":
        back.ellipse([cx - face_w * 0.24, top - face_h * 0.30, cx + face_w * 0.24, top + face_h * 0.06], fill=hair + (255,))

    # Neck and ears
    neck_color = shade(skin, 0.80)
    back.rounded_rectangle([cx - face_w * 0.22, cy + face_h * 0.20, cx + face_w * 0.22, canvas_h],
                           radius=int(face_w * 0.08), fill=neck_color + (255,))
    for side in (-1, 1):
        ex = cx + side * face_w * 0.49
        back.ellipse([ex - face_w * 0.08, cy - face_h * 0.06, ex + face_w * 0.08, cy + face_h * 0.13],
                     fill=shade(skin, 0.90) + (255,))

    # Skin with soft modelling: lighter centre, darker edges and under the jaw
    mask = skin_mask()
    yy, xx = np.mgrid[0:canvas_h, 0:W].astype(np.float32)
    nx = (xx - cx) / (face_w / 2)
    ny = (yy - (cy - face_h * 0.06)) / (face_h / 2)
    r = np.sqrt(nx ** 2 + (ny * 0.95) ** 2)
    light = np.clip(1.08 - 0.22 * r ** 2 - 0.05 * nx, 0.78, 1.10)
    base = np.array(skin, np.float32)[None, None, :] * light[:, :, None]
    skin_img = Image.fromarray(np.clip(base, 0, 255).astype(np.uint8), "RGB")
    img.paste(skin_img, (0, 0), mask)

    d = ImageDraw.Draw(img)
    eye_y = top + face_h * 0.47
    eye_dx = face_w * 0.21

    # Shadow under the brow ridge and either side of the nose
    soft = Image.new("L", (W, canvas_h), 0)
    sd = ImageDraw.Draw(soft)
    for side in (-1, 1):
        ex = cx + side * eye_dx
        sd.ellipse([ex - face_w * 0.15, eye_y - face_h * 0.075, ex + face_w * 0.15, eye_y + face_h * 0.055], fill=80)
    sd.polygon([(cx - face_w * 0.02, eye_y), (cx - face_w * 0.085, top + face_h * 0.68), (cx - face_w * 0.01, top + face_h * 0.68)], fill=90)
    sd.ellipse([cx - face_w * 0.10, top + face_h * 0.655, cx + face_w * 0.10, top + face_h * 0.72], fill=70)
    sd.ellipse([cx - face_w * 0.16, top + face_h * 0.86, cx + face_w * 0.16, top + face_h * 0.93], fill=40)
    soft = ImageChops.multiply(soft.filter(ImageFilter.GaussianBlur(s * 4)), mask)
    img.paste(Image.new("RGB", (W, canvas_h), shade(skin, 0.62)), (0, 0), soft)
    # Cheeks
    blush = Image.new("L", (W, canvas_h), 0)
    bd = ImageDraw.Draw(blush)
    for side in (-1, 1):
        bx = cx + side * face_w * 0.27
        bd.ellipse([bx - face_w * 0.11, top + face_h * 0.60, bx + face_w * 0.11, top + face_h * 0.72], fill=45)
    blush = ImageChops.multiply(blush.filter(ImageFilter.GaussianBlur(s * 6)), mask)
    img.paste(Image.new("RGB", (W, canvas_h), (214, 110, 110)), (0, 0), blush)

    d = ImageDraw.Draw(img)
    # Eyes
    for side in (-1, 1):
        ex = cx + side * eye_dx
        ew, eh = face_w * 0.088, face_h * 0.030
        d.ellipse([ex - ew, eye_y - eh, ex + ew, eye_y + eh], fill=(246, 242, 238, 255))
        ir = eh * 1.05
        d.ellipse([ex - ir, eye_y - ir, ex + ir, eye_y + ir], fill=eye + (255,))
        pr = ir * 0.50
        d.ellipse([ex - pr, eye_y - pr, ex + pr, eye_y + pr], fill=(16, 12, 10, 255))
        hl = ir * 0.32
        d.ellipse([ex + ir * 0.15, eye_y - ir * 0.65, ex + ir * 0.15 + hl * 2, eye_y - ir * 0.65 + hl * 2], fill=(255, 255, 255, 230))
        # lids: a lash line over the top
        d.arc([ex - ew * 1.08, eye_y - eh * 1.45, ex + ew * 1.08, eye_y + eh * 1.25], 195, 345,
              fill=(36, 24, 20, 255), width=max(2, int(s * height / 110)))
        # brows
        by = eye_y - face_h * 0.095
        d.line([(ex - side * face_w * 0.10, by + face_h * 0.012), (ex + side * face_w * 0.005, by - face_h * 0.010),
                (ex + side * face_w * 0.12, by + face_h * 0.004)],
               fill=shade(hair, 0.8) + (255,), width=max(3, int(s * height / 48)), joint="curve")

    # Nostrils
    ny0 = top + face_h * 0.685
    for side in (-1, 1):
        nx0 = cx + side * face_w * 0.045
        d.ellipse([nx0 - face_w * 0.022, ny0 - face_h * 0.008, nx0 + face_w * 0.022, ny0 + face_h * 0.012],
                  fill=shade(skin, 0.50) + (255,))

    # Mouth
    my = top + face_h * 0.80
    mw = face_w * 0.15
    if smile:
        d.chord([cx - mw, my - face_h * 0.035, cx + mw, my + face_h * 0.045], 0, 180, fill=(250, 246, 240, 255))
        d.arc([cx - mw, my - face_h * 0.035, cx + mw, my + face_h * 0.045], 0, 180, fill=lips + (255,), width=max(3, int(s * height / 55)))
        d.line([(cx - mw, my + face_h * 0.004), (cx + mw, my + face_h * 0.004)], fill=lips + (255,), width=max(2, int(s * height / 80)))
    else:
        d.chord([cx - mw, my - face_h * 0.02, cx + mw, my + face_h * 0.035], 0, 180, fill=lips + (255,))
        d.chord([cx - mw * 0.9, my - face_h * 0.03, cx + mw * 0.9, my + face_h * 0.012], 180, 360, fill=shade(lips, 0.88) + (255,))
        d.line([(cx - mw, my + face_h * 0.002), (cx + mw, my + face_h * 0.002)], fill=shade(lips, 0.6) + (255,), width=max(2, int(s * height / 90)))

    if beard:
        bm = Image.new("L", (W, canvas_h), 0)
        bdraw = ImageDraw.Draw(bm)
        bdraw.ellipse([cx - face_w * 0.46, cy - face_h * 0.02, cx + face_w * 0.46, top + face_h * 1.03], fill=255)
        bdraw.ellipse([cx - face_w * 0.40, cy - face_h * 0.12, cx + face_w * 0.40, top + face_h * 0.80], fill=0)
        bdraw.ellipse([cx - mw * 1.25, my - face_h * 0.05, cx + mw * 1.25, my + face_h * 0.06], fill=0)
        bm = ImageChops.multiply(bm.filter(ImageFilter.GaussianBlur(s * 2)), mask)
        img.paste(Image.new("RGB", (W, canvas_h), shade(hair, 0.9)), (0, 0), bm.point(lambda v: v * 200 // 255))

    # Hair on top
    hm = Image.new("L", (W, canvas_h), 0)
    hd = ImageDraw.Draw(hm)
    if hair_style == "short":
        hd.ellipse([cx - face_w * 0.56, top - face_h * 0.10, cx + face_w * 0.56, top + face_h * 0.52], fill=255)
        hd.ellipse([cx - face_w * 0.47, top + face_h * 0.16, cx + face_w * 0.47, top + face_h * 1.05], fill=0)
        hd.polygon([(cx - face_w * 0.47, top + face_h * 0.30), (cx - face_w * 0.10, top + face_h * 0.13),
                    (cx + face_w * 0.47, top + face_h * 0.26), (cx + face_w * 0.47, top + face_h * 0.5),
                    (cx - face_w * 0.47, top + face_h * 0.5)], fill=0)
    elif hair_style == "curly":
        rng = random.Random(7)
        for _ in range(70):
            a = rng.uniform(math.pi * 0.95, math.pi * 2.05)
            rr = rng.uniform(0.40, 0.58)
            px = cx + math.cos(a) * face_w * rr
            py = top + face_h * 0.30 + math.sin(a) * face_h * rr * 0.75
            br = face_w * rng.uniform(0.08, 0.13)
            hd.ellipse([px - br, py - br, px + br, py + br], fill=255)
        hd.ellipse([cx - face_w * 0.45, top + face_h * 0.17, cx + face_w * 0.45, top + face_h * 1.05], fill=0)
    else:  # long, bob, bun: hair framing the face with a side parting
        hd.ellipse([cx - face_w * 0.58, top - face_h * 0.08, cx + face_w * 0.58, top + face_h * 0.55], fill=255)
        if hair_style in ("long", "bob"):
            hd.rectangle([cx - face_w * 0.60, top + face_h * 0.25, cx - face_w * 0.42, top + face_h * (1.10 if hair_style == "long" else 0.86)], fill=255)
            hd.rectangle([cx + face_w * 0.42, top + face_h * 0.25, cx + face_w * 0.60, top + face_h * (1.10 if hair_style == "long" else 0.86)], fill=255)
        hd.ellipse([cx - face_w * 0.45, top + face_h * 0.18, cx + face_w * 0.45, top + face_h * 1.05], fill=0)
        hd.polygon([(cx - face_w * 0.45, top + face_h * 0.36), (cx - face_w * 0.05, top + face_h * 0.12),
                    (cx + face_w * 0.45, top + face_h * 0.30), (cx + face_w * 0.45, top + face_h * 0.6),
                    (cx - face_w * 0.45, top + face_h * 0.6)], fill=0)
    hm = hm.filter(ImageFilter.GaussianBlur(s * 1.5))
    # Hair with a soft highlight
    hair_arr = np.zeros((canvas_h, W, 3), np.float32) + np.array(hair, np.float32)
    hl = np.exp(-(((xx - (cx - face_w * 0.15)) / (face_w * 0.35)) ** 2 + ((yy - (top + face_h * 0.05)) / (face_h * 0.12)) ** 2))
    hair_arr = hair_arr * (1 + 0.25 * hl[:, :, None])
    img.paste(Image.fromarray(np.clip(hair_arr, 0, 255).astype(np.uint8), "RGB"), (0, 0), hm)

    out = img.resize((W // s, canvas_h // s), Image.LANCZOS)
    return out


def draw_bust(head_height: int, skin: tuple, hair: tuple, shirt: tuple, hair_style: str = "short",
              collar: str = "crew", beard: bool = False, smile: bool = True, eye=(64, 42, 30),
              jacket: tuple | None = None, length: float = 3.1) -> tuple[Image.Image, tuple[int, int]]:
    """Head and shoulders, ``length`` head heights tall.  Returns the image and the head's centre in it."""
    head = draw_head(head_height, skin, hair, hair_style, eye=eye, beard=beard, smile=smile)
    hh = head_height
    w = int(hh * 2.0)
    h = int(hh * length)
    s = 2
    img = Image.new("RGBA", (w * s, h * s), (0, 0, 0, 0))
    d = ImageDraw.Draw(img)
    cx = w * s / 2
    neck_y = head.height * 0.84 * s
    sh_y = neck_y + hh * 0.10 * s
    half = hh * 0.80 * s   # half the shoulder width
    body = shirt if jacket is None else jacket

    # The outline, left side down then right side up: the trapezius sloping from
    # the neck to the shoulder, the round of the shoulder, then the arm.
    def side(sign: int) -> list:
        neck = (cx + sign * hh * 0.22 * s, sh_y - hh * 0.10 * s)
        point = (cx + sign * half, sh_y + hh * 0.20 * s)
        slope = bezier([neck, (cx + sign * half * 0.55, sh_y - hh * 0.02 * s), (cx + sign * half * 0.92, sh_y + hh * 0.06 * s), point])
        arm_top = (cx + sign * (half + hh * 0.06 * s), sh_y + hh * 0.42 * s)
        round_ = bezier([point, (cx + sign * (half + hh * 0.07 * s), sh_y + hh * 0.26 * s), arm_top])
        # Longer figures widen a little towards the elbows.
        arm = [(cx + sign * (half + hh * (0.08 + 0.05 * max(0.0, length - 3.1)) * s), h * s)]
        return slope + round_ + arm
    left, right = side(-1), side(1)
    d.polygon(left + list(reversed(right)), fill=body + (255,))
    alpha = img.split()[3]
    # side shading and the line of each arm
    sh = Image.new("L", img.size, 0)
    sd = ImageDraw.Draw(sh)
    sd.rectangle([0, 0, cx - half * 0.80, h * s], fill=80)
    sd.rectangle([cx + half * 0.86, 0, w * s, h * s], fill=50)
    sd.ellipse([cx - half * 0.7, sh_y + hh * 0.9 * s, cx + half * 0.7, h * s * 1.3], fill=25)
    sh = ImageChops.multiply(sh.filter(ImageFilter.GaussianBlur(hh * 0.10 * s)), alpha)
    img.paste(Image.new("RGB", img.size, shade(body, 0.62)), (0, 0), sh)
    d = ImageDraw.Draw(img)
    for side in (-1, 1):
        x0 = cx + side * (half - hh * 0.30 * s)
        d.line([(x0, sh_y + hh * 0.40 * s), (x0 + side * hh * 0.03 * s, h * s)], fill=shade(body, 0.72) + (255,), width=max(2, int(hh * 0.025 * s)))
    if jacket is not None:
        # open jacket over the shirt
        d.polygon([(cx - hh * 0.30 * s, sh_y - hh * 0.04 * s), (cx + hh * 0.30 * s, sh_y - hh * 0.04 * s),
                   (cx + hh * 0.38 * s, h * s), (cx - hh * 0.38 * s, h * s)], fill=shirt + (255,))
        for side in (-1, 1):
            d.polygon([(cx + side * hh * 0.30 * s, sh_y - hh * 0.06 * s), (cx + side * hh * 0.08 * s, sh_y + hh * 0.55 * s),
                       (cx + side * hh * 0.40 * s, sh_y + hh * 0.30 * s)], fill=shade(jacket, 1.15) + (255,))
            d.line([(cx + side * hh * 0.33 * s, sh_y + hh * 0.3 * s), (cx + side * hh * 0.40 * s, h * s)], fill=shade(jacket, 0.7) + (255,), width=max(2, int(hh * 0.02 * s)))
    if collar == "crew":
        d.ellipse([cx - hh * 0.30 * s, sh_y - hh * 0.16 * s, cx + hh * 0.30 * s, sh_y + hh * 0.12 * s], fill=shade(shirt, 0.82) + (255,))
        d.ellipse([cx - hh * 0.25 * s, sh_y - hh * 0.18 * s, cx + hh * 0.25 * s, sh_y + hh * 0.07 * s], fill=shade(skin, 0.74) + (255,))
    elif collar == "v":
        d.polygon([(cx - hh * 0.25 * s, sh_y - hh * 0.10 * s), (cx, sh_y + hh * 0.30 * s),
                   (cx + hh * 0.25 * s, sh_y - hh * 0.10 * s)], fill=shade(skin, 0.76) + (255,))
    elif collar == "shirt":
        d.polygon([(cx - hh * 0.22 * s, sh_y - hh * 0.12 * s), (cx, sh_y + hh * 0.20 * s),
                   (cx + hh * 0.22 * s, sh_y - hh * 0.12 * s)], fill=shade(skin, 0.76) + (255,))
        for side in (-1, 1):
            d.polygon([(cx + side * hh * 0.25 * s, sh_y - hh * 0.16 * s), (cx + side * hh * 0.02 * s, sh_y + hh * 0.22 * s),
                       (cx + side * hh * 0.34 * s, sh_y + hh * 0.08 * s)], fill=mix(shirt, (255, 255, 255), 0.25) + (255,))
    img = img.resize((w, h), Image.LANCZOS)
    img.alpha_composite(head, (int(w / 2 - head.width / 2), 0))
    return img, (w // 2, int(head.height * 0.50))


# ── Props ──────────────────────────────────────────────────────────────────
def text_size(draw: ImageDraw.ImageDraw, text: str, face: ImageFont.FreeTypeFont) -> tuple[int, int]:
    box = draw.textbbox((0, 0), text, font=face)
    return box[2] - box[0], box[3] - box[1]


def draw_centered(draw: ImageDraw.ImageDraw, center: tuple[float, float], text: str, face, fill) -> None:
    draw.text(center, text, font=face, fill=fill, anchor="mm")


def coffee_cup(diameter: int, coffee=(150, 98, 60), cup=(250, 248, 244)) -> Image.Image:
    """A cup on a saucer seen from above at an angle, with a heart of latte art."""
    s = 3
    D = diameter * s
    img = Image.new("RGBA", (int(D * 1.55), int(D * 1.05)), (0, 0, 0, 0))
    d = ImageDraw.Draw(img)
    W, H = img.size
    cx, cy = W / 2, H / 2
    # saucer
    d.ellipse([cx - D * 0.74, cy - D * 0.36, cx + D * 0.74, cy + D * 0.44], fill=shade(cup, 0.86) + (255,))
    d.ellipse([cx - D * 0.70, cy - D * 0.38, cx + D * 0.70, cy + D * 0.38], fill=cup + (255,))
    # cup body (a short cylinder) and rim
    d.rectangle([cx - D * 0.42, cy - D * 0.16, cx + D * 0.42, cy + D * 0.14], fill=shade(cup, 0.93) + (255,))
    d.ellipse([cx - D * 0.42, cy - D * 0.02, cx + D * 0.42, cy + D * 0.28], fill=shade(cup, 0.93) + (255,))
    d.ellipse([cx - D * 0.46, cy - D * 0.42, cx + D * 0.46, cy + D * 0.06], fill=cup + (255,))
    d.ellipse([cx - D * 0.40, cy - D * 0.37, cx + D * 0.40, cy + D * 0.01], fill=coffee + (255,))
    # latte heart
    crema = (236, 214, 184)
    hx, hy, r = cx, cy - D * 0.19, D * 0.10
    d.ellipse([hx - r * 1.9, hy - r * 1.1, hx, hy + r * 0.5], fill=crema + (255,))
    d.ellipse([hx, hy - r * 1.1, hx + r * 1.9, hy + r * 0.5], fill=crema + (255,))
    d.polygon([(hx - r * 1.85, hy - r * 0.2), (hx + r * 1.85, hy - r * 0.2), (hx, hy + r * 1.3)], fill=crema + (255,))
    # handle
    d.ellipse([cx + D * 0.38, cy - D * 0.12, cx + D * 0.62, cy + D * 0.10], outline=shade(cup, 0.9) + (255,), width=int(D * 0.06))
    return img.resize((W // s, H // s), Image.LANCZOS)


def pastry_plate(width: int) -> Image.Image:
    """A plate with two cinnamon rolls."""
    s = 3
    W, H = width * s, int(width * 0.62) * s
    img = Image.new("RGBA", (W, H), (0, 0, 0, 0))
    d = ImageDraw.Draw(img)
    d.ellipse([0, H * 0.08, W, H], fill=(214, 210, 204, 255))
    d.ellipse([W * 0.03, H * 0.08, W * 0.97, H * 0.94], fill=(248, 246, 242, 255))
    dough, swirl = (196, 132, 70), (150, 88, 44)
    for cx, cy, r in ((W * 0.34, H * 0.50, W * 0.20), (W * 0.66, H * 0.54, W * 0.19)):
        d.ellipse([cx - r, cy - r * 0.62 + H * 0.05, cx + r, cy + r * 0.62 + H * 0.05], fill=shade(dough, 0.8) + (255,))
        d.ellipse([cx - r, cy - r * 0.62, cx + r, cy + r * 0.62], fill=dough + (255,))
        pts = []
        for i in range(140):
            t = i / 139 * math.pi * 5.5
            rr = r * 0.92 * (t / (math.pi * 5.5))
            pts.append((cx + math.cos(t) * rr, cy + math.sin(t) * rr * 0.62))
        d.line(pts, fill=swirl + (255,), width=int(W * 0.012), joint="curve")
        for k in range(4):  # icing drizzle
            y = cy - r * 0.35 + k * r * 0.22
            d.line([(cx - r * 0.7, y), (cx - r * 0.2, y + r * 0.08), (cx + r * 0.3, y - r * 0.05), (cx + r * 0.7, y + r * 0.05)],
                   fill=(252, 248, 240, 255), width=int(W * 0.010), joint="curve")
    return img.resize((W // s, H // s), Image.LANCZOS)


def payment_card(width: int, number: str, holder: str, bank: str) -> Image.Image:
    """A fictional bank card, front side."""
    s = 2
    W, H = width * s, int(width * 0.63) * s
    img = Image.new("RGBA", (W, H), (0, 0, 0, 0))
    grad = vertical_gradient((W, H), (34, 74, 140), (22, 40, 92))
    # diagonal sheen
    sheen = Image.new("L", (W, H), 0)
    ImageDraw.Draw(sheen).polygon([(W * 0.45, 0), (W * 0.75, 0), (W * 0.35, H), (W * 0.05, H)], fill=40)
    grad.paste(Image.new("RGB", (W, H), (255, 255, 255)), (0, 0), sheen.filter(ImageFilter.GaussianBlur(W * 0.04)))
    mask = Image.new("L", (W, H), 0)
    ImageDraw.Draw(mask).rounded_rectangle([0, 0, W - 1, H - 1], radius=int(W * 0.05), fill=255)
    img.paste(grad, (0, 0), mask)
    d = ImageDraw.Draw(img)
    d.text((W * 0.07, H * 0.09), bank, font=avenir(int(H * 0.11), "demi"), fill=(255, 255, 255, 235))
    # chip
    d.rounded_rectangle([W * 0.08, H * 0.34, W * 0.21, H * 0.53], radius=int(W * 0.012), fill=(222, 190, 112, 255))
    for k in range(1, 3):
        d.line([(W * 0.08, H * (0.34 + 0.063 * k)), (W * 0.21, H * (0.34 + 0.063 * k))], fill=(176, 144, 72, 255), width=s * 2)
    d.text((W * 0.07, H * 0.60), number, font=font(MENLO, int(H * 0.115), index=1), fill=(255, 255, 255, 255))
    d.text((W * 0.07, H * 0.82), holder, font=avenir(int(H * 0.075), "medium"), fill=(230, 236, 250, 255))
    d.text((W * 0.62, H * 0.82), "VALID THRU 08/29", font=avenir(int(H * 0.06), "medium"), fill=(230, 236, 250, 255))
    # contactless mark: three arcs
    for k in range(3):
        r = H * (0.05 + 0.035 * k)
        d.arc([W * 0.80 - r, H * 0.18 - r, W * 0.80 + r, H * 0.18 + r], -50, 50, fill=(255, 255, 255, 220), width=int(H * 0.018))
    return img.resize((W // s, H // s), Image.LANCZOS)


def table_tent(width: int, payload: str) -> Image.Image:
    """A small stand with "Scan to order" and a QR code."""
    s = 2
    W, H = width * s, int(width * 1.45) * s
    img = Image.new("RGBA", (W, H), (0, 0, 0, 0))
    d = ImageDraw.Draw(img)
    d.rounded_rectangle([0, H * 0.02, W, H * 0.97], radius=int(W * 0.05), fill=(32, 64, 54, 255))
    d.rounded_rectangle([W * 0.06, H * 0.05, W * 0.94, H * 0.93], radius=int(W * 0.04), fill=(250, 246, 236, 255))
    draw_centered(d, (W / 2, H * 0.14), "Scan to order", avenir(int(W * 0.10), "demi"), (32, 64, 54))
    qr = qr_image(payload, 10).resize((int(W * 0.74), int(W * 0.74)), Image.NEAREST)
    img.paste(qr, (int(W * 0.13), int(H * 0.24)))
    draw_centered(d, (W / 2, H * 0.84), "Table 12", avenir(int(W * 0.08), "medium"), (90, 100, 96))
    return img.resize((W // s, H // s), Image.LANCZOS)


def paper_poster(size: tuple[int, int], lines: list[tuple[str, ImageFont.FreeTypeFont, tuple]], accent=(214, 92, 60)) -> Image.Image:
    W, H = size
    img = Image.new("RGBA", (W, H), (0, 0, 0, 0))
    d = ImageDraw.Draw(img)
    d.rectangle([0, 0, W - 1, H - 1], fill=(250, 247, 238, 255))
    d.rectangle([0, 0, W - 1, int(H * 0.05)], fill=accent + (255,))
    y = H * 0.12
    for text, face, color in lines:
        if not text:
            y += face.size * 0.6
            continue
        d.text((W / 2, y), text, font=face, fill=color, anchor="ma")
        y += face.size * 1.28
    # tape
    for x in (W * 0.08, W * 0.78):
        d.rectangle([x, -2, x + W * 0.16, H * 0.035], fill=(236, 226, 196, 210))
    return img


# ── The café photo ─────────────────────────────────────────────────────────
def cafe_photo(size=(1536, 2048), interior_blur: float = 9, head_h: int = 300) -> Image.Image:
    W, H = size
    img = Image.new("RGB", size, (36, 70, 60))
    d = ImageDraw.Draw(img)
    facade = (34, 70, 60)
    # Awning across the top: cream and green stripes, scalloped edge
    awning_h = 150
    stripe = 96
    for i in range(0, W + stripe, stripe):
        color = (240, 232, 214) if (i // stripe) % 2 == 0 else (46, 112, 92)
        d.rectangle([i, 0, i + stripe, awning_h], fill=color)
        d.pieslice([i, awning_h - stripe // 2, i + stripe, awning_h + stripe // 2], 0, 180, fill=color)
    shadow = Image.new("L", size, 0)
    ImageDraw.Draw(shadow).rectangle([0, awning_h + stripe // 2, W, awning_h + stripe // 2 + 60], fill=120)
    img.paste((20, 40, 34), (0, 0), shadow.filter(ImageFilter.GaussianBlur(30)))
    d = ImageDraw.Draw(img)
    # Sign over the window
    sign_y = 255
    gold = (226, 190, 110)
    d.text((W / 2, sign_y), "JUNIPER & RYE", font=font(FONT_DIR / "Supplemental" / "Georgia Bold.ttf", 92), fill=gold, anchor="mm")
    d.text((W / 2, sign_y + 78), "COFFEE  ·  BAKERY  ·  SINCE 2009", font=avenir(34, "demi"), fill=shade(gold, 0.9), anchor="mm")
    # Window: warm interior, blurred, with reflections
    wx0, wy0, wx1, wy1 = 90, 380, W - 90, 1240
    interior = vertical_gradient((wx1 - wx0, wy1 - wy0), (92, 74, 58), (150, 112, 74))
    idr = ImageDraw.Draw(interior)
    iw, ih = interior.size
    for k in range(4):  # shelves with jars
        y = 140 + k * 150
        idr.rectangle([60, y, iw - 60, y + 14], fill=(70, 48, 32))
        rng = random.Random(k)
        x = 80
        while x < iw - 120:
            jw = rng.randint(40, 80)
            jh = rng.randint(50, 110)
            col = rng.choice([(196, 160, 110), (230, 210, 170), (120, 150, 120), (170, 90, 60), (90, 110, 140)])
            idr.rounded_rectangle([x, y - jh, x + jw, y], radius=8, fill=col)
            x += jw + rng.randint(14, 40)
    for k in range(3):  # pendant lights
        lx = iw * (0.2 + 0.3 * k)
        idr.line([(lx, 0), (lx, 70)], fill=(40, 30, 24), width=4)
        idr.ellipse([lx - 46, 60, lx + 46, 110], fill=(255, 226, 160))
    interior = interior.filter(ImageFilter.GaussianBlur(interior_blur))
    glow = Image.new("L", interior.size, 0)
    gd = ImageDraw.Draw(glow)
    for k in range(3):
        lx = iw * (0.2 + 0.3 * k)
        gd.ellipse([lx - 160, -40, lx + 160, 260], fill=90)
    interior.paste((255, 214, 150), (0, 0), glow.filter(ImageFilter.GaussianBlur(60)))
    refl = Image.new("L", interior.size, 0)
    rd = ImageDraw.Draw(refl)
    rd.polygon([(iw * 0.05, 0), (iw * 0.22, 0), (iw * 0.02, ih), (0, ih), (0, ih * 0.6)], fill=60)
    rd.polygon([(iw * 0.55, 0), (iw * 0.62, 0), (iw * 0.40, ih), (iw * 0.33, ih)], fill=45)
    interior.paste((255, 255, 255), (0, 0), refl.filter(ImageFilter.GaussianBlur(25)))
    img.paste(interior, (wx0, wy0))
    d = ImageDraw.Draw(img)
    d.rectangle([wx0 - 18, wy0 - 18, wx1 + 18, wy1 + 18], outline=shade(facade, 0.7), width=18)
    d.line([(W / 2, wy0), (W / 2, wy1)], fill=shade(facade, 0.7), width=16)
    # Poster taped inside the window, right pane, with a phone number
    poster = paper_poster((330, 440), [
        ("OPEN MIC", avenir(60, "heavy"), (214, 92, 60)),
        ("Fridays · 7 pm", avenir(34, "demi"), (60, 50, 44)),
        ("", avenir(30), (0, 0, 0)),
        ("To sign up, call", avenir(30, "medium"), (60, 50, 44)),
        ("415-555-0136", avenir(44, "bold"), (30, 26, 24)),
    ])
    poster = poster.rotate(1.5, resample=Image.BICUBIC, expand=True)
    img.paste(poster, (W - 90 - 360, 430), poster)
    # Pavement
    d.rectangle([0, wy1 + 18, W, H], fill=(178, 172, 164))
    for y in range(wy1 + 60, H, 90):
        d.line([(0, y), (W, y)], fill=(160, 154, 146), width=3)
    # Chairs' backs behind the people
    for cx in (520, 1016):
        d.rounded_rectangle([cx - 230, 1090, cx + 230, 1400], radius=40, fill=(46, 54, 58))
        d.rounded_rectangle([cx - 200, 1110, cx + 200, 1380], radius=30, fill=(64, 74, 80))
    # The two friends
    people = [
        (dict(skin=SKIN["brown"], hair=(36, 26, 20), shirt=(232, 196, 92), hair_style="curly", collar="crew"), (520, 860)),
        (dict(skin=SKIN["light"], hair=(150, 96, 52), shirt=(70, 120, 170), hair_style="long", collar="v", jacket=(52, 58, 72)), (1016, 880)),
    ]
    pass
    for spec, (hx, hy) in people:
        bust, (bx, by) = draw_bust(head_h, **spec)
        img.paste(bust, (hx - bx, hy - by), bust)
    # Table: round marble top in perspective
    tcx, tcy, trx, try_ = W / 2, 1660, 860, 330
    table = Image.new("RGBA", size, (0, 0, 0, 0))
    td = ImageDraw.Draw(table)
    td.ellipse([tcx - trx, tcy - try_ + 34, tcx + trx, tcy + try_ + 34], fill=(150, 146, 140, 255))
    td.ellipse([tcx - trx, tcy - try_, tcx + trx, tcy + try_], fill=(238, 236, 232, 255))
    marble = Image.new("L", size, 0)
    md = ImageDraw.Draw(marble)
    rng = random.Random(3)
    for _ in range(14):
        x = rng.uniform(tcx - trx, tcx + trx)
        y = rng.uniform(tcy - try_, tcy + try_)
        pts = [(x, y)]
        for _ in range(6):
            x += rng.uniform(40, 140)
            y += rng.uniform(-30, 30)
            pts.append((x, y))
        md.line(pts, fill=60, width=3, joint="curve")
    marble = marble.filter(ImageFilter.GaussianBlur(2))
    top_mask = Image.new("L", size, 0)
    ImageDraw.Draw(top_mask).ellipse([tcx - trx, tcy - try_, tcx + trx, tcy + try_], fill=255)
    table.paste((170, 166, 160, 255), (0, 0), ImageChops.multiply(marble, top_mask))
    img.paste(table, (0, 0), table)
    # Things on the table, each with a soft shadow
    def put(item: Image.Image, center: tuple[int, int], shadow_opacity: int = 90) -> None:
        x, y = int(center[0] - item.width / 2), int(center[1] - item.height / 2)
        paste_shadow(img, item.split()[3], (x + 10, y + 16), 14, shadow_opacity)
        img.paste(item, (x, y), item)
    put(coffee_cup(230), (430, 1440))
    put(coffee_cup(230, coffee=(120, 76, 46)), (1120, 1450))
    put(pastry_plate(380), (775, 1480))
    card = payment_card(560, "4242 4242 4242 4242", "JORDAN RIVERA", "Harbor Bank")
    card = card.rotate(-3, resample=Image.BICUBIC, expand=True)
    put(card, (520, 1760), 110)
    tent = table_tent(250, "https://order.example.org/juniper-rye/table-12")
    put(tent, (1150, 1690), 120)
    img = vignette(img, 0.22)
    return add_grain(img, 3.0)


# ── The visitor with a badge (viewfinder) ──────────────────────────────────
def visitor_badge(width: int, name: str, email: str, payload: str, accent=(232, 96, 64)) -> Image.Image:
    """A conference-style lanyard badge: company, VISITOR, a name, an email and a QR code."""
    s = 2
    W, H = width * s, int(width * 1.42) * s
    img = Image.new("RGBA", (W, H), (0, 0, 0, 0))
    d = ImageDraw.Draw(img)
    d.rounded_rectangle([0, 0, W - 1, H - 1], radius=int(W * 0.06), fill=(252, 252, 250, 255))
    d.rounded_rectangle([0, 0, W - 1, H * 0.20], radius=int(W * 0.06), fill=(28, 44, 66, 255))
    d.rectangle([0, H * 0.12, W - 1, H * 0.20], fill=(28, 44, 66, 255))
    # slot for the clip
    d.rounded_rectangle([W * 0.40, H * 0.035, W * 0.60, H * 0.065], radius=int(W * 0.02), fill=(200, 205, 212, 255))
    draw_centered(d, (W / 2, H * 0.135), "BRIGHTLINE STUDIO", avenir(int(W * 0.075), "demi"), (255, 255, 255))
    d.rectangle([0, H * 0.20, W - 1, H * 0.29], fill=accent + (255,))
    draw_centered(d, (W / 2, H * 0.245), "VISITOR", avenir(int(W * 0.10), "heavy"), (255, 255, 255))
    draw_centered(d, (W / 2, H * 0.355), name, avenir(int(W * 0.105), "bold"), (24, 30, 40))
    draw_centered(d, (W / 2, H * 0.425), email, avenir(int(W * 0.062), "demi"), (60, 66, 76))
    qr = qr_image(payload, 10).resize((int(W * 0.50), int(W * 0.50)), Image.NEAREST)
    img.paste(qr, (int(W * 0.25), int(H * 0.49)))
    draw_centered(d, (W / 2, H * 0.90), "Oct 14 · Level 3", avenir(int(W * 0.055), "medium"), (110, 116, 126))
    return img.resize((W // s, H // s), Image.LANCZOS)


def lobby_background(size: tuple[int, int]) -> Image.Image:
    """A bright office lobby, far out of focus."""
    W, H = size
    img = vertical_gradient(size, (226, 232, 236), (196, 186, 172))
    d = ImageDraw.Draw(img)
    # tall windows on the left, a wooden slat wall on the right
    for k in range(3):
        x = 40 + k * 260
        d.rectangle([x, 120, x + 220, H * 0.72], fill=(242, 248, 252))
        d.rectangle([x + 20, 140, x + 200, H * 0.72 - 20], fill=(200, 222, 236))
        d.rectangle([x + 20, H * 0.48, x + 200, H * 0.72 - 20], fill=(150, 176, 150))  # trees outside
    for k in range(18):
        x = W * 0.58 + k * 38
        d.rectangle([x, 60, x + 24, H * 0.78], fill=(176, 128, 84) if k % 2 else (196, 146, 98))
    # plants
    rng = random.Random(11)
    for cx, cy in ((W * 0.08, H * 0.80), (W * 0.93, H * 0.74)):
        for _ in range(26):
            r = rng.uniform(40, 90)
            x = cx + rng.uniform(-120, 120)
            y = cy + rng.uniform(-260, 60)
            d.ellipse([x - r, y - r, x + r, y + r], fill=rng.choice([(62, 120, 72), (84, 146, 88), (46, 98, 60)]))
        d.rectangle([cx - 90, cy + 60, cx + 90, H], fill=(70, 70, 76))
    # ceiling lights
    for k in range(5):
        x = W * (0.1 + 0.2 * k)
        d.ellipse([x - 60, 20, x + 60, 60], fill=(255, 250, 236))
    # floor
    d.rectangle([0, H * 0.80, W, H], fill=(182, 170, 156))
    img = img.filter(ImageFilter.GaussianBlur(26))
    # bokeh highlights
    glow = Image.new("L", size, 0)
    gd = ImageDraw.Draw(glow)
    for _ in range(18):
        x, y, r = rng.uniform(0, W), rng.uniform(0, H * 0.6), rng.uniform(20, 55)
        gd.ellipse([x - r, y - r, x + r, y + r], fill=rng.randint(40, 90))
    img.paste((255, 252, 240), (0, 0), glow.filter(ImageFilter.GaussianBlur(6)))
    return img


def badge_photo(size=(1536, 2048)) -> Image.Image:
    W, H = size
    img = lobby_background(size)
    hh = 420
    bust, (bx, by) = draw_bust(hh, skin=SKIN["tan"], hair=(46, 32, 26), shirt=(236, 236, 230), hair_style="short",
                               collar="shirt", beard=True, jacket=(54, 84, 120), length=4.4)
    hx, hy = int(W * 0.50), int(H * 0.27)
    img.paste(bust, (hx - bx, hy - by), bust)
    d = ImageDraw.Draw(img)
    # Lanyard from behind the neck to the badge
    badge = visitor_badge(420, "Sam Ortiz", "sam.ortiz@example.com", "https://example.org/visit/sam-ortiz")
    badge_x, badge_y = hx - badge.width // 2 + 10, int(H * 0.55)
    strap = (232, 96, 64)
    for side in (-1, 1):
        d.line([(hx + side * hh * 0.18, hy + hh * 0.42), (hx + side * 40 + 10, badge_y + 18)], fill=strap, width=22)
    d.rounded_rectangle([hx - 14 + 10, badge_y - 30, hx + 14 + 10, badge_y + 26], radius=6, fill=(180, 186, 194))
    paste_shadow(img, badge.split()[3], (badge_x + 8, badge_y + 14), 16, 110)
    img.paste(badge, (badge_x, badge_y), badge)
    img = vignette(img, 0.16)
    return add_grain(img, 2.5, seed=2)


# ── The street video ───────────────────────────────────────────────────────
def street_background(size: tuple[int, int]) -> Image.Image:
    W, H = size
    img = vertical_gradient(size, (170, 206, 232), (214, 230, 238))
    d = ImageDraw.Draw(img)
    # buildings across the back
    d.rectangle([0, 40, W * 0.46, H * 0.70], fill=(196, 120, 92))          # brick
    d.rectangle([W * 0.46, 10, W * 0.78, H * 0.70], fill=(232, 220, 196))  # cream
    d.rectangle([W * 0.78, 70, W, H * 0.70], fill=(110, 134, 150))        # slate
    # bakery front in the cream building
    d.rectangle([W * 0.48, H * 0.30, W * 0.76, H * 0.70], fill=(60, 52, 48))
    d.rectangle([W * 0.495, H * 0.33, W * 0.745, H * 0.68], fill=(214, 176, 120))
    d.text((W * 0.62, H * 0.24), "GOLDEN CRUMB", font=font(FONT_DIR / "Supplemental" / "Georgia Bold.ttf", 34), fill=(120, 70, 40), anchor="mm")
    # awning
    for i in range(8):
        x0 = W * 0.47 + i * (W * 0.30 / 8)
        d.polygon([(x0, H * 0.27), (x0 + W * 0.30 / 8, H * 0.27), (x0 + W * 0.30 / 8 + 6, H * 0.33), (x0 + 6, H * 0.33)],
                  fill=(200, 64, 52) if i % 2 == 0 else (248, 240, 228))
    # windows on the brick and slate buildings
    for row in range(3):
        for col in range(4):
            x = 30 + col * 140
            y = 70 + row * 110
            d.rectangle([x, y, x + 90, y + 80], fill=(150, 186, 210))
            d.rectangle([x, y + 80, x + 90, y + 88], fill=(236, 226, 214))
        for col in range(2):
            x = W * 0.80 + col * 120
            y = 100 + row * 110
            d.rectangle([x, y, x + 80, y + 76], fill=(196, 216, 230))
    # tree on the left, behind the lamppost
    d.rectangle([W * 0.045, H * 0.30, W * 0.06, H * 0.80], fill=(96, 72, 54))
    rng = random.Random(5)
    for _ in range(40):
        r = rng.uniform(40, 80)
        x = W * 0.05 + rng.uniform(-110, 110)
        y = H * 0.20 + rng.uniform(-110, 70)
        d.ellipse([x - r, y - r, x + r, y + r], fill=rng.choice([(70, 132, 70), (92, 154, 84), (56, 112, 62)]))
    # pavement and the street
    d.rectangle([0, H * 0.70, W, H], fill=(196, 192, 186))
    d.rectangle([0, H * 0.70, W, H * 0.72], fill=(170, 166, 160))
    # parked car at the right, behind the people
    car_y = H * 0.70
    cx0 = W * 0.70
    d.rounded_rectangle([cx0, car_y - 120, cx0 + 360, car_y - 30], radius=30, fill=(52, 110, 160))
    d.polygon([(cx0 + 60, car_y - 120), (cx0 + 110, car_y - 185), (cx0 + 260, car_y - 185), (cx0 + 320, car_y - 120)], fill=(52, 110, 160))
    d.polygon([(cx0 + 80, car_y - 122), (cx0 + 120, car_y - 172), (cx0 + 180, car_y - 172), (cx0 + 180, car_y - 122)], fill=(190, 216, 232))
    d.polygon([(cx0 + 192, car_y - 122), (cx0 + 192, car_y - 172), (cx0 + 252, car_y - 172), (cx0 + 300, car_y - 122)], fill=(190, 216, 232))
    for wx in (cx0 + 80, cx0 + 290):
        d.ellipse([wx - 38, car_y - 70, wx + 38, car_y + 6], fill=(34, 34, 38))
        d.ellipse([wx - 18, car_y - 50, wx + 18, car_y - 14], fill=(170, 170, 176))
    # lamppost with a flyer
    lx = W * 0.20
    d.rectangle([lx - 7, H * 0.08, lx + 7, H * 0.80], fill=(46, 52, 58))
    d.ellipse([lx - 28, H * 0.05, lx + 28, H * 0.12], fill=(46, 52, 58))
    flyer = paper_poster((210, 240), [
        ("LOST CAT", avenir(34, "heavy"), (200, 60, 50)),
        ("Grey tabby, \"Miso\"", avenir(18, "demi"), (60, 50, 44)),
        ("", avenir(12), (0, 0, 0)),
        ("Please call", avenir(18, "medium"), (60, 50, 44)),
        ("", avenir(10), (0, 0, 0)),
        ("415-555-0172", avenir(24, "bold"), (30, 26, 24)),
    ], accent=(200, 60, 50))
    img.paste(flyer, (int(lx - 105), int(H * 0.29)), flyer)
    img = img.filter(ImageFilter.GaussianBlur(1.2))
    return img


def street_frames(size=(1280, 720), seconds: float = 6.0, fps: int = 30):
    """Yields the frames of two friends walking towards the camera and to the left."""
    W, H = size
    background = street_background(size)
    hh = 150
    walkers = [
        (draw_bust(hh, skin=SKIN["deep"], hair=(30, 22, 18), shirt=(240, 196, 76), hair_style="curly", collar="crew", length=4.0),
         (0.56, 0.40), (0.40, 0.42)),
        (draw_bust(hh, skin=SKIN["light"], hair=(200, 160, 100), shirt=(64, 130, 120), hair_style="bob", collar="v",
                   jacket=(150, 80, 70), length=4.0), (0.79, 0.41), (0.63, 0.43)),
    ]
    total = int(seconds * fps)
    for frame in range(total):
        t = frame / max(total - 1, 1)
        img = background.copy()
        for k, ((bust, (bx, by)), start, end) in enumerate(walkers):
            scale = 1.0 + 0.10 * t
            bob = math.sin((t * seconds * 2 + k * 0.5) * math.pi) * 5
            sprite = bust.resize((int(bust.width * scale), int(bust.height * scale)), Image.LANCZOS)
            x = (start[0] + (end[0] - start[0]) * t) * W - bx * scale
            y = (start[1] + (end[1] - start[1]) * t) * H - by * scale + bob
            img.paste(sprite, (int(x), int(y)), sprite)
        yield add_grain(img, 2.0, seed=frame)


def speech_track(path: Path, seconds: float, rate: int = 44_100) -> None:
    """A voice-like mono track: voiced syllables in phrases, with pauses."""
    n = int(seconds * rate)
    t = np.arange(n) / rate
    rng = np.random.default_rng(4)
    env = np.zeros(n)
    pos = 0.15
    while pos < seconds - 0.2:
        phrase = rng.uniform(0.9, 1.6)
        end = min(pos + phrase, seconds - 0.1)
        while pos < end:
            length = rng.uniform(0.10, 0.22)
            i0, i1 = int(pos * rate), int(min(pos + length, seconds) * rate)
            win = np.hanning(max(i1 - i0, 2))
            env[i0:i1] = np.maximum(env[i0:i1], win * rng.uniform(0.45, 1.0))
            pos += length + rng.uniform(0.02, 0.08)
        pos += rng.uniform(0.25, 0.45)
    pitch = 150 + 25 * np.sin(2 * np.pi * 0.7 * t)
    phase = 2 * np.pi * np.cumsum(pitch) / rate
    voice = sum(np.sin(phase * k) / k for k in range(1, 9))
    signal = 0.32 * env * voice / 2.0 + 0.004 * rng.normal(size=n)
    pcm = np.clip(signal * 32767, -32767, 32767).astype("<i2")
    with wave.open(str(path), "wb") as out:
        out.setnchannels(1)
        out.setsampwidth(2)
        out.setframerate(rate)
        out.writeframes(pcm.tobytes())


def street_movie(path: Path, size=(1280, 720), seconds: float = 6.0, fps: int = 30) -> None:
    ffmpeg = shutil.which("ffmpeg")
    if ffmpeg is None:
        raise SystemExit("ffmpeg is needed to make the movie (brew install ffmpeg)")
    with tempfile.TemporaryDirectory() as tmp:
        tmp = Path(tmp)
        for index, frame in enumerate(street_frames(size, seconds, fps)):
            frame.save(tmp / f"f{index:04d}.png")
        speech_track(tmp / "voice.wav", seconds)
        subprocess.run([
            ffmpeg, "-loglevel", "error", "-y", "-framerate", str(fps), "-i", str(tmp / "f%04d.png"),
            "-i", str(tmp / "voice.wav"), "-c:v", "libx264", "-pix_fmt", "yuv420p", "-crf", "22",
            "-preset", "slow", "-tag:v", "avc1", "-c:a", "aac", "-b:a", "96k", "-shortest",
            "-movflags", "+faststart", str(path),
        ], check=True)


def camera_exif() -> Image.Exif:
    """What a phone writes into a photo: where (to the metre), when, and on what."""
    exif = Image.Exif()
    exif[0x010F] = "Apple"                      # Make
    exif[0x0110] = "iPhone 17 Pro"              # Model
    exif[0x0131] = "26.0"                       # Software
    exif[0x0132] = "2026:09:19 10:42:17"        # DateTime
    details = exif.get_ifd(0x8769)              # Exif
    details[0x9003] = "2026:09:19 10:42:17"     # DateTimeOriginal
    details[0x9004] = "2026:09:19 10:42:17"     # DateTimeDigitized
    details[0x9011] = "-07:00"                  # OffsetTimeOriginal
    details[0x829A] = IFDRational(1, 240)       # ExposureTime
    details[0x829D] = IFDRational(178, 100)     # FNumber
    details[0x8827] = 64                        # ISOSpeedRatings
    details[0x920A] = IFDRational(686, 100)     # FocalLength
    details[0xA405] = 24                        # FocalLengthIn35mmFilm
    details[0xA433] = "Apple"                   # LensMake
    details[0xA434] = "iPhone 17 Pro back triple camera 6.86mm f/1.78"
    # Where it was taken, to a few metres: a bench in a city park.  Only the
    # coordinates (ImageIO lists fields by name, and a GPS time would bring a
    # DateStamp in ahead of them), so the location panel opens on them.
    gps = exif.get_ifd(0x8825)
    gps[1] = "N"
    gps[2] = (37.0, 45.0, 34.38)
    gps[3] = "W"
    gps[4] = (122.0, 25.0, 36.84)
    return exif


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--out", type=Path, default=OUT)
    parser.add_argument("--only", choices=["cafe", "badge", "street"], action="append")
    args = parser.parse_args()
    args.out.mkdir(parents=True, exist_ok=True)
    only = set(args.only or ["cafe", "badge", "street"])
    if "cafe" in only:
        cafe_photo().save(args.out / "store_cafe.jpg", quality=90, exif=camera_exif().tobytes())
    if "badge" in only:
        badge_photo().save(args.out / "store_badge.jpg", quality=90)
    if "street" in only:
        street_movie(args.out / "store_street.mov")
    for name in sorted(args.out.iterdir()):
        print(f"{name.relative_to(ROOT) if name.is_relative_to(ROOT) else name}: {name.stat().st_size:,} bytes")


if __name__ == "__main__":
    main()
