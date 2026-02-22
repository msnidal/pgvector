---
name: pgvector-hnsw-acorn-bench
description: Run synthetic end-to-end ACORN load benchmarks for pgvector HNSW INCLUDE filtering. Produces throughput, latency percentiles, recall@k, and reproducible run artifacts.
compatibility: Requires make, pg_config, initdb, pg_ctl, pg_isready, psql, pgbench, perl, and permission to run make install for the active PostgreSQL installation.
metadata:
  author: local-dev
  version: "0.1.0"
---

# pgvector HNSW ACORN Benchmark

Use this skill to run repeatable synthetic load tests on ACORN predicate queries and compare against standard WHERE-filtered ANN queries.

## What it measures

- Throughput (TPS)
- Average latency (ms)
- p50 / p95 / p99 latency from pgbench logs
- Recall@k against exact filtered search

## Entrypoint

From repository root:

```bash
skills/pgvector-hnsw-acorn-bench/scripts/run-acorn-bench.sh --mode quick
```

Run a comprehensive matrix:

```bash
skills/pgvector-hnsw-acorn-bench/scripts/run-acorn-bench.sh --mode full
```

## Useful options

- `--mode quick|full`
- `--rows N`
- `--dim N`
- `--query-count N`
- `--recall-queries N`
- `--duration N`
- `--repeats N`
- `--efs 40,80,160`
- `--clients 1,8,32`
- `--scenarios low,medium,high,range`
- `--skip-build`

## Environment variables

- `PGVECTOR_BENCH_PORT` (default `6546`)
- `PGVECTOR_BENCH_USER` (default current user)
- `PGVECTOR_BENCH_SKIP_BUILD` (`1` skips make/install)
- `PGVECTOR_BENCH_KEEP_DATA` (`1` keeps cluster data dir)

## Artifacts

Each run writes to:

`tmp_check/pgvector-acorn-bench/runs/<timestamp>/`

- `summary.md`
- `metrics.csv`
- `recall.csv`
- `env.txt`
- `pgbench-logs/`
- `workloads/`

## Notes

- `quick` is intended for iteration.
- `full` is intended for machine-level evaluation and can take a long time.
- ACORN workload uses native multicolumn key predicates in SQL (`WHERE` clauses on non-vector index keys).
