#!/bin/sh
# Idempotent: installs the index template and the ISM retention policy.
# Runs once per `docker compose up` and exits 0 when done.
set -eu

OPENSEARCH_URL="${OPENSEARCH_URL:-http://opensearch:9200}"
RETENTION="${LOG_RETENTION_DAYS:-30}"

echo "[bootstrap] target=${OPENSEARCH_URL} retention=${RETENTION}d"

echo "[bootstrap] installing index template 'log4opensearch'"
curl -fsS -X PUT "${OPENSEARCH_URL}/_index_template/log4opensearch" \
  -H 'Content-Type: application/json' \
  --data-binary @/provisioning/index-template.json > /dev/null
echo "[bootstrap]   ok"

echo "[bootstrap] installing ISM policy 'log4opensearch-retention'"
sed "s/__RETENTION__/${RETENTION}/" /provisioning/ism-policy.json > /tmp/ism.json

# PUT on an existing policy requires the current seq_no / primary_term.
if curl -fsS "${OPENSEARCH_URL}/_plugins/_ism/policies/log4opensearch-retention" > /tmp/existing.json 2>/dev/null; then
  SEQ=$(sed -n 's/.*"_seq_no":\([0-9]*\).*/\1/p' /tmp/existing.json)
  PT=$(sed -n 's/.*"_primary_term":\([0-9]*\).*/\1/p' /tmp/existing.json)
  curl -fsS -X PUT "${OPENSEARCH_URL}/_plugins/_ism/policies/log4opensearch-retention?if_seq_no=${SEQ}&if_primary_term=${PT}" \
    -H 'Content-Type: application/json' --data-binary @/tmp/ism.json > /dev/null
  echo "[bootstrap]   ok (updated)"
else
  curl -fsS -X PUT "${OPENSEARCH_URL}/_plugins/_ism/policies/log4opensearch-retention" \
    -H 'Content-Type: application/json' --data-binary @/tmp/ism.json > /dev/null
  echo "[bootstrap]   ok (created)"
fi

echo "[bootstrap] done"
