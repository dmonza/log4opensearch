#!/usr/bin/env python3
# Idempotent: imports a saved-objects artifact (index patterns, visualizations, dashboards)
# into OpenSearch Dashboards so Discover and the dashboard work out of the box.
#
# WHY this is Python (not the curl one-shot the storage steps use): OpenSearch Dashboards 3.7.0
# has NO lazy field resolution and NO server-side "refresh fields" endpoint — a visualization
# resolves its fields against the list PERSISTED on the index pattern, and an index pattern with
# an empty field list fails with "Could not locate that index-pattern-field (id: @timestamp)".
# So the field list has to be materialised. Rather than freeze a hand-baked snapshot into the
# committed artifact (which goes stale every time the grok/schema changes), this script COMPUTES
# it at every startup:
#
#   1. live  — GET _fields_for_wildcard for the index pattern's title (Dashboards reads the live
#              field_caps of the matching indices) — so it reflects whatever the pipeline is
#              actually producing right now, including newly-added grok fields.
#   2. fallback — on a cold start the index does not exist yet, so field_caps is empty; derive a
#              field list from the committed index template (the declared schema) so the dashboard
#              still resolves its fields and shows "no data" instead of an error.
#
# The computed list is injected into the index pattern before import. The committed .ndjson ships
# WITHOUT a fields list on purpose — it is not a source of truth, it is derived here.
#
# Usage: import-dashboards.py <artifact.ndjson> <fallback-index-template.json>
import json
import os
import sys
import urllib.request
import urllib.error
import urllib.parse

DASHBOARDS_URL = os.environ.get("DASHBOARDS_URL", "http://dashboards:5601").rstrip("/")
# DEV-FIRST: no credentials. When security is enabled (see README > Security), set these and
# switch DASHBOARDS_URL to https:// — the request below adds basic auth when they are present.
DASHBOARDS_USER = os.environ.get("DASHBOARDS_USER")
DASHBOARDS_PASSWORD = os.environ.get("DASHBOARDS_PASSWORD")

META_FIELDS = ["_source", "_id", "_type", "_index", "_score"]


def _auth_header():
    if DASHBOARDS_USER and DASHBOARDS_PASSWORD:
        import base64
        raw = f"{DASHBOARDS_USER}:{DASHBOARDS_PASSWORD}".encode()
        return {"Authorization": "Basic " + base64.b64encode(raw).decode()}
    return {}


def _request(method, path, data=None, headers=None):
    url = DASHBOARDS_URL + path
    h = {"osd-xsrf": "true"}
    h.update(_auth_header())
    if headers:
        h.update(headers)
    req = urllib.request.Request(url, data=data, method=method, headers=h)
    with urllib.request.urlopen(req, timeout=60) as resp:
        return resp.status, resp.read().decode()


# --- field-list sources --------------------------------------------------------------------

def fields_from_live(title):
    """Fetch the field list from the live indices via Dashboards. Returns [] if the index does
    not exist yet (cold start) or the call fails."""
    qs = urllib.parse.urlencode(
        [("pattern", title)] + [("meta_fields", m) for m in META_FIELDS]
    )
    try:
        _, body = _request("GET", "/api/index_patterns/_fields_for_wildcard?" + qs)
        return json.loads(body).get("fields", [])
    except (urllib.error.HTTPError, urllib.error.URLError, ValueError):
        return []


_ES_TO_OSD = {
    "keyword": ("string", True, True, True),
    "text": ("string", True, False, False),
    "date": ("date", True, True, True),
    "date_nanos": ("date", True, True, True),
    "boolean": ("boolean", True, True, True),
    "ip": ("ip", True, True, True),
    "geo_point": ("geo_point", True, False, False),
}
_NUMERIC = {"long", "integer", "short", "byte", "double", "float", "half_float", "scaled_float"}


def _walk_properties(props, prefix, out):
    """Flatten an index-template `properties` map into OpenSearch-Dashboards field descriptors,
    dotting nested object paths (severity.text, event.exception.type, ...)."""
    for name, spec in props.items():
        path = f"{prefix}{name}"
        if "properties" in spec:            # nested object → recurse
            _walk_properties(spec["properties"], path + ".", out)
            continue
        es_type = spec.get("type")
        if es_type == "alias":              # aliases have no field_caps entry of their own
            continue
        if es_type in _NUMERIC:
            osd_type, searchable, aggregatable, docvalues = "number", True, True, True
        elif es_type in _ES_TO_OSD:
            osd_type, searchable, aggregatable, docvalues = _ES_TO_OSD[es_type]
        else:
            continue
        out.append({
            "name": path, "type": osd_type, "esTypes": [es_type],
            "searchable": searchable, "aggregatable": aggregatable,
            "readFromDocValues": docvalues,
        })


def _meta_fields():
    return [
        {"name": "_id", "type": "string", "esTypes": ["_id"], "searchable": True, "aggregatable": False, "readFromDocValues": False},
        {"name": "_index", "type": "string", "esTypes": ["_index"], "searchable": True, "aggregatable": True, "readFromDocValues": False},
        {"name": "_source", "type": "_source", "esTypes": ["_source"], "searchable": False, "aggregatable": False, "readFromDocValues": False},
        {"name": "_type", "type": "string", "esTypes": ["_type"], "searchable": True, "aggregatable": True, "readFromDocValues": False},
        {"name": "_score", "type": "number", "searchable": False, "aggregatable": False, "readFromDocValues": False},
    ]


def fields_from_template(template_path):
    """Cold-start fallback: derive the field list from the committed index template's explicit
    mappings. Dynamic-template fields (e.g. resource.attributes.*) can't be enumerated ahead of
    data — they fill in from the live source on a later start."""
    with open(template_path, encoding="utf-8") as f:
        tmpl = json.load(f)
    props = tmpl.get("template", {}).get("mappings", {}).get("properties", {})
    out = []
    _walk_properties(props, "", out)
    out.extend(_meta_fields())
    return out


# --- import --------------------------------------------------------------------------------

def multipart_import(ndjson_text):
    boundary = "----log4opensearchDashboardsImport"
    body = (
        f"--{boundary}\r\n"
        'Content-Disposition: form-data; name="file"; filename="import.ndjson"\r\n'
        "Content-Type: application/x-ndjson\r\n\r\n"
        f"{ndjson_text}\r\n"
        f"--{boundary}--\r\n"
    ).encode("utf-8")
    status, resp = _request(
        "POST", "/api/saved_objects/_import?overwrite=true", data=body,
        headers={"Content-Type": f"multipart/form-data; boundary={boundary}"},
    )
    return status, resp


def main():
    if len(sys.argv) != 3:
        sys.exit("usage: import-dashboards.py <artifact.ndjson> <fallback-index-template.json>")
    ndjson_path, template_path = sys.argv[1], sys.argv[2]
    print(f"[import-dashboards] target={DASHBOARDS_URL} artifact={ndjson_path}")

    lines = []
    for raw in open(ndjson_path, encoding="utf-8"):
        raw = raw.strip()
        if not raw:
            continue
        obj = json.loads(raw)
        if obj.get("type") == "index-pattern":
            title = obj["attributes"]["title"]
            fields = fields_from_live(title)
            source = "live"
            if not fields:
                fields = fields_from_template(template_path)
                source = "template-fallback"
            obj["attributes"]["fields"] = json.dumps(fields, separators=(",", ":"))
            print(f"[import-dashboards]   index-pattern '{title}': {len(fields)} fields ({source})")
        lines.append(json.dumps(obj, separators=(",", ":")))

    status, resp = multipart_import("\n".join(lines))
    print(f"[import-dashboards] response: {resp}")
    # The HTTP call succeeds (2xx) even when individual objects fail; the body carries the verdict.
    if '"success":true' not in resp:
        sys.exit("[import-dashboards] import reported failure")
    print("[import-dashboards] done")


if __name__ == "__main__":
    main()
