#!/usr/bin/env python3
"""Register iPhone UDIDs with the Apple Developer account.

Development-signed builds only install on devices listed in the team's
provisioning profile. This script adds any missing UDIDs through the
App Store Connect API so the export step can include them.

Environment:
  APPSTORE_ISSUER_ID, APPSTORE_API_KEY_ID, APPSTORE_API_KEY_PATH
  DEV_DEVICE_UDIDS  comma- or whitespace-separated UDIDs, optionally
                    written as NAME=UDID to set the portal device name.

Uses only the Python standard library and the openssl CLI.
"""

import base64
import json
import os
import re
import subprocess
import sys
import time
import urllib.error
import urllib.parse
import urllib.request

API = "https://api.appstoreconnect.apple.com/v1"


def b64url(data: bytes) -> str:
    return base64.urlsafe_b64encode(data).rstrip(b"=").decode()


def der_to_raw_signature(der: bytes) -> bytes:
    """Convert an ECDSA DER signature from openssl into JWS r||s form."""
    if der[0] != 0x30:
        raise ValueError("unexpected signature encoding")
    index = 2 if der[1] < 0x80 else 2 + (der[1] & 0x7F)
    parts = []
    for _ in range(2):
        if der[index] != 0x02:
            raise ValueError("unexpected signature encoding")
        length = der[index + 1]
        value = der[index + 2:index + 2 + length].lstrip(b"\x00")
        parts.append(value.rjust(32, b"\x00"))
        index += 2 + length
    return b"".join(parts)


def make_token(issuer: str, key_id: str, key_path: str) -> str:
    header = {"alg": "ES256", "kid": key_id, "typ": "JWT"}
    now = int(time.time())
    payload = {"iss": issuer, "iat": now, "exp": now + 600, "aud": "appstoreconnect-v1"}
    signing_input = f"{b64url(json.dumps(header).encode())}.{b64url(json.dumps(payload).encode())}"
    der = subprocess.run(
        ["openssl", "dgst", "-sha256", "-sign", key_path],
        input=signing_input.encode(),
        capture_output=True,
        check=True,
    ).stdout
    return f"{signing_input}.{b64url(der_to_raw_signature(der))}"


def request(token: str, method: str, path: str, body=None):
    data = json.dumps(body).encode() if body is not None else None
    req = urllib.request.Request(f"{API}{path}", data=data, method=method)
    req.add_header("Authorization", f"Bearer {token}")
    req.add_header("Content-Type", "application/json")
    try:
        with urllib.request.urlopen(req) as response:
            return json.load(response)
    except urllib.error.HTTPError as error:
        detail = error.read().decode(errors="replace")
        raise SystemExit(f"App Store Connect API {method} {path} failed: HTTP {error.code}\n{detail}")


def parse_devices(raw: str):
    devices = []
    for item in re.split(r"[\s,]+", raw.strip()):
        if not item:
            continue
        name, _, udid = item.rpartition("=")
        devices.append((name or f"Dev iPhone {udid[-6:]}", udid))
    return devices


def main() -> int:
    devices = parse_devices(os.environ.get("DEV_DEVICE_UDIDS", ""))
    if not devices:
        print("DEV_DEVICE_UDIDS is empty; set the DEV_DEVICE_UDIDS repository secret.", file=sys.stderr)
        return 1

    token = make_token(
        os.environ["APPSTORE_ISSUER_ID"],
        os.environ["APPSTORE_API_KEY_ID"],
        os.environ["APPSTORE_API_KEY_PATH"],
    )

    for name, udid in devices:
        query = urllib.parse.urlencode({"filter[udid]": udid, "limit": 1})
        existing = request(token, "GET", f"/devices?{query}")["data"]
        if existing:
            status = existing[0]["attributes"].get("status")
            print(f"Device ...{udid[-6:]} already registered ({status}).")
            if status != "ENABLED":
                print(f"Device ...{udid[-6:]} is not ENABLED; enable it in the Developer portal.", file=sys.stderr)
                return 1
            continue
        body = {"data": {"type": "devices", "attributes": {"name": name, "platform": "IOS", "udid": udid}}}
        request(token, "POST", "/devices", body)
        print(f"Registered device ...{udid[-6:]} as '{name}'.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
