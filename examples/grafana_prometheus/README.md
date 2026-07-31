# Grafana + Prometheus

Run PgDog behind three sharded Postgres instances, **push** its metrics to
Prometheus over OTLP, and visualize them in Grafana. Everything is wired up
via Docker Compose and Grafana provisioning — bring the stack up and open a
dashboard.

## Layout

```
docker-compose.yml           # shards + pgdog + synthetic
docker-compose.metrics.yml   # prometheus + grafana (auto-included)
pgdog.toml                   # [otel] endpoint = http://prometheus:9090/api/v1/otlp/v1/metrics
users.toml
synthetic/                   # Rust workload generator (Cargo project)
provisioning/
  prometheus/prometheus.yml            # global config, no scrape jobs (push-only)
  grafana/datasources/prometheus.yml   # Prometheus datasource
  grafana/dashboards/dashboards.yml    # dashboard provider
  grafana/dashboards/pgdog.json        # PgDog dashboard
```

## Architecture

```
pgdog  --OTLP push (every 5s)-->  prometheus  <--  grafana
```

PgDog uses its OTEL exporter (`[otel]` block in `pgdog.toml`) to POST OTLP JSON
directly to Prometheus's built-in OTLP receiver, enabled with
`--web.enable-otlp-receiver`. There is no scrape target — Prometheus only
ingests what PgDog pushes.

## Running

```sh
docker compose up
```

Ports on the host:

| Service    | URL                    |
|------------|------------------------|
| PgDog      | `postgres://postgres:postgres@127.0.0.1:6432/postgres` |
| Prometheus | http://127.0.0.1:9091 |
| Grafana    | http://127.0.0.1:3000 (admin / admin) |

The **PgDog** dashboard appears under the *PgDog* folder in Grafana once
PgDog has pushed a few samples.

## Generating traffic

A `synthetic` service (small Rust binary in `synthetic/`) starts automatically
and drives mixed load through PgDog: reads, upserts, and short transactions
holding a session-level advisory lock against a sharded `kv` table. PgDog pins
the client to a single server while the advisory lock is held (see
`pgdog/src/frontend/regex_parser.rs`), so the *Locked %* gauge picks up
movement.

Tune it via env vars on the `synthetic` service in `docker-compose.yml`:

- `CONCURRENCY` — number of concurrent client workers (default 10)
- `LOCK_RATE` — fraction of ops that acquire an advisory lock (default 0.05)
- `TX_RATE` — fraction of ops that run inside a transaction (default 0.05)
- `KEY_SPACE` — id range, spread across shards (default 10000)

To use your own traffic instead, comment the service out and point `pgbench` at
PgDog:

```sh
PGPASSWORD=postgres pgbench -h 127.0.0.1 -p 6432 -U postgres -i postgres
PGPASSWORD=postgres pgbench -h 127.0.0.1 -p 6432 -U postgres -c 8 -T 60 postgres
```

## Metrics

Metric names are prefixed with `pgdog_` (via `namespace` in `[otel]`). OTLP
attributes become Prometheus labels. Non-exhaustive list of what the dashboard
uses:

- `pgdog_clients`, `pgdog_cl_waiting` — client counts
- `pgdog_sv_active`, `pgdog_sv_idle` — server-side pool state (labeled by
  `shard`, `role`, `user`, `database`, `host`, `port`)
- `pgdog_maxwait_seconds` — longest client wait for a server
- `pgdog_total_query_count`, `pgdog_total_xact_count` — counters
- `pgdog_query_cache_hits`, `pgdog_query_cache_misses` — prepared statement
  cache activity

Browse them in Prometheus at http://127.0.0.1:9091/graph.
