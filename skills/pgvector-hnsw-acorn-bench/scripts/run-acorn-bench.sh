#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../../.." && pwd)"

usage() {
  cat <<'EOF'
Usage:
  skills/pgvector-hnsw-acorn-bench/scripts/run-acorn-bench.sh [options]

Options:
  --mode quick|full           Benchmark mode (default: quick)
  --rows N                    Number of synthetic item rows
  --dim N                     Vector dimensions
  --query-count N             Query pool size for pgbench
  --recall-queries N          Query count for recall@k evaluation
  --duration N                pgbench duration in seconds per run
  --repeats N                 Repeats per matrix point
  --k N                       Top-k value
  --efs A,B,C                ef_search values (comma separated)
  --clients A,B,C            Client counts (comma separated)
  --scenarios A,B,C          Scenarios: low,medium,high,range
  --methods A,B              Methods: acorn,where
  --port N                    Isolated PostgreSQL port
  --skip-build                Skip make/make install
  --keep-data                 Keep benchmark data directory
  -h, --help                  Show this help

Environment overrides:
  PGVECTOR_BENCH_MODE
  PGVECTOR_BENCH_PORT
  PGVECTOR_BENCH_USER
  PGVECTOR_BENCH_SKIP_BUILD
  PGVECTOR_BENCH_KEEP_DATA
EOF
}

set_mode_defaults() {
  local mode="$1"

  case "$mode" in
    quick)
      ROWS=50000
      DIM=64
      QUERY_COUNT=2000
      RECALL_QUERIES=100
      DURATION=8
      REPEATS=1
      K=20
      EF_LIST="40,80"
      CLIENT_LIST="1,8"
      SCENARIO_LIST="low,medium,high,range"
      METHOD_LIST="acorn,where"
      ;;
    full)
      ROWS=200000
      DIM=128
      QUERY_COUNT=10000
      RECALL_QUERIES=300
      DURATION=20
      REPEATS=3
      K=20
      EF_LIST="40,80,160"
      CLIENT_LIST="1,8,32"
      SCENARIO_LIST="low,medium,high,range"
      METHOD_LIST="acorn,where"
      ;;
    *)
      echo "Unknown mode: $mode" >&2
      exit 1
      ;;
  esac
}

scenario_where_clause() {
  local scenario="$1"

  case "$scenario" in
    low)
      echo "i.cat_low = q.cat_low"
      ;;
    medium)
      echo "i.cat_med = q.cat_med"
      ;;
    high)
      echo "i.cat_high = q.cat_high"
      ;;
    range)
      echo "i.score BETWEEN q.score_lo AND q.score_hi"
      ;;
    *)
      echo "Invalid scenario: $scenario" >&2
      exit 1
      ;;
  esac
}

write_workload_script() {
  local method="$1"
  local scenario="$2"
  local out_path="$3"
  local where_clause

  where_clause="$(scenario_where_clause "$scenario")"

  if [ "$method" = "where" ]; then
    cat > "$out_path" <<EOF
\set qid random(1, :query_count)
BEGIN;
SET LOCAL enable_seqscan = off;
SET LOCAL hnsw.ef_search = :ef_search;
WITH q AS (
  SELECT embedding, cat_low, cat_med, cat_high, score_lo, score_hi
  FROM acorn_queries
  WHERE id = :qid
)
SELECT id
FROM q, LATERAL (
  SELECT id
  FROM acorn_items i
  WHERE ${where_clause}
  ORDER BY i.embedding <-> q.embedding
  LIMIT :k
) nn;
COMMIT;
EOF
    return
  fi

  case "$scenario" in
    low)
      cat > "$out_path" <<'EOF'
\set qid random(1, :query_count)
BEGIN;
SET LOCAL enable_seqscan = off;
SET LOCAL hnsw.ef_search = :ef_search;
WITH q AS (
  SELECT embedding, cat_low::text AS filter_value
  FROM acorn_queries
  WHERE id = :qid
),
s AS (
  SELECT hnsw_set_filter('acorn_hnsw_idx', 'cat_low', '=', q.filter_value)
  FROM q
)
SELECT id
FROM q, s, LATERAL (
  SELECT id
  FROM acorn_items
  ORDER BY embedding <-> q.embedding
  LIMIT :k
) nn;
COMMIT;
EOF
      ;;
    medium)
      cat > "$out_path" <<'EOF'
\set qid random(1, :query_count)
BEGIN;
SET LOCAL enable_seqscan = off;
SET LOCAL hnsw.ef_search = :ef_search;
WITH q AS (
  SELECT embedding, cat_med::text AS filter_value
  FROM acorn_queries
  WHERE id = :qid
),
s AS (
  SELECT hnsw_set_filter('acorn_hnsw_idx', 'cat_med', '=', q.filter_value)
  FROM q
)
SELECT id
FROM q, s, LATERAL (
  SELECT id
  FROM acorn_items
  ORDER BY embedding <-> q.embedding
  LIMIT :k
) nn;
COMMIT;
EOF
      ;;
    high)
      cat > "$out_path" <<'EOF'
\set qid random(1, :query_count)
BEGIN;
SET LOCAL enable_seqscan = off;
SET LOCAL hnsw.ef_search = :ef_search;
WITH q AS (
  SELECT embedding, cat_high::text AS filter_value
  FROM acorn_queries
  WHERE id = :qid
),
s AS (
  SELECT hnsw_set_filter('acorn_hnsw_idx', 'cat_high', '=', q.filter_value)
  FROM q
)
SELECT id
FROM q, s, LATERAL (
  SELECT id
  FROM acorn_items
  ORDER BY embedding <-> q.embedding
  LIMIT :k
) nn;
COMMIT;
EOF
      ;;
    range)
      cat > "$out_path" <<'EOF'
\set qid random(1, :query_count)
BEGIN;
SET LOCAL enable_seqscan = off;
SET LOCAL hnsw.ef_search = :ef_search;
WITH q AS (
  SELECT embedding, score_lo::text AS lo, score_hi::text AS hi
  FROM acorn_queries
  WHERE id = :qid
),
s1 AS (
  SELECT hnsw_set_filter('acorn_hnsw_idx', 'score', '>=', q.lo)
  FROM q
),
s2 AS (
  SELECT hnsw_set_filter('acorn_hnsw_idx', 'score', '<=', q.hi)
  FROM q
)
SELECT id
FROM q, s1, s2, LATERAL (
  SELECT id
  FROM acorn_items
  ORDER BY embedding <-> q.embedding
  LIMIT :k
) nn;
COMMIT;
EOF
      ;;
    *)
      echo "Invalid scenario: $scenario" >&2
      exit 1
      ;;
  esac
}

pgbench_log_stats() {
  local pattern="$1"
  local files=()
  local file

  shopt -s nullglob
  for file in $pattern; do
    files+=("$file")
  done
  shopt -u nullglob

  if [ "${#files[@]}" -eq 0 ]; then
    echo "nan,nan,nan,nan"
    return
  fi

  perl -e '
    my @v;
    while (<>) {
      my @f = split(/\s+/, $_);
      next if @f < 3;
      my $lat = $f[2];
      next unless $lat =~ /^\d+(?:\.\d+)?$/;
      push @v, $lat + 0;
    }
    if (!@v) {
      print "nan,nan,nan,nan\n";
      exit;
    }
    @v = sort { $a <=> $b } @v;
    my $n = scalar @v;
    my $sum = 0;
    $sum += $_ for @v;

    sub pct {
      my ($vals, $p) = @_;
      my $count = scalar @$vals;
      my $idx = int(($count - 1) * $p);
      return $vals->[$idx] / 1000.0;
    }

    printf("%.6f,%.6f,%.6f,%.6f\n",
      $sum / $n / 1000.0,
      pct(\@v, 0.50),
      pct(\@v, 0.95),
      pct(\@v, 0.99));
  ' "${files[@]}"
}

run_recall_case() {
  local method="$1"
  local scenario="$2"
  local ef="$3"
  local where_clause
  local exact_select
  local actual_select
  local sql
  local row
  local recall
  local avg_exact
  local query_rows

  where_clause="$(scenario_where_clause "$scenario")"
  exact_select="SELECT q.id AS qid, r.id AS item_id FROM acorn_queries q CROSS JOIN LATERAL (SELECT i.id FROM acorn_items i WHERE ${where_clause} ORDER BY i.embedding <-> q.embedding LIMIT ${K}) r WHERE q.id <= ${RECALL_QUERIES}"

  if [ "$method" = "acorn" ]; then
    actual_select="SELECT q.id AS qid, r.item_id AS item_id FROM acorn_queries q CROSS JOIN LATERAL acorn_bench_acorn_search(q.embedding, '${scenario}', q.cat_low, q.cat_med, q.cat_high, q.score_lo, q.score_hi, ${K}) r WHERE q.id <= ${RECALL_QUERIES}"
  else
    actual_select="SELECT q.id AS qid, r.id AS item_id FROM acorn_queries q CROSS JOIN LATERAL (SELECT i.id FROM acorn_items i WHERE ${where_clause} ORDER BY i.embedding <-> q.embedding LIMIT ${K}) r WHERE q.id <= ${RECALL_QUERIES}"
  fi

  sql="
SET jit = off;
SET hnsw.ef_search = ${ef};
SET enable_seqscan = off;
CREATE TEMP TABLE actual_results AS ${actual_select};
SET enable_indexscan = off;
SET enable_bitmapscan = off;
SET enable_seqscan = on;
CREATE TEMP TABLE exact_results AS ${exact_select};
WITH exact_counts AS (
  SELECT qid, count(*) AS exact_count
  FROM exact_results
  GROUP BY qid
),
match_counts AS (
  SELECT e.qid, count(*) AS match_count
  FROM exact_results e
  JOIN actual_results a USING (qid, item_id)
  GROUP BY e.qid
),
per_query AS (
  SELECT ec.qid,
         ec.exact_count,
         CASE
           WHEN ec.exact_count = 0 THEN 1.0
           ELSE COALESCE(mc.match_count, 0)::float8 / ec.exact_count
         END AS recall
  FROM exact_counts ec
  LEFT JOIN match_counts mc USING (qid)
)
SELECT COALESCE(round(avg(recall)::numeric, 6), 1.0),
       COALESCE(round(avg(exact_count)::numeric, 2), 0),
       count(*)
FROM per_query;"

  row="$(PGHOST="$SOCKET_DIR" PGPORT="$PORT" PGUSER="$PGUSER_NAME" "$PSQL_BIN" -X -q -v ON_ERROR_STOP=1 -At -F ',' -h "$SOCKET_DIR" -p "$PORT" -U "$PGUSER_NAME" "$DB_NAME" -c "$sql" | awk -F',' '/^[0-9]+(\.[0-9]+)?,/ {print; exit}')"

  if [ -z "$row" ]; then
    recall="nan"
    avg_exact="nan"
    query_rows="nan"
  else
    IFS=',' read -r recall avg_exact query_rows <<< "$row"
  fi
  echo "${RUN_ID},${MODE},${method},${scenario},${ef},${recall},${avg_exact},${query_rows}" >> "$RECALL_CSV"
}

run_pgbench_case() {
  local method="$1"
  local scenario="$2"
  local ef="$3"
  local clients="$4"
  local repeat="$5"
  local tag
  local out_file
  local script_path
  local tx_count
  local tps
  local latency_avg
  local log_stats
  local latency_log_avg
  local p50
  local p95
  local p99

  tag="${method}_${scenario}_ef${ef}_c${clients}_r${repeat}"
  out_file="${RUN_DIR}/${tag}.out"
  script_path="${WORKLOAD_DIR}/${method}_${scenario}.sql"

  rm -f "${PGBENCH_LOG_DIR}/${tag}_"*

  (
    cd "$PGBENCH_LOG_DIR"
    PGHOST="$SOCKET_DIR" PGPORT="$PORT" PGUSER="$PGUSER_NAME" \
      "$PGBENCH_BIN" -n -M simple -r -l --log-prefix="${tag}_" \
      -c "$clients" -j "$clients" -T "$DURATION" \
      -D query_count="$QUERY_COUNT" -D ef_search="$ef" -D k="$K" \
      -f "$script_path" "$DB_NAME"
  ) > "$out_file" 2>&1

  tx_count="$(awk -F': ' '/number of transactions actually processed/ {split($2, a, "/"); gsub(/[[:space:]]/, "", a[1]); print a[1]; exit}' "$out_file")"
  tps="$(awk '/^tps =/ {print $3; exit}' "$out_file")"
  latency_avg="$(awk -F'= ' '/latency average =/ {gsub(/ ms/, "", $2); gsub(/^[[:space:]]+/, "", $2); print $2; exit}' "$out_file")"

  if [ -z "$tx_count" ]; then
    tx_count="nan"
  fi

  if [ -z "$tps" ]; then
    tps="nan"
  fi

  if [ -z "$latency_avg" ]; then
    latency_avg="nan"
  fi

  log_stats="$(pgbench_log_stats "${PGBENCH_LOG_DIR}/${tag}_*")"
  IFS=',' read -r latency_log_avg p50 p95 p99 <<< "$log_stats"

  echo "${RUN_ID},${MODE},${method},${scenario},${ef},${clients},${DURATION},${repeat},${tx_count},${tps},${latency_avg},${latency_log_avg},${p50},${p95},${p99}" >> "$METRICS_CSV"
}

write_summary() {
  {
    echo "# ACORN HNSW Benchmark Summary"
    echo
    echo "- Run ID: ${RUN_ID}"
    echo "- Mode: ${MODE}"
    echo "- Rows: ${ROWS}"
    echo "- Dimensions: ${DIM}"
    echo "- Query count: ${QUERY_COUNT}"
    echo "- Recall queries: ${RECALL_QUERIES}"
    echo "- k: ${K}"
    echo "- Duration per run (s): ${DURATION}"
    echo "- Repeats: ${REPEATS}"
    echo
    echo "## Recall@k"
    echo
    echo "method,scenario,ef_search,recall_at_k,avg_exact_candidates,queries"
    awk -F',' 'NR > 1 {printf "%s,%s,%s,%s,%s,%s\n", $3, $4, $5, $6, $7, $8}' "$RECALL_CSV" | sort
    echo
    echo "## Throughput and Latency (averaged across repeats)"
    echo
    echo "method,scenario,ef_search,clients,avg_tps,avg_latency_ms,avg_p95_ms,avg_p99_ms,runs"
    awk -F',' '
      NR > 1 {
        key = $3 "," $4 "," $5 "," $6;
        tps[key] += $10;
        lat[key] += $11;
        p95[key] += $14;
        p99[key] += $15;
        n[key]++;
      }
      END {
        for (k in n) {
          printf "%s,%.6f,%.6f,%.6f,%.6f,%d\n", k, tps[k] / n[k], lat[k] / n[k], p95[k] / n[k], p99[k] / n[k], n[k];
        }
      }
    ' "$METRICS_CSV" | sort
    echo
    echo "## Artifacts"
    echo
    echo "- env: ${ENV_TXT}"
    echo "- metrics: ${METRICS_CSV}"
    echo "- recall: ${RECALL_CSV}"
    echo "- pgbench logs: ${PGBENCH_LOG_DIR}"
    echo "- workloads: ${WORKLOAD_DIR}"
  } > "$SUMMARY_MD"
}

MODE_OVERRIDE=""
ROWS_OVERRIDE=""
DIM_OVERRIDE=""
QUERY_COUNT_OVERRIDE=""
RECALL_QUERIES_OVERRIDE=""
DURATION_OVERRIDE=""
REPEATS_OVERRIDE=""
K_OVERRIDE=""
EF_LIST_OVERRIDE=""
CLIENT_LIST_OVERRIDE=""
SCENARIO_LIST_OVERRIDE=""
METHOD_LIST_OVERRIDE=""
PORT_OVERRIDE=""

SKIP_BUILD="${PGVECTOR_BENCH_SKIP_BUILD:-0}"
KEEP_DATA="${PGVECTOR_BENCH_KEEP_DATA:-0}"
PORT="${PGVECTOR_BENCH_PORT:-6546}"
PGUSER_NAME="${PGVECTOR_BENCH_USER:-${USER}}"

while [ "$#" -gt 0 ]; do
  case "$1" in
    --mode)
      MODE_OVERRIDE="$2"
      shift 2
      ;;
    --rows)
      ROWS_OVERRIDE="$2"
      shift 2
      ;;
    --dim)
      DIM_OVERRIDE="$2"
      shift 2
      ;;
    --query-count)
      QUERY_COUNT_OVERRIDE="$2"
      shift 2
      ;;
    --recall-queries)
      RECALL_QUERIES_OVERRIDE="$2"
      shift 2
      ;;
    --duration)
      DURATION_OVERRIDE="$2"
      shift 2
      ;;
    --repeats)
      REPEATS_OVERRIDE="$2"
      shift 2
      ;;
    --k)
      K_OVERRIDE="$2"
      shift 2
      ;;
    --efs)
      EF_LIST_OVERRIDE="$2"
      shift 2
      ;;
    --clients)
      CLIENT_LIST_OVERRIDE="$2"
      shift 2
      ;;
    --scenarios)
      SCENARIO_LIST_OVERRIDE="$2"
      shift 2
      ;;
    --methods)
      METHOD_LIST_OVERRIDE="$2"
      shift 2
      ;;
    --port)
      PORT_OVERRIDE="$2"
      shift 2
      ;;
    --skip-build)
      SKIP_BUILD=1
      shift
      ;;
    --keep-data)
      KEEP_DATA=1
      shift
      ;;
    --help|-h)
      usage
      exit 0
      ;;
    *)
      echo "Unknown option: $1" >&2
      usage
      exit 1
      ;;
  esac
done

MODE="${MODE_OVERRIDE:-${PGVECTOR_BENCH_MODE:-quick}}"
set_mode_defaults "$MODE"

if [ -n "${PGVECTOR_BENCH_EFS:-}" ]; then
  EF_LIST="${PGVECTOR_BENCH_EFS}"
fi

if [ -n "${PGVECTOR_BENCH_CLIENTS:-}" ]; then
  CLIENT_LIST="${PGVECTOR_BENCH_CLIENTS}"
fi

if [ -n "${PGVECTOR_BENCH_SCENARIOS:-}" ]; then
  SCENARIO_LIST="${PGVECTOR_BENCH_SCENARIOS}"
fi

if [ -n "${PGVECTOR_BENCH_METHODS:-}" ]; then
  METHOD_LIST="${PGVECTOR_BENCH_METHODS}"
fi

if [ -n "$ROWS_OVERRIDE" ]; then
  ROWS="$ROWS_OVERRIDE"
fi

if [ -n "$DIM_OVERRIDE" ]; then
  DIM="$DIM_OVERRIDE"
fi

if [ -n "$QUERY_COUNT_OVERRIDE" ]; then
  QUERY_COUNT="$QUERY_COUNT_OVERRIDE"
fi

if [ -n "$RECALL_QUERIES_OVERRIDE" ]; then
  RECALL_QUERIES="$RECALL_QUERIES_OVERRIDE"
fi

if [ -n "$DURATION_OVERRIDE" ]; then
  DURATION="$DURATION_OVERRIDE"
fi

if [ -n "$REPEATS_OVERRIDE" ]; then
  REPEATS="$REPEATS_OVERRIDE"
fi

if [ -n "$K_OVERRIDE" ]; then
  K="$K_OVERRIDE"
fi

if [ -n "$EF_LIST_OVERRIDE" ]; then
  EF_LIST="$EF_LIST_OVERRIDE"
fi

if [ -n "$CLIENT_LIST_OVERRIDE" ]; then
  CLIENT_LIST="$CLIENT_LIST_OVERRIDE"
fi

if [ -n "$SCENARIO_LIST_OVERRIDE" ]; then
  SCENARIO_LIST="$SCENARIO_LIST_OVERRIDE"
fi

if [ -n "$METHOD_LIST_OVERRIDE" ]; then
  METHOD_LIST="$METHOD_LIST_OVERRIDE"
fi

if [ -n "$PORT_OVERRIDE" ]; then
  PORT="$PORT_OVERRIDE"
fi

EF_LIST="$(echo "$EF_LIST" | tr -d ' ')"
CLIENT_LIST="$(echo "$CLIENT_LIST" | tr -d ' ')"
SCENARIO_LIST="$(echo "$SCENARIO_LIST" | tr -d ' ')"
METHOD_LIST="$(echo "$METHOD_LIST" | tr -d ' ')"

IFS=',' read -r -a EF_VALUES <<< "$EF_LIST"
IFS=',' read -r -a CLIENTS <<< "$CLIENT_LIST"
IFS=',' read -r -a SCENARIOS <<< "$SCENARIO_LIST"
IFS=',' read -r -a METHODS <<< "$METHOD_LIST"

if [ "${#EF_VALUES[@]}" -eq 0 ] || [ -z "${EF_VALUES[0]}" ]; then
  echo "ef_search list cannot be empty" >&2
  exit 1
fi

if [ "${#CLIENTS[@]}" -eq 0 ] || [ -z "${CLIENTS[0]}" ]; then
  echo "clients list cannot be empty" >&2
  exit 1
fi

if [ "${#SCENARIOS[@]}" -eq 0 ] || [ -z "${SCENARIOS[0]}" ]; then
  echo "scenarios list cannot be empty" >&2
  exit 1
fi

if [ "${#METHODS[@]}" -eq 0 ] || [ -z "${METHODS[0]}" ]; then
  echo "methods list cannot be empty" >&2
  exit 1
fi

for scenario in "${SCENARIOS[@]}"; do
  case "$scenario" in
    low|medium|high|range)
      ;;
    *)
      echo "Invalid scenario: $scenario" >&2
      exit 1
      ;;
  esac
done

for method in "${METHODS[@]}"; do
  case "$method" in
    acorn|where)
      ;;
    *)
      echo "Invalid method: $method" >&2
      exit 1
      ;;
  esac
done

if [ "$RECALL_QUERIES" -gt "$QUERY_COUNT" ]; then
  RECALL_QUERIES="$QUERY_COUNT"
fi

WORK_DIR="${REPO_ROOT}/tmp_check/pgvector-acorn-bench"
DATA_DIR="${PGVECTOR_BENCH_DATA_DIR:-${WORK_DIR}/data}"
SOCKET_DIR="${PGVECTOR_BENCH_SOCKET_DIR:-${WORK_DIR}/run}"
LOG_DIR="${PGVECTOR_BENCH_LOG_DIR:-${WORK_DIR}/log}"
RUNS_DIR="${WORK_DIR}/runs"

RUN_ID="$(date +%Y%m%d-%H%M%S)"
RUN_DIR="${RUNS_DIR}/${RUN_ID}"
WORKLOAD_DIR="${RUN_DIR}/workloads"
PGBENCH_LOG_DIR="${RUN_DIR}/pgbench-logs"
ENV_TXT="${RUN_DIR}/env.txt"
METRICS_CSV="${RUN_DIR}/metrics.csv"
RECALL_CSV="${RUN_DIR}/recall.csv"
SUMMARY_MD="${RUN_DIR}/summary.md"

mkdir -p "$RUN_DIR" "$WORKLOAD_DIR" "$PGBENCH_LOG_DIR" "$LOG_DIR" "$SOCKET_DIR"

for cmd in make pg_config perl; do
  if ! command -v "$cmd" >/dev/null 2>&1; then
    echo "Missing required command: $cmd" >&2
    exit 1
  fi
done

PGBIN="$(pg_config --bindir)"
INITDB_BIN="${PGBIN}/initdb"
PG_CTL_BIN="${PGBIN}/pg_ctl"
PG_ISREADY_BIN="${PGBIN}/pg_isready"
PSQL_BIN="${PGBIN}/psql"
PGBENCH_BIN="${PGBIN}/pgbench"
CREATEDB_BIN="${PGBIN}/createdb"
DROPDB_BIN="${PGBIN}/dropdb"

for cmd in "$INITDB_BIN" "$PG_CTL_BIN" "$PG_ISREADY_BIN" "$PSQL_BIN" "$PGBENCH_BIN" "$CREATEDB_BIN" "$DROPDB_BIN"; do
  if [ ! -x "$cmd" ]; then
    echo "Missing PostgreSQL binary: $cmd" >&2
    exit 1
  fi
done

if [ "$KEEP_DATA" != "1" ]; then
  if [ -f "${DATA_DIR}/postmaster.pid" ]; then
    "$PG_CTL_BIN" -D "$DATA_DIR" -m fast stop >/dev/null 2>&1 || true
  fi
  rm -rf "$DATA_DIR" "$SOCKET_DIR"
  mkdir -p "$SOCKET_DIR"
fi

if [ ! -f "${DATA_DIR}/PG_VERSION" ]; then
  rm -rf "$DATA_DIR"
  "$INITDB_BIN" -D "$DATA_DIR" -A trust -U "$PGUSER_NAME" >/dev/null
fi

BENCH_CONF="${DATA_DIR}/bench.conf"
cat > "$BENCH_CONF" <<EOF
port = ${PORT}
listen_addresses = ''
unix_socket_directories = '${SOCKET_DIR}'
jit = off
synchronous_commit = off
log_min_messages = warning
EOF

if ! grep -q "include_if_exists = 'bench.conf'" "${DATA_DIR}/postgresql.conf"; then
  echo "include_if_exists = 'bench.conf'" >> "${DATA_DIR}/postgresql.conf"
fi

STARTED_BY_SCRIPT=0

cleanup() {
  if [ "$STARTED_BY_SCRIPT" -eq 1 ]; then
    "$PG_CTL_BIN" -D "$DATA_DIR" -m fast stop >/dev/null 2>&1 || true
  fi
}

trap cleanup EXIT

if ! "$PG_ISREADY_BIN" -h "$SOCKET_DIR" -p "$PORT" -U "$PGUSER_NAME" >/dev/null 2>&1; then
  "$PG_CTL_BIN" -D "$DATA_DIR" -l "${LOG_DIR}/postgres.log" start >/dev/null
  STARTED_BY_SCRIPT=1
fi

cd "$REPO_ROOT"

if [ "$SKIP_BUILD" != "1" ]; then
  echo "Building and installing pgvector"
  make -j4
  make install
fi

DB_NAME="acorn_bench"

PGHOST="$SOCKET_DIR" PGPORT="$PORT" PGUSER="$PGUSER_NAME" "$DROPDB_BIN" --if-exists "$DB_NAME" >/dev/null 2>&1 || true
PGHOST="$SOCKET_DIR" PGPORT="$PORT" PGUSER="$PGUSER_NAME" "$CREATEDB_BIN" "$DB_NAME"

ARRAY_SQL="$(perl -e 'my $d = shift; print join(",", ("random()") x $d);' "$DIM")"

LOW_CARD=5
MED_CARD=50
HIGH_CARD=500
SCORE_CARD=1000
SCORE_BAND=10
MAINTENANCE_WORK_MEM="${PGVECTOR_BENCH_MAINTENANCE_WORK_MEM:-1GB}"

echo "Preparing synthetic dataset and index"
PGHOST="$SOCKET_DIR" PGPORT="$PORT" PGUSER="$PGUSER_NAME" "$PSQL_BIN" -X -v ON_ERROR_STOP=1 -h "$SOCKET_DIR" -p "$PORT" -U "$PGUSER_NAME" "$DB_NAME" <<SQL
CREATE EXTENSION IF NOT EXISTS vector;

DROP TABLE IF EXISTS acorn_queries;
DROP TABLE IF EXISTS acorn_items;

CREATE TABLE acorn_items (
  id bigserial PRIMARY KEY,
  embedding vector(${DIM}),
  cat_low int NOT NULL,
  cat_med int NOT NULL,
  cat_high int NOT NULL,
  score int NOT NULL
);

CREATE TABLE acorn_queries (
  id int PRIMARY KEY,
  embedding vector(${DIM}),
  cat_low int NOT NULL,
  cat_med int NOT NULL,
  cat_high int NOT NULL,
  score int NOT NULL,
  score_lo int NOT NULL,
  score_hi int NOT NULL
);

INSERT INTO acorn_items (embedding, cat_low, cat_med, cat_high, score)
SELECT ARRAY[${ARRAY_SQL}],
       i % ${LOW_CARD},
       i % ${MED_CARD},
       i % ${HIGH_CARD},
       i % ${SCORE_CARD}
FROM generate_series(1, ${ROWS}) i;

WITH q AS (
  SELECT i,
         ARRAY[${ARRAY_SQL}]::vector(${DIM}) AS embedding,
         floor(random() * ${LOW_CARD})::int AS cat_low,
         floor(random() * ${MED_CARD})::int AS cat_med,
         floor(random() * ${HIGH_CARD})::int AS cat_high,
         floor(random() * ${SCORE_CARD})::int AS score
  FROM generate_series(1, ${QUERY_COUNT}) i
)
INSERT INTO acorn_queries (id, embedding, cat_low, cat_med, cat_high, score, score_lo, score_hi)
SELECT i,
       embedding,
       cat_low,
       cat_med,
       cat_high,
       score,
       GREATEST(score - ${SCORE_BAND}, 0),
       LEAST(score + ${SCORE_BAND}, ${SCORE_CARD} - 1)
FROM q;

SET maintenance_work_mem = '${MAINTENANCE_WORK_MEM}';
CREATE INDEX acorn_hnsw_idx ON acorn_items USING hnsw (embedding vector_l2_ops) INCLUDE (cat_low, cat_med, cat_high, score);

ANALYZE acorn_items;
ANALYZE acorn_queries;

CREATE OR REPLACE FUNCTION acorn_bench_acorn_search(
  q_embedding vector,
  scenario text,
  q_cat_low int,
  q_cat_med int,
  q_cat_high int,
  q_score_lo int,
  q_score_hi int,
  k int
) RETURNS TABLE(item_id bigint)
LANGUAGE plpgsql
AS \$\$
BEGIN
  IF scenario = 'low' THEN
    PERFORM hnsw_set_filter('acorn_hnsw_idx', 'cat_low', '=', q_cat_low::text);
  ELSIF scenario = 'medium' THEN
    PERFORM hnsw_set_filter('acorn_hnsw_idx', 'cat_med', '=', q_cat_med::text);
  ELSIF scenario = 'high' THEN
    PERFORM hnsw_set_filter('acorn_hnsw_idx', 'cat_high', '=', q_cat_high::text);
  ELSIF scenario = 'range' THEN
    PERFORM hnsw_set_filter('acorn_hnsw_idx', 'score', '>=', q_score_lo::text);
    PERFORM hnsw_set_filter('acorn_hnsw_idx', 'score', '<=', q_score_hi::text);
  ELSE
    RAISE EXCEPTION 'unknown scenario: %', scenario;
  END IF;

  RETURN QUERY
    SELECT id
    FROM acorn_items
    ORDER BY embedding <-> q_embedding
    LIMIT k;

  PERFORM hnsw_clear_filter('acorn_hnsw_idx');
END;
\$\$;
SQL

echo "run_id,mode,method,scenario,ef_search,clients,duration_s,repeat,transactions,tps,latency_avg_ms,latency_log_avg_ms,p50_ms,p95_ms,p99_ms" > "$METRICS_CSV"
echo "run_id,mode,method,scenario,ef_search,recall_at_k,avg_exact_candidates,queries" > "$RECALL_CSV"

{
  echo "run_id=${RUN_ID}"
  echo "mode=${MODE}"
  echo "rows=${ROWS}"
  echo "dim=${DIM}"
  echo "query_count=${QUERY_COUNT}"
  echo "recall_queries=${RECALL_QUERIES}"
  echo "duration=${DURATION}"
  echo "repeats=${REPEATS}"
  echo "k=${K}"
  echo "efs=${EF_LIST}"
  echo "clients=${CLIENT_LIST}"
  echo "scenarios=${SCENARIO_LIST}"
  echo "methods=${METHOD_LIST}"
  echo "socket_dir=${SOCKET_DIR}"
  echo "port=${PORT}"
  echo "git_head=$(git rev-parse --short HEAD 2>/dev/null || echo unknown)"
  echo "postgres_version=$(${PSQL_BIN} --version)"
  echo "pgbench_version=$(${PGBENCH_BIN} --version)"
  echo "timestamp_utc=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
} > "$ENV_TXT"

for method in "${METHODS[@]}"; do
  for scenario in "${SCENARIOS[@]}"; do
    write_workload_script "$method" "$scenario" "${WORKLOAD_DIR}/${method}_${scenario}.sql"
  done
done

echo "Running recall matrix"
for method in "${METHODS[@]}"; do
  for scenario in "${SCENARIOS[@]}"; do
    for ef in "${EF_VALUES[@]}"; do
      echo "  recall method=${method} scenario=${scenario} ef=${ef}"
      run_recall_case "$method" "$scenario" "$ef"
    done
  done
done

echo "Running pgbench matrix"
for ((repeat = 1; repeat <= REPEATS; repeat++)); do
  for method in "${METHODS[@]}"; do
    for scenario in "${SCENARIOS[@]}"; do
      for ef in "${EF_VALUES[@]}"; do
        for clients in "${CLIENTS[@]}"; do
          echo "  pgbench repeat=${repeat} method=${method} scenario=${scenario} ef=${ef} clients=${clients}"
          run_pgbench_case "$method" "$scenario" "$ef" "$clients" "$repeat"
        done
      done
    done
  done
done

write_summary

echo
echo "Benchmark complete"
echo "- Summary: ${SUMMARY_MD}"
echo "- Metrics: ${METRICS_CSV}"
echo "- Recall: ${RECALL_CSV}"
echo "- Run dir: ${RUN_DIR}"
