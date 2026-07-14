# log4opensearch

A ready-to-run Docker Compose stack that receives **log4j** and **log4net** logs over UDP, parses them with **Logstash**, stores them in **OpenSearch**, and lets you explore them in **OpenSearch Dashboards**.

Point your application's UDP appender at port `5960`, run `docker compose up`, and your logs are searchable.

> [!WARNING]
> **This stack ships with security disabled — by design.** It is meant for local development
> and internal environments. Do not expose it to an untrusted network as-is.
> See [Security](#security) to turn authentication and TLS on.

![OpenSearch Dashboards showing parsed log4net logs](dashboard.png)

---

## Architecture

```
  ┌──────────────┐   UDP 5960    ┌──────────┐              ┌────────────┐
  │  Your app    │──────────────▶│ Logstash │─────────────▶│ OpenSearch │
  │ log4j/log4net│  plain text   │  (grok)  │   logstash-* │  :9200     │
  └──────────────┘               └──────────┘              └─────┬──────┘
                                                                 │
                                                          ┌──────▼──────────┐
                                                          │   Dashboards    │
                                                          │     :5601       │
                                                          └─────────────────┘
```

| Service        | Port         | Purpose                                         |
| -------------- | ------------ | ----------------------------------------------- |
| `logstash`     | `5960/udp`   | Log ingestion endpoint — point your appender here |
| `opensearch`   | `9200/tcp`   | Search & storage API                            |
| `dashboards`   | `5601/tcp`   | Web UI                                          |
| `provisioning` | —            | One-shot: installs index template + ISM policy, then exits |

---

## Requirements

- Docker Engine 24+ with Compose v2 (Docker Desktop works out of the box)
- ~2 GB of free RAM

## Quick start

```bash
git clone https://github.com/dmonza/log4opensearch.git
cd log4opensearch
docker compose up --build
```

Then open **http://localhost:5601**.

That's it — no setup step. Versions, ports, heap sizes and retention live in
[`.env`](.env), which **is committed on purpose**: it holds defaults, not secrets.
See [Configuration](#configuration) to change them.

### Verify it works

Send a test log line and check it landed:

**Linux / macOS**

```bash
echo '2026-07-13 10:00:00,123-03:00 [1] INFO  - myhost - PROD - APP - [trace-1] [10.0.0.5] [MyProg] [42] hello world' \
  | nc -u -w1 localhost 5960
```

**Windows (PowerShell)**

```powershell
$msg = '2026-07-13 10:00:00,123-03:00 [1] INFO  - myhost - PROD - APP - [trace-1] [10.0.0.5] [MyProg] [42] hello world'
$udp = New-Object System.Net.Sockets.UdpClient
$bytes = [Text.Encoding]::UTF8.GetBytes($msg)
$udp.Send($bytes, $bytes.Length, 'localhost', 5960)
$udp.Close()
```

Then query OpenSearch:

```bash
curl -s 'localhost:9200/logstash-*/_search?pretty&size=1'
```

You should see `traceId` as `"trace-1"`.
If the document has a `_grokparsefailure_log4net` tag, your line did not match any pattern —
see [Log formats](#log-formats).

### View in Dashboards

1. Go to **Management → Dashboards Management → Index patterns → Create index pattern**
2. Pattern: `logstash-*`
3. Time field: `@timestamp`
4. Open **Discover**

---

## Configuring your application

The stack expects plain-text log lines over UDP. The layout matters — see [Log formats](#log-formats).

### log4j (Java)

```xml
<Socket name="UdpAppender" host="localhost" port="5960" protocol="UDP">
    <PatternLayout pattern="%d{yyyy-MM-dd HH:mm:ss,SSSZZ} [%t] %-5p - ${hostName} - MYAPP.BACKOFFICE - %m%n"/>
    <encoding value="utf-8" />
</Socket>
```

### log4net (.NET)

```xml
<appender name="UdpAppender" type="log4net.Appender.UdpAppender">
   <RemoteAddress value="localhost" />
   <RemotePort value="5960" />
   <layout type="log4net.Layout.PatternLayout">
      <conversionPattern value="%d{ISO8601}%d{zzz} [%t] %-5p - %P{log4net:HostName} - MYAPP.BACKEND - %m%n" />
   </layout>
   <encoding value="utf-8" />
</appender>
```

Replace `localhost` with the host running the stack.

### GeneXus

The [`genexus/`](genexus) folder contains ready-made configs for GeneXus applications:

| File                 | What it is                                                          |
| -------------------- | ------------------------------------------------------------------- |
| `log.config`         | log4net config sending `GeneXusUserLog` output to this stack via UDP |
| `log.console.config` | Same, but writing to the console — useful while developing           |
| `sincrumlogs.xpz`    | GeneXus export with helper objects for structured logging            |

Drop `log.config` into your GeneXus model's deployment directory and adjust `RemoteAddress`.

---

## Log formats

Logstash tries three grok patterns, **in this order**, and stops at the first match.
Order matters: the generic pattern would otherwise swallow the specific ones.

**1. Structured / traced** — most specific

```
2026-07-13 10:00:00,123-03:00 [1] INFO  - host - ENV - TAG - [traceId] [10.0.0.5] [ProgramName] [42] message
```
Extracts: `traceId`, `source_ip`, `program_name`, `entityId` (a `keyword`, not a number)

**2. Program + tag**

```
2026-07-13 10:00:00,123-03:00 [1] WARN  - host - ENV - ProgramName - sometag - message
```
Extracts: `program`, `tag`

**3. Bare** — most generic, keep last

```
2026-07-13 10:00:00,123-03:00 [1] DEBUG - host - ENV - message
```

Every pattern extracts `@timestamp`, `threadid`, `loglevel`, `host` and `env`.

Lines that match none of the three are **still indexed**, with the original text intact and
tagged `_grokparsefailure_log4net`. Search for that tag in Dashboards to find them.

To add a format, edit [`logstash/pipeline/logstash.conf`](logstash/pipeline/logstash.conf) —
and place your new pattern **above** any pattern more generic than it.

---

## Data management

Logs land in daily indices: `logstash-YYYY.MM.dd`.

Two artifacts are installed automatically on startup by the `provisioning` service:

- **[`provisioning/index-template.json`](provisioning/index-template.json)** — explicit field mappings.
- **[`provisioning/ism-policy.json`](provisioning/ism-policy.json)** — an ISM policy that
  **deletes indices older than 30 days**. Without it, disk usage grows forever.

To change retention, override `LOG_RETENTION_DAYS` on the `provisioning` service
(see [Configuration](#configuration)) and re-run `docker compose up`. The bootstrap script is
idempotent — it updates the existing policy in place.

Data persists in the `opensearch-data` volume across restarts.
To wipe everything: `docker compose down -v`.

---

## Configuration

All tunables live in **[`.env`](.env)** — image versions, published ports, JVM heap sizes and
log retention. It is tracked in git, which is a deliberate choice:

- It contains **no secrets**, only defaults for a stack that ships without authentication.
- A single source of truth. No `.env.example` to keep in sync with a gitignored twin.
- A fresh clone runs with `docker compose up`, no `cp` step.

> **Never put credentials in `.env`.** If you enable security (see below), supply the password
> through `docker-compose.override.yml` or a shell variable instead.

Three ways to override, in increasing precedence:

| How | Committed? | Use it for |
| --- | --- | --- |
| Edit `.env` | yes | changing a default for everyone |
| Shell variable | no | your machine, or a one-off run: `OPENSEARCH_PORT=19200 docker compose up` |
| `docker-compose.override.yml` | no | secrets, and structural changes `.env` cannot express |

Ports, heap, retention and image versions are all variables in `.env`, so changing any of them
needs nothing more than a shell variable — no file to edit, nothing to keep out of git.

Reach for `docker-compose.override.yml` only when `.env` cannot help: credentials (it is
committed) or structure (an extra volume, a different healthcheck). It is a standard Compose
convention, not something this project invents: create the file and Compose merges it over
`docker-compose.yml` automatically, with no `-f`. It is gitignored.

Two merge rules worth knowing, because they differ and the difference bites:
`environment` is merged **key by key** — yours wins. But `ports` is **concatenated** — yours is
*added* to the existing one, so you cannot resolve a port conflict this way. To replace a port
list instead of appending to it, tag it `ports: !override`.

---

## Version notes

Pinned in [`.env`](.env). Two things worth knowing before you bump anything:

**Logstash is stuck in the 8.x series.** The `opensearch-project` Logstash image has not been
rebuilt in a long time, so it does not track OpenSearch releases. That is fine — Logstash talks
to OpenSearch over the REST API — but it means the version numbers of the two are unrelated, and
you should not expect a Logstash `3.x` to exist.

**ECS compatibility is switched off, in two places.** Logstash 8 turns ECS mode on by default,
which turns `host` into an object (`host.hostname`, `host.ip`) instead of a string. This pipeline
uses the flat, pre-ECS layout, and the index template maps `host` as a `keyword`, so ECS mode
produces mapping conflicts and OpenSearch starts rejecting documents.

It is therefore disabled twice, on purpose:

- **Per plugin**, with `ecs_compatibility => "disabled"` on the input, its codec, the grok filter
  and the output, in [`logstash/pipeline/logstash.conf`](logstash/pipeline/logstash.conf). This is
  what actually holds the schema flat.
- **Pipeline-wide**, with `PIPELINE_ECS_COMPATIBILITY=disabled` on the `logstash` service in
  [`docker-compose.yml`](docker-compose.yml), which the image's entrypoint maps into
  `logstash.yml`. This one is the safety net: a plugin added later without its own
  `ecs_compatibility` setting cannot silently start emitting ECS fields into the same index.

Note that this flag only governs the fields the *plugins* generate. The fields grok extracts
(`traceId`, `entityId`, `env`, …) are named by the pattern, and ECS mode does not touch them.

Relatedly, the pipeline sets `manage_template => false`: the index template is ours, installed by
the `provisioning` service, so the output plugin has no business pushing its own.

---

## Security

**The default setup has no authentication and no TLS.** The OpenSearch security plugin is
disabled (`DISABLE_SECURITY_PLUGIN=true`), the Dashboards security plugin is removed from the
image, and the UDP ingestion port accepts anything sent to it. This is a deliberate
*dev-first* trade-off: zero friction to get running.

What that means in practice:

- Anyone who can reach port `9200` can read and delete all your logs.
- Anyone who can reach port `5960/udp` can inject arbitrary log entries.
- Everything travels in plaintext.

**Only run this on `localhost` or a trusted internal network.**

### Enabling security

To run with the security plugin on:

1. **`docker-compose.yml`** — on the `opensearch` service, remove `DISABLE_SECURITY_PLUGIN`
   and `DISABLE_INSTALL_DEMO_CONFIG`, and set an admin password:
   ```yaml
   - OPENSEARCH_INITIAL_ADMIN_PASSWORD=${OPENSEARCH_ADMIN_PASSWORD}
   ```
   Supply the value from a shell variable, or from a `docker-compose.override.yml` — **never**
   from `.env`, which is committed (CI fails the build if it finds a credential in there):
   ```yaml
   # docker-compose.override.yml — gitignored, create it yourself
   services:
     opensearch:
       environment:
         - OPENSEARCH_INITIAL_ADMIN_PASSWORD=your-password
   ```
   Switch the healthcheck and all `OPENSEARCH_URL` / `OPENSEARCH_HOSTS` values to `https://`.

2. **The Dashboards security plugin is disabled twice** — undo both, or it stays off:
   delete the `RUN ... plugin remove securityDashboards` line in
   `opensearch_dashboards/Dockerfile`, and drop `DISABLE_SECURITY_DASHBOARDS_PLUGIN=true`
   from the `dashboards` service in `docker-compose.yml`.

3. **`opensearch_dashboards/opensearch_dashboards.yml`** — add:
   ```yaml
   opensearch.username: kibanaserver
   opensearch.password: <your-password>
   opensearch.requestHeadersWhitelist: [authorization, securitytenant]
   opensearch_security.multitenancy.enabled: false
   opensearch_security.cookie.secure: false   # true if you serve Dashboards over HTTPS
   ```

4. **`logstash/pipeline/logstash.conf`** — uncomment the `user`, `password` and `ssl` options
   in the `output` block and supply them via environment variables.

5. Provide **real certificates**. Do not reuse the OpenSearch demo certificates outside of a
   throwaway environment — their private keys are published and known to everyone.

For the full picture, see the
[OpenSearch security documentation](https://docs.opensearch.org/latest/security/).

---

## Troubleshooting

**Nothing shows up in Dashboards.**
Check that Logstash is actually receiving traffic: `docker compose logs -f logstash`.
UDP is fire-and-forget — if the port is wrong or blocked, the sender gets no error.

**Logs arrive but every field is `_grokparsefailure_log4net`.**
Your appender layout does not match any of the three patterns. Compare your output against
[Log formats](#log-formats), paying attention to the timestamp format and the ` - ` separators.

**OpenSearch container exits immediately.**
Almost always `max_map_count` on Linux/WSL:
```bash
sudo sysctl -w vm.max_map_count=262144
```

**Timestamps are off by a few hours.**
Make sure your layout emits the timezone offset (`%d{ISO8601}%d{zzz}` in log4net,
`ZZ` in log4j). Without it, Logstash assumes UTC.

**Port already in use.**
Republish on another host port with the variables from `.env` — no file needs editing:
```bash
OPENSEARCH_PORT=19200 DASHBOARDS_PORT=15601 LOG_UDP_PORT=15960 docker compose up
```
Do *not* try to fix this by adding a `ports:` entry in `docker-compose.override.yml`: Compose
concatenates port lists, so the conflicting binding would still be there. See
[Configuration](#configuration).

---

## Contributing

Bug reports and pull requests are welcome. See [CONTRIBUTING.md](CONTRIBUTING.md).

## License

[MIT](LICENSE) © Daniel Monza

Background reading (Spanish): [Gestión de logs con OpenSearch](https://blog.danielmonza.com/2022/05/gestion-logs-kibana-elasticsearch-simple.html)
