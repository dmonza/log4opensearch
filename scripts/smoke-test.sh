#!/usr/bin/env bash
# End-to-end smoke test: send a log line over UDP and assert it was parsed and indexed
# with the correct field types. Assumes the stack is already up.
#
#   docker compose up -d --build && ./scripts/smoke-test.sh
set -euo pipefail

OPENSEARCH_URL="${OPENSEARCH_URL:-http://localhost:9200}"
# 127.0.0.1, not localhost: bash's /dev/udp can resolve localhost to ::1, while Docker
# publishes the UDP port on IPv4 — the datagram would go nowhere, silently.
LOG_HOST="${LOG_HOST:-127.0.0.1}"
LOG_PORT="${LOG_PORT:-5960}"

TRACE_ID="smoke-$(date +%s)-$RANDOM"
TS=$(date '+%Y-%m-%d %H:%M:%S,000%z' | sed -E 's/([0-9]{2})([0-9]{2})$/\1:\2/')
LINE="${TS} [1] INFO  - smokehost - CI - SMOKE - [${TRACE_ID}] [10.0.0.5] [SmokeProg] [42] smoke test payload"

echo "==> sending test line to ${LOG_HOST}:${LOG_PORT}/udp"
echo "    ${LINE}"

# Resend on every attempt instead of sending once and polling. UDP is fire-and-forget: a
# datagram that arrives while the listener is still binding is gone, with no error to the
# sender, and no amount of polling brings it back. The duplicates are harmless — they all
# carry the same traceId and the assertions run against the first hit.
echo "==> waiting for the document to be indexed"
for i in $(seq 1 30); do
  printf '%s\n' "$LINE" > /dev/udp/"${LOG_HOST}"/"${LOG_PORT}"
  sleep 1
  HITS=$(curl -fsS "${OPENSEARCH_URL}/logstash-*/_search" \
    -H 'Content-Type: application/json' \
    -d "{\"query\":{\"term\":{\"traceId\":\"${TRACE_ID}\"}}}" || echo '{}')
  if echo "$HITS" | grep -q "\"${TRACE_ID}\""; then
    break
  fi
  if [ "$i" -eq 30 ]; then
    echo "FAIL: document never showed up after 30s"
    echo "--- logstash logs ---"
    docker compose logs --tail=50 logstash || true
    exit 1
  fi
done

# The document goes to a file, never inline into the Python source: `message` legitimately
# contains backslash escapes, and interpolating it into a source literal would let Python
# unescape them a second time.
DOC=$(mktemp)
trap 'rm -f "$DOC"' EXIT
echo "$HITS" | python3 -c \
  'import json, sys; json.dump(json.load(sys.stdin)["hits"]["hits"][0]["_source"], open(sys.argv[1], "w"))' "$DOC"

echo "==> indexed document:"
python3 -m json.tool "$DOC"

fail=0
assert() { # <name> <python expression over the document `d`>
  if python3 -c '
import json, sys
d = json.load(open(sys.argv[1]))
sys.exit(0 if eval(sys.argv[2]) else 1)
' "$DOC" "$2"; then
    echo "  ok   $1"
  else
    echo "  FAIL $1"
    fail=1
  fi
}

echo "==> assertions"
assert "no grok parse failure"          "'_grokparsefailure_log4net' not in d.get('tags', [])"
assert "traceId extracted"              "d.get('traceId') == '${TRACE_ID}'"
assert "entityId extracted (keyword)"   "d.get('entityId') == '42'"
assert "source_ip extracted"            "d.get('source_ip') == '10.0.0.5'"
assert "program_name extracted"         "d.get('program_name') == 'SmokeProg'"
assert "loglevel extracted"             "d.get('loglevel') == 'INFO'"
assert "host extracted"                 "d.get('host') == 'smokehost'"
assert "message stripped of the prefix" "d.get('message') == 'smoke test payload'"
assert "temp fields removed"            "'tempMessage' not in d and 'tempHost' not in d"

if [ "$fail" -ne 0 ]; then
  echo "==> SMOKE TEST FAILED"
  exit 1
fi
echo "==> SMOKE TEST PASSED"
