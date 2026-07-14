# Changelog

All notable changes to this project are documented here.
The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/).

## [Unreleased]

## [1.0.0] - 2026-07-14

First tagged release. The stack is complete and CI-verified end to end: send a log line over UDP,
find it in Dashboards.

### Added
- Index template with explicit field mappings.
- ISM retention policy: log indices are deleted after 30 days (configurable).
- `provisioning` service that installs both artifacts on startup, idempotently.
- Healthchecks on OpenSearch and Logstash; services now start in the correct order.
- Persistent volume `opensearch-data` — logs survive `docker compose down`.
- `.env` (committed) as the single source of truth for versions, ports, heap and retention —
  every tunable is a variable, so overriding one needs only a shell variable, no second file.
- ECS mode disabled twice over: `ecs_compatibility => "disabled"` per plugin in the pipeline, plus
  `PIPELINE_ECS_COMPATIBILITY=disabled` on the `logstash` service as a pipeline-wide default, so a
  plugin added later cannot silently emit ECS fields. Logstash 8 defaults to ECS mode, which turns
  `host` into an object and clashes with the flat index template.
- `manage_template => false` on the OpenSearch output, so the plugin cannot overwrite our
  index template with its own (which predates OpenSearch 3).
- Smoke test (`scripts/smoke-test.sh`) and CI running it on every push.
- `SECURITY.md`, `CONTRIBUTING.md`, `.gitignore`, issue and PR templates, Dependabot.
- `.editorconfig`, and a `.gitattributes` pinning shell scripts to LF — a CRLF checkout would
  make CI fail with `bad interpreter: bash^M`.

### Fixed
- **Logstash reported healthy before the UDP listener was bound.** The healthcheck only probed the
  API on `:9600`, which answers well before the pipeline starts, so `docker compose up --wait`
  returned while port 5960 was still closed — and UDP being fire-and-forget, every line sent in
  that window was lost with no error. The healthcheck now also requires the socket to be bound.
- Trailing newline stripped from `message`: appender layouts end with `%n`, so every payload
  arrived with a `\n` glued to it. Internal newlines (stack traces) are untouched.
- **Grok patterns were evaluated in the wrong order**: the generic pattern matched first, so
  `traceId`, `source_ip`, `program_name` were never extracted. Patterns now go
  from most specific to most generic.
- Grok failures are tagged `_grokparsefailure_log4net` instead of being silently mangled.
- Logstash no longer starts before OpenSearch is ready, which used to drop the first events.

### Changed
- **BREAKING** — services renamed for coherence: `loges01` → `opensearch`, `kibana` → `dashboards`.
  Cluster renamed to `log4opensearch-cluster`. Update any external reference to the old names.
- Image versions pinned (no more `:latest` / `:3`). OpenSearch and Dashboards on 3.7.0;
  Logstash bumped from 7.16.2 to 8.9.0 (the OpenSearch Logstash image does not follow the
  OpenSearch version numbering).
- `restart: always` → `restart: unless-stopped`.
- Removed the obsolete Compose `version:` key and the fixed `container_name` entries.
- Rewrote the README: architecture, verification steps, log formats, retention, troubleshooting,
  and how to enable security.

### Removed
- `data/` — contained a committed RSA private key (the public OpenSearch demo key) plus a config
  file no service ever mounted.
- `opensearch/Dockerfile` — orphaned; it installed Dashboards *inside* the OpenSearch node and was
  never referenced by the Compose file.
- `logstash/config/` — never copied into the image.
- `docker-compose.old` — that is what git history is for.
- Hardcoded passwords from Compose and the Logstash pipeline.

[Unreleased]: https://github.com/dmonza/log4opensearch/compare/v1.0.0...HEAD
[1.0.0]: https://github.com/dmonza/log4opensearch/releases/tag/v1.0.0
