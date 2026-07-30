title: Piping OTEL metrics directly to Prometheus causes two errors

**PgDog version**
`c4f63fd6` latest main

**Description**
I was attempting to test some OTEL code locally, and I ran into a couple of interesting warnings when piping directly to Prometheus's native OTLP receiver (`--web.enable-otlp-receiver`).

Pgdog's OTEL exporter appears to be designed for Datadog and instead Prometheus users are pointed at the OpenMetrics `/metrics` endpoint. Datadog's OTLP ingest tolerates both issues below, so this only surfaces when someone points the exporter directly at Prometheus's native OTLP receiver. Filing anyway because the failure mode was confusing to me.

There are two independent issues.

**1. DELTA temporality on counters is rejected by Prometheus**

pgdog hardcodes `aggregation_temporality: 1` (DELTA) for counters at [`pgdog/src/stats/otel.rs:285`](../pgdog/src/stats/otel.rs). Prometheus's OTLP receiver defaults to CUMULATIVE-only and rejects the whole batch:

```
invalid temporality and type combination for metric "pgdog.total_server_errors"
```

Because Prometheus 400s the entire request, every gauge sharing that batch with a DELTA counter is dropped too.

Workaround on the Prometheus side is a single flag: `--enable-feature=otlp-deltatocumulative`.

The code at [`otel.rs:236-249`](../pgdog/src/stats/otel.rs) already stores cumulative values to compute the delta. We could switch to Cumulative, but I figure that will mess up datadog. I think the correct way to implement this would be to read the [`OTEL_EXPORTER_OTLP_METRICS_TEMPORALITY_PREFERENCE`](https://opentelemetry.io/docs/specs/otel/metrics/sdk_exporters/otlp/) environment variable, which OTEL describes as required.

**2. `target_info` out-of-order writes from parallel batching** _(fixed on this branch)_

```
Out of order sample from remote write ... series="{__name__=\"target_info\", host_name=\"...\", instance=\"...\", job=\"pgdog\"}"
```

The push loop in [`pgdog/src/stats/otel_exporter.rs`](../pgdog/src/stats/otel_exporter.rs) splits metrics into batches of 10 and fires them concurrently via `futures::future::join_all`. Each batch previously called `otel::build_request()` which captured its own `now_nanos()`. Every batch carries the same OTLP `Resource` block, so Prometheus's OTLP receiver synthesizes one `target_info` write per batch — same series identity, timestamps microseconds apart within one push cycle, arriving in nondeterministic order, colliding at millisecond precision on the server side. First-arriving batch's write lands at time T; the other N-1 in that cycle stamp their samples at T (or ≤ T after ms rounding), none of which are strictly greater than T, so Prometheus rejects them as out-of-order for the `target_info` series. Actual metric samples were unaffected because each metric appeared in exactly one batch per cycle.

Fix applied: `build_request` now takes a `now: &str` parameter and the exporter loop captures `otel::now_nanos()` once per push cycle before splitting into batches. Every batch in the cycle carries an identical timestamp, so Prometheus treats the resulting `target_info` writes as idempotent duplicates instead of out-of-order samples. Per-series monotonicity across cycles is preserved by the existing `sleep(interval)`. Verified end-to-end: with `--enable-feature=otlp-deltatocumulative` on Prometheus, running for 60s produces zero `target_info` errors (was ~2-3/cycle before) and `pgdog_clients_locked_ratio` correctly reports 1 while an advisory lock is held.

Low priority in absolute terms since it only affects the `target_info` metadata series, but easy to fix — hence this branch's change.

<details>
  <summary>Reproduction</summary>

Requires the `docker-compose.yml` on this branch. Prometheus is pointed at pgdog's OTLP endpoint with delta-to-cumulative enabled so the first error class no longer masks the second.

```yaml
# docker-compose.yml (excerpt)
services:
  pgdog:
    build: .
    environment:
      RUST_LOG: debug
      OTEL_EXPORTER_OTLP_ENDPOINT: http://prometheus:9090/api/v1/otlp/v1/metrics
      OTEL_METRIC_EXPORT_INTERVAL: "2000"
    depends_on: [prometheus]
  prometheus:
    image: prom/prometheus:latest
    command:
      - --config.file=/etc/prometheus/prometheus.yml
      - --web.enable-otlp-receiver
      - --enable-feature=otlp-deltatocumulative
      - --log.level=debug
    ports: [9090:9090]
```

```sh
docker compose up --build -d
sleep 15
docker compose logs prometheus | grep -E "temporality|Out of order"
```

Without `--enable-feature=otlp-deltatocumulative` you see error #1 (invalid temporality). With it enabled you see error #2 (target_info out of order). Every push cycle produces both classes until the flag is set; only #2 remains after.

</details>

**Logs**

```shell
prometheus-1  | time=2026-07-30T00:05:57.608Z level=ERROR source=write_handler.go:323 msg="Out of order sample from remote write" component=web err="out of order sample" series="{__name__=\"target_info\", host_name=\"047695bd73aa\", instance=\"90fcc956\", job=\"pgdog\"}" timestamp=1785369957605
pgdog-1       | 2026-07-30T00:05:57.608661Z TRACE shouldn't retry!
prometheus-1  | time=2026-07-30T00:05:57.608Z level=WARN source=write_handler.go:619 msg="Error translating OTLP metrics to Prometheus write request" component=web err="invalid temporality and type combination for metric \"pgdog.two_pc_recovered_total\""
pgdog-1       | 2026-07-30T00:05:57.608678Z TRACE put; add idle connection for ("http", prometheus:9090)

prometheus-1  | time=2026-07-30T00:05:57.608Z level=ERROR source=write_handler.go:323 msg="Out of order sample from remote write" component=web err="out of order sample" series="{__name__=\"target_info\", host_name=\"047695bd73aa\", instance=\"90fcc956\", job=\"pgdog\"}" timestamp=1785369957605
pgdog-1       | 2026-07-30T00:05:57.608688Z DEBUG pooling idle connection for ("http", prometheus:9090)
pgdog-1       | 2026-07-30T00:05:57.608694Z TRACE shouldn't retry!

pgdog-1       | 2026-07-30T00:05:57.608712Z TRACE put; add idle connection for ("http", prometheus:9090)
pgdog-1       | 2026-07-30T00:05:57.608718Z DEBUG pooling idle connection for ("http", prometheus:9090)
pgdog-1       | 2026-07-30T00:05:57.608723Z TRACE shouldn't retry!
pgdog-1       | 2026-07-30T00:05:57.608758Z  WARN otel exporter: endpoint returned 400 Bad Request: out of order sample
```

**Configuration**
I utilized ./docker/pgdog.toml and ./docker/users.toml, with pgdog built from source (`build: .` in docker-compose.yml) so `OTEL_EXPORTER_OTLP_ENDPOINT` was picked up from the environment. Note: the env var only takes effect when an `[otel]` section is also present in pgdog.toml — with no `[otel]` block, serde uses `Otel::default()` and never consults the env-var fallbacks in [`pgdog-config/src/otel.rs:71-101`](../pgdog-config/src/otel.rs). Worth documenting or fixing.
