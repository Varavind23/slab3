# mitmproxy addon: record what Courtyard's iOS app actually calls (spike, 2026-08-29).
#
# Why this exists: Slabs sources Courtyard from its Algolia MARKETPLACE indices,
# which describe vaulted inventory. Courtyard's own app scans a slab and returns a
# market value + confidence for cards it does NOT hold — verified on cert 96679812
# (their app: $50.80 / confidence 2; that slab is absent from the index entirely).
# The whole courtyard.io web API was enumerated from their bundle — 172 endpoints,
# with no cert-lookup and no price-by-card-identity route — so the pricing service
# the scanner uses is reachable only from the mobile app. This captures it.
#
# Run:   mitmdump -s spike/courtyard/capture-app.py --listen-port 8080
# Phone: Wi-Fi > (i) > Configure Proxy > Manual > <mac-ip>:8080
#        then http://mit.it in Safari to install the CA, and
#        Settings > General > About > Certificate Trust Settings to TRUST it.
#
# Everything interesting lands in spike/.state/courtyard-app.jsonl (gitignored).
# Auth headers are redacted on the way in: this file is evidence, not a credential
# store, and the endpoint shape is what we need — not the user's token.

import json
import os
import time

HOSTS = ("courtyard.io", "courtyard.com")
OUT = os.path.join(os.path.dirname(__file__), "..", ".state", "courtyard-app.jsonl")
SENSITIVE = {"authorization", "cookie", "set-cookie", "x-api-key", "privy-app-id"}
MAX_BODY = 200_000  # a pricing payload is small; don't inhale image bytes


def _headers(h):
    return {k: ("<redacted>" if k.lower() in SENSITIVE else v) for k, v in h.items()}


def _body(content, headers):
    ctype = headers.get("content-type", "")
    if not content:
        return None
    if "json" not in ctype and "text" not in ctype and "form" not in ctype:
        return f"<{len(content)} bytes {ctype or 'unknown'}>"
    if len(content) > MAX_BODY:
        return f"<{len(content)} bytes, truncated>"
    try:
        return json.loads(content)
    except Exception:
        try:
            return content.decode("utf8", "replace")
        except Exception:
            return f"<{len(content)} bytes>"


def response(flow):
    host = flow.request.pretty_host
    if not any(h in host for h in HOSTS):
        return
    os.makedirs(os.path.dirname(OUT), exist_ok=True)
    entry = {
        "t": time.strftime("%H:%M:%S"),
        "method": flow.request.method,
        "url": flow.request.pretty_url,
        "status": flow.response.status_code,
        "req_headers": _headers(flow.request.headers),
        "req_body": _body(flow.request.raw_content, flow.request.headers),
        "res_body": _body(flow.response.raw_content, flow.response.headers),
    }
    with open(OUT, "a", encoding="utf8") as f:
        f.write(json.dumps(entry, ensure_ascii=False) + "\n")
    # Live feedback in the terminal so the person holding the phone can see it work.
    print(f"  [{entry['status']}] {entry['method']} {flow.request.path[:96]}")


def error(flow):
    """A TLS failure here is the signal that matters: it means the app pins its
    certificate, and no amount of proxy fiddling will open it. Say so loudly
    rather than leaving a silent gap in the capture."""
    host = getattr(flow.request, "pretty_host", "?") if flow.request else "?"
    if any(h in str(host) for h in HOSTS):
        print(f"  !! FAILED {host} — possible certificate pinning")
