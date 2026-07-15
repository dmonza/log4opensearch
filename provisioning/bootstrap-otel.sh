#!/bin/sh
# Idempotent: installs the OpenTelemetry index templates so Data Prepper's OTLP sinks
# (which run with index_type: management_disabled — they create nothing themselves) write
# into indices with the correct mappings. Runs once per `docker compose --profile otel up`
# and exits 0 when done.
#
# The retention ISM that governs these indices is NOT installed here: it lives in the
# always-on provisioning step (provisioning/ism-policy.json), extended to cover the OTLP
# span and log patterns. This script only lays down the mappings.
set -eu

OPENSEARCH_URL="${OPENSEARCH_URL:-http://opensearch:9200}"

echo "[bootstrap-otel] target=${OPENSEARCH_URL}"

install_template() {
  name="$1"
  file="$2"
  echo "[bootstrap-otel] installing index template '${name}'"
  curl -fsS -X PUT "${OPENSEARCH_URL}/_index_template/${name}" \
    -H 'Content-Type: application/json' \
    --data-binary "@${file}" > /dev/null
  echo "[bootstrap-otel]   ok"
}

install_template "otel-v1-apm-span"        /provisioning/otel-span-template.json
install_template "otel-v1-apm-service-map" /provisioning/otel-service-map-template.json
install_template "otel-logs"               /provisioning/otel-logs-template.json

echo "[bootstrap-otel] done"
