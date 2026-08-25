# Load testing

<!--
TK markers are placeholders for numbers to paste from k6 summary output before
publishing. Everything not marked TK is a number this project produced. Search
for "TK" to find them all, and delete this comment afterwards.
-->

Script: `loadtest/load.js`. Run against a live stack with:

```powershell
$env:BASE_URL = (tofu output -raw alb_url)
k6 run loadtest/load.js
```

This document records the investigation rather than the tool. The useful finding
is not a latency number. It is that the first set of latency numbers was
measuring the wrong thing.

---

## Run 1: a baseline that could not be interpreted

100 VUs ramping over 3 minutes and holding for 4, against 2 Fargate tasks at 256
CPU and 512 MB, and one `db.t4g.micro`.

| Metric | p95 |
|---|---|
| `GET /library` | 7.71 s |
| `GET /stats` | 10.45 s |
| Write (`POST`/`PATCH`) | 16.6 s (max 4 m 47 s) |

There were also 30 `db_connection_errors` and a 3.76% error rate.

Two problems with the run showed up before any conclusion could be drawn from
those numbers.

Only 63 of 100 VUs were ever reached. `ramping-vus` is a closed model, so a
virtual user waits for its response before issuing the next request. Average
iteration duration was around 30 seconds, which meant k6 could not start VUs
fast enough to hit the target. That is not a limitation of k6. It is the server
throttling the offered load, and it means the test was measuring a system well
past saturation.

Every iteration also registered a new user. Registration hashes a password with
argon2, which is deliberately CPU-expensive, on a task with 0.25 vCPU. Each
`/library` timing therefore included an argon2 hash competing for the same CPU.

The second problem invalidates the run. Nothing in these numbers distinguishes
between a slow query, an exhausted connection pool, and argon2 saturating the
CPU. Those are three problems with three different fixes, and the measurement
could not separate them.

## The fix, and the A/B that established it mattered

Registration and login moved into k6's `setup()`, which runs once before load
starts. The default function now reuses tokens handed to it by `setup()`. A
`MEASURE_AUTH` environment flag re-enables in-loop auth so the two modes can be
compared directly rather than argued about.

Both variants ran on the same machine against the same Postgres 16 instance
under the same offered load:

| | auth in loop | auth in `setup()` |
|---|---|---|
| `GET /library` p95 | 195 ms | **3.2 ms** |
| Write p95 | 599 ms | **4.0 ms** |

A 60x difference on reads and 150x on writes, from a change that touched no
application code and no infrastructure. The application was never the thing
under measurement.

One caveat. This A/B ran locally, where the CPU is far larger than a Fargate
task's 0.25 vCPU, so the absolute numbers do not transfer. The ratio is the
result. The size of the confound scales with how CPU-constrained the target is,
so on Fargate it was larger rather than smaller.

## Run 2: a baseline that means something

The same 100 VU profile against the deployed stack, with auth outside the
measured window.

| Metric | p50 | p95 | p99 |
|---|---|---|---|
| `GET /library` | TK | TK | TK |
| `GET /stats` | TK | TK | TK |
| Write | TK | TK | TK |

`db_connection_errors`: TK. Error rate: TK. VUs reached: TK.

CloudWatch over the same window: ALB `TargetResponseTime` p95 of TK, RDS
`DatabaseConnections` peaking at TK, ECS service CPU at TK%. The ALB figure
should track the k6 numbers within a few milliseconds. A large gap would mean
time is being spent between the load generator and the target rather than inside
the application.

## The autoscaling result

The obvious response to a saturated service is more tasks.
`autoscaling_max_capacity` went from 6 to TK and the test was re-run.

Latency got worse. TK

The arithmetic explains it. Each task opens an asyncpg pool with
`POOL_MAX_SIZE = 10`. A `db.t4g.micro` has 1 GB of memory, which puts Postgres'
`max_connections` at roughly 112.

| Tasks | App connections | Share of `max_connections` |
|---|---|---|
| 2 | 20 | 18% |
| 6 | 60 | 54% |
| 10 | 100 | 89% |

Scaling out adds no database capacity. It multiplies demand against a fixed pool
of connections while each additional task's CPU sits mostly idle. Past a point,
new tasks contribute connection contention and Postgres backend memory and
nothing else. The CPU-based scaling policy cannot detect this, because CPU is
not the constrained resource.

That is why `max_capacity` is capped at 6 rather than raised. Six tasks is
approximately where the connection budget runs out, not where the CPU does. The
real fix is a connection pooler such as PgBouncer in transaction mode, or a
larger instance class. Either way it is a change to the database tier and not to
the compute tier.

## Where the alarm thresholds came from

`alarm_latency_p95_seconds = 1.0` is roughly 3x the observed p95 under the
intended load. Tight enough to catch a regression, loose enough not to fire on a
cold start.

`alarm_db_connections_threshold = 80` is about 70% of the 112 ceiling, crossed
at around 8 tasks. The alarm fires before the pool exhausts rather than after.

`alarm_app_error_threshold = 10` over 5 minutes counts `ERROR`, `CRITICAL`, and
`Traceback` through a log metric filter. That sits above the noise floor of a
single transient Open Library timeout.

## Method notes

Thresholds in `options.thresholds` are assertions. A crossed threshold exits
non-zero, which is what makes the script runnable in CI later.

`db_connection_errors` is a separate counter and not part of the error rate. The
distinction between an exhausted pool and an unhandled exception is the reason
for running the test at all.

Metric names were kept identical between runs so results are directly
comparable.

Data seeded by `setup()` persists in the database. Re-runs against the same
stack read a larger `library_entries` table than the first run did. The ramp is
short enough that this has not been significant so far, but it is a known bias.

## What this would need to be a real benchmark

A single load generator on a laptop over the public internet includes home
uplink and TLS handshake time in every measurement. Running k6 from an EC2
instance in `ca-central-1`, and repeating each run three times rather than once,
would separate network variance from application variance. Neither was done
here, so the numbers should be read as directional.
