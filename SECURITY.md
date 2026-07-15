# Security Policy

## Scope: this is a dev-first stack

log4opensearch ships **with authentication and TLS disabled on purpose**, so that it runs with
a single `docker compose up`. This is a documented design decision, not a vulnerability:

- No authentication on OpenSearch (`9200`) or Dashboards (`5601`)
- No TLS anywhere
- The UDP ingestion port (`5960`) accepts unauthenticated input from anyone who can reach it
- Under the `otel` profile, the OTLP/gRPC ports (`4317` traces, `4318` logs) likewise accept
  unauthenticated, plaintext input from anyone who can reach them

**Do not deploy this configuration on an untrusted network.** The README explains how to enable
the security plugin, TLS and credentials.

Reports that amount to "security is disabled by default" will be closed as by-design, with a
pointer here.

## Reporting a vulnerability

If you find an actual vulnerability — a committed secret, an injection in the Logstash pipeline,
a supply-chain issue in the images — please **do not open a public issue**.

Use GitHub's [private vulnerability reporting](https://github.com/dmonza/log4opensearch/security/advisories/new).

Expect an initial response within 7 days.

## Supported versions

Only the latest release is supported.
