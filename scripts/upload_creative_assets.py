#!/usr/bin/env python3
"""Upload PicStrip's universal creative asset to App Store Connect.

Run it yourself, with your own App Store Connect API key (App Manager or
Admin). It needs only the Python standard library and `openssl`, and keeps
nothing: the key is read from your .p8 file to sign each request.

For each language of the app version (1.7.0 by default) that has a
`PicStrip-universal-<locale>.png` in the folder (made by
scripts/make_creative_assets.py), it:

1. uploads the image to the app's Asset Library as a creative asset,
2. waits for Apple to process it, and
3. places it on that language's product page as both the header asset and the
   search results asset (a universal asset fills both).

A language whose placements already exist is left alone, so it is safe to run
again. Nothing is deleted. The assets go to App Review with the version; the
version must still be "Prepare for Submission".

By default it only shows what it would do. Add --apply to upload.

    python3 scripts/upload_creative_assets.py \\
        --key-id ABC123XYZ --issuer-id 69a6de7e-... --key ~/Downloads/AuthKey_ABC123XYZ.p8
    python3 scripts/upload_creative_assets.py ... --apply
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


# --- The upload ------------------------------------------------------------

def png_size(path: Path) -> tuple[int, int]:
    with path.open("rb") as file:
        head = file.read(24)
    if head[:8] != b"\x89PNG\r\n\x1a\n":
        raise ValueError(f"{path.name} is not a PNG")
    return struct.unpack(">II", head[16:24])


def upload_image(client: Client, library_id: str, path: Path, reference: str) -> str:
    """Creates the Asset Library image, sends its bytes, and waits until Apple has processed it."""
    data = path.read_bytes()
    created = client.request("POST", "/v1/appAssetLibraryImages", {"data": {
        "type": "appAssetLibraryImages",
        "attributes": {"category": "CREATIVE_ASSETS", "fileName": path.name, "fileSize": len(data),
                       "referenceName": reference},
        "relationships": {"assetLibrary": {"data": {"type": "appAssetLibraries", "id": library_id}}},
    }})["data"]
    for operation in created["attributes"].get("uploadOperations") or []:
        offset, length = operation["offset"], operation["length"]
        headers = {h["name"]: h["value"] for h in operation.get("requestHeaders") or []}
        part = urllib.request.Request(operation["url"], data=data[offset:offset + length],
                                      method=operation["method"], headers=headers)
        with urllib.request.urlopen(part, timeout=300):
            pass
    client.request("PATCH", f"/v1/appAssetLibraryImages/{created['id']}", {"data": {
        "type": "appAssetLibraryImages", "id": created["id"], "attributes": {"uploaded": True}}})

    deadline = time.time() + 600
    while time.time() < deadline:
        image = client.request("GET", f"/v1/appAssetLibraryImages/{created['id']}")["data"]["attributes"]
        state = image.get("state")
        if state == "FAILED":
            reasons = "; ".join(d.get("description", d.get("code", "")) for d in image.get("stateDetails") or [])
            raise RuntimeError(f"Apple could not process {path.name}: {reasons or 'no reason given'}")
        if state not in ("AWAITING_UPLOAD", "UPLOAD_COMPLETE"):
            return created["id"]
        time.sleep(5)
    raise RuntimeError(f"Apple was still processing {path.name} after 10 minutes; run the script again later")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    parser.add_argument("--key-id", default=os.environ.get("ASC_KEY_ID"), help="App Store Connect API Key ID")
    parser.add_argument("--issuer-id", default=os.environ.get("ASC_ISSUER_ID"), help="Issuer ID")
    parser.add_argument("--key", default=os.environ.get("ASC_KEY_PATH"), help="Path to AuthKey_<id>.p8")
    parser.add_argument("--folder", default=str(Path.home() / "Desktop" / "PicStrip Creative Assets"))
    parser.add_argument("--version", default="1.7.0", help="App Store version to place the assets on")
    parser.add_argument("--locales", help="Only these locales, comma-separated (e.g. en-US,ja)")
    parser.add_argument("--apply", action="store_true", help="Upload and place (default: only show the plan)")
    args = parser.parse_args()

    key_id = args.key_id or input("Key ID: ").strip()
    issuer_id = args.issuer_id or input("Issuer ID: ").strip()
    key_path = Path(os.path.expanduser(args.key or input("Path to the AuthKey_….p8 file: ").strip()))
    if not key_path.is_file():
        sys.exit(f"No key file at {key_path}")
    folder = Path(os.path.expanduser(args.folder))
    wanted = {l.strip() for l in args.locales.split(",")} if args.locales else None
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
        sys.exit(f"Version {args.version} is {state}; creative assets can only be added while it is {EDITABLE}")
    localizations = client.get_all(f"/v1/appStoreVersions/{version['id']}/appStoreVersionLocalizations")
    library_id = client.request("GET", f"/v1/apps/{app_id}/assetLibrary")["data"]["id"]

    print(f"PicStrip {args.version} ({state}) — {'uploading' if args.apply else 'plan only; add --apply to upload'}\n")
    failures = 0
    for localization in sorted(localizations, key=lambda l: l["attributes"]["locale"]):
        locale = localization["attributes"]["locale"]
        if wanted and locale not in wanted:
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
            image_id = upload_image(client, library_id, path, f"PicStrip universal {args.version} {locale}")
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

    if failures:
        print(f"\n{failures} language(s) failed; fix the cause and run again (finished ones are skipped).")
        return 1
    if args.apply:
        print("\nDone. Check them with Preview in App Store Connect, then submit the version as usual.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
