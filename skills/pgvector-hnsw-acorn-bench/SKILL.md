---
name: pgvector-hnsw-acorn-bench
description: Run synthetic ACORN e2e load test benchmarks for pgvector HNSW predicate filtering. Produces build time, size, recall, read TPS, churn R/W TPS, and WAL amplification metrics.
compatibility: Requires python3, make, pg_config, initdb, pg_ctl, pg_isready, psql, pgbench, perl, and permission to run make install for the active PostgreSQL installation.
metadata:
  author: local-dev
  version: "2.0.0"
---

# pgvector HNSW ACORN Benchmark v2

This skill provides a comprehensive end-to-end testing suite for profiling the behavior of pgvector's HNSW ACORN implementation.

Unlike static v1 benchmarks, the v2 suite focuses on dynamic workloads, specifically proving that the index scales well under heavy R/W churn without suffering from WAL amplification, memory leaks, LWLocks, or severe graph degradation (Recall collapse).

## What it measures

- **Index Build Time** (`CREATE INDEX`)
- **Initial Index Size** (MB)
- **Initial Recall@k** (Against an exact SeqScan)
- **Initial Read TPS** (`SELECT` queries)
- **Mixed R/W Churn TPS** (Concurrent `INSERT`, `UPDATE`, `DELETE`, `SELECT`)
- **WAL Amplification** (MBs of WAL generated during the churn)
- **Lock Contention** (Wait Event sampling during the churn)
- **Vacuum Behavior** (Time to `VACUUM ANALYZE` and space reclaimed)
- **Final Recall & TPS** (Proving the graph remains intact after extreme modifications)

## Entrypoints

Run a complete end-to-end benchmark:

```bash
skills/pgvector-hnsw-acorn-bench/scripts/run-e2e-bench.sh
```

Compare two runs (e.g., to verify an optimization):

```bash
skills/pgvector-hnsw-acorn-bench/scripts/compare-e2e-runs.sh \
  tmp_check/pgvector-e2e-bench/runs/<baseline> \
  tmp_check/pgvector-e2e-bench/runs/<candidate>
```

## Useful options

- `--rows N` (default: 50000)
- `--dim N` (default: 128)
- `--query-count N` (default: 2000)
- `--recall-queries N` (default: 100)
- `--skew-alpha N` (Zipfian skew factor, default: 1.5)
- `--m N` (HNSW max connections, default: 16)
- `--aux-m N` (ACORN max aux connections, default: 16)
- `--ef-construction N` (HNSW ef_construction, default: 64)
- `--ef-search N` (HNSW ef_search, default: 40)
- `--k N` (Top-K value, default: 20)
- `--churn-duration N` (Seconds to run the mixed R/W workload, default: 15)
- `--read-duration N` (Seconds to run read-only baseline benchmarks, default: 10)
- `--clients N` (Concurrency for pgbench tests, default: 8)
- `--port N` (Isolated PostgreSQL port, default: 6546)
- `--skip-build` (Skips make/install if you already compiled pgvector)
- `--keep-data` (Keeps the Postgres data directory after run for debugging)

## Artifacts

Each run writes to:

`tmp_check/pgvector-e2e-bench/runs/<timestamp>/`

- `summary.md` (Markdown report)
- `report.csv` (Raw data for the compare script)
- `items.csv` / `queries.csv` (Temporary data generation artifacts, deleted after load)
- `pgbench-logs/` (Raw pgbench outputs)
- `workloads/` (Generated SQL scripts for pgbench)

## Notes
- The dataset generation uses Python to inject real statistical Zipfian skew into the categories to properly stress the `epcache_hash` logic.
- The `aux_m` parameter is exposed and configurable to tune multicolumn routing density.
