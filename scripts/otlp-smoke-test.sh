#!/usr/bin/env bash
# End-to-end OTLP smoke test: emit real OpenTelemetry traces and logs over OTLP/gRPC with
# telemetrygen, then assert Data Prepper ingested them into OpenSearch with the right shape.
# Assumes the stack is already up WITH the otel profile:
#
#   docker compose --profile otel up -d --build && ./scripts/otlp-smoke-test.sh
#
# Unlike the UDP smoke test, OTLP/gRPC is not fire-and-forget: telemetrygen gets a real error
# if the receiver is down, so we send once (with a short connect retry) and then poll for the
# documents while the 5s refresh interval catches up.
set -euo pipefail

OPENSEARCH_URL="${OPENSEARCH_URL:-http://localhost:9200}"
# telemetrygen runs as a container ON the compose network and talks to the receiver by its
# service name — portable across Linux CI and Docker Desktop (host networking is not).
OTEL_NETWORK="${OTEL_NETWORK:-log4opensearch_default}"
TELEMETRYGEN_IMAGE="${TELEMETRYGEN_IMAGE:-ghcr.io/open-telemetry/opentelemetry-collector-contrib/telemetrygen:v0.116.0}"
TRACES_TARGET="${TRACES_TARGET:-data-prepper:21890}"
LOGS_TARGET="${LOGS_TARGET:-data-prepper:21892}"

STAMP="$(date +%s)-$RANDOM"
SVC="otlp-smoke-${STAMP}"
# service.namespace is the "project" grouping — soft multi-project isolation by resource attribute.
NS="otlp-smoke-project-${STAMP}"
SQL="SELECT * FROM orders WHERE id=${STAMP}"
# A known 32-hex trace id lets us prove a log record is correlatable to its trace.
TID="$(head -c16 /dev/urandom | od -An -tx1 | tr -d ' \n')"

telemetrygen() {
  docker run --rm --network "${OTEL_NETWORK}" "${TELEMETRYGEN_IMAGE}" "$@"
}

echo "==> emitting OTLP traces to ${TRACES_TARGET} (service=${SVC})"
# A DB-statement span attribute proves the query text survives ingestion (the drilldown case).
for i in $(seq 1 5); do
  if telemetrygen traces \
      --otlp-endpoint "${TRACES_TARGET}" --otlp-insecure \
      --traces 10 --service "${SVC}" \
      --otlp-attributes "service.namespace=\"${NS}\"" \
      --telemetry-attributes 'db.system="mysql"' \
      --telemetry-attributes "db.statement=\"${SQL}\""; then
    break
  fi
  [ "$i" -eq 5 ] && { echo "FAIL: could not send traces after 5 tries"; exit 1; }
  echo "    receiver not ready yet, retrying ($i)"; sleep 3
done

# `telemetrygen logs` has no --service (that is a traces flag); the service name goes in as a
# resource attribute, and --trace-id stamps a known trace id so we can prove correlation.
echo "==> emitting OTLP logs to ${LOGS_TARGET} (trace_id=${TID})"
for i in $(seq 1 5); do
  if telemetrygen logs \
      --otlp-endpoint "${LOGS_TARGET}" --otlp-insecure \
      --logs 10 --trace-id "${TID}" \
      --otlp-attributes "service.name=\"${SVC}\""; then
    break
  fi
  [ "$i" -eq 5 ] && { echo "FAIL: could not send logs after 5 tries"; exit 1; }
  echo "    receiver not ready yet, retrying ($i)"; sleep 3
done

# Poll: return the hit count for a query, or 0.
count() { # <index> <json-query>
  curl -fsS "${OPENSEARCH_URL}/$1/_search?size=0" \
    -H 'Content-Type: application/json' -d "$2" 2>/dev/null \
    | python3 -c 'import json,sys; print(json.load(sys.stdin).get("hits",{}).get("total",{}).get("value",0))' 2>/dev/null \
    || echo 0
}

# Generous window: on a cold start Data Prepper can take ~40s from send to first flush into
# OpenSearch (buffer warmup + sink connecting to a freshly-started cluster). CI always starts cold.
POLL_SECONDS="${POLL_SECONDS:-120}"
wait_for() { # <label> <index> <json-query>
  echo "==> waiting for: $1"
  for i in $(seq 1 "$POLL_SECONDS"); do
    n=$(count "$2" "$3")
    if [ "${n:-0}" -gt 0 ]; then echo "  ok   $1 (hits=$n)"; return 0; fi
    sleep 1
  done
  echo "  FAIL $1 (no hits after ${POLL_SECONDS}s)"
  echo "--- data-prepper logs ---"; docker compose --profile otel logs --tail=60 data-prepper || true
  return 1
}

fail=0
# CA-01: the trace was stored as spans under our service.
wait_for "trace spans stored (CA-01)" "otel-v1-apm-span-*" \
  "{\"query\":{\"term\":{\"serviceName\":\"${SVC}\"}}}" || fail=1

# CA-01: the span tree is reconstructable — at least one span has a NON-EMPTY parent
# (parentSpanId is always present but empty on root spans, so match one or more chars).
wait_for "span tree has a parent link (CA-01)" "otel-v1-apm-span-*" \
  "{\"query\":{\"bool\":{\"filter\":[{\"term\":{\"serviceName\":\"${SVC}\"}},{\"wildcard\":{\"parentSpanId\":\"?*\"}}]}}}" || fail=1

# CA-02: the database-statement attribute survived, so drilldown-to-query is possible.
# Data Prepper flattens attribute keys, replacing '.' with '@': db.statement -> db@statement.
wait_for "db.statement attribute preserved (CA-02)" "otel-v1-apm-span-*" \
  "{\"query\":{\"term\":{\"span.attributes.db@statement\":\"${SQL}\"}}}" || fail=1

# CA-03: the log records were stored AND carry the trace id, so they correlate to the trace.
wait_for "OTLP logs stored & correlatable by trace id (CA-03)" "otel-logs-*" \
  "{\"query\":{\"term\":{\"traceId\":\"${TID}\"}}}" || fail=1

# CA-11: soft multi-project isolation — spans are filterable by the client's service.namespace.
wait_for "project filter by service.namespace (CA-11)" "otel-v1-apm-span-*" \
  "{\"query\":{\"term\":{\"resource.attributes.service@namespace\":\"${NS}\"}}}" || fail=1

if [ "$fail" -ne 0 ]; then
  echo "==> OTLP SMOKE TEST FAILED"
  exit 1
fi
echo "==> OTLP SMOKE TEST PASSED"
