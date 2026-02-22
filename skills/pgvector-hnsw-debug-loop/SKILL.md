---
name: pgvector-hnsw-debug-loop
description: Build pgvector with assertions, run HNSW regression tests against an isolated PostgreSQL instance with verbose server logging, and triage ACORN INCLUDE failures from regression.diffs plus server logs. Use when editing src/hnsw*.c, src/hnsw.h, or INCLUDE predicate filtering behavior.
compatibility: Requires make, pg_config, initdb, pg_ctl, psql, and permission to run make install for the active PostgreSQL installation.
metadata:
  author: local-dev
  version: "0.1.0"
---

# pgvector HNSW Debug Loop

Use this skill for the ACORN/INCLUDE development loop in this repository.

## When to use

- Changes touch `src/hnsw*.c`, `src/hnsw.h`, or HNSW regression outputs
- You need PostgreSQL-side evidence (server logs) for crashes, corruption, or wrong tuples
- `make installcheck` fails and you need a repeatable, isolated repro

## Recommended entrypoint

Run the helper script from the skill root:

```bash
scripts/run-debug-loop.sh
```

From this repository root, the equivalent command is:

```bash
skills/pgvector-hnsw-debug-loop/scripts/run-debug-loop.sh
```

Defaults:

- Builds with assertions enabled (`-DUSE_ASSERT_CHECKING`)
- Starts an isolated local cluster under `tmp_check/pgvector-debug/`
- Enables verbose server logging (`debug1`, `log_statement=all`, verbose errors)
- Runs focused tests: `hnsw_vector hnsw_halfvec hnsw_sparsevec`

Run specific tests:

```bash
skills/pgvector-hnsw-debug-loop/scripts/run-debug-loop.sh hnsw_vector
```

Useful environment variables:

- `PGVECTOR_DEBUG_PORT` (default `6543`)
- `PGVECTOR_DEBUG_ASSERTS` (`1` or `0`, default `1`)
- `PGVECTOR_DEBUG_KEEP_DATA` (`1` keeps cluster files after run)
- `PGVECTOR_DEBUG_USER` (defaults to current shell user)

## Artifacts to inspect

- `regression.out`
- `regression.diffs`
- `results/*.out`
- `tmp_check/pgvector-debug/log/postgres.log`
- `tmp_check/pgvector-debug/log/installcheck.log`

## Triage checklist

1. Confirm first failing SQL statement from `regression.diffs`
2. Match timestamp window in `postgres.log`
3. Capture the first backend error (not downstream noise)
4. Map signature using `references/failure-signatures.md`
5. Propose the smallest code change and rerun the same focused test

## Expected report format

After each run, report:

1. Command used
2. Tests that failed
3. First causal server error line(s)
4. Likely code hotspot (`file + function`)
5. Next minimal verification step

## Manual fallback (if script cannot run)

If script execution is blocked, run the same loop manually:

1. Build/install extension (`make clean`, `make`, `make install`)
2. Start isolated PostgreSQL with verbose logging
3. Run `make installcheck REGRESS="..."`
4. Review `regression.diffs` and server log together
5. Iterate on the smallest repro test before widening scope
