#!/usr/bin/env bash
# End-to-end smoke test: assert the Dashboards saved objects were auto-provisioned, so Discover
# and the overview dashboard work with no manual "create an index pattern" step. Assumes the
# stack is already up (the provisioning-dashboards one-shot has run):
#
#   docker compose up -d --build --wait && ./scripts/dashboards-smoke-test.sh
#
# Pass `otel` to additionally assert the OTLP-log index pattern (only present under the profile):
#
#   docker compose --profile otel up -d --build --wait && ./scripts/dashboards-smoke-test.sh otel
set -euo pipefail

DASHBOARDS_URL="${DASHBOARDS_URL:-http://localhost:5601}"
CHECK_OTEL="${1:-}"

# Stable saved-object ids — the contract that makes provisioning deterministic (REQ-0003).
IP_ID="log4opensearch-logstash"
DASH_ID="log4opensearch-overview"
OTEL_IP_ID="log4opensearch-otel-logs"

api() { curl -fsS "$@" -H 'osd-xsrf: true'; }

# GET a saved object by stable id, retrying: after `up --wait` the one-shot has completed, but a
# short poll keeps the test robust against import timing on a cold start.
get_object() { # <type> <id> -> body on stdout, or empty
  for _ in $(seq 1 30); do
    if body=$(api "${DASHBOARDS_URL}/api/saved_objects/$1/$2" 2>/dev/null); then
      printf '%s' "$body"; return 0
    fi
    sleep 1
  done
  return 1
}

fail=0
assert() { # <name> <python expression over the object `d`>
  if python3 -c '
import json, sys
d = json.load(open(sys.argv[1]))
sys.exit(0 if eval(sys.argv[2]) else 1)
' "$1" "$2"; then echo "  ok   $3"; else echo "  FAIL $3"; fail=1; fi
}

TMP=$(mktemp); trap 'rm -f "$TMP"' EXIT

echo "==> asserting the log index pattern exists (DASH-01)"
if get_object index-pattern "$IP_ID" > "$TMP"; then
  assert "$TMP" "d['attributes']['title'] == 'logstash-*'"        "index pattern title is logstash-*"
  assert "$TMP" "d['attributes']['timeFieldName'] == '@timestamp'" "index pattern time field is @timestamp"
  # The index pattern must ship its cached field list, or the visualizations fail with
  # "Could not locate that index-pattern-field (id: @timestamp)" until the user refreshes it
  # by hand — the very manual step this feature removes. Assert the core fields are cached.
  assert "$TMP" "all(any(fd['name']==n for fd in json.loads(d['attributes'].get('fields','[]'))) for n in ('@timestamp','host','loglevel','message','program_name'))" \
                "index pattern has cached fields (@timestamp, host, loglevel, message, program_name)"
else
  echo "  FAIL log index pattern '${IP_ID}' not found"; fail=1
fi

echo "==> asserting the overview dashboard exists and resolves its references (DASH-02)"
if get_object dashboard "$DASH_ID" > "$TMP"; then
  assert "$TMP" "len(d['references']) >= 1" "dashboard has panel references"
  # Every panel reference must resolve to a present object — a dangling reference imports
  # without error but renders an empty panel, so we prove each referenced id exists.
  MISSING=0
  while IFS='|' read -r rtype rid; do
    rtype=${rtype%$'\r'}; rid=${rid%$'\r'}   # strip CR in case python emits CRLF
    [ -z "$rtype" ] && continue
    if ! api "${DASHBOARDS_URL}/api/saved_objects/${rtype}/${rid}" >/dev/null 2>&1; then
      echo "  FAIL dashboard reference ${rtype}/${rid} does not resolve"; MISSING=1
    fi
  done < <(python3 -c 'import json,sys;[print(r["type"]+"|"+r["id"]) for r in json.load(open(sys.argv[1]))["references"]]' "$TMP")
  [ "$MISSING" -eq 0 ] && echo "  ok   all dashboard references resolve" || fail=1
else
  echo "  FAIL dashboard '${DASH_ID}' not found"; fail=1
fi

if [ "$CHECK_OTEL" = "otel" ]; then
  echo "==> asserting the OTLP-log index pattern exists (DASH-03)"
  if get_object index-pattern "$OTEL_IP_ID" > "$TMP"; then
    assert "$TMP" "d['attributes']['title'] == 'otel-logs-*'" "otel index pattern title is otel-logs-*"
    assert "$TMP" "d['attributes']['timeFieldName'] == 'time'" "otel index pattern time field is time"
    assert "$TMP" "any(fd['name']=='time' for fd in json.loads(d['attributes'].get('fields','[]'))) and len(json.loads(d['attributes'].get('fields','[]'))) > 5" \
                  "otel index pattern has cached fields (time)"
  else
    echo "  FAIL otel-logs index pattern '${OTEL_IP_ID}' not found"; fail=1
  fi
fi

if [ "$fail" -ne 0 ]; then
  echo "==> DASHBOARDS SMOKE TEST FAILED"
  docker compose logs --tail=50 provisioning-dashboards || true
  exit 1
fi
echo "==> DASHBOARDS SMOKE TEST PASSED"
