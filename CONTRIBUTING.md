# Contributing

Thanks for taking the time. This is a small project — keep it simple.

Bug reports, questions and improvement proposals are all welcome, and you do not need to write
code to be useful. Here is where each one goes.

| I want to… | Go to |
| --- | --- |
| Report something broken | [Bug report](https://github.com/dmonza/log4opensearch/issues/new?template=bug_report.yml) |
| Propose an improvement | [Feature request](https://github.com/dmonza/log4opensearch/issues/new?template=feature_request.yml) |
| Ask a question, share a setup, leave a comment | [Discussions](https://github.com/dmonza/log4opensearch/discussions) |
| Report a security vulnerability | [Private advisory](https://github.com/dmonza/log4opensearch/security/advisories/new) — **not** a public issue. See [SECURITY.md](SECURITY.md) |

Blank issues are disabled on purpose: the templates ask for the handful of things that turn an
unreproducible report into a fixable one.

## Two things that are not bugs

- **"There is no authentication / no TLS."** That is deliberate and documented in
  [SECURITY.md](SECURITY.md). The README explains [how to turn security on](README.md#security).
- **"Every field is `_grokparsefailure_log4net`."** Your appender layout does not match any of the
  three patterns. Compare it against [Log formats](README.md#log-formats) — the timestamp format
  and the ` - ` separators are what usually differ.

## Reporting bugs

Open an issue with the template. Whatever else you leave out, these three make the difference
between a report that can be fixed and one that cannot:

1. **The exact log line you sent**, copied verbatim. Whitespace and separators matter for grok, so
   a retyped or prettified line is worse than none.
2. **The output of `docker compose logs logstash`.**
3. **Your environment** — Docker flavour, version and OS.

If the line was accepted but parsed wrong, paste the indexed document too:

```bash
curl -s 'localhost:9200/logstash-*/_search?pretty&size=1'
```

## Proposing improvements

Open a feature request and **lead with the problem, not the solution**. What were you trying to do,
and what stopped you? The proposed change is the easy part to discuss once the use case is clear.

Worth knowing before you write it up: this stack is deliberately *dev-first* and deliberately small
— four services, one pipeline, no setup step. Proposals that grow it into a production-hardened
deployment, or that add a service to cover something `docker-compose.override.yml` already handles,
will usually be declined. That is a scope decision, not a judgment on the idea.

## Development

```bash
git clone https://github.com/dmonza/log4opensearch.git
cd log4opensearch
docker compose up --build
```

`.env` is committed and holds the defaults — edit it when you want to change the default **for
everyone**. For your own machine, a shell variable is enough and touches nothing tracked:
`OPENSEARCH_PORT=19200 docker compose up`. **Never commit a credential to `.env`** — CI fails the
build if it finds one. See [Configuration](README.md#configuration).

## Changing the Logstash pipeline

The grok patterns in `logstash/pipeline/logstash.conf` are evaluated **in order**, and matching
stops at the first hit. A new pattern must go **above** any pattern that is more generic than it,
or it will never be reached.

After any pipeline change, run the smoke test:

```bash
docker compose up -d --build
./scripts/smoke-test.sh
```

It sends a real log line over UDP and asserts it came out the other end parsed correctly — right
`traceId`, right field types, no grok failure. CI runs the same script on every PR, along with
`docker compose config`, hadolint, shellcheck, and a check that `.env` holds no credentials. Run it
locally first: the end-to-end job takes minutes to tell you what a local run tells you in seconds.

## Pull requests

For anything beyond a typo, open an issue first so the approach can be agreed on before you spend
time on it.

- One concern per PR.
- [Conventional Commits](https://www.conventionalcommits.org/) for the title, e.g.
  `fix(logstash): order grok patterns from specific to generic`.
- Update `CHANGELOG.md` under `## [Unreleased]`.
- Keep everything — code, comments, docs — in **English**.
- Formatting follows [`.editorconfig`](.editorconfig): UTF-8, LF, two-space indent, final newline.

## Bumping versions

Image versions are pinned in `.env`. When bumping: verify the tag actually exists, run the smoke
test, and note it in the changelog. Never use `:latest`. Dependabot proposes the bumps weekly.

Two traps when touching Logstash:

- The `ecs_compatibility => "disabled"` settings are **load-bearing** — all of them. Logstash 8
  defaults to ECS mode, which turns `host` into an object, breaks the pipeline's `mutate replace`
  and collides with the index template. They live per plugin in `logstash/pipeline/logstash.conf`
  and, as a safety net, pipeline-wide via `PIPELINE_ECS_COMPATIBILITY` in `docker-compose.yml`.
  A new input or filter gets its own `ecs_compatibility => "disabled"` too. Do not turn ECS on
  without reworking the pipeline and the index template together.
- `manage_template => false` in the output keeps the plugin from pushing its own index template
  over ours. Leave it off.

## Code of conduct

There is no formal document. Be decent, assume good faith, and keep it technical.
