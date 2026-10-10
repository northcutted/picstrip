#!/usr/bin/env python3
"""Upload PicStrip's universal creative asset or app previews to App Store Connect.

Run it yourself, with your own App Store Connect API key (App Manager or
Admin). It needs only the Python standard library and `openssl`, and keeps
nothing: the key is read from your .p8 file to sign each request.

Creative asset (the default). For each language of the app version (1.7.0 by
default) that has a `PicStrip-universal-<locale>.png` in the folder (made by
scripts/make_creative_assets.py), it:

1. uploads the image to the app's Asset Library as a creative asset,
2. waits for Apple to process it, and
3. places it on that language's product page as both the header asset and the
   search results asset (a universal asset fills both).

App previews (--previews). For each language that has
`PicStrip-preview-<locale>-iphone.mp4` or `...-ipad.mp4` in the folder (made by
scripts/make_app_previews.py), it:

1. uploads the video to the Asset Library under App Screenshots and Previews,
   with its poster frame at --poster-time,
2. waits for Apple to process it, and
3. places it as that language's App Preview for the 6.9" iPhone
   (IPHONE_DYNAMIC_ISLAND_LARGE_DISPLAY) or the 13" iPad (IPAD_13_DISPLAY).
   Apple's Asset Library reference data names the placement group of each
   display class; the script looks it up rather than guessing.

A language (and device) whose placements already exist is left alone, so it is
safe to run again; a preview uploaded by an earlier run that stopped before
placing it is found by its reference name and placed rather than uploaded
again. Nothing is deleted. The assets go to App Review with the version; the
version must still be "Prepare for Submission".

By default it only shows what it would do. Add --apply to upload.

    python3 scripts/upload_creative_assets.py \\
        --key-id ABC123XYZ --issuer-id 69a6de7e-... --key ~/Downloads/AuthKey_ABC123XYZ.p8
    python3 scripts/upload_creative_assets.py ... --apply
    python3 scripts/upload_creative_assets.py ... --previews            # plan the app previews
    python3 scripts/upload_creative_assets.py ... --previews --apply
"""
from __future__ import annotations

import argparse
import base64
import json
import os
from pathlib import Path
import struct
import subprocess
import sys
import time
import urllib.error
import urllib.parse
import urllib.request

API = "https://api.appstoreconnect.apple.com"
BUNDLE_ID = "com.northcutt.PicStrip"
SIZE = (5244, 2950)
PLACEMENTS = ("PRODUCT_PAGE_HEADER_ASSET", "APP_STORE_SEARCH_RESULTS_ASSET")
EDITABLE = "PREPARE_FOR_SUBMISSION"

# App previews: the device class each file is for, as Asset Library display
# classes and store platforms, and the size scripts/make_app_previews.py makes.
PREVIEW_DEVICES = {
    "iphone": {"name": '6.9" iPhone', "displayClass": "IPHONE_DYNAMIC_ISLAND_LARGE_DISPLAY",
               "platform": "IPHONE_APP_STORE", "size": (886, 1920)},
    "ipad": {"name": '13" iPad', "displayClass": "IPAD_13_DISPLAY", "platform": "IPAD_APP_STORE", "size": (1200, 1600)},
}
PREVIEW_CATEGORY = "APP_SCREENSHOTS_AND_PREVIEWS"
PREVIEW_PLACEMENT = "APP_PREVIEW"
PREVIEW_FPS = 30
# The poster frame scripts/make_app_previews.py draws (its POSTER_SECONDS).
POSTER_SECONDS = 7.0
# Assets in these states are no use to place again; anything else can be.
UNUSABLE = ("FAILED", "ARCHIVED", "REJECTED", "AWAITING_UPLOAD")


# --- ES256 token (the same approach as scripts/export_app_store_settings.py) ---

def b64url(data: bytes) -> str:
    return base64.urlsafe_b64encode(data).rstrip(b"=").decode()


def der_to_raw_signature(der: bytes, size: int = 32) -> bytes:
    """openssl prints an ASN.1 DER ECDSA signature; a JWT wants r||s."""
    def length_at(index):
        first = der[index]
        if first < 0x80:
            return first, index + 1
        count = first & 0x7F
        return int.from_bytes(der[index + 1:index + 1 + count], "big"), index + 1 + count

    if der[0] != 0x30:
        raise ValueError("Unexpected signature from openssl")
    _, index = length_at(1)
    parts = []
    for _ in range(2):
        if der[index] != 0x02:
            raise ValueError("Unexpected signature from openssl")
        length, index = length_at(index + 1)
        parts.append(der[index:index + length].lstrip(b"\0").rjust(size, b"\0"))
        index += length
    return b"".join(parts)


class Client:
    """GETs and POSTs to the App Store Connect API with a fresh 20-minute token."""

    def __init__(self, key_path: Path, key_id: str, issuer_id: str):
        self.key_path, self.key_id, self.issuer_id = key_path, key_id, issuer_id
        self.token, self.expires = "", 0.0

    def _bearer(self) -> str:
        now = time.time()
        if now > self.expires - 60:
            header = {"alg": "ES256", "kid": self.key_id, "typ": "JWT"}
            payload = {"iss": self.issuer_id, "iat": int(now) - 10, "exp": int(now) + 1200, "aud": "appstoreconnect-v1"}
            signing_input = (b64url(json.dumps(header, separators=(",", ":")).encode()) + "."
                             + b64url(json.dumps(payload, separators=(",", ":")).encode()))
            signed = subprocess.run(["openssl", "dgst", "-sha256", "-sign", str(self.key_path)],
                                    input=signing_input.encode(), capture_output=True)
            if signed.returncode != 0:
                sys.exit("openssl could not sign with that key: is it the AuthKey_….p8 file?")
            self.token = signing_input + "." + b64url(der_to_raw_signature(signed.stdout))
            self.expires = now + 1200
        return self.token

    def request(self, method: str, path: str, body: dict | None = None, query: dict | None = None) -> dict:
        url = API + path + ("?" + urllib.parse.urlencode(query) if query else "")
        data = json.dumps(body).encode() if body is not None else None
        req = urllib.request.Request(url, data=data, method=method, headers={
            "Authorization": "Bearer " + self._bearer(), "Content-Type": "application/json"})
        try:
            with urllib.request.urlopen(req, timeout=60) as response:
                raw = response.read()
                return json.loads(raw) if raw else {}
        except urllib.error.HTTPError as error:
            detail = error.read().decode(errors="replace")
            try:
                errors = json.loads(detail).get("errors", [])
                detail = "; ".join(f"{e.get('title', '')}: {e.get('detail', '')}" for e in errors) or detail
            except json.JSONDecodeError:
                pass
            raise RuntimeError(f"{method} {path} → {error.code} {detail}") from None

    def get_all(self, path: str, query: dict | None = None) -> list:
        items, query = [], dict(query or {}, limit=200)
        page = self.request("GET", path, query=query)
        while True:
            items += page.get("data", [])
            following = page.get("links", {}).get("next")
            if not following:
                return items
            page = self.request("GET", following.removeprefix(API))


# --- Files ---------------------------------------------------------------------

def png_size(path: Path) -> tuple[int, int]:
    with path.open("rb") as file:
        head = file.read(24)
    if head[:8] != b"\x89PNG\r\n\x1a\n":
        raise ValueError(f"{path.name} is not a PNG")
    return struct.unpack(">II", head[16:24])


def movie_facts(path: Path) -> tuple[int, int, float]:
    """The width, height and length in seconds of an MP4 or QuickTime movie's
    video track, read from its moov box (mvhd and the video track's tkhd)."""
    data = path.read_bytes()

    def boxes(start: int, end: int):
        while start + 8 <= end:
            size, kind = struct.unpack(">I4s", data[start:start + 8])
            header = 8
            if size == 1:
                size, header = struct.unpack(">Q", data[start + 8:start + 16])[0], 16
            elif size == 0:
                size = end - start
            if size < header:
                break
            yield kind, start + header, start + size
            start += size

    for kind, body, end in boxes(0, len(data)):
        if kind != b"moov":
            continue
        seconds, size = 0.0, (0, 0)
        for child, child_body, child_end in boxes(body, end):
            if child == b"mvhd":
                version = data[child_body]
                if version == 1:
                    timescale, duration = struct.unpack(">IQ", data[child_body + 20:child_body + 32])
                else:
                    timescale, duration = struct.unpack(">II", data[child_body + 12:child_body + 20])
                seconds = duration / timescale if timescale else 0.0
            elif child == b"trak":
                for part, part_body, _ in boxes(child_body, child_end):
                    if part == b"tkhd":
                        # 16.16 fixed point, after the matrix: byte 76 (version 0) or 88 (version 1).
                        start = part_body + (88 if data[part_body] == 1 else 76)
                        width, height = struct.unpack(">II", data[start:start + 8])
                        if width and height:
                            size = (width >> 16, height >> 16)
        return size[0], size[1], seconds
    raise ValueError(f"{path.name} is not a movie Apple can read (no moov box)")


def timecode(seconds: float, fps: int = PREVIEW_FPS) -> str:
    """HH:MM:SS:FF, the time code App Store Connect takes for a poster frame."""
    frames = round(seconds * fps)
    return f"{frames // (3600 * fps):02d}:{frames // (60 * fps) % 60:02d}:{frames // fps % 60:02d}:{frames % fps:02d}"


# --- The upload ----------------------------------------------------------------

def upload_asset(client: Client, kind: str, library_id: str, path: Path, attributes: dict,
                 patch: dict | None = None, minutes: int = 10) -> str:
    """Creates an Asset Library image or video (``kind`` is appAssetLibraryImages
    or appAssetLibraryVideos), sends its bytes, and waits until Apple has
    processed it."""
    data = path.read_bytes()
    created = client.request("POST", f"/v1/{kind}", {"data": {
        "type": kind,
        "attributes": {"fileName": path.name, "fileSize": len(data), **attributes},
        "relationships": {"assetLibrary": {"data": {"type": "appAssetLibraries", "id": library_id}}},
    }})["data"]
    for operation in created["attributes"].get("uploadOperations") or []:
        offset, length = operation["offset"], operation["length"]
        headers = {h["name"]: h["value"] for h in operation.get("requestHeaders") or []}
        part = urllib.request.Request(operation["url"], data=data[offset:offset + length],
                                      method=operation["method"], headers=headers)
        with urllib.request.urlopen(part, timeout=300):
            pass
    client.request("PATCH", f"/v1/{kind}/{created['id']}", {"data": {
        "type": kind, "id": created["id"], "attributes": {"uploaded": True, **(patch or {})}}})
    return wait_for_processing(client, kind, created["id"], path.name, minutes)


def wait_for_processing(client: Client, kind: str, asset_id: str, name: str, minutes: int) -> str:
    deadline = time.time() + minutes * 60
    while time.time() < deadline:
        asset = client.request("GET", f"/v1/{kind}/{asset_id}")["data"]["attributes"]
        state = asset.get("state")
        if state == "FAILED":
            reasons = "; ".join(d.get("description", d.get("code", "")) for d in asset.get("stateDetails") or [])
            raise RuntimeError(f"Apple could not process {name}: {reasons or 'no reason given'}")
        if state not in ("AWAITING_UPLOAD", "UPLOAD_COMPLETE"):
            return asset_id
        time.sleep(5 if kind == "appAssetLibraryImages" else 10)
    raise RuntimeError(f"Apple was still processing {name} after {minutes} minutes; run the script again later")


def upload_creative_assets(args, client: Client, localizations: list, library_id: str) -> int:
    folder = Path(os.path.expanduser(args.folder or Path.home() / "Desktop" / "PicStrip Creative Assets"))
    failures = 0
    for localization in sorted(localizations, key=lambda l: l["attributes"]["locale"]):
        locale = localization["attributes"]["locale"]
        if args.wanted and locale not in args.wanted:
            continue
        path = folder / f"PicStrip-universal-{locale}.png"
        if not path.exists():
            print(f"  {locale:8} no file ({path.name}); skipped")
            continue
        try:
            if png_size(path) != SIZE:
                raise ValueError(f"{path.name} is {png_size(path)}, not {SIZE}")
            existing = client.get_all(f"/v1/appStoreVersionLocalizations/{localization['id']}/placements")
            have = {p["attributes"].get("placementType") for p in existing}
            missing = [p for p in PLACEMENTS if p not in have]
            if not missing:
                print(f"  {locale:8} already has a header and a search results asset; left alone")
                continue
            if not args.apply:
                print(f"  {locale:8} would upload {path.name} and place it as {', '.join(missing)}")
                continue
            image_id = upload_asset(client, "appAssetLibraryImages", library_id, path, {
                "category": "CREATIVE_ASSETS", "referenceName": f"PicStrip universal {args.version} {locale}"})
            for placement in missing:
                client.request("POST", "/v1/appAssetLibraryPlacements", {"data": {
                    "type": "appAssetLibraryPlacements",
                    "attributes": {"placementType": placement},
                    "relationships": {
                        "image": {"data": {"type": "appAssetLibraryImages", "id": image_id}},
                        "appStoreVersionLocalization": {"data": {"type": "appStoreVersionLocalizations",
                                                                 "id": localization["id"]}},
                    }}})
            print(f"  {locale:8} uploaded and placed as {', '.join(missing)}")
        except (RuntimeError, ValueError, OSError) as error:
            failures += 1
            print(f"  {locale:8} FAILED: {error}")
    return failures


# --- App previews ----------------------------------------------------------------

def iso_seconds(duration: str | None) -> float | None:
    """PT15S / PT0M30S / PT30.5S → seconds."""
    if not duration or not duration.startswith("PT"):
        return None
    seconds, number = 0.0, ""
    for ch in duration[2:]:
        if ch.isdigit() or ch == ".":
            number += ch
        else:
            seconds += float(number or 0) * {"H": 3600, "M": 60, "S": 1}.get(ch, 0)
            number = ""
    return seconds


def preview_groups(client: Client, overrides: dict[str, str]) -> dict[str, dict]:
    """For each device: the placement group of its display class, and the
    video specs App Previews in that group must meet, from the Asset Library's
    reference data."""
    # (This collection takes no limit parameter, so not get_all.)
    page, data = client.request("GET", "/v1/appAssetLibraryRefData"), []
    while True:
        data += page.get("data") or []
        following = (page.get("links") or {}).get("next")
        if not following:
            break
        page = client.request("GET", following.removeprefix(API))
    profile_groups, placement_types, video_specs = [], [], {}
    for item in data:
        attributes = item.get("attributes") or {}
        profile_groups += attributes.get("placementProfileGroups") or []
        placement_types += attributes.get("placementTypes") or []
        for spec in attributes.get("videoSpecs") or []:
            video_specs[spec.get("specId")] = spec
    preview_types = [t for t in placement_types if t.get("placementTypeId") == PREVIEW_PLACEMENT]
    categories = {c for t in preview_types for c in t.get("acceptsAssetCategories") or []}
    if preview_types and categories and PREVIEW_CATEGORY not in categories:
        raise RuntimeError(f"App Previews no longer accept {PREVIEW_CATEGORY} assets ({', '.join(sorted(categories))})")
    mappings = {m.get("placementGroupId"): m.get("specs") or [] for t in preview_types for m in t.get("specMappings") or []}

    groups = {}
    for device, facts in PREVIEW_DEVICES.items():
        if device in overrides:
            group = overrides[device]
        else:
            candidates = [g.get("placementProfileGroupId") for g in profile_groups
                          if g.get("displayClassId") == facts["displayClass"]
                          and g.get("platform") in (facts["platform"], None)]
            for_previews = [g for g in candidates if g in mappings]
            chosen = for_previews or candidates
            if len(chosen) != 1:
                known = ", ".join(f"{g.get('placementProfileGroupId')} ({g.get('platform')} {g.get('displayClassId')})"
                                  for g in profile_groups) or "none"
                raise RuntimeError(f"Cannot tell which placement group is the {facts['name']} "
                                   f"({facts['displayClass']}): {len(chosen)} match. Groups: {known}. "
                                   f"Name it with --placement-group {device}=<id>.")
            group = chosen[0]
        groups[device] = {"group": group, "specs": [video_specs[s] for s in mappings.get(group, []) if s in video_specs]}
    return groups


def check_preview(path: Path, device: str, specs: list[dict], poster: float) -> str:
    """Refuses a file App Store Connect would reject: wrong size or length."""
    width, height, seconds = movie_facts(path)
    if not 0 <= poster < seconds:
        raise ValueError(f"the poster time {poster:g} s is outside {path.name} ({seconds:.1f} s)")
    if (width, height) != PREVIEW_DEVICES[device]["size"]:
        raise ValueError(f"{path.name} is {width}x{height}, not {PREVIEW_DEVICES[device]['size'][0]}x"
                         f"{PREVIEW_DEVICES[device]['size'][1]}")
    if not 15 <= seconds <= 30:
        raise ValueError(f"{path.name} lasts {seconds:.1f} s; App Previews last 15–30 s")
    if specs:
        def fits(spec: dict) -> bool:
            size = spec.get("dimensions") or {}
            length = spec.get("duration") or {}
            low, high = iso_seconds(length.get("min")), iso_seconds(length.get("max"))
            return (size.get("minWidth", 0) <= width <= size.get("maxWidth", width)
                    and size.get("minHeight", 0) <= height <= size.get("maxHeight", height)
                    and (low is None or seconds >= low) and (high is None or seconds <= high)
                    and (not spec.get("maxFileSize") or path.stat().st_size <= spec["maxFileSize"]))
        if not any(fits(spec) for spec in specs):
            raise ValueError(f"{path.name} ({width}x{height}, {seconds:.1f} s) meets none of Apple's specs for this "
                             f"placement: {', '.join(s.get('shortName') or s.get('specId', '?') for s in specs)}")
    return f"{width}x{height}, {seconds:.1f} s"


def upload_previews(args, client: Client, localizations: list, library_id: str) -> int:
    folder = Path(os.path.expanduser(args.folder or Path.home() / "Desktop" / "PicStrip App Previews"))
    groups = preview_groups(client, args.placement_groups)
    poster = timecode(args.poster_time)
    for device, found in groups.items():
        print(f"  {PREVIEW_DEVICES[device]['name']} previews go in placement group {found['group']}")
    print(f"  poster frame at {poster}\n")
    failures = 0
    for localization in sorted(localizations, key=lambda l: l["attributes"]["locale"]):
        locale = localization["attributes"]["locale"]
        if args.wanted and locale not in args.wanted:
            continue
        for device, found in groups.items():
            path = folder / f"PicStrip-preview-{locale}-{device}.mp4"
            label = f"{locale:8} {device:6}"
            if not path.exists():
                print(f"  {label} no file ({path.name}); skipped")
                continue
            try:
                facts = check_preview(path, device, found["specs"], args.poster_time)
                existing = client.get_all(f"/v1/appStoreVersionLocalizations/{localization['id']}/placements", {
                    "filter[placementType]": PREVIEW_PLACEMENT, "filter[placementGroup]": found["group"]})
                existing = [p for p in existing if (p.get("attributes") or {}).get("placementGroup") in (None, found["group"])]
                if existing:
                    print(f"  {label} already has {len(existing)} app preview(s); left alone")
                    continue
                reference = f"PicStrip preview {args.version} {locale} {device}"
                earlier = [v for v in client.get_all(f"/v1/appAssetLibraries/{library_id}/videos", {
                               "filter[referenceName]": reference, "filter[category]": PREVIEW_CATEGORY})
                           if (v.get("attributes") or {}).get("state") not in UNUSABLE
                           and (v.get("attributes") or {}).get("fileSize") == path.stat().st_size]
                if not args.apply:
                    how = "place the copy uploaded earlier" if earlier else f"upload {path.name} ({facts})"
                    print(f"  {label} would {how} as the {PREVIEW_DEVICES[device]['name']} app preview")
                    continue
                if earlier:
                    video_id = wait_for_processing(client, "appAssetLibraryVideos", earlier[0]["id"], path.name, 30)
                else:
                    video_id = upload_asset(client, "appAssetLibraryVideos", library_id, path, {
                        "category": PREVIEW_CATEGORY, "referenceName": reference, "previewFrameTimeCode": poster,
                    }, patch={"previewFrameTimeCode": poster}, minutes=30)
                client.request("POST", "/v1/appAssetLibraryPlacements", {"data": {
                    "type": "appAssetLibraryPlacements",
                    "attributes": {"placementType": PREVIEW_PLACEMENT, "placementGroup": found["group"]},
                    "relationships": {
                        "video": {"data": {"type": "appAssetLibraryVideos", "id": video_id}},
                        "appStoreVersionLocalization": {"data": {"type": "appStoreVersionLocalizations",
                                                                 "id": localization["id"]}},
                    }}})
                print(f"  {label} {'placed the copy uploaded earlier' if earlier else 'uploaded and placed'} "
                      f"as the {PREVIEW_DEVICES[device]['name']} app preview")
            except (RuntimeError, ValueError, OSError) as error:
                failures += 1
                print(f"  {label} FAILED: {error}")
    return failures


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    parser.add_argument("--key-id", default=os.environ.get("ASC_KEY_ID"), help="App Store Connect API Key ID")
    parser.add_argument("--issuer-id", default=os.environ.get("ASC_ISSUER_ID"), help="Issuer ID")
    parser.add_argument("--key", default=os.environ.get("ASC_KEY_PATH"), help="Path to AuthKey_<id>.p8")
    parser.add_argument("--folder", help="Where the files are (default: ~/Desktop/PicStrip Creative Assets, "
                                         "or ~/Desktop/PicStrip App Previews with --previews)")
    parser.add_argument("--version", default="1.7.0", help="App Store version to place the assets on")
    parser.add_argument("--locales", help="Only these locales, comma-separated (e.g. en-US,ja)")
    parser.add_argument("--previews", action="store_true", help="Upload the app previews instead of the creative asset")
    parser.add_argument("--poster-time", type=float, default=POSTER_SECONDS,
                        help=f"With --previews: the poster frame, in seconds (default {POSTER_SECONDS:g})")
    parser.add_argument("--placement-group", action="append", default=[], metavar="DEVICE=ID",
                        help="With --previews: the placement group for iphone or ipad, if the reference data is unclear")
    parser.add_argument("--apply", action="store_true", help="Upload and place (default: only show the plan)")
    args = parser.parse_args()
    args.wanted = {l.strip() for l in args.locales.split(",")} if args.locales else None
    args.placement_groups = dict(item.split("=", 1) for item in args.placement_group)
    if set(args.placement_groups) - set(PREVIEW_DEVICES):
        sys.exit("--placement-group takes iphone=<id> or ipad=<id>")

    key_id = args.key_id or input("Key ID: ").strip()
    issuer_id = args.issuer_id or input("Issuer ID: ").strip()
    key_path = Path(os.path.expanduser(args.key or input("Path to the AuthKey_….p8 file: ").strip()))
    if not key_path.is_file():
        sys.exit(f"No key file at {key_path}")
    client = Client(key_path, key_id, issuer_id)

    apps = client.request("GET", "/v1/apps", query={"filter[bundleId]": BUNDLE_ID})["data"]
    if not apps:
        sys.exit(f"No app with bundle ID {BUNDLE_ID} is visible to this key")
    app_id = apps[0]["id"]
    versions = client.get_all(f"/v1/apps/{app_id}/appStoreVersions",
                              {"filter[versionString]": args.version, "filter[platform]": "IOS"})
    if not versions:
        sys.exit(f"No iOS version {args.version} in App Store Connect")
    version = versions[0]
    state = version["attributes"].get("appVersionState") or version["attributes"].get("appStoreState")
    if state != EDITABLE:
        what = "App previews" if args.previews else "Creative assets"
        sys.exit(f"Version {args.version} is {state}; {what.lower()} can only be added while it is {EDITABLE}")
    localizations = client.get_all(f"/v1/appStoreVersions/{version['id']}/appStoreVersionLocalizations")
    library_id = client.request("GET", f"/v1/apps/{app_id}/assetLibrary")["data"]["id"]

    print(f"PicStrip {args.version} ({state}) — {'app previews' if args.previews else 'creative asset'} — "
          f"{'uploading' if args.apply else 'plan only; add --apply to upload'}\n")
    try:
        failures = (upload_previews if args.previews else upload_creative_assets)(args, client, localizations, library_id)
    except RuntimeError as error:
        sys.exit(str(error))

    if failures:
        print(f"\n{failures} upload(s) failed; fix the cause and run again (finished ones are skipped).")
        return 1
    if args.apply:
        print("\nDone. Check them with Preview in App Store Connect, then submit the version as usual.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
