---
name: pgvector-hnsw-acorn-bench
description: Run synthetic ACORN tradeoff benchmarks for pgvector HNSW predicate filtering. Produces build/index size metrics, throughput, latency, recall@k, and EXPLAIN BUFFERS evidence.
compatibility: Requires make, pg_config, initdb, pg_ctl, pg_isready, psql, pgbench, perl, and permission to run make install for the active PostgreSQL installation.
metadata:
  author: local-dev
  version: "0.2.0"
---

# pgvector HNSW ACORN Benchmark

Use this skill to run repeatable synthetic load tests on ACORN predicate queries and compare against explicit post-filter ANN queries.

## What it measures

- HNSW build time and index size (`vector_only` vs `acorn_multicol`)
- Throughput (TPS)
- Average latency (ms)
- p50 / p95 / p99 latency from pgbench logs
- Recall@k against exact filtered search
- Buffer behavior from `EXPLAIN (ANALYZE, BUFFERS)`

## Entrypoints

Quick iteration run (recommended starting point):

```bash
skills/pgvector-hnsw-acorn-bench/scripts/run-acorn-tradeoff-bench.sh --mode quick
```

Comprehensive matrix:

```bash
skills/pgvector-hnsw-acorn-bench/scripts/run-acorn-tradeoff-bench.sh --mode full
```

Legacy benchmark script (throughput/recall only):

```bash
skills/pgvector-hnsw-acorn-bench/scripts/run-acorn-bench.sh --mode quick
```

Compare two tradeoff runs (for ACORN-1 vs ACORN-gamma deltas):

```bash
skills/pgvector-hnsw-acorn-bench/scripts/compare-acorn-tradeoff-runs.sh \
  tmp_check/pgvector-acorn-bench/runs/<baseline> \
  tmp_check/pgvector-acorn-bench/runs/<candidate>
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
- `--io-probe-queries N`
- `--acorn-gamma N`
- `--acorn-m-beta N`
- `--seed FLOAT`
- `--shared-buffers VALUE`
- `--skip-build`

## Environment variables

- `PGVECTOR_BENCH_PORT` (default `6546`)
- `PGVECTOR_BENCH_USER` (default current user)
- `PGVECTOR_BENCH_SKIP_BUILD` (`1` skips make/install)
- `PGVECTOR_BENCH_KEEP_DATA` (`1` keeps cluster data dir)
- `PGVECTOR_BENCH_SHARED_BUFFERS` (default `64MB`)
- `PGVECTOR_BENCH_ACORN_GAMMA` (default `1`)
- `PGVECTOR_BENCH_ACORN_M_BETA` (default `0`)
- `PGVECTOR_BENCH_SEED` (default `0.42`)

## Artifacts

Each run writes to:

`tmp_check/pgvector-acorn-bench/runs/<timestamp>/`

- `summary.md`
- `index_build.csv`
- `metrics.csv`
- `recall.csv`
- `io_probe.csv`
- `env.txt`
- `pgbench-logs/`
- `workloads/`

## Notes

- `quick` is intended for iteration.
- `full` is intended for machine-level evaluation and can take a long time.
- `acorn` method uses native multicolumn key predicates in SQL (`WHERE` on non-vector index keys).
- `post` method forces ANN first, then applies predicates to the ANN candidate set.
- Use the compare script after implementing ACORN-gamma to produce clean before/after deltas.
