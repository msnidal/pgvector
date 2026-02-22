# Failure Signatures

Use this file to map common errors to likely hotspots in the current ACORN/INCLUDE work.

## Signature: `Predicate pointer is NULL, possible memory corruption`

- Likely issue: predicate pointer allocation, serialization, or tuple layout mismatch
- First files to inspect:
  - `src/hnswbuild.c`
  - `src/hnswutils.c`
  - `src/hnsw.h`

## Signature: `could not open file ... target block ... previous segment is only 1 blocks`

- Likely issue: corrupted block references or invalid tuple/page offsets
- First files to inspect:
  - `src/hnswutils.c`
  - `src/hnswbuild.c`
  - `src/hnswinsert.c`
  - `src/hnsw.h`

## Signature: `could not read block ... read only 0 of 8192 bytes`

- Likely issue: invalid block number generated during graph traversal or tuple decoding
- First files to inspect:
  - `src/hnswscan.c`
  - `src/hnswutils.c`
  - `src/hnswinsert.c`

## Signature: assertion failure in HNSW functions

- Likely issue: invariants broken by INCLUDE column handling (neighbor counts, element tuple sizes, pointer validity)
- First files to inspect:
  - `src/hnswutils.c`
  - `src/hnswbuild.c`
  - `src/hnswinsert.c`

## SQL sections to prioritize

- `test/sql/hnsw_vector.sql` include sections
- `test/sql/hnsw_halfvec.sql` early HNSW query sections
- `test/sql/hnsw_sparsevec.sql` early HNSW query sections
