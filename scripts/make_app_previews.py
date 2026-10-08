#!/usr/bin/env python3
"""Make PicStrip's App Store app previews.

Each preview is a screen recording of the app itself on the simulator, played
by the UI test ``testAppPreviewFlow`` (PicStripUITests) on the store-screenshot
fixtures. The test writes a mark at every step; this script records the
simulator's screen while the test runs, cuts the recording at those marks (a
little faster where waiting would drag), lets the recording fill the picture
with a one-line caption on a translucent band over the status bar (App Review
guideline 2.3.4: screen captures of the app, with text overlays; --framed
puts it in the screenshots' device frame instead, for comparison), and encodes
the result to Apple's App Preview specification:

    iPhone 6.9" (Dynamic Island, large)  886 x 1920   iPhone 18 Pro Max
    iPad 13"                             1200 x 1600  iPad Pro 13-inch (M5)

    H.264 High Profile level 4.0, 30 fps, about 11 Mbit/s, progressive,
    with a silent stereo AAC track (256 kbit/s, 48 kHz); 15 to 30 seconds.

The scenes are in STORYBOARD: faces found, covered and followed in the street
video; a stretch of sound bleeped; the live viewfinder outlining a badge; the
café photo's location and camera details; and the review before sharing.
Captions are line 1 of the matching screenshot headline in
fastlane/MarketingHeadlines.xcstrings, so they read the same as the
screenshots; the bleep scene has no screenshot and takes its caption from
CAPTIONS.

Writes PicStrip-preview-<locale>-iphone.mp4 and ...-ipad.mp4 to
~/Desktop/PicStrip App Previews/, and a poster frame (the frame at
POSTER_SECONDS, which scripts/upload_creative_assets.py --previews names as
the poster) and a contact sheet of each to previews/ there. Recordings and
intermediate clips stay in build/app-previews/.

    python3 -m venv build/preview-venv
    build/preview-venv/bin/pip install --require-hashes -r scripts/requirements.txt
    build/preview-venv/bin/python scripts/make_app_previews.py                 # record and compose both
    build/preview-venv/bin/python scripts/make_app_previews.py --compose-only  # re-cut the last recordings
    build/preview-venv/bin/python scripts/make_app_previews.py --device ipad   # one device

It needs Xcode 27.0 (DEVELOPER_DIR, by default /Applications/Xcode.app), the
iOS 27.0 simulators above (or --simulator iphone=<UDID>), and ffmpeg and
ffprobe with libx264 on PATH or in /opt/homebrew/bin.
"""
from __future__ import annotations

import argparse
from dataclasses import dataclass
import json
import math
import os
from pathlib import Path
import re
import shutil
import signal
import subprocess
import sys
import time

from PIL import Image, ImageChops, ImageDraw, ImageFilter, ImageFont

SCRIPTS = Path(__file__).resolve().parent
ROOT = SCRIPTS.parent
sys.path.insert(0, str(SCRIPTS))

import process_screenshots as shots  # noqa: E402  (palette, headline catalog, fonts, device frames)

CONFIG = json.loads((ROOT / ".github" / "ios-release.json").read_text())
OUT = Path.home() / "Desktop" / "PicStrip App Previews"
WORK = ROOT / "build" / "app-previews"
HEADLINES = ROOT / "fastlane" / "MarketingHeadlines.xcstrings"
# Shared with PicStripUITests.previewFolder: the test runs only while
# request.json is there, and writes marks.jsonl beside it.
HANDOFF = Path("/tmp/picstrip_app_preview")
TEST = "PicStripUITests/PicStripUITests/testAppPreviewFlow"

FPS = 30
MIN_SECONDS, MAX_SECONDS = 15.0, 30.0
VIDEO_BITRATE = "11M"
# The frame App Store Connect shows before the preview plays: the street video
# with one face blurred, the other in sunglasses and the flyer's number covered.
# scripts/upload_creative_assets.py --previews uses the same time by default.
POSTER_SECONDS = 7.0


# ── Devices ────────────────────────────────────────────────────────────────
@dataclass(frozen=True)
class Device:
    key: str
    simulator: str
    size: tuple[int, int]
    is_ipad: bool


DEVICES = {
    "iphone": Device("iphone", "iPhone 18 Pro Max", (886, 1920), False),
    "ipad": Device("ipad", "iPad Pro 13-inch (M5)", (1200, 1600), True),
}


# ── Storyboard ─────────────────────────────────────────────────────────────
@dataclass(frozen=True)
class Clip:
    """A stretch of the recording between two marks the UI test wrote.

    ``start`` and ``end`` are mark names, optionally shifted in seconds
    ("video.found+1"). ``seconds`` is how long it lasts in the preview: to
    fit, the moments the screen stands still are shortened first, then the
    whole stretch plays faster (see retime); a short one holds its last frame.
    ``fade`` crossfades into it from the clip before; 0 cuts.
    """
    start: str
    end: str
    seconds: float
    fade: float = 0.0


@dataclass(frozen=True)
class Scene:
    caption: str  # a MarketingHeadlines.xcstrings key (line 1 is used) or a CAPTIONS key
    clips: tuple[Clip, ...]


SCENE_FADE = 0.4
STORYBOARD: tuple[Scene, ...] = (
    # The street video scanned (faces and the flyer's number outlined), then the
    # editor: Face 2's clip held for its covers and given 😎, and the timeline
    # tapped along so both covers are seen following the faces.
    Scene("01_VideoEditor", (
        Clip("video.found+0.5", "video.found+3.5", 2.0),
        Clip("video.hold-0.5", "video.emoji", 5.5, fade=0.3),
        Clip("video.follow0-0.2", "video.follow3", 3.6),
    )),
    # A stretch of the audio lane held and dragged across, and Bleep chosen.
    Scene("bleep", (Clip("bleep.hold-0.3", "bleep.end", 4.2, fade=SCENE_FADE),)),
    # Photo mode outlining the visitor's face, email and QR code, then the
    # preview of them covered.
    Scene("03_Viewfinder", (
        Clip("viewfinder.start-0.6", "viewfinder.found", 3.0, fade=SCENE_FADE),
        Clip("viewfinder.covered-1.6", "viewfinder.end", 2.2, fade=0.2),
    )),
    # The café photo's Location, then Camera & date, listed to be removed.
    Scene("02_Location", (Clip("location.start-0.5", "location.end+0.3", 4.2, fade=SCENE_FADE),)),
    # Review & Share: the summary (location removed), held to compare with the
    # original, let go.
    Scene("05_ReviewAndShare", (Clip("review.sheet-0.6", "review.end", 4.6, fade=SCENE_FADE),)),
)

# Captions that have no screenshot headline, per store locale.
CAPTIONS: dict[str, dict[str, str]] = {
    "bleep": {"en-US": "Bleep what was said"},
}

# Store locale → catalog code in the .xcstrings files (as in make_creative_assets.py).
STORE_LOCALES: dict[str, str] = {
    "ar-SA": "ar", "de-DE": "de", "en-US": "en", "es-ES": "es", "es-MX": "es-419",
    "fr-FR": "fr", "it": "it", "ja": "ja", "ko": "ko", "nl-NL": "nl", "pl": "pl",
    "pt-BR": "pt-BR", "pt-PT": "pt-PT", "sv": "sv", "tr": "tr",
    "zh-Hans": "zh-Hans", "zh-Hant": "zh-Hant",
}


# ── Tools ──────────────────────────────────────────────────────────────────
DEVELOPER_DIR = Path(os.environ.get("DEVELOPER_DIR", "/Applications/Xcode.app/Contents/Developer"))
XCODEBUILD = DEVELOPER_DIR / "usr" / "bin" / "xcodebuild"
SIMCTL = DEVELOPER_DIR / "usr" / "bin" / "simctl"


def tool(name: str) -> str:
    found = shutil.which(name) or (f"/opt/homebrew/bin/{name}" if Path(f"/opt/homebrew/bin/{name}").exists() else None)
    if not found:
        sys.exit(f"{name} is needed (brew install ffmpeg)")
    return found


FFMPEG, FFPROBE = tool("ffmpeg"), tool("ffprobe")
# Apple's AAC encoder keeps 256 kbit/s even for silence; FFmpeg's own spends
# almost nothing on it.
AUDIO = (["-c:a", "aac_at", "-aac_at_mode", "cbr"]
         if "aac_at" in subprocess.run([FFMPEG, "-hide_banner", "-encoders"], capture_output=True, text=True).stdout
         else ["-c:a", "aac"])


def run(command: list, log: Path | None = None, **kwargs) -> subprocess.CompletedProcess:
    env = dict(os.environ, DEVELOPER_DIR=str(DEVELOPER_DIR))
    if log is None:
        return subprocess.run([str(c) for c in command], check=True, env=env, **kwargs)
    with log.open("w") as handle:
        result = subprocess.run([str(c) for c in command], stdout=handle, stderr=subprocess.STDOUT, env=env, **kwargs)
    if result.returncode != 0:
        sys.exit(f"{Path(str(command[0])).name} failed ({result.returncode}); see {log}")
    return result


def ffmpeg(*args) -> None:
    subprocess.run([FFMPEG, "-hide_banner", "-loglevel", "error", "-y", *map(str, args)], check=True)


# ── Recording ──────────────────────────────────────────────────────────────
def find_simulator(name: str) -> str:
    """The UDID of the one simulator called ``name`` on the pinned iOS runtime."""
    listing = json.loads(subprocess.run([SIMCTL, "list", "devices", "-j"], check=True, capture_output=True,
                                        text=True, env=dict(os.environ, DEVELOPER_DIR=str(DEVELOPER_DIR))).stdout)
    runtime = "iOS-" + CONFIG["xcode"]["runtime"].replace(".", "-")
    matches = [d["udid"] for key, devices in listing["devices"].items() if key.endswith(runtime)
               for d in devices if d["name"] == name and d.get("isAvailable", True)]
    if len(matches) != 1:
        sys.exit(f"{len(matches)} {name} simulators on {runtime}; name one with --simulator")
    return matches[0]


def record(device: Device, udid: str, locale: str, folder: Path, build: bool) -> None:
    """Plays testAppPreviewFlow on ``udid`` while recording its screen."""
    folder.mkdir(parents=True, exist_ok=True)
    derived = WORK / "DerivedData"
    destination = f"platform=iOS Simulator,id={udid}"
    subprocess.run([SIMCTL, "boot", udid], capture_output=True)  # fails harmlessly when booted
    run([SIMCTL, "bootstatus", udid, "-b"], log=folder / "boot.log")
    # 9:41 on a full battery.
    run([SIMCTL, "status_bar", udid, "override", "--time", "9:41", "--batteryState", "discharging",
         "--batteryLevel", "100", "--cellularMode", "active", "--cellularBars", "4", "--wifiBars", "3"])
    run([SIMCTL, "ui", udid, "appearance", "light"])
    if build:
        print(f"  building for {device.simulator}…")
        run([XCODEBUILD, "build-for-testing", "-project", ROOT / "PicStrip.xcodeproj", "-scheme", "PicStripScreenshots",
             "-destination", destination, "-derivedDataPath", derived, "CODE_SIGNING_ALLOWED=NO"],
            log=folder / "build.log")

    code = STORE_LOCALES[locale]
    HANDOFF.mkdir(parents=True, exist_ok=True)
    (HANDOFF / "marks.jsonl").unlink(missing_ok=True)
    (HANDOFF / "request.json").write_text(json.dumps({"language": code, "locale": locale.replace("-", "_")}))
    raw = folder / "raw.mov"
    recorder_log = folder / "record.log"
    recorder = None
    try:
        with recorder_log.open("w") as log:
            recorder = subprocess.Popen([SIMCTL, "io", udid, "recordVideo", "--codec=h264", "--mask=ignored", "--force", raw],
                                        stdout=log, stderr=subprocess.STDOUT, env=dict(os.environ, DEVELOPER_DIR=str(DEVELOPER_DIR)))
        deadline = time.time() + 30
        while "Recording started" not in recorder_log.read_text():
            if time.time() > deadline or recorder.poll() is not None:
                recorder.kill()
                sys.exit(f"The simulator did not start recording; see {recorder_log}")
            time.sleep(0.02)
        started = time.time()
        # A clap for the clock: the status bar reads 9:42 for a few seconds.
        # Where the change shows in the recording lines its clock up with the
        # marks (see sync_offset). simctl returns once the change is made.
        claps = []
        for minute, pause in (("9:42", 2.0), ("9:41", 3.0)):
            time.sleep(pause)
            run([SIMCTL, "status_bar", udid, "override", "--time", minute])
            claps.append(round(time.time() - started, 3))
        print(f"  recording {device.simulator} while the UI test plays the preview…")
        test = subprocess.run([XCODEBUILD, "test-without-building", "-project", ROOT / "PicStrip.xcodeproj",
                               "-scheme", "PicStripScreenshots", "-destination", destination, "-derivedDataPath", derived,
                               f"-only-testing:{TEST}", "-parallel-testing-enabled", "NO",
                               "-collect-test-diagnostics", "never", "CODE_SIGNING_ALLOWED=NO"],
                              stdout=(folder / "test.log").open("w"), stderr=subprocess.STDOUT,
                              env=dict(os.environ, DEVELOPER_DIR=str(DEVELOPER_DIR)), timeout=1800)
    finally:
        if recorder and recorder.poll() is None:
            recorder.send_signal(signal.SIGINT)  # it writes the movie out on SIGINT
            recorder.wait(timeout=120)
        (HANDOFF / "request.json").unlink(missing_ok=True)
        subprocess.run([SIMCTL, "status_bar", udid, "clear"], capture_output=True)
    if test.returncode != 0:
        sys.exit(f"testAppPreviewFlow failed; see {folder / 'test.log'} and its .xcresult in {derived / 'Logs' / 'Test'}")
    offset = sync_offset(raw, device, claps)
    marks = {}
    for line in (HANDOFF / "marks.jsonl").read_text().splitlines():
        mark = json.loads(line)
        marks.setdefault(mark["mark"], round(mark["time"] - started + offset, 3))
    if "done" not in marks:
        sys.exit("The UI test finished without marking the end of the preview")
    (folder / "marks.json").write_text(json.dumps(marks, indent=2) + "\n")
    print(f"  recorded {raw} ({marks['done']:.0f} s; its clock runs {offset:+.2f} s from the marks)")


def sync_offset(raw: Path, device: Device, claps: list[float]) -> float:
    """How far into the recording (in seconds) the status bar changed, less
    when it was changed: what to add to a mark's time to find it in the video.
    (Measured at about 0 ± 0.2 s; a recording without the change keeps 0.)"""
    width, height, rate = 160, 24, 60
    crop = "crop=iw/2:ih*0.045:0:0" if device.is_ipad else "crop=iw/2:ih*0.045:0:ih*0.005"
    frames = subprocess.run([FFMPEG, "-v", "error", "-t", str(claps[-1] + 3), "-i", raw, "-vf",
                             f"fps={rate}:start_time=0,{crop},scale={width}:{height},format=gray", "-f", "rawvideo", "-"],
                            check=True, capture_output=True).stdout
    size = width * height
    images = [frames[i:i + size] for i in range(0, len(frames) - size + 1, size)]
    changes = [sum(abs(a - b) for a, b in zip(images[i - 1], images[i])) / size for i in range(1, len(images))]
    found = []
    for clap in claps:
        # The first change of the status bar in the 1.5 s before simctl
        # returned (it takes about a second) or the second after.
        window = [i for i in range(len(changes)) if -1.5 <= (i + 1) / rate - clap < 1.0]
        moved = [i for i in window if changes[i] > 0.5]
        if moved:
            found.append((moved[0] + 1) / rate - clap)
    if len(found) < len(claps):
        print("  note: the status bar change is not in the recording; assuming its clock matches the marks")
        return 0.0
    if abs(found[0] - found[1]) > 0.3:
        print(f"  note: the two status bar changes disagree ({found[0]:+.2f} s, {found[1]:+.2f} s)")
    return round(sum(found) / len(found), 3)


# ── Captions, frame and background ─────────────────────────────────────────
def captions(locale: str) -> list[str]:
    catalog = shots._load_headlines_xcstrings(HEADLINES)
    code = STORE_LOCALES[locale]
    out = []
    for scene in STORYBOARD:
        if scene.caption in CAPTIONS:
            text = CAPTIONS[scene.caption].get(locale)
            if not text:
                sys.exit(f"No {locale} caption for the {scene.caption} scene: add one to CAPTIONS")
        else:
            text = shots._resolve_headline(scene.caption, code, catalog).split("\n")[0]
        out.append(text)
    return out


def layout(device: Device) -> shots.Layout:
    """The screenshots' layout on the phone; on the iPad a slimmer caption band,
    so the iPad's small text stays readable at preview size."""
    width, height = device.size
    if not device.is_ipad:
        return shots._device_layout(width, height, False)
    return shots.Layout(width, height, headline_box=(int(width * 0.08), int(height * 0.035), int(width * 0.92), int(height * 0.13)),
                        device_box=(int(width * 0.03), int(height * 0.15), int(width * 0.97), height - int(height * 0.015)))


@dataclass(frozen=True)
class Stage:
    """Where the recording goes in the composed frame, and the frame over it."""
    screen: tuple[int, int, int, int]  # x, y, width, height on the canvas
    mask: Image.Image                  # the screen's rounded corners, screen-sized
    frame: Image.Image                 # canvas-sized device frame with a hole for the screen
    shadow: Image.Image                # canvas-sized device shadow


def stage(device: Device, capture: tuple[int, int]) -> Stage:
    """The screenshots' device frame around a ``capture``-sized screen, with
    the screen cut out so the recording shows through."""
    sw, sh = capture
    blank = Image.new("RGBA", capture, (0, 0, 0, 0))
    framed = shots._build_device_frame(blank, device.is_ipad)
    # The screen's place inside the frame, as _build_device_frame lays it out.
    if device.is_ipad:
        radius = max(1, int(sw * shots.IPAD_SCREEN_RADIUS_FRAC))
        bezel = max(1, int(sw * shots.IPAD_BEZEL_FRAC))
        gutter = max(1, int(sw * shots.IPAD_CONTROL_GUTTER_FRAC))
    else:
        bezel = max(1, int(sw * shots.IPHONE_BEZEL_FRAC))
        gutter = max(1, int(sw * shots.IPHONE_CONTROL_GUTTER_FRAC))
        radius = max(1, int(sw * shots.IPHONE_OUTER_RADIUS_FRAC)) - bezel
    box = (gutter + bezel, gutter // 2 + bezel, gutter + bezel + sw - 1, gutter // 2 + bezel + sh - 1)

    solid = framed.copy()
    hole = Image.new("L", framed.size, 255)
    ImageDraw.Draw(hole).rounded_rectangle(box, radius=radius, fill=0)
    framed.putalpha(Image.composite(framed.getchannel("A"), hole, hole))
    if not device.is_ipad:
        shots._draw_dynamic_island(framed, box)

    plan = layout(device)
    resized, origin = shots._fit_device(framed, plan.device_box, fill_width=not device.is_ipad, align_top=not device.is_ipad)
    scale = resized.width / framed.width
    canvas = Image.new("RGBA", device.size, (0, 0, 0, 0))
    shots._alpha_composite_clipped(canvas, resized, origin)
    shadow = Image.new("RGBA", device.size, (0, 0, 0, 0))
    shots._composite_device_shadows(shadow, solid.resize(resized.size, Image.LANCZOS), origin)
    x0 = math.floor(origin[0] + box[0] * scale)
    y0 = math.floor(origin[1] + box[1] * scale)
    x1 = math.ceil(origin[0] + (box[2] + 1) * scale)
    y1 = math.ceil(origin[1] + (box[3] + 1) * scale)
    # The display's corners are rounder than the frame's: without its own
    # corners the recording would show past the frame's.
    mask = Image.new("L", ((x1 - x0) * 4, (y1 - y0) * 4), 0)
    ImageDraw.Draw(mask).rounded_rectangle((0, 0, mask.width - 1, mask.height - 1), radius=radius * scale * 4, fill=255)
    mask = mask.resize((x1 - x0, y1 - y0), Image.LANCZOS)
    return Stage((x0, y0, x1 - x0, y1 - y0), mask, canvas, shadow)


def caption_size(texts: list[str], references: list[str], device: Device, capture: tuple[int, int],
                 band: tuple[int, int, int, int]) -> int:
    """One type size for every caption: the largest that fits each on one line
    in ``band``, but no larger than the screenshots' headlines are on their
    canvas, so the captions read like them."""
    probe = ImageDraw.Draw(Image.new("RGBA", (1, 1)))
    box = shots._device_layout(*capture, device.is_ipad).headline_box
    screenshot = min(getattr(shots._fit_headline_font(text, box[2] - box[0], box[3] - box[1], probe)[0], "size", 32)
                     for text in references)
    largest = int(screenshot * device.size[0] / capture[0])
    width, height = band[2] - band[0], band[3] - band[1]
    sizes = []
    for text in texts:
        candidates = shots._font_candidates_for_text(text)
        shaped = shots._shape_for_display(text, candidates)
        for size in range(largest, 23, -1):
            font = shots._find_font(size, candidates)
            lines = shots._wrap_headline(shaped, font, width, probe)
            stroke = max(1, int(size * shots.HEADLINE_STROKE_WIDTH_FRAC))
            widest, tall, _ = shots._headline_block_size(probe, lines, font, stroke)
            if len(lines) == 1 and widest <= width and tall <= height:
                break
        sizes.append(size)
    return min(sizes)


def draw_caption(canvas: Image.Image, text: str, box: tuple[int, int, int, int], size: int) -> None:
    """``text`` centred in ``box`` as the screenshots draw headlines: white, a
    thin dark stroke, a soft shadow."""
    candidates = shots._font_candidates_for_text(text)
    font = shots._find_font(size, candidates)
    probe = ImageDraw.Draw(Image.new("RGBA", (1, 1)))
    lines = shots._wrap_headline(shots._shape_for_display(text, candidates), font, box[2] - box[0], probe)
    stroke = max(1, int(size * shots.HEADLINE_STROKE_WIDTH_FRAC))
    _, block_h, gap = shots._headline_block_size(probe, lines, font, stroke)
    bboxes = [shots._line_bbox(probe, line, font, stroke) for line in lines]
    top = box[1] + max(0, (box[3] - box[1] - block_h) // 2)
    for layer_kind in ("shadow", "text"):
        layer = Image.new("RGBA", canvas.size, (0, 0, 0, 0))
        draw = ImageDraw.Draw(layer)
        y = top
        for line, bbox in zip(lines, bboxes):
            x = box[0] + (box[2] - box[0] - (bbox[2] - bbox[0])) // 2 - bbox[0]
            if layer_kind == "shadow":
                shade = (0, 0, 0, shots.HEADLINE_SHADOW_OPACITY)
                draw.text((x, y - bbox[1] + shots.HEADLINE_SHADOW_Y_OFFSET * size // 100), line, font=font,
                          fill=shade, stroke_width=stroke, stroke_fill=shade)
            else:
                draw.text((x, y - bbox[1]), line, font=font, fill=(*shots.HEADLINE_COLOR, 255),
                          stroke_width=stroke, stroke_fill=(*shots.HEADLINE_STROKE_COLOR, 255))
            y += bbox[3] - bbox[1] + gap
        if layer_kind == "shadow":
            layer = layer.filter(ImageFilter.GaussianBlur(radius=max(4, shots.HEADLINE_SHADOW_BLUR * size // 100)))
        canvas.alpha_composite(layer)


def backgrounds(device: Device, locale: str, place: Stage, capture: tuple[int, int], folder: Path) -> list[Path]:
    """One background per scene: gradient, glow, device shadow and caption."""
    plan = layout(device)
    texts = captions(locale)
    catalog = shots._load_headlines_xcstrings(HEADLINES)
    references = [shots._resolve_headline(key, STORE_LOCALES[locale], catalog) for key in shots.HEADLINES]
    size = caption_size(texts, references, device, capture, plan.headline_box)
    paths = []
    for index, text in enumerate(texts):
        canvas = Image.new("RGBA", device.size, (0, 0, 0, 255))
        shots._draw_gradient_on(canvas, shots.BRAND_TOP, shots.BRAND_BOTTOM)
        shots._paint_top_highlight(canvas)
        canvas.alpha_composite(place.shadow)
        draw_caption(canvas, text, plan.headline_box, size)
        path = folder / f"background-{index + 1}.png"
        canvas.convert("RGB").save(path)
        paths.append(path)
    return paths


# How much of the top of the screen the caption band covers in the default,
# full-screen layout: the status bar and a little more.
BAND_FRAC = {"iphone": 0.078, "ipad": 0.066}
BAND_TINT = (6, 44, 33, 168)   # the gradient's dark teal, about two-thirds opaque
BAND_BLUR = 14                 # how much the recording under the band is softened


def bands(device: Device, locale: str, capture: tuple[int, int], folder: Path) -> tuple[list[Path], int]:
    """One caption band per scene for the full-screen layout: the dark teal
    of the screenshots, translucent over the softened top of the recording,
    with the caption in the screenshots' type. Returns the bands and their height."""
    width = device.size[0]
    height = round(device.size[1] * BAND_FRAC[device.key])
    box = (round(width * 0.06), round(height * 0.16), width - round(width * 0.06), height - round(height * 0.12))
    texts = captions(locale)
    catalog = shots._load_headlines_xcstrings(HEADLINES)
    references = [shots._resolve_headline(key, STORE_LOCALES[locale], catalog) for key in shots.HEADLINES]
    size = caption_size(texts, references, device, capture, box)
    paths = []
    for index, text in enumerate(texts):
        band = Image.new("RGBA", (width, height), BAND_TINT)
        ImageDraw.Draw(band).line([(0, height - 1), (width, height - 1)], fill=(255, 255, 255, 46))
        draw_caption(band, text, box, size)
        path = folder / f"band-{index + 1}.png"
        band.save(path)
        paths.append(path)
    return paths, height


# ── Cutting and composing ──────────────────────────────────────────────────
def at(marks: dict[str, float], reference: str) -> float:
    match = re.fullmatch(r"([\w.]+?)([+-]\d+(?:\.\d+)?)?", reference)
    if not match or match.group(1) not in marks:
        sys.exit(f"The recording has no mark {reference!r}; marks: {', '.join(marks)}")
    return marks[match.group(1)] + float(match.group(2) or 0)


def probe(path: Path) -> dict:
    return json.loads(subprocess.run([FFPROBE, "-v", "error", "-print_format", "json", "-show_streams", "-show_format", path],
                                     check=True, capture_output=True, text=True).stdout)


MIN_DWELL = 0.4    # the shortest a still screen is held between two steps
END_HOLD = 1.0     # how long a clip's last still (the result of its step) is held, at least
STILL_CHANGE = 20  # how much a pixel (0–255) must change for the screen to have moved
MAX_SPEED = 2.5    # the fastest a clip may play to fit its time


def still_stretches(raw: Path, folder: Path) -> list[tuple[float, float]]:
    """When the screen stood still: mostly XCTest looking for the next control
    to tap. Frames are compared at a quarter size; a pixel that changes by less
    than STILL_CHANGE (the recording's noise, a glass material's shimmer) does
    not count. Kept in still.json beside the recording."""
    cache = folder / "still.json"
    if cache.exists() and cache.stat().st_mtime > raw.stat().st_mtime:
        return [tuple(pair) for pair in json.loads(cache.read_text())]
    video = next(s for s in probe(raw)["streams"] if s["codec_type"] == "video")
    width, height = int(video["width"]) // 4, int(video["height"]) // 4
    decoder = subprocess.Popen([FFMPEG, "-v", "error", "-i", raw, "-vf",
                                f"fps={FPS}:start_time=0,scale={width}:{height}:flags=area,format=gray",
                                "-f", "rawvideo", "-"], stdout=subprocess.PIPE)
    moved = [255 if level > STILL_CHANGE else 0 for level in range(256)]
    size, index, last, changes = width * height, 0, None, [0]
    while chunk := decoder.stdout.read(size):
        if len(chunk) < size:
            break
        frame = Image.frombytes("L", (width, height), chunk)
        if last is not None and ImageChops.difference(last, frame).point(moved).getbbox():
            changes.append(index)
        last, index = frame, index + 1
    decoder.wait()
    changes.append(index)
    stills = [(a / FPS, b / FPS) for a, b in zip(changes, changes[1:]) if (b - a) / FPS > MIN_DWELL]
    cache.write_text(json.dumps(stills))
    return stills


def retime(start: float, end: float, seconds: float, still: list[tuple[float, float]]) -> tuple[list, float]:
    """The parts of start…end to keep, and how fast to play them, to last ``seconds``.

    Motion plays at its own speed; a still screen is held for at most a
    "dwell" chosen so the clip fits, and the clip's last still (what its step
    did) for at least END_HOLD. Only if every still is down to that and it
    is still too long is the whole clip played faster; if it is short even
    with every still kept, its last frame is held."""
    stills = [(max(a, start), min(b, end)) for a, b in still if min(b, end) - max(a, start) > MIN_DWELL]
    last = len(stills) - 1 if stills and stills[-1][1] >= end - 1e-6 else -1

    def held(index: int, dwell: float) -> float:
        return max(dwell, END_HOLD) if index == last else dwell

    def length(dwell: float) -> float:
        return (end - start) - sum(max(0.0, (b - a) - held(i, dwell)) for i, (a, b) in enumerate(stills))

    if length(math.inf) <= seconds:
        dwell = math.inf
    elif length(MIN_DWELL) >= seconds:
        dwell = MIN_DWELL
    else:
        low, high = MIN_DWELL, max(b - a for a, b in stills)
        for _ in range(40):
            middle = (low + high) / 2
            low, high = (middle, high) if length(middle) < seconds else (low, middle)
        dwell = low
    kept, cursor = [], start
    for index, (a, b) in enumerate(stills):
        if b - a > held(index, dwell):
            kept.append((cursor, a + held(index, dwell)))
            cursor = b
    kept.append((cursor, end))
    speed = max(1.0, length(dwell) / seconds)
    if speed > MAX_SPEED:
        sys.exit(f"{start:.1f}–{end:.1f} s would play at {speed:.2f}x to fit {seconds} s; adjust STORYBOARD")
    return [(a, b) for a, b in kept if b > a], speed


def compose(device: Device, locale: str, folder: Path, output: Path, framed: bool = False) -> list[tuple[str, float, float]]:
    """Cuts the recording in ``folder`` to the storyboard and encodes ``output``.

    By default the recording fills the picture, as App Review guideline 2.3.4
    asks of previews (screen captures of the app, with text overlays), and
    each caption is a translucent band over the status bar. ``framed`` puts
    it in the screenshots' device frame on their gradient instead.

    Returns each scene's caption with its start and end in the preview."""
    marks = json.loads((folder / "marks.json").read_text())
    raw = folder / "raw.mov"
    video = next(s for s in probe(raw)["streams"] if s["codec_type"] == "video")
    capture = (int(video["width"]), int(video["height"]))
    width, height = device.size
    if framed:
        place = stage(device, capture)
        place.frame.save(folder / "frame.png")
        place.mask.save(folder / "screen-mask.png")
        overlays = backgrounds(device, locale, place, capture, folder)
        x, y, w, h = place.screen
    else:
        overlays, band = bands(device, locale, capture, folder)
        # The capture's shape is the preview's within a few pixels: fill the
        # width and trim what is left over from the top and bottom evenly.
        scaled = max(height, round(capture[1] * width / capture[0]))
    still = still_stretches(raw, folder)
    # The simulator records Display P3; the preview is BT.709 (sRGB primaries).
    primaries = video.get("color_primaries", "bt709")
    source = {"smpte432": "smpte432", "bt709": "bt709"}.get(primaries, "bt709")

    clips: list[tuple[Path, float, float]] = []  # file, seconds, fade
    timeline: list[tuple[str, float, float]] = []
    elapsed = 0.0
    texts = captions(locale)
    for scene_index, scene in enumerate(STORYBOARD):
        scene_start = None
        for clip in scene.clips:
            start, end = at(marks, clip.start), at(marks, clip.end)
            if end <= start:
                sys.exit(f"{clip.start} → {clip.end} is empty in this recording")
            kept, speed = retime(start, end, clip.seconds, still)
            if speed > 2.2:
                print(f"  note: {clip.start} → {clip.end} plays at {speed:.2f}x")
            frames = round(clip.seconds * FPS)
            seek = max(0.0, start - 10)
            path = folder / f"clip-{len(clips) + 1:02d}.mkv"
            keep = "+".join(f"between(t,{a - seek:.4f},{b - seek:.4f})" for a, b in kept)
            cut = (
                f"[0:v]fps={FPS},select='{keep}',setpts=N/{FPS}/TB,setpts=PTS/{speed:.5f},"
                f"fps={FPS},tpad=stop_mode=clone:stop_duration={clip.seconds:.2f},trim=end_frame={frames},"
                f"colorspace=space=bt709:trc=srgb:primaries=bt709:range=tv:ispace=bt709:itrc=srgb:iprimaries={source}:irange=tv,"
            )
            looped = ["-loop", "1", "-framerate", FPS, "-i"]
            if framed:
                graph = cut + (
                    f"scale={w}:{h}:flags=lanczos:in_color_matrix=bt709:in_range=tv,format=gbrp[picture];"
                    f"[3:v]format=gray[corners];[picture][corners]alphamerge[screen];"
                    f"[1:v]format=gbrp[back];[2:v]format=gbrap[frame];"
                    f"[back][screen]overlay={x}:{y}:format=gbrp:shortest=1[on];"
                    f"[on][frame]overlay=0:0:format=gbrp,settb=1/{FPS},setpts=N[out]"
                )
                inputs = [*looped, overlays[scene_index], *looped, folder / "frame.png", *looped, folder / "screen-mask.png"]
            else:
                graph = cut + (
                    f"scale={width}:{scaled}:flags=lanczos:in_color_matrix=bt709:in_range=tv,"
                    f"crop={width}:{height}:0:{(scaled - height) // 2},format=gbrp,split[picture][top];"
                    f"[top]crop={width}:{band}:0:0,gblur=sigma={BAND_BLUR}[soft];"
                    f"[picture][soft]overlay=0:0:format=gbrp[under];[1:v]format=gbrap[band];"
                    f"[under][band]overlay=0:0:format=gbrp,settb=1/{FPS},setpts=N[out]"
                )
                inputs = [*looped, overlays[scene_index]]
            ffmpeg("-ss", f"{seek:.3f}", "-i", raw, *inputs, "-filter_complex", graph, "-map", "[out]",
                   "-frames:v", frames, "-r", FPS, "-c:v", "ffv1", "-pix_fmt", "gbrp", path)
            fade = clip.fade if clips else 0.0
            elapsed -= fade
            scene_start = elapsed if scene_start is None else scene_start
            elapsed += clip.seconds
            clips.append((path, clip.seconds, fade))
        timeline.append((texts[scene_index], scene_start, elapsed))

    total = elapsed
    if not MIN_SECONDS <= total <= MAX_SECONDS:
        sys.exit(f"The preview would last {total:.1f} s; App Previews last {MIN_SECONDS:.0f}–{MAX_SECONDS:.0f} s")

    inputs, chain, length = [], [], 0.0
    for index, (path, seconds, fade) in enumerate(clips):
        inputs += ["-i", path]
        chain.append(f"[{index}:v]fps={FPS},format=gbrp,settb=AVTB[c{index}]")
    current = "c0"
    length = clips[0][1]
    for index in range(1, len(clips)):
        _, seconds, fade = clips[index]
        joined = f"j{index}"
        if fade > 0:
            chain.append(f"[{current}][c{index}]xfade=transition=fade:duration={fade}:offset={length - fade:.4f}[{joined}]")
            length += seconds - fade
        else:
            chain.append(f"[{current}][c{index}]concat=n=2:v=1:a=0[{joined}]")
            length += seconds
        current = joined
    # Tagged BT.709 on the frames themselves: FFmpeg prefers their tags to -color_* options.
    chain.append(f"[{current}]scale=out_color_matrix=bt709:out_range=tv,format=yuv420p,setsar=1,"
                 "setparams=range=tv:color_primaries=bt709:color_trc=bt709:colorspace=bt709[video]")
    output.parent.mkdir(parents=True, exist_ok=True)
    ffmpeg(*inputs, "-f", "lavfi", "-i", "anullsrc=channel_layout=stereo:sample_rate=48000",
           "-filter_complex", ";".join(chain), "-map", "[video]", "-map", f"{len(clips)}:a",
           "-t", f"{total:.4f}", "-r", FPS,
           "-c:v", "libx264", "-preset", "slow", "-profile:v", "high", "-level:v", "4.0", "-pix_fmt", "yuv420p",
           # Constant 11 Mbit/s, padded where the picture needs fewer bits.
           "-b:v", VIDEO_BITRATE, "-minrate", VIDEO_BITRATE, "-maxrate", VIDEO_BITRATE, "-bufsize", VIDEO_BITRATE,
           "-x264-params", "nal-hrd=cbr:force-cfr=1", "-g", FPS * 2,
           "-color_primaries", "bt709", "-color_trc", "bt709", "-colorspace", "bt709", "-color_range", "tv",
           *AUDIO, "-b:a", "256k", "-ar", "48000", "-ac", "2",
           "-movflags", "+faststart", output)
    return timeline


# ── Checking and review images ─────────────────────────────────────────────
def verify(path: Path, device: Device) -> str:
    """Checks ``path`` against Apple's App Preview specification."""
    info = probe(path)
    video = next(s for s in info["streams"] if s["codec_type"] == "video")
    audio = [s for s in info["streams"] if s["codec_type"] == "audio"]
    duration = float(info["format"]["duration"])
    num, den = map(int, video["avg_frame_rate"].split("/"))
    rate = num / den if den else 0
    problems = []
    if (int(video["width"]), int(video["height"])) != device.size:
        problems.append(f"size {video['width']}x{video['height']}, not {device.size[0]}x{device.size[1]}")
    if video["codec_name"] != "h264" or video.get("profile") != "High" or int(video.get("level", 99)) > 40:
        problems.append(f"video {video['codec_name']} {video.get('profile')} level {video.get('level')}")
    if rate > 30.01:
        problems.append(f"{rate:.2f} fps")
    if video.get("field_order", "progressive") not in ("progressive", "unknown"):
        problems.append(f"field order {video['field_order']}")
    if not MIN_SECONDS <= duration <= MAX_SECONDS:
        problems.append(f"{duration:.2f} s long")
    if len(audio) != 1 or audio[0]["codec_name"] != "aac" or int(audio[0]["channels"]) != 2 \
            or int(audio[0]["sample_rate"]) not in (44100, 48000):
        problems.append("audio is not one stereo AAC track at 44.1 or 48 kHz")
    size = path.stat().st_size
    if size > 500 * 1024 * 1024:
        problems.append(f"{size / 1e6:.0f} MB")
    if problems:
        sys.exit(f"{path.name} does not meet the App Preview specification: {'; '.join(problems)}")
    return (f"{video['width']}x{video['height']} H.264 {video['profile']} L{int(video['level']) / 10:.1f} "
            f"{rate:.0f} fps {int(info['format']['bit_rate']) / 1e6:.1f} Mbit/s, "
            f"AAC {audio[0]['channels']}ch {int(audio[0]['sample_rate']) / 1000:g} kHz "
            f"{int(audio[0].get('bit_rate', 0)) / 1000:.0f} kbit/s, {duration:.2f} s, {size / 1e6:.1f} MB")


def review_images(path: Path, folder: Path, every: float = 1.0) -> tuple[Path, Path]:
    """The poster frame, and a labelled contact sheet of a frame every ``every`` seconds."""
    folder.mkdir(parents=True, exist_ok=True)
    poster = folder / f"{path.stem}-poster.png"
    ffmpeg("-ss", f"{POSTER_SECONDS:.3f}", "-i", path, "-frames:v", "1", poster)
    frames = folder / f".{path.stem}-frames"
    shutil.rmtree(frames, ignore_errors=True)
    frames.mkdir()
    ffmpeg("-i", path, "-vf", f"fps=1/{every}:start_time={every / 2}", frames / "%03d.png")
    shots_list = sorted(frames.glob("*.png"))
    thumb_w = 300
    first = Image.open(shots_list[0])
    thumb_h = round(first.height * thumb_w / first.width)
    columns = 8 if first.height > first.width * 1.6 else 7
    rows = math.ceil(len(shots_list) / columns)
    label_h = 34
    sheet = Image.new("RGB", (columns * (thumb_w + 12) + 12, rows * (thumb_h + label_h + 12) + 12), (24, 24, 24))
    draw = ImageDraw.Draw(sheet)
    font = shots._find_font(22)
    for index, frame_path in enumerate(shots_list):
        column, row = index % columns, index // columns
        left, top = 12 + column * (thumb_w + 12), 12 + row * (thumb_h + label_h + 12)
        with Image.open(frame_path) as frame:
            sheet.paste(frame.convert("RGB").resize((thumb_w, thumb_h), Image.LANCZOS), (left, top + label_h))
        draw.text((left, top + 4), f"{every / 2 + index * every:.1f} s", font=font, fill=(235, 235, 235))
    contact = folder / f"{path.stem}-contact.png"
    sheet.save(contact)
    shutil.rmtree(frames)
    return poster, contact


# ── Main ───────────────────────────────────────────────────────────────────
def main() -> int:
    sys.stdout.reconfigure(line_buffering=True)
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    parser.add_argument("--device", action="append", choices=sorted(DEVICES), help="iphone and/or ipad (default: both)")
    parser.add_argument("--locale", default="en-US", choices=sorted(STORE_LOCALES))
    parser.add_argument("--simulator", action="append", default=[], metavar="DEVICE=UDID",
                        help="the simulator to use, e.g. iphone=225A67E4-… (default: the one with the device's name)")
    parser.add_argument("--compose-only", action="store_true", help="re-cut the last recordings in build/app-previews")
    parser.add_argument("--skip-build", action="store_true", help="reuse the last UI test build")
    parser.add_argument("--framed", action="store_true",
                        help="put the recording in the screenshots' device frame, as PicStrip-preview-…-framed.mp4 "
                             "(for comparison: App Review wants previews to be screen captures)")
    parser.add_argument("--out", default=str(OUT))
    args = parser.parse_args()

    chosen = [DEVICES[key] for key in (args.device or ["iphone", "ipad"])]
    pinned = dict(item.split("=", 1) for item in args.simulator)
    out = Path(os.path.expanduser(args.out))
    captions(args.locale)  # fail early on a missing caption
    summaries = []
    for device in chosen:
        folder = WORK / args.locale / device.key
        print(f"{device.simulator} ({args.locale})")
        if not args.compose_only:
            record(device, pinned.get(device.key) or find_simulator(device.simulator), args.locale, folder,
                   build=not args.skip_build)
        elif not (folder / "marks.json").exists():
            sys.exit(f"No recording in {folder}; run without --compose-only first")
        output = out / f"PicStrip-preview-{args.locale}-{device.key}{'-framed' if args.framed else ''}.mp4"
        timeline = compose(device, args.locale, folder, output, framed=args.framed)
        summary = verify(output, device)
        poster, contact = review_images(output, out / "previews")
        summaries.append((output, summary, timeline, poster, contact))
    for output, summary, timeline, poster, contact in summaries:
        print(f"\n{output}\n  {summary}")
        for text, start, end in timeline:
            print(f"  {start:5.2f}–{end:5.2f} s  {text}")
        print(f"  poster ({POSTER_SECONDS:g} s): {poster}\n  contact sheet: {contact}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
