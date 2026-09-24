#!/usr/bin/env python3
"""Minimal in-memory mock of the Cloudflare v4 API used by the Octoflare test suite.

Usage: mock_api.py <port> <repo-root>

Besides the API it serves:
  GET  /__health          liveness probe
  GET  /__log             every request received since the last reset (JSON)
  POST /__reset           reset state and log
  POST /__seed?records=N  add N A records to zone123
  GET  /raw/<ref>/src/... files from the repository (module auto-install tests)
"""
import copy
import json
import os
import re
import sys
import uuid
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlparse

PORT = int(sys.argv[1]) if len(sys.argv) > 1 else 8787
REPO_ROOT = sys.argv[2] if len(sys.argv) > 2 else os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

DEFAULT_SETTINGS = {
    "security_level": "medium", "ssl": "full", "always_use_https": "off", "development_mode": "off",
    "min_tls_version": "1.0", "tls_1_3": "on", "automatic_https_rewrites": "off", "cache_level": "aggressive",
    "browser_cache_ttl": 14400, "brotli": "on", "opportunistic_encryption": "on",
    "security_header": {"strict_transport_security": {"enabled": False, "max_age": 0, "include_subdomains": False, "preload": False, "nosniff": False}},
}


def fresh_state():
    return {
        "zones": [
            {"id": "zone123", "name": "example.com", "status": "active", "paused": False, "type": "full",
             "account": {"id": "acc123", "name": "Test Account"}, "plan": {"name": "Free Website"},
             "name_servers": ["a.ns.cloudflare.com", "b.ns.cloudflare.com"]},
            {"id": "zone456", "name": "other.org", "status": "active", "paused": False, "type": "full",
             "account": {"id": "acc123", "name": "Test Account"}, "plan": {"name": "Free Website"},
             "name_servers": ["a.ns.cloudflare.com", "b.ns.cloudflare.com"]},
        ],
        "dns": {"zone123": [], "zone456": []},
        "settings": {"zone123": copy.deepcopy(DEFAULT_SETTINGS), "zone456": copy.deepcopy(DEFAULT_SETTINGS)},
        "rulesets": {"zone123": [], "zone456": []},
        "access_rules": {"zone123": [], "zone456": []},
        "pagerules": {"zone123": [], "zone456": []},
        "tiered_cache": {"zone123": "off", "zone456": "off"},
        "flaky_hits": 0,
        "ratelimit_hits": 0,
        "counter": 0,
        "log": [],
    }


STATE = fresh_state()


def normalize_txt(rec):
    """Store TXT content the way the real API does: as RFC 1035 quoted strings."""
    content = rec.get("content")
    if rec.get("type") == "TXT" and isinstance(content, str) and content and not content.startswith('"'):
        rec["content"] = '"%s"' % content.replace("\\", "\\\\").replace('"', '\\"')
    return rec


NUMERIC_SETTINGS = ("browser_cache_ttl", "challenge_ttl", "max_upload", "edge_cache_ttl", "proxy_read_timeout")
STRING_ENUM_SETTINGS = {"min_tls_version": ("1.0", "1.1", "1.2", "1.3"), "origin_max_http_version": ("1", "2"),
                        "security_level": ("essentially_off", "low", "medium", "high", "under_attack")}


def invalid_setting(name, value):
    """Return an error message when the value has the wrong JSON type for the setting (like the real API)."""
    if name in NUMERIC_SETTINGS and (isinstance(value, bool) or not isinstance(value, (int, float))):
        return "Invalid value for zone setting %s (expected a number)" % name
    if name in STRING_ENUM_SETTINGS and value not in STRING_ENUM_SETTINGS[name]:
        return "Invalid value for zone setting %s" % name
    return None


def next_id(prefix):
    STATE["counter"] += 1
    return "%s%04d" % (prefix, STATE["counter"])


def envelope(result, info=None, success=True, errors=None, messages=None):
    body = {"success": success, "errors": errors or [], "messages": messages or [], "result": result}
    if info is not None:
        body["result_info"] = info
    return body


def paginate(items, query):
    page = int(query.get("page", ["1"])[0])
    per_page = int(query.get("per_page", ["20"])[0])
    total = len(items)
    total_pages = max(1, (total + per_page - 1) // per_page)
    chunk = items[(page - 1) * per_page: page * per_page]
    return chunk, {"page": page, "per_page": per_page, "count": len(chunk), "total_count": total, "total_pages": total_pages}


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, fmt, *args):  # quiet
        pass

    # ------------------------------------------------------------------ helpers
    def send_json(self, code, body, headers=None):
        data = json.dumps(body).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        for k, v in (headers or {}).items():
            self.send_header(k, v)
        self.end_headers()
        self.wfile.write(data)

    def send_text(self, code, text, ctype="text/plain"):
        data = text.encode()
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def not_found(self, msg="Not found"):
        self.send_json(404, envelope(None, success=False, errors=[{"code": 10000, "message": msg}]))

    def bad_request(self, msg, code=1004):
        self.send_json(400, envelope(None, success=False, errors=[{"code": code, "message": msg}]))

    def read_body(self):
        length = int(self.headers.get("Content-Length") or 0)
        raw = self.rfile.read(length) if length else b""
        ctype = self.headers.get("Content-Type", "")
        if raw and ctype.startswith("application/json"):
            try:
                return json.loads(raw.decode())
            except ValueError:
                return raw.decode(errors="replace")
        return raw.decode(errors="replace") if raw else None

    def authed(self):
        auth = self.headers.get("Authorization", "")
        if auth == "Bearer test-token":
            return True
        if self.headers.get("X-Auth-Key") == "test-key" and self.headers.get("X-Auth-Email"):
            return True
        return False

    # ------------------------------------------------------------------ dispatch
    def handle_any(self):
        global STATE
        parsed = urlparse(self.path)
        path = parsed.path
        query = parse_qs(parsed.query)
        body = self.read_body()
        method = self.command

        # test / service endpoints
        if path == "/__health":
            return self.send_text(200, "ok")
        if path == "/__log":
            return self.send_json(200, STATE["log"])
        if path == "/__reset":
            STATE = fresh_state()
            return self.send_json(200, {"reset": True})
        if path == "/__seed":
            n = int(query.get("records", ["100"])[0])
            for i in range(n):
                STATE["dns"]["zone123"].append(self.mk_record("zone123", {"type": "A", "name": "host%d.example.com" % i, "content": "203.0.113.%d" % (i % 250 + 1), "ttl": 1, "proxied": False}))
            return self.send_json(200, {"seeded": n})
        if path.startswith("/raw/"):
            rel = path.split("/", 3)[3] if path.count("/") >= 3 else ""
            file_path = os.path.normpath(os.path.join(REPO_ROOT, rel))
            if file_path.startswith(REPO_ROOT) and os.path.isfile(file_path):
                with open(file_path, "rb") as fh:
                    data = fh.read()
                self.send_response(200)
                self.send_header("Content-Type", "text/plain")
                self.send_header("Content-Length", str(len(data)))
                self.end_headers()
                self.wfile.write(data)
                return None
            return self.send_text(404, "missing")

        STATE["log"].append({"method": method, "path": path, "query": {k: v[0] for k, v in query.items()}, "body": body,
                             "headers": {"authorization": self.headers.get("Authorization", ""), "content-type": self.headers.get("Content-Type", "")}})

        if not path.startswith("/client/v4/"):
            return self.not_found("Unknown API base")
        api = path[len("/client/v4"):]

        if api == "/ips":
            return self.send_json(200, envelope({"ipv4_cidrs": ["173.245.48.0/20", "103.21.244.0/22"], "ipv6_cidrs": ["2400:cb00::/32"], "etag": "abc"}))

        if not self.authed():
            return self.send_json(401, envelope(None, success=False, errors=[{"code": 10000, "message": "Authentication error"}]))

        try:
            return self.route(method, api, query, body)
        except Exception as exc:  # pragma: no cover - surfaced in test output
            return self.send_json(500, envelope(None, success=False, errors=[{"code": 500, "message": "mock error: %r" % exc}]))

    def mk_record(self, zone_id, data):
        zone = next(z for z in STATE["zones"] if z["id"] == zone_id)
        rec = {"id": next_id("rec"), "zone_id": zone_id, "zone_name": zone["name"], "ttl": 1, "proxied": False,
               "created_on": "2025-01-01T00:00:00Z", "modified_on": "2025-01-01T00:00:00Z"}
        rec.update({k: v for k, v in data.items() if k not in ("id",)})
        return rec

    def route(self, method, api, query, body):
        # -------------------------------------------------------------- accounts / user
        if api == "/accounts" and method == "GET":
            items, info = paginate([{"id": "acc123", "name": "Test Account", "type": "standard"}], query)
            return self.send_json(200, envelope(items, info))
        if api == "/accounts/acc123" and method == "GET":
            return self.send_json(200, envelope({"id": "acc123", "name": "Test Account", "type": "standard"}))
        if api == "/user/tokens/verify":
            return self.send_json(200, envelope({"id": "tok123", "status": "active"}))
        if api == "/user":
            return self.send_json(200, envelope({"id": "user1", "email": "user@example.com"}))

        # -------------------------------------------------------------- zones
        if api == "/zones" and method == "GET":
            zones = STATE["zones"]
            if "name" in query:
                zones = [z for z in zones if z["name"] == query["name"][0]]
            items, info = paginate(zones, query)
            return self.send_json(200, envelope(items, info))
        if api == "/zones" and method == "POST":
            zone = {"id": next_id("zone"), "name": body["name"], "status": "pending", "paused": False, "type": body.get("type", "full"),
                    "account": {"id": body["account"]["id"], "name": "Test Account"}, "plan": {"name": "Free Website"}, "name_servers": []}
            STATE["zones"].append(zone)
            STATE["dns"][zone["id"]] = []
            STATE["settings"][zone["id"]] = copy.deepcopy(DEFAULT_SETTINGS)
            STATE["rulesets"][zone["id"]] = []
            STATE["access_rules"][zone["id"]] = []
            STATE["pagerules"][zone["id"]] = []
            STATE["tiered_cache"][zone["id"]] = "off"
            return self.send_json(200, envelope(zone))

        m = re.match(r"^/zones/([^/]+)(/.*)?$", api)
        if not m:
            return self.not_found()
        zone_id, rest = m.group(1), m.group(2) or ""
        zone = next((z for z in STATE["zones"] if z["id"] == zone_id), None)
        if zone is None:
            return self.not_found("Zone not found")

        if rest == "":
            if method == "GET":
                return self.send_json(200, envelope(zone))
            if method == "PATCH":
                zone.update({k: v for k, v in body.items() if k in ("paused", "type")})
                return self.send_json(200, envelope(zone))
            if method == "DELETE":
                STATE["zones"].remove(zone)
                return self.send_json(200, envelope({"id": zone_id}))
        if rest == "/activation_check":
            return self.send_json(200, envelope({"id": zone_id}))
        if rest == "/purge_cache":
            return self.send_json(200, envelope({"id": zone_id}))
        if rest == "/flaky":
            STATE["flaky_hits"] += 1
            if STATE["flaky_hits"] == 1:
                return self.send_json(503, envelope(None, success=False, errors=[{"code": 503, "message": "temporarily unavailable"}]))
            return self.send_json(200, envelope({"ok": True, "hits": STATE["flaky_hits"]}))
        if rest == "/ratelimited":
            STATE["ratelimit_hits"] += 1
            if STATE["ratelimit_hits"] == 1:
                return self.send_json(429, envelope(None, success=False, errors=[{"code": 10429, "message": "rate limited"}]), {"Retry-After": "1"})
            return self.send_json(200, envelope({"ok": True, "hits": STATE["ratelimit_hits"]}))

        # -------------------------------------------------------------- smart tiered cache
        if rest == "/cache/tiered_cache_smart_topology_enable":
            if method == "PATCH":
                if body.get("value") not in ("on", "off"):
                    return self.bad_request("Invalid value for tiered_cache_smart_topology_enable", 1007)
                STATE["tiered_cache"][zone_id] = body["value"]
            return self.send_json(200, envelope({"id": "tiered_cache_smart_topology_enable", "value": STATE["tiered_cache"][zone_id], "editable": True}))

        # -------------------------------------------------------------- settings
        settings = STATE["settings"][zone_id]
        if rest == "/settings":
            if method == "GET":
                return self.send_json(200, envelope([{"id": k, "value": v, "editable": True} for k, v in settings.items()]))
            if method == "PATCH":
                out = []
                for item in body.get("items", []):
                    msg = invalid_setting(item["id"], item["value"])
                    if msg:
                        return self.bad_request(msg, 1007)
                for item in body.get("items", []):
                    settings[item["id"]] = item["value"]
                    out.append({"id": item["id"], "value": item["value"], "editable": True})
                return self.send_json(200, envelope(out))
        sm = re.match(r"^/settings/([a-z0-9_]+)$", rest)
        if sm:
            name = sm.group(1)
            if method == "GET":
                if name not in settings:
                    return self.not_found("Unknown setting")
                return self.send_json(200, envelope({"id": name, "value": settings[name], "editable": True}))
            if method == "PATCH":
                msg = invalid_setting(name, body.get("value"))
                if msg:
                    return self.bad_request(msg, 1007)
                settings[name] = body.get("value")
                return self.send_json(200, envelope({"id": name, "value": settings[name], "editable": True}))

        # -------------------------------------------------------------- dns
        records = STATE["dns"][zone_id]
        if rest == "/dns_records/export":
            lines = [";; Zone file for %s" % zone["name"]] + ["%s.\t%s\tIN\t%s\t%s" % (r["name"], r["ttl"] if r["ttl"] != 1 else 300, r["type"], r.get("content", "")) for r in records]
            return self.send_text(200, "\n".join(lines) + "\n")
        if rest == "/dns_records/import":
            return self.send_json(200, envelope({"recs_added": 2, "total_records_parsed": 2}))
        if rest == "/dns_records/batch":
            result = {"posts": [], "patches": [], "puts": [], "deletes": []}
            for d in body.get("deletes", []):
                records[:] = [r for r in records if r["id"] != d["id"]]
                result["deletes"].append({"id": d["id"]})
            for p in body.get("posts", []):
                rec = normalize_txt(self.mk_record(zone_id, p))
                records.append(rec)
                result["posts"].append(rec)
            for p in body.get("patches", []):
                for r in records:
                    if r["id"] == p["id"]:
                        r.update({k: v for k, v in p.items() if k != "id"})
                        result["patches"].append(r)
            return self.send_json(200, envelope(result))
        if rest == "/dns_records":
            if method == "GET":
                items = records
                for key in ("name", "type", "content"):
                    if key in query:
                        items = [r for r in items if str(r.get(key, "")).lower() == query[key][0].lower()]
                if "proxied" in query:
                    items = [r for r in items if str(r.get("proxied", False)).lower() == query["proxied"][0].lower()]
                items, info = paginate(items, query)
                return self.send_json(200, envelope(items, info))
            if method == "POST":
                for key in ("type", "name"):
                    if key not in body:
                        return self.bad_request("DNS record %s is required" % key, 9100)
                if "content" not in body and "data" not in body:
                    return self.bad_request("DNS record content is required", 9100)
                if body["type"] in ("A", "AAAA", "CNAME") and any(r["name"] == body["name"] and r["type"] == "CNAME" for r in records):
                    return self.bad_request("A CNAME record with that host already exists", 81053)
                rec = normalize_txt(self.mk_record(zone_id, body))
                records.append(rec)
                return self.send_json(200, envelope(rec))
        rm = re.match(r"^/dns_records/([^/]+)$", rest)
        if rm:
            rec = next((r for r in records if r["id"] == rm.group(1)), None)
            if rec is None:
                return self.not_found("Record does not exist.")
            if method == "GET":
                return self.send_json(200, envelope(rec))
            if method in ("PATCH", "PUT"):
                rec.update({k: v for k, v in body.items() if k != "id"})
                normalize_txt(rec)
                rec["modified_on"] = "2025-01-02T00:00:00Z"
                return self.send_json(200, envelope(rec))
            if method == "DELETE":
                records.remove(rec)
                return self.send_json(200, envelope({"id": rec["id"]}))

        # -------------------------------------------------------------- rulesets
        rulesets = STATE["rulesets"][zone_id]
        em = re.match(r"^/rulesets/phases/([a-z_]+)/entrypoint$", rest)
        if em:
            phase = em.group(1)
            rs = next((r for r in rulesets if r["phase"] == phase), None)
            if method == "GET":
                if rs is None:
                    return self.not_found("could not find ruleset")
                return self.send_json(200, envelope(rs))
            if method == "PUT":
                if rs is None:
                    rs = {"id": next_id("rs"), "name": "default", "kind": "zone", "phase": phase, "version": "1", "rules": []}
                    rulesets.append(rs)
                rs["rules"] = [dict(r, id=r.get("id") or next_id("rule"), version="1", last_updated="2025-01-01T00:00:00Z") for r in body.get("rules", [])]
                rs["version"] = str(int(rs["version"]) + 1)
                return self.send_json(200, envelope(rs))
        if rest == "/rulesets":
            if method == "GET":
                return self.send_json(200, envelope([{k: v for k, v in r.items() if k != "rules"} for r in rulesets]))
            if method == "POST":
                if any(r["phase"] == body["phase"] for r in rulesets):
                    return self.bad_request("a ruleset for this phase already exists", 20010)
                rs = {"id": next_id("rs"), "name": body.get("name"), "kind": body.get("kind", "zone"), "phase": body["phase"], "version": "1",
                      "rules": [dict(r, id=next_id("rule"), version="1", last_updated="2025-01-01T00:00:00Z") for r in body.get("rules", [])]}
                rulesets.append(rs)
                return self.send_json(200, envelope(rs))
        rrm = re.match(r"^/rulesets/([^/]+)/rules(?:/([^/]+))?$", rest)
        if rrm:
            rs = next((r for r in rulesets if r["id"] == rrm.group(1)), None)
            if rs is None:
                return self.not_found("ruleset not found")
            rule_id = rrm.group(2)
            if method == "POST" and rule_id is None:
                if "expression" not in body or "action" not in body:
                    return self.bad_request("rule needs expression and action", 20006)
                rule = dict(body, id=next_id("rule"), version="1", last_updated="2025-01-01T00:00:00Z")
                rule.setdefault("enabled", True)
                rs["rules"].append(rule)
                rs["version"] = str(int(rs["version"]) + 1)
                return self.send_json(200, envelope(rs))
            rule = next((r for r in rs["rules"] if r["id"] == rule_id), None)
            if rule is None:
                return self.not_found("rule not found")
            if method == "PATCH":
                rule.update(body)
                rule["last_updated"] = "2025-01-02T00:00:00Z"
                rs["version"] = str(int(rs["version"]) + 1)
                return self.send_json(200, envelope(rs))
            if method == "DELETE":
                rs["rules"].remove(rule)
                return self.send_json(200, envelope(rs))

        # -------------------------------------------------------------- access rules
        rules = STATE["access_rules"][zone_id]
        if rest == "/firewall/access_rules/rules":
            if method == "GET":
                items = rules
                if "configuration.value" in query:
                    items = [r for r in items if r["configuration"]["value"] == query["configuration.value"][0]]
                if "configuration.target" in query:
                    items = [r for r in items if r["configuration"]["target"] == query["configuration.target"][0]]
                if "mode" in query:
                    items = [r for r in items if r["mode"] == query["mode"][0]]
                items, info = paginate(items, query)
                return self.send_json(200, envelope(items, info))
            if method == "POST":
                rule = {"id": next_id("ar"), "mode": body["mode"], "configuration": body["configuration"], "notes": body.get("notes", ""), "scope": {"type": "zone"}}
                rules.append(rule)
                return self.send_json(200, envelope(rule))
        am = re.match(r"^/firewall/access_rules/rules/([^/]+)$", rest)
        if am:
            rule = next((r for r in rules if r["id"] == am.group(1)), None)
            if rule is None:
                return self.not_found("access rule not found")
            if method == "PATCH":
                rule.update(body)
                return self.send_json(200, envelope(rule))
            if method == "DELETE":
                rules.remove(rule)
                return self.send_json(200, envelope({"id": rule["id"]}))

        # -------------------------------------------------------------- page rules
        prs = STATE["pagerules"][zone_id]
        if rest == "/pagerules":
            if method == "GET":
                return self.send_json(200, envelope(prs))
            if method == "POST":
                if len(prs) >= 3:
                    return self.bad_request("You have reached the maximum number of Page Rules", 1004)
                pr = dict(body, id=next_id("pr"))
                prs.append(pr)
                return self.send_json(200, envelope(pr))
        pm = re.match(r"^/pagerules/([^/]+)$", rest)
        if pm:
            pr = next((r for r in prs if r["id"] == pm.group(1)), None)
            if pr is None:
                return self.not_found("page rule not found")
            if method == "GET":
                return self.send_json(200, envelope(pr))
            if method in ("PUT", "PATCH"):
                pr.update(body)
                return self.send_json(200, envelope(pr))
            if method == "DELETE":
                prs.remove(pr)
                return self.send_json(200, envelope({"id": pr["id"]}))

        return self.not_found("mock: unhandled %s %s" % (method, api))

    do_GET = handle_any
    do_POST = handle_any
    do_PUT = handle_any
    do_PATCH = handle_any
    do_DELETE = handle_any


if __name__ == "__main__":
    server = ThreadingHTTPServer(("127.0.0.1", PORT), Handler)
    print("mock cloudflare api on http://127.0.0.1:%d (repo %s)" % (PORT, REPO_ROOT), flush=True)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
