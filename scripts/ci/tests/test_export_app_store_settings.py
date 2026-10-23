import base64
import importlib.util
import json
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest
import urllib.parse

SCRIPT = Path(__file__).resolve().parents[2] / "export_app_store_settings.py"
spec = importlib.util.spec_from_file_location("export_app_store_settings", SCRIPT)
exporter = importlib.util.module_from_spec(spec)
spec.loader.exec_module(exporter)


def raw_to_der(raw):
    def integer(value):
        value = value.lstrip(b"\0") or b"\0"
        if value[0] & 0x80:
            value = b"\0" + value
        return b"\x02" + bytes([len(value)]) + value
    body = integer(raw[:32]) + integer(raw[32:])
    return b"\x30" + bytes([len(body)]) + body


def decode_segment(segment):
    return json.loads(base64.urlsafe_b64decode(segment + "=" * (-len(segment) % 4)))


class FakeApi:
    """Answers by URL path; anything unknown is a 403, like a key without that role."""

    def __init__(self, routes):
        self.routes, self.calls = routes, []

    def __call__(self, url, headers):
        self.calls.append((url, headers))
        response = self.routes.get(urllib.parse.urlsplit(url).path)
        if response is None:
            return 403, b""
        status, body = response if isinstance(response, tuple) else (200, response)
        return status, json.dumps(body).encode()


def client(routes):
    fake = FakeApi(routes)
    return exporter.AppStoreConnect(lambda: "token", fetch=fake, sleep=lambda seconds: None), fake


class SignatureTests(unittest.TestCase):
    def test_der_signature_becomes_fixed_width_r_and_s(self):
        r = b"\x80" + b"\x11" * 31  # high bit set: DER adds a leading zero byte
        s = b"\x00" + b"\x22" * 31  # leading zero: DER drops it
        self.assertEqual(exporter.der_to_raw_signature(raw_to_der(r + s)), r + s)
        long_form = b"\x30\x81\x44\x02\x20" + b"\x11" * 32 + b"\x02\x20" + b"\x22" * 32
        self.assertEqual(exporter.der_to_raw_signature(long_form), b"\x11" * 32 + b"\x22" * 32)

    def test_malformed_der_is_rejected(self):
        valid = raw_to_der(b"\x11" * 64)
        for der in [b"", b"\x31" + valid[1:], valid[:-1], valid + b"\0",
                    b"\x30\x26\x02\x21\x01" + b"\x11" * 32 + b"\x02\x01\x01"]:
            with self.assertRaises(ValueError):
                exporter.der_to_raw_signature(der)

    @unittest.skipUnless(shutil.which("openssl"), "openssl is required for ES256 signing")
    def test_token_is_an_es256_jwt_that_openssl_verifies(self):
        with tempfile.TemporaryDirectory() as temp:
            temp = Path(temp)
            run = lambda *args: subprocess.run(["openssl", *args], check=True, capture_output=True)
            run("ecparam", "-name", "prime256v1", "-genkey", "-noout", "-out", str(temp / "sec1.pem"))
            run("pkcs8", "-topk8", "-nocrypt", "-in", str(temp / "sec1.pem"), "-out", str(temp / "key.p8"))
            run("ec", "-in", str(temp / "sec1.pem"), "-pubout", "-out", str(temp / "public.pem"))
            pem = (temp / "key.p8").read_text()
            escaped, encoded = pem.replace("\n", "\\n"), base64.b64encode(pem.encode()).decode()
            for content in [pem, escaped, encoded]:
                self.assertEqual(exporter.normalized_private_key(content), pem.strip() + "\n")
            with self.assertRaises(ValueError):
                exporter.normalized_private_key("not a key")

            token = exporter.make_jwt(temp / "key.p8", "KEYID", "issuer", now=1_000_000)
            header, payload, signature = token.split(".")
            self.assertEqual(decode_segment(header), {"alg": "ES256", "kid": "KEYID", "typ": "JWT"})
            self.assertEqual(decode_segment(payload), {"iss": "issuer", "iat": 999_990, "exp": 1_000_900,
                                                       "aud": "appstoreconnect-v1"})
            raw = base64.urlsafe_b64decode(signature + "=" * (-len(signature) % 4))
            self.assertEqual(len(raw), 64)
            (temp / "signature.der").write_bytes(raw_to_der(raw))
            verified = subprocess.run(["openssl", "dgst", "-sha256", "-verify", str(temp / "public.pem"),
                                       "-signature", str(temp / "signature.der")],
                                      input=(header + "." + payload).encode(), capture_output=True)
            self.assertEqual(verified.returncode, 0, verified.stdout + verified.stderr)


class ClientTests(unittest.TestCase):
    def test_pagination_stays_on_the_apple_api(self):
        api, fake = client({"/v1/apps/1/betaGroups": {
            "data": [{"id": "a"}], "links": {"next": "https://api.appstoreconnect.apple.com/v1/next?cursor=x"}},
            "/v1/next": {"data": [{"id": "b"}], "links": {}}})
        self.assertEqual([item["id"] for item in api.list("/v1/apps/1/betaGroups", {"limit": 50})], ["a", "b"])
        self.assertTrue(all(headers["Authorization"] == "Bearer token" for _, headers in fake.calls))
        for url in ["https://example.com/v1/apps", "http://api.appstoreconnect.apple.com/v1/apps",
                    "https://api.appstoreconnect.apple.com:8443/v1/apps"]:
            with self.assertRaises(ValueError):
                api.get(url)
        api, _ = client({"/v1/apps": {"data": [], "links": {"next": "https://example.com/steal"}}})
        with self.assertRaises(ValueError):
            api.list("/v1/apps")

    def test_throttling_retries_but_missing_access_does_not(self):
        responses = [(429, b""), (503, b""), (200, b'{"data": null}')]
        api = exporter.AppStoreConnect(lambda: "token", fetch=lambda url, headers: responses.pop(0), sleep=lambda s: None)
        self.assertIsNone(api.one("/v1/apps/1/appPriceSchedule"))
        api, fake = client({"/v1/apps/1/appAvailabilityV2": (404, {})})
        self.assertIsNone(api.one("/v1/apps/1/appAvailabilityV2"))
        with self.assertRaises(exporter.ApiError):
            api.one("/v1/apps/1/appPriceSchedule")
        self.assertEqual(len(fake.calls), 2)


class ExportTests(unittest.TestCase):
    PERSONAL = {"contactFirstName": "Pat", "contactLastName": "Doe", "contactPhone": "+1 555 0100",
                "contactEmail": "pat@example.com", "demoAccountName": "demo-user", "demoAccountPassword": "hunter2",
                "notes": "Call Pat on +1 555 0100", "demoAccountRequired": True}

    def test_unavailable_endpoints_are_recorded_and_personal_data_is_omitted(self):
        api, _ = client({
            "/v1/apps": {"data": [{"id": "1", "attributes": {"bundleId": "com.example.app", "name": "Example"}}]},
            "/v1/apps/1/appStoreVersions": {"data": [
                {"id": "old", "attributes": {"versionString": "1.0", "createdDate": "2025-01-01T00:00:00Z"}},
                {"id": "new", "attributes": {"versionString": "1.1", "createdDate": "2026-01-01T00:00:00Z"}}]},
            "/v1/appStoreVersions/new/appStoreReviewDetail": {"data": {"id": "r", "attributes": self.PERSONAL}},
            "/v1/appStoreVersions/new/appStoreVersionPhasedRelease": (404, {}),
            "/v1/appStoreVersions/new/appStoreVersionLocalizations": {"data": [
                {"id": "l", "attributes": {"locale": "en-US", "keywords": "photo,privacy"}}]},
            "/v1/appStoreVersionLocalizations/l/appScreenshotSets": {"data": [
                {"id": "s", "attributes": {"screenshotDisplayType": "APP_IPHONE_67"}}]},
            "/v1/appScreenshotSets/s/appScreenshots": {"data": [{"id": "1"}, {"id": "2"}]},
            "/v1/apps/1/betaAppReviewDetail": {"data": {"id": "1", "attributes": self.PERSONAL}},
            "/v1/apps/1/betaGroups": {"data": [{"id": "g", "attributes": {"name": "Friends", "isInternalGroup": True}}]},
        })
        document = exporter.Exporter(api, versions=1).export("com.example.app", "TEAM")
        versions = document["appStoreVersions"]
        self.assertEqual((versions["total"], [v["versionString"] for v in versions["exported"]]), (2, ["1.1"]))
        version = versions["exported"][0]
        self.assertEqual(version["appStoreReviewDetail"], {"demoAccountRequired": True, "notesLength": 23})
        self.assertIsNone(version["phasedRelease"])
        self.assertEqual(version["build"], "unavailable: 403")
        localization = version["localizations"][0]
        self.assertEqual(localization["characterCounts"], {"keywords": 13})
        self.assertEqual(localization["screenshotSets"], [{"displayType": "APP_IPHONE_67", "count": 2}])
        self.assertEqual(localization["appPreviewSets"], "unavailable: 403")
        self.assertEqual(document["testFlight"]["betaGroups"], {"count": 1, "internal": 1, "publicLinkEnabled": 0})
        for section in ["appInfos", "pricing", "availability", "inAppPurchases", "productPageOptimization"]:
            self.assertEqual(document[section], "unavailable: 403")
        text = json.dumps(document)
        for value in ["Pat", "Doe", "555", "example.com", "demo-user", "hunter2", "Friends"]:
            self.assertNotIn(value, text)
        self.assertIn(("$.pricing", "unavailable: 403"), list(exporter.unavailable_paths(document)))

    def test_scrub_removes_contact_and_credential_keys_anywhere(self):
        scrubbed = exporter.scrub({"supportUrl": "https://example.org", "demoAccountRequired": False,
                                   "nested": [{"feedbackEmail": "x", "contactPhone": "y", "demoAccountPassword": "z",
                                               "betaTesters": [], "locale": "en-US"}]})
        self.assertEqual(scrubbed, {"supportUrl": "https://example.org", "demoAccountRequired": False,
                                    "nested": [{"locale": "en-US"}]})


if __name__ == "__main__":
    unittest.main()
