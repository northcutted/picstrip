#!/usr/bin/env python3
"""Export PicStrip's App Store Connect settings as JSON for an App Store optimization review.

Read-only by construction: the client below can only issue GET requests to
https://api.appstoreconnect.apple.com, refuses redirects and pagination links to
any other host, and never prints the API key or the signed token. It needs only
the Python standard library and the `openssl` command (for ES256 signing).

Run it from GitHub: Actions -> "App Store Settings Export" -> Run workflow (main).
The JSON is uploaded as a one-day artifact. Locally, with the same three
variables a release key uses:

  APP_STORE_CONNECT_API_KEY_ID=... APP_STORE_CONNECT_API_KEY_ISSUER_ID=... \\
  APP_STORE_CONNECT_API_KEY_CONTENT="$(cat AuthKey_XXXX.p8)" \\
  python3 scripts/export_app_store_settings.py [--versions 3] [--output FILE]

What it exports for the bundle ID in .github/ios-release.json:
  * app record attributes (name, primary locale, content rights, kids flag, ...)
  * app infos: state, categories, age rating declaration, localized name,
    subtitle and privacy URLs
  * the latest app store versions: state, release type, phased release, copyright,
    attached build, localized store text, screenshot / app preview set display
    types and counts, and an App Review detail summary (notes length and whether
    a demo account is required)
  * pricing (base territory, manual prices), availability (territory codes),
    in-app purchase / subscription / custom product page / product page
    optimization / in-app event summaries, TestFlight review and group counts,
    accessibility declarations and encryption declaration summaries

Each endpoint is independent: a 403/404 (or other failure) is recorded as
"unavailable: <status>" and the export continues. Only finding the app is fatal.

Deliberately excluded because the repository and its artifacts are public:
App Review and TestFlight contact names, phone numbers and email addresses, demo
account credentials, review notes text, users, testers, customer reviews, and
sales or financial reports. Any key that looks like contact or credential data is
also removed from the whole document before it is written.

Not available through the API: App Privacy ("nutrition label") answers. Review
those in App Store Connect under App Privacy.
"""
import argparse
import base64
import datetime
import http.client
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import tempfile
import time
import urllib.error
import urllib.parse
import urllib.request

ROOT = Path(__file__).resolve().parents[1]
API_HOST = "api.appstoreconnect.apple.com"
API_ROOT = "https://" + API_HOST
TOKEN_LIFETIME = 15 * 60  # Apple rejects tokens that live longer than 20 minutes.
PAGE_SIZE = 50  # Every App Store Connect list endpoint accepts at least 50.
MAX_PAGES = 100
# Matched against every key of the exported document, case-insensitively.
PERSONAL_KEY = re.compile(r"contact|demoAccount(Name|Password)|email|phone|firstName|lastName|password|userName|tester", re.I)


class ApiError(Exception):
    def __init__(self, status, path):
        super().__init__(f"App Store Connect GET {path}: HTTP {status}")
        self.status = status


# --- ES256 token -------------------------------------------------------------

def b64url(data):
    return base64.urlsafe_b64encode(data).rstrip(b"=").decode()


def der_to_raw_signature(der, size=32):
    """Convert an ASN.1 DER ECDSA signature (what openssl prints) to the JWS r||s form."""
    def length_at(index):
        first = der[index]
        if first < 0x80:
            return first, index + 1
        count = first & 0x7F
        if not 1 <= count <= 2:
            raise ValueError("Unsupported DER length")
        return int.from_bytes(der[index + 1:index + 1 + count], "big"), index + 1 + count

    try:
        if der[0] != 0x30:
            raise ValueError("Expected a DER sequence")
        length, index = length_at(1)
        if index + length != len(der):
            raise ValueError("DER sequence length mismatch")
        parts = []
        for _ in range(2):
            if der[index] != 0x02:
                raise ValueError("Expected a DER integer")
            length, index = length_at(index + 1)
            value = der[index:index + length].lstrip(b"\0")
            index += length
            if len(value) > size:
                raise ValueError("DER integer is too large for the curve")
            parts.append(value.rjust(size, b"\0"))
        if index != len(der):
            raise ValueError("Trailing bytes after the DER signature")
    except IndexError:
        raise ValueError("Truncated DER signature") from None
    return b"".join(parts)


def normalized_private_key(content):
    """Accept PEM text, PEM with literal \\n escapes, or base64-encoded PEM."""
    text = content.replace("\\n", "\n").strip()
    if "-----BEGIN" not in text:
        try:
            text = base64.b64decode(text, validate=False).decode().strip()
        except (ValueError, UnicodeDecodeError):
            text = ""
    if "-----BEGIN" not in text or "PRIVATE KEY-----" not in text:
        raise ValueError("APP_STORE_CONNECT_API_KEY_CONTENT is not a PEM private key")
    return text + "\n"


def make_jwt(key_path, key_id, issuer_id, now=None):
    now = int(time.time() if now is None else now)
    header = {"alg": "ES256", "kid": key_id, "typ": "JWT"}
    payload = {"iss": issuer_id, "iat": now - 10, "exp": now + TOKEN_LIFETIME, "aud": "appstoreconnect-v1"}
    signing_input = b64url(json.dumps(header, separators=(",", ":")).encode()) + "." + \
        b64url(json.dumps(payload, separators=(",", ":")).encode())
    signed = subprocess.run(["openssl", "dgst", "-sha256", "-sign", str(key_path)],
                            input=signing_input.encode(), capture_output=True)
    if signed.returncode != 0:
        raise ValueError("openssl could not sign the App Store Connect token")
    return signing_input + "." + b64url(der_to_raw_signature(signed.stdout))


class TokenSource:
    """Signs short-lived tokens from a private key held in a 0600 temporary file."""

    def __init__(self, key_id, issuer_id, key_content):
        self.key_id, self.issuer_id = key_id, issuer_id
        key = normalized_private_key(key_content)
        handle, self.key_path = tempfile.mkstemp(suffix=".p8")  # created with mode 0600
        with os.fdopen(handle, "w") as file:
            file.write(key)
        self.token, self.issued = None, 0.0

    def __call__(self):
        if not self.token or time.time() - self.issued > TOKEN_LIFETIME - 300:
            self.token, self.issued = make_jwt(self.key_path, self.key_id, self.issuer_id), time.time()
            if os.environ.get("GITHUB_ACTIONS") == "true":
                print("::add-mask::" + self.token, flush=True)
        return self.token

    def close(self):
        if os.path.exists(self.key_path):
            os.remove(self.key_path)


# --- GET-only client -----------------------------------------------------------

class _NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, *args, **kwargs):
        return None  # Never forward the bearer token to another location.


_OPENER = urllib.request.build_opener(_NoRedirect)


def urllib_fetch(url, headers):
    request = urllib.request.Request(url, headers=headers, method="GET")
    try:
        with _OPENER.open(request, timeout=60) as response:
            return response.status, response.read()
    except urllib.error.HTTPError as error:
        error.close()
        return error.code, b""


class AppStoreConnect:
    def __init__(self, token, fetch=urllib_fetch, sleep=time.sleep):
        self.token, self.fetch, self.sleep = token, fetch, sleep
        self.requests = 0

    def get(self, path, params=None):
        url = path if path.startswith("https:") else API_ROOT + path
        if params:
            url += ("&" if "?" in url else "?") + urllib.parse.urlencode(params)
        parsed = urllib.parse.urlsplit(url)
        if parsed.scheme != "https" or parsed.hostname != API_HOST or parsed.port is not None:
            raise ValueError("Refusing a request outside the App Store Connect API")
        for attempt in range(4):
            self.requests += 1
            status, body = self.fetch(url, {"Authorization": "Bearer " + self.token(), "Accept": "application/json"})
            if status == 200:
                return json.loads(body)
            if (status == 429 or status >= 500) and attempt < 3:
                self.sleep(5 * 2 ** attempt)
                continue
            # Response bodies are never logged or stored.
            raise ApiError(status, parsed.path)

    def list(self, path, params=None):
        items, page = [], self.get(path, params)
        for _ in range(MAX_PAGES):
            items.extend(page.get("data") or [])
            following = (page.get("links") or {}).get("next")
            if not following:
                return items
            page = self.get(following)
        raise ValueError("Too many result pages for " + path)

    def one(self, path, params=None):
        """A to-one relationship; Apple answers 404 (or null data) when it is absent."""
        try:
            return self.get(path, params).get("data")
        except ApiError as error:
            if error.status == 404:
                return None
            raise


# --- shaping helpers -------------------------------------------------------------

def unavailable(error):
    if isinstance(error, ApiError):
        return f"unavailable: {error.status}"
    if isinstance(error, (OSError, http.client.HTTPException)):  # includes URLError
        return "unavailable: network error"
    return f"unavailable: unexpected response ({type(error).__name__})"


def attempt(function, *args):
    try:
        return function(*args)
    except (ApiError, OSError, http.client.HTTPException, KeyError, TypeError, ValueError) as error:
        return unavailable(error)


def record(item, keys=None):
    attributes = item.get("attributes") or {}
    if keys is not None:
        attributes = {key: attributes.get(key) for key in keys}
    return {"id": item.get("id"), **attributes}


def scrub(value):
    """Drop contact and credential keys anywhere in the document."""
    if isinstance(value, dict):
        return {key: scrub(item) for key, item in value.items() if not PERSONAL_KEY.search(key)}
    if isinstance(value, list):
        return [scrub(item) for item in value]
    return value


def review_detail_summary(detail):
    """App Review / TestFlight review detail without names, phone, email, credentials or notes text."""
    if detail is None:
        return None
    attributes = detail.get("attributes") or {}
    notes = attributes.get("notes") or ""
    return {"demoAccountRequired": attributes.get("demoAccountRequired"), "notesLength": len(notes)}


def counted(items, *fields):
    summary = {"count": len(items)}
    for field in fields:
        values = {}
        for item in items:
            key = str((item.get("attributes") or {}).get(field))
            values[key] = values.get(key, 0) + 1
        summary["by_" + field] = dict(sorted(values.items()))
    return summary


def text_lengths(attributes, fields):
    return {field: len(attributes[field]) for field in fields if isinstance(attributes.get(field), str)}


def territory_code(item):
    related = ((item.get("relationships") or {}).get("territory") or {}).get("data") or {}
    if related.get("id"):
        return related["id"]
    try:  # Apple's territory availability IDs are base64 JSON such as {"s": app, "t": "USA"}.
        return json.loads(base64.urlsafe_b64decode(item["id"] + "=" * (-len(item["id"]) % 4))).get("t")
    except (KeyError, ValueError, AttributeError):
        return None


# --- sections --------------------------------------------------------------------

class Exporter:
    def __init__(self, api, versions=3):
        self.api, self.versions = api, versions

    def list(self, path, params=None):
        return self.api.list(path, {"limit": PAGE_SIZE, **(params or {})})

    def related(self, path, keys=None):
        item = self.api.one(path)
        return None if item is None else record(item, keys)

    def find_app(self, bundle_id):
        apps = [app for app in self.api.list("/v1/apps", {"filter[bundleId]": bundle_id})
                if (app.get("attributes") or {}).get("bundleId") == bundle_id]
        if len(apps) != 1:
            raise SystemExit(f"Expected exactly one app for {bundle_id}; found {len(apps)}. Check the key's app access.")
        return apps[0]

    def app_info(self, info):
        info_id = info["id"]
        categories = ["primaryCategory", "primarySubcategoryOne", "primarySubcategoryTwo",
                      "secondaryCategory", "secondarySubcategoryOne", "secondarySubcategoryTwo"]
        localizations = []
        for item in self.list(f"/v1/appInfos/{info_id}/appInfoLocalizations"):
            localization = record(item)
            localization["characterCounts"] = text_lengths(item.get("attributes") or {}, ["name", "subtitle"])
            localizations.append(localization)
        return {
            **record(info),
            "categories": {name: attempt(lambda: (self.related(f"/v1/appInfos/{info_id}/{name}") or {}).get("id"))
                           for name in categories},
            "ageRatingDeclaration": attempt(self.related, f"/v1/appInfos/{info_id}/ageRatingDeclaration"),
            "localizations": sorted(localizations, key=lambda item: item.get("locale") or ""),
        }

    def media_sets(self, localization_id, sets, type_field, items):
        """Display types and image/video counts only; asset URLs are not exported."""
        result = []
        for item in self.list(f"/v1/appStoreVersionLocalizations/{localization_id}/{sets}"):
            result.append({"displayType": (item.get("attributes") or {}).get(type_field),
                           "count": attempt(lambda: len(self.list(f"/v1/{sets}/{item['id']}/{items}")))})
        return sorted(result, key=lambda entry: str(entry["displayType"]))

    def version_localization(self, item):
        localization = record(item)
        localization["characterCounts"] = text_lengths(item.get("attributes") or {},
                                                       ["description", "keywords", "promotionalText", "whatsNew"])
        localization["screenshotSets"] = attempt(self.media_sets, item["id"], "appScreenshotSets",
                                                 "screenshotDisplayType", "appScreenshots")
        localization["appPreviewSets"] = attempt(self.media_sets, item["id"], "appPreviewSets",
                                                 "previewType", "appPreviews")
        return localization

    def version_localizations(self, version_id):
        items = self.list(f"/v1/appStoreVersions/{version_id}/appStoreVersionLocalizations")
        return sorted((self.version_localization(item) for item in items), key=lambda item: item.get("locale") or "")

    def version(self, item):
        version_id = item["id"]
        build = ["version", "uploadedDate", "processingState", "minOsVersion", "buildAudienceType", "usesNonExemptEncryption"]
        return {
            **record(item),
            "phasedRelease": attempt(self.related, f"/v1/appStoreVersions/{version_id}/appStoreVersionPhasedRelease"),
            "build": attempt(self.related, f"/v1/appStoreVersions/{version_id}/build", build),
            "appStoreReviewDetail": attempt(lambda: review_detail_summary(
                self.api.one(f"/v1/appStoreVersions/{version_id}/appStoreReviewDetail"))),
            "localizations": attempt(self.version_localizations, version_id),
        }

    def versions_section(self, app_id):
        items = self.list(f"/v1/apps/{app_id}/appStoreVersions", {"filter[platform]": "IOS"})
        items.sort(key=lambda item: (item.get("attributes") or {}).get("createdDate") or "", reverse=True)
        return {"total": len(items), "exported": [self.version(item) for item in items[:self.versions]]}

    def pricing(self, app_id):
        schedule = self.api.one(f"/v1/apps/{app_id}/appPriceSchedule")
        if schedule is None:
            return None
        base = self.related(f"/v1/appPriceSchedules/{schedule['id']}/baseTerritory") or {}
        response = self.api.get(f"/v1/appPriceSchedules/{schedule['id']}/manualPrices",
                                {"include": "appPricePoint,territory", "limit": PAGE_SIZE})
        points = {item["id"]: item.get("attributes") or {} for item in response.get("included") or []
                  if item.get("type") == "appPricePoints"}
        today = datetime.date.today().isoformat()
        prices = []
        for item in response.get("data") or []:
            attributes, relationships = item.get("attributes") or {}, item.get("relationships") or {}
            point = ((relationships.get("appPricePoint") or {}).get("data") or {}).get("id")
            start, end = attributes.get("startDate"), attributes.get("endDate")
            prices.append({"territory": ((relationships.get("territory") or {}).get("data") or {}).get("id"),
                           "startDate": start, "endDate": end,
                           "customerPrice": points.get(point, {}).get("customerPrice"),
                           "current": (start is None or start <= today) and (end is None or end > today)})
        current = [price["customerPrice"] for price in prices if price["current"] and price["territory"] == base.get("id")]
        return {"baseTerritory": base.get("id"), "baseCurrency": base.get("currency"),
                "currentBasePrice": current[0] if current else None, "manualPrices": prices,
                "manualPricesTruncated": bool((response.get("links") or {}).get("next"))}

    def availability(self, app_id):
        availability = self.api.one(f"/v1/apps/{app_id}/appAvailabilityV2")
        if availability is None:
            return None
        territories = self.list(f"/v2/appAvailabilities/{availability['id']}/territoryAvailabilities",
                                {"include": "territory"})
        available, unavailable_territories, pre_orders = [], {}, []
        for item in territories:
            attributes, code = item.get("attributes") or {}, str(territory_code(item))
            if attributes.get("available"):
                available.append(code)
            else:
                unavailable_territories[code] = attributes.get("contentStatuses")
            if attributes.get("preOrderEnabled"):
                pre_orders.append(code)
        return {"availableInNewTerritories": (availability.get("attributes") or {}).get("availableInNewTerritories"),
                "availableTerritoryCount": len(available), "availableTerritories": sorted(available),
                "unavailableTerritories": dict(sorted(unavailable_territories.items())),
                "preOrderTerritories": sorted(pre_orders)}

    def subscriptions(self, app_id):
        groups = []
        for group in self.list(f"/v1/apps/{app_id}/subscriptionGroups"):
            items = self.list(f"/v1/subscriptionGroups/{group['id']}/subscriptions")
            groups.append({**record(group, ["referenceName"]), "subscriptions": [
                record(item, ["name", "productId", "state", "subscriptionPeriod", "familySharable", "groupLevel"])
                for item in items]})
        return {"groupCount": len(groups), "subscriptionCount": sum(len(group["subscriptions"]) for group in groups),
                "groups": groups}

    def testflight(self, app_id):
        """Counts only: no group names, public links, testers or review contacts."""
        groups = self.list(f"/v1/apps/{app_id}/betaGroups")
        flagged = lambda name: sum(1 for group in groups if (group.get("attributes") or {}).get(name))
        return {"betaAppReviewDetail": attempt(lambda: review_detail_summary(self.api.one(f"/v1/apps/{app_id}/betaAppReviewDetail"))),
                "betaGroups": {"count": len(groups), "internal": flagged("isInternalGroup"),
                               "publicLinkEnabled": flagged("publicLinkEnabled")}}

    def export(self, bundle_id, team_id=None):
        app = self.find_app(bundle_id)
        app_id = app["id"]
        listing = lambda relationship: self.list(f"/v1/apps/{app_id}/{relationship}")
        document = {
            "schema_version": 1,
            "generated_at": datetime.datetime.now(datetime.timezone.utc).replace(microsecond=0).isoformat(),
            "source": API_ROOT + " (GET requests only)",
            "bundle_id": bundle_id, "team_id": team_id, "source_commit": os.environ.get("GITHUB_SHA"),
            "notes": [
                "App Privacy (nutrition label) answers are not available through the App Store Connect API; review them in App Store Connect.",
                "Contact details, demo account credentials, review notes text, users, testers and sales data are deliberately excluded.",
                "A value of 'unavailable: <status>' means that endpoint failed for this API key; the rest of the export is unaffected.",
            ],
            "app": record(app),
            "appInfos": attempt(lambda: [self.app_info(info) for info in self.api.list(f"/v1/apps/{app_id}/appInfos")]),
            "appStoreVersions": attempt(self.versions_section, app_id),
            "pricing": attempt(self.pricing, app_id),
            "availability": attempt(self.availability, app_id),
            "inAppPurchases": attempt(lambda: counted(listing("inAppPurchasesV2"), "inAppPurchaseType", "state")),
            "subscriptions": attempt(self.subscriptions, app_id),
            "customProductPages": attempt(lambda: [record(item, ["name", "url", "visible"])
                                                   for item in listing("appCustomProductPages")]),
            "productPageOptimization": attempt(lambda: [
                record(item, ["name", "platform", "state", "trafficProportion", "reviewRequired", "startDate", "endDate"])
                for item in listing("appStoreVersionExperimentsV2")]),
            "appEvents": attempt(lambda: counted(listing("appEvents"), "eventState", "badge")),
            "testFlight": attempt(self.testflight, app_id),
            "accessibilityDeclarations": attempt(lambda: [record(item) for item in listing("accessibilityDeclarations")]),
            "encryptionDeclarations": attempt(lambda: [
                record(item, ["platform", "appEncryptionDeclarationState", "usesEncryption", "exempt",
                              "containsProprietaryCryptography", "containsThirdPartyCryptography",
                              "availableOnFrenchStore", "createdDate"])
                for item in self.list("/v1/appEncryptionDeclarations", {"filter[app]": app_id})]),
        }
        return scrub(document)


def unavailable_paths(value, path="$"):
    if isinstance(value, str) and value.startswith("unavailable:"):
        yield path, value
    elif isinstance(value, dict):
        for key, item in value.items():
            yield from unavailable_paths(item, f"{path}.{key}")
    elif isinstance(value, list):
        for index, item in enumerate(value):
            yield from unavailable_paths(item, f"{path}[{index}]")


def main(argv=None):
    parser = argparse.ArgumentParser(description="Export App Store Connect settings (read-only).")
    parser.add_argument("--config", default=str(ROOT / ".github/ios-release.json"))
    parser.add_argument("--output", default=str(ROOT / "build/app-store-settings/app-store-settings.json"))
    parser.add_argument("--versions", type=int, default=3, help="number of most recent app store versions to export")
    args = parser.parse_args(argv)
    config = json.loads(Path(args.config).read_text())
    missing = [name for name in ["APP_STORE_CONNECT_API_KEY_ID", "APP_STORE_CONNECT_API_KEY_ISSUER_ID",
                                 "APP_STORE_CONNECT_API_KEY_CONTENT"] if not os.environ.get(name)]
    if missing:
        raise SystemExit("Missing environment: " + ", ".join(missing))
    token = TokenSource(os.environ["APP_STORE_CONNECT_API_KEY_ID"], os.environ["APP_STORE_CONNECT_API_KEY_ISSUER_ID"],
                        os.environ["APP_STORE_CONNECT_API_KEY_CONTENT"])
    try:
        api = AppStoreConnect(token)
        document = Exporter(api, max(1, args.versions)).export(config["app_store"]["bundle_id"], config.get("team_id"))
    finally:
        token.close()
    output = Path(args.output)
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_text(json.dumps(document, indent=2, ensure_ascii=False, sort_keys=False) + "\n")
    gaps = list(unavailable_paths(document))
    # Paths and statuses only: the run summary of a public repository is public.
    summary = "\n".join([f"Exported App Store Connect settings for {config['app_store']['bundle_id']} "
                         f"with {api.requests} GET requests.", "", f"Unavailable endpoints: {len(gaps)}",
                         *(f"- `{path}`: {value}" for path, value in gaps)])
    print(summary)
    if os.environ.get("GITHUB_STEP_SUMMARY"):
        with open(os.environ["GITHUB_STEP_SUMMARY"], "a") as file:
            file.write(summary + "\n")
    return 0


if __name__ == "__main__":
    sys.exit(main())
