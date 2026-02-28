#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../../.." && pwd)"

usage() {
  cat <<'EOF'
Usage:
  skills/pgvector-hnsw-acorn-bench/scripts/run-e2e-bench.sh [options]

Options:
  --rows N                  Number of synthetic items to generate (default: 50000)
  --dim N                   Vector dimensions (default: 128)
  --query-count N           Query pool size for pgbench (default: 2000)
  --recall-queries N        Query count for recall@k evaluation (default: 100)
  --skew-alpha N            Zipfian skew factor (1.0 = uniformish, 2.0 = highly skewed) (default: 1.5)
  --m N                     HNSW max connections (default: 16)
  --aux-m N                 ACORN max aux connections (default: 16)
  --ef-construction N       HNSW ef_construction (default: 64)
  --ef-search N             HNSW ef_search (default: 40)
  --k N                     Top-K value (default: 20)
  --churn-duration N        Seconds to run the mixed R/W workload (default: 15)
  --read-duration N         Seconds to run read-only baseline benchmarks (default: 10)
  --clients N               Concurrency for pgbench tests (default: 8)
  --port N                  Isolated PostgreSQL port (default: 6546)
  --skip-build              Skip make/make install (default: false)
  --keep-data               Keep the Postgres data directory after run (default: false)
  -h, --help                Show this help
EOF
}

# Defaults
ROWS=50000
DIM=128
QUERY_COUNT=2000
RECALL_QUERIES=100
SKEW_ALPHA=1.5
M_PARAM=16
AUX_M_PARAM=16
EF_CONSTRUCTION=64
EF_SEARCH=40
K=20
CHURN_DURATION=15
READ_DURATION=10
CLIENTS=8
PORT=6546
SKIP_BUILD=0
KEEP_DATA=0

# Parse args
while [ "$#" -gt 0 ]; do
  case "$1" in
    --rows) ROWS="$2"; shift 2 ;;
    --dim) DIM="$2"; shift 2 ;;
    --query-count) QUERY_COUNT="$2"; shift 2 ;;
    --recall-queries) RECALL_QUERIES="$2"; shift 2 ;;
    --skew-alpha) SKEW_ALPHA="$2"; shift 2 ;;
    --m) M_PARAM="$2"; shift 2 ;;
    --aux-m) AUX_M_PARAM="$2"; shift 2 ;;
    --ef-construction) EF_CONSTRUCTION="$2"; shift 2 ;;
    --ef-search) EF_SEARCH="$2"; shift 2 ;;
    --k) K="$2"; shift 2 ;;
    --churn-duration) CHURN_DURATION="$2"; shift 2 ;;
    --read-duration) READ_DURATION="$2"; shift 2 ;;
    --clients) CLIENTS="$2"; shift 2 ;;
    --port) PORT="$2"; shift 2 ;;
    --skip-build) SKIP_BUILD=1; shift ;;
    --keep-data) KEEP_DATA=1; shift ;;
    --help|-h) usage; exit 0 ;;
    *) echo "Unknown option: $1" >&2; usage; exit 1 ;;
  esac
done

# Ensure RECALL_QUERIES <= QUERY_COUNT
if [ "$RECALL_QUERIES" -gt "$QUERY_COUNT" ]; then
  RECALL_QUERIES="$QUERY_COUNT"
fi

# Directory setup
WORK_DIR="${REPO_ROOT}/tmp_check/pgvector-e2e-bench"
DATA_DIR="${WORK_DIR}/data"
SOCKET_DIR="${WORK_DIR}/run"
LOG_DIR="${WORK_DIR}/log"
RUNS_DIR="${WORK_DIR}/runs"
RUN_ID="$(date +%Y%m%d-%H%M%S)"
RUN_DIR="${RUNS_DIR}/${RUN_ID}"
WORKLOAD_DIR="${RUN_DIR}/workloads"
PGBENCH_LOG_DIR="${RUN_DIR}/pgbench-logs"

mkdir -p "$RUN_DIR" "$WORKLOAD_DIR" "$PGBENCH_LOG_DIR" "$LOG_DIR" "$SOCKET_DIR"

# Requirements Check
for cmd in make pg_config perl python3; do
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

PGUSER_NAME="${USER}"
DB_NAME="acorn_e2e_bench"

psql_cmd() {
  PGHOST="$SOCKET_DIR" PGPORT="$PORT" PGUSER="$PGUSER_NAME" "$PSQL_BIN" -X -v ON_ERROR_STOP=1 -h "$SOCKET_DIR" -p "$PORT" -U "$PGUSER_NAME" "$DB_NAME" "$@"
}

psql_cmd_quiet() {
  PGHOST="$SOCKET_DIR" PGPORT="$PORT" PGUSER="$PGUSER_NAME" "$PSQL_BIN" -X -q -At -v ON_ERROR_STOP=1 -h "$SOCKET_DIR" -p "$PORT" -U "$PGUSER_NAME" "$DB_NAME" "$@"
}

echo "========================================================"
echo "    pgvector HNSW ACORN End-to-End Test Suite v2"
echo "========================================================"
echo "Run ID: ${RUN_ID}"
echo "--------------------------------------------------------"

# Clean up any lingering data if not kept
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

# Postgres config
cat > "${DATA_DIR}/bench.conf" <<EOF
port = ${PORT}
listen_addresses = ''
unix_socket_directories = '${SOCKET_DIR}'
jit = off
synchronous_commit = off
wal_level = minimal
max_wal_senders = 0
shared_buffers = '256MB'
maintenance_work_mem = '1GB'
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
  echo "--> Compiling pgvector..."
  make -j4 >/dev/null
  make install >/dev/null
fi

echo "--> Initializing Database..."
PGHOST="$SOCKET_DIR" PGPORT="$PORT" PGUSER="$PGUSER_NAME" "$DROPDB_BIN" --if-exists "$DB_NAME" >/dev/null 2>&1 || true
PGHOST="$SOCKET_DIR" PGPORT="$PORT" PGUSER="$PGUSER_NAME" "$CREATEDB_BIN" "$DB_NAME"

psql_cmd -c "CREATE EXTENSION IF NOT EXISTS vector;" >/dev/null

psql_cmd <<SQL >/dev/null
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
SQL

echo "--> Generating Zipfian dataset (Rows: $ROWS, Skew: $SKEW_ALPHA)..."
ITEMS_CSV="${RUN_DIR}/items.csv"
QUERIES_CSV="${RUN_DIR}/queries.csv"

python3 "${SCRIPT_DIR}/generate_dataset.py" \
  --rows "$ROWS" \
  --queries "$QUERY_COUNT" \
  --dim "$DIM" \
  --skew-alpha "$SKEW_ALPHA" \
  --items-out "$ITEMS_CSV" \
  --queries-out "$QUERIES_CSV" >/dev/null

echo "--> Loading data..."
psql_cmd -c "\copy acorn_items FROM '$ITEMS_CSV' CSV" >/dev/null
psql_cmd -c "\copy acorn_queries FROM '$QUERIES_CSV' CSV" >/dev/null
psql_cmd -c "SELECT setval('acorn_items_id_seq', (SELECT MAX(id) FROM acorn_items));" >/dev/null

rm -f "$ITEMS_CSV" "$QUERIES_CSV"

ACORN_SUPPORTED=$(psql_cmd_quiet -c "SELECT COALESCE(pg_indexam_has_property(oid, 'can_multi_col'), false) FROM pg_am WHERE amname = 'hnsw'")

INDEX_KEYS=""
WITH_CLAUSE="WITH (m=${M_PARAM}, ef_construction=${EF_CONSTRUCTION})"
if [ "$ACORN_SUPPORTED" = "t" ]; then
  INDEX_KEYS=", cat_low vector_integer_ops, cat_med vector_integer_ops, cat_high vector_integer_ops, score vector_integer_ops"
  WITH_CLAUSE="WITH (m=${M_PARAM}, aux_m=${AUX_M_PARAM}, ef_construction=${EF_CONSTRUCTION})"
fi

echo "--> Building HNSW Index (${WITH_CLAUSE})..."
START_TIME=$(date +%s)
psql_cmd -c "CREATE INDEX acorn_hnsw_idx ON acorn_items USING hnsw (embedding vector_l2_ops${INDEX_KEYS}) ${WITH_CLAUSE};" >/dev/null
END_TIME=$(date +%s)
BUILD_TIME=$((END_TIME - START_TIME))

psql_cmd -c "ANALYZE acorn_items;" >/dev/null
psql_cmd -c "ANALYZE acorn_queries;" >/dev/null

INDEX_SIZE_BYTES=$(psql_cmd_quiet -c "SELECT pg_relation_size('acorn_hnsw_idx')")
INDEX_SIZE_MB=$(awk "BEGIN {printf \"%.2f\", $INDEX_SIZE_BYTES / 1024 / 1024}")
echo "    Build Time: ${BUILD_TIME}s"
echo "    Initial Index Size: ${INDEX_SIZE_MB} MB"

# Prepare Recall Script
run_recall() {
  local phase="$1"
  local scenario="cat_med"
  local where_clause="i.cat_med = q.cat_med"
  
  local exact_select="SELECT q.id AS qid, r.id AS item_id FROM acorn_queries q CROSS JOIN LATERAL (SELECT i.id FROM acorn_items i WHERE ${where_clause} ORDER BY i.embedding <-> q.embedding LIMIT ${K}) r WHERE q.id <= ${RECALL_QUERIES}"
  local actual_select="SELECT q.id AS qid, r.id AS item_id FROM acorn_queries q CROSS JOIN LATERAL (SELECT i.id FROM acorn_items i WHERE ${where_clause} ORDER BY i.embedding <-> q.embedding LIMIT ${K}) r WHERE q.id <= ${RECALL_QUERIES}"

  local sql="
SET jit = off;
SET hnsw.ef_search = ${EF_SEARCH};
SET enable_seqscan = off;
CREATE TEMP TABLE actual_results AS ${actual_select};
SET enable_indexscan = off;
SET enable_bitmapscan = off;
SET enable_seqscan = on;
CREATE TEMP TABLE exact_results AS ${exact_select};
WITH exact_counts AS (
  SELECT qid, count(*) AS exact_count FROM exact_results GROUP BY qid
),
match_counts AS (
  SELECT e.qid, count(*) AS match_count FROM exact_results e JOIN actual_results a USING (qid, item_id) GROUP BY e.qid
),
per_query AS (
  SELECT ec.qid, CASE WHEN ec.exact_count = 0 THEN 1.0 ELSE COALESCE(mc.match_count, 0)::float8 / ec.exact_count END AS recall FROM exact_counts ec LEFT JOIN match_counts mc USING (qid)
)
SELECT COALESCE(round(avg(recall)::numeric, 6), 1.0) FROM per_query;"

  local recall=$(psql_cmd_quiet -c "$sql")
  echo "$recall"
}

echo "--> Measuring Initial Recall..."
INITIAL_RECALL=$(run_recall "initial")
echo "    Initial Recall@${K}: ${INITIAL_RECALL}"

# Create pgbench scripts
cat > "${WORKLOAD_DIR}/read.sql" <<EOF
\set qid random(1, :query_count)
BEGIN;
SET LOCAL enable_seqscan = off;
SET LOCAL hnsw.ef_search = :ef_search;
WITH q AS (SELECT embedding, cat_med FROM acorn_queries WHERE id = :qid)
SELECT id FROM q, LATERAL (SELECT id FROM acorn_items i WHERE i.cat_med = q.cat_med ORDER BY i.embedding <-> q.embedding LIMIT :k) nn;
COMMIT;
EOF

cat > "${WORKLOAD_DIR}/write.sql" <<EOF
\set cat_med random_zipfian(1, 50, 1.5)
\set cat_low random_zipfian(1, 5, 1.5)
\set cat_high random_zipfian(1, 500, 1.5)
\set score random_zipfian(1, 1000, 1.5)
INSERT INTO acorn_items (embedding, cat_low, cat_med, cat_high, score) 
SELECT (array(select random() from generate_series(1, ${DIM})))::vector, :cat_low, :cat_med, :cat_high, :score;
EOF

cat > "${WORKLOAD_DIR}/delete.sql" <<EOF
\set item_id random(1, :rows)
DELETE FROM acorn_items WHERE id = :item_id;
EOF

cat > "${WORKLOAD_DIR}/update.sql" <<EOF
\set item_id random(1, :rows)
\set score random_zipfian(1, 1000, 1.5)
UPDATE acorn_items SET score = :score WHERE id = :item_id;
EOF

run_pgbench() {
  local script="$1"
  local duration="$2"
  local tag="$3"
  local out_file="${PGBENCH_LOG_DIR}/${tag}.out"
  
  PGHOST="$SOCKET_DIR" PGPORT="$PORT" PGUSER="$PGUSER_NAME" "$PGBENCH_BIN" -n -M simple -c "$CLIENTS" -j "$CLIENTS" -T "$duration" -D query_count="$QUERY_COUNT" -D ef_search="$EF_SEARCH" -D k="$K" -D rows="$ROWS" -f "$script" "$DB_NAME" > "$out_file" 2>&1 || true
  
  local tps=$(awk '/^tps =/ {print $3; exit}' "$out_file" || echo "N/A")
  if [ -z "$tps" ]; then tps="N/A"; fi
  echo "$tps"
}

echo "--> Measuring Initial Read TPS..."
INITIAL_TPS=$(run_pgbench "${WORKLOAD_DIR}/read.sql" "$READ_DURATION" "initial_read")
echo "    Initial Read TPS: ${INITIAL_TPS}"

echo "--> Running Mixed Workload Churn (Duration: ${CHURN_DURATION}s)..."

psql_cmd -c "CREATE TABLE IF NOT EXISTS wait_events_log (ts timestamp, wait_event_type text, wait_event text);" >/dev/null

START_LSN=$(psql_cmd_quiet -c "SELECT pg_current_wal_lsn();")

# Start lock monitor
while true; do
  PGHOST="$SOCKET_DIR" PGPORT="$PORT" PGUSER="$PGUSER_NAME" "$PSQL_BIN" -X -q -At -h "$SOCKET_DIR" -p "$PORT" -U "$PGUSER_NAME" "$DB_NAME" -c "INSERT INTO wait_events_log SELECT now(), wait_event_type, wait_event FROM pg_stat_activity WHERE wait_event_type IN ('LWLock', 'Lock', 'BufferPin') AND wait_event IS NOT NULL AND pid <> pg_backend_pid();" >/dev/null 2>&1 || true
  sleep 0.1
done &
MONITOR_PID=$!

CHURN_OUT="${PGBENCH_LOG_DIR}/churn.out"
PGHOST="$SOCKET_DIR" PGPORT="$PORT" PGUSER="$PGUSER_NAME" "$PGBENCH_BIN" -n -M simple -c "$CLIENTS" -j "$CLIENTS" -T "$CHURN_DURATION" -D query_count="$QUERY_COUNT" -D ef_search="$EF_SEARCH" -D k="$K" -D rows="$ROWS" \
  -f "${WORKLOAD_DIR}/read.sql@70" \
  -f "${WORKLOAD_DIR}/write.sql@20" \
  -f "${WORKLOAD_DIR}/update.sql@5" \
  -f "${WORKLOAD_DIR}/delete.sql@5" \
  "$DB_NAME" > "$CHURN_OUT" 2>&1 || true

kill $MONITOR_PID 2>/dev/null || true
wait $MONITOR_PID 2>/dev/null || true

END_LSN=$(psql_cmd_quiet -c "SELECT pg_current_wal_lsn();" || echo "")
if [ -n "$END_LSN" ]; then
  WAL_BYTES=$(psql_cmd_quiet -c "SELECT pg_wal_lsn_diff('${END_LSN}', '${START_LSN}');" || echo "0")
else
  WAL_BYTES=0
fi
if [ -z "$WAL_BYTES" ]; then WAL_BYTES=0; fi
WAL_MB=$(awk "BEGIN {printf \"%.2f\", $WAL_BYTES / 1024 / 1024}")

CHURN_TPS=$(awk '/^tps =/ {print $3; exit}' "$CHURN_OUT" || echo "")
if [ -z "$CHURN_TPS" ]; then CHURN_TPS="N/A"; fi
CHURN_TX=$(awk -F': ' '/number of transactions actually processed/ {split($2, a, "/"); gsub(/[[:space:]]/, "", a[1]); print a[1]; exit}' "$CHURN_OUT" || echo "")
if [ -z "$CHURN_TX" ]; then CHURN_TX="0"; fi

echo "    Churn TPS: ${CHURN_TPS}"
echo "    Total Transactions: ${CHURN_TX}"
echo "    WAL Generated: ${WAL_MB} MB"

echo "--> Evaluating Lock Contention..."
TOTAL_LOCK_EVENTS=$(psql_cmd_quiet -c "SELECT count(*) FROM wait_events_log;")
echo "    Total Wait Events Sampled: ${TOTAL_LOCK_EVENTS}"
if [ "$TOTAL_LOCK_EVENTS" -gt 0 ]; then
  psql_cmd -c "SELECT wait_event, count(*) as count FROM wait_events_log GROUP BY wait_event ORDER BY count DESC LIMIT 5;" | sed 's/^/    /'
fi

INDEX_SIZE_BYTES_PRE_VACUUM=$(psql_cmd_quiet -c "SELECT pg_relation_size('acorn_hnsw_idx')")
INDEX_SIZE_MB_PRE_VACUUM=$(awk "BEGIN {printf \"%.2f\", $INDEX_SIZE_BYTES_PRE_VACUUM / 1024 / 1024}")
echo "--> Pre-Vacuum Index Size: ${INDEX_SIZE_MB_PRE_VACUUM} MB"

echo "--> Running VACUUM ANALYZE..."
START_TIME=$(date +%s)
psql_cmd -c "VACUUM ANALYZE acorn_items;" >/dev/null || VAC_FAILED=1
END_TIME=$(date +%s)

if [ "${VAC_FAILED:-0}" -eq 1 ]; then
  echo "    [!] Database crashed or vacuum failed!"
  VAC_TIME="CRASHED"
  INDEX_SIZE_MB_POST_VACUUM="N/A"
  FINAL_RECALL="N/A"
  FINAL_TPS="N/A"
else
  VAC_TIME=$((END_TIME - START_TIME))
  echo "    Vacuum Time: ${VAC_TIME}s"
  
  INDEX_SIZE_BYTES_POST_VACUUM=$(psql_cmd_quiet -c "SELECT pg_relation_size('acorn_hnsw_idx')")
  INDEX_SIZE_MB_POST_VACUUM=$(awk "BEGIN {printf \"%.2f\", $INDEX_SIZE_BYTES_POST_VACUUM / 1024 / 1024}")
  echo "    Post-Vacuum Index Size: ${INDEX_SIZE_MB_POST_VACUUM} MB"

  echo "--> Measuring Final Recall and TPS..."
  FINAL_RECALL=$(run_recall "final")
  echo "    Final Recall@${K}: ${FINAL_RECALL}"

  FINAL_TPS=$(run_pgbench "${WORKLOAD_DIR}/read.sql" "$READ_DURATION" "final_read")
  echo "    Final Read TPS: ${FINAL_TPS}"
fi

echo "--> Generating Reports..."
CSV_REPORT="${RUN_DIR}/report.csv"
MD_REPORT="${RUN_DIR}/summary.md"

echo "run_id,rows,dim,skew,m,aux_m,ef_cons,clients,build_time_s,idx_initial_mb,initial_tps,initial_recall,churn_tps,wal_mb,idx_prevac_mb,vac_time_s,idx_postvac_mb,final_tps,final_recall" > "$CSV_REPORT"
echo "${RUN_ID},${ROWS},${DIM},${SKEW_ALPHA},${M_PARAM},${AUX_M_PARAM},${EF_CONSTRUCTION},${CLIENTS},${BUILD_TIME},${INDEX_SIZE_MB},${INITIAL_TPS},${INITIAL_RECALL},${CHURN_TPS},${WAL_MB},${INDEX_SIZE_MB_PRE_VACUUM},${VAC_TIME},${INDEX_SIZE_MB_POST_VACUUM},${FINAL_TPS},${FINAL_RECALL}" >> "$CSV_REPORT"

cat > "$MD_REPORT" <<EOF
# pgvector HNSW ACORN End-to-End Test Suite v2 - Report
**Run ID:** ${RUN_ID}
**Date:** $(date)

## Configuration
- **Dataset:** ${ROWS} rows, ${DIM} dimensions, Zipfian Skew Alpha: ${SKEW_ALPHA}
- **Index Params:** m=${M_PARAM}, aux_m=${AUX_M_PARAM}, ef_construction=${EF_CONSTRUCTION}
- **Workload Params:** clients=${CLIENTS}, ef_search=${EF_SEARCH}, k=${K}

## Build Phase
- **Index Build Time:** ${BUILD_TIME} seconds
- **Initial Index Size:** ${INDEX_SIZE_MB} MB

## Baseline Phase
- **Initial Read TPS:** ${INITIAL_TPS}
- **Initial Recall@${K}:** ${INITIAL_RECALL}

## Churn Phase (Mixed R/W)
- **Duration:** ${CHURN_DURATION} seconds
- **Throughput:** ${CHURN_TPS} TPS (${CHURN_TX} total transactions)
- **WAL Generated:** ${WAL_MB} MB
- **Lock Wait Events Sampled:** ${TOTAL_LOCK_EVENTS}

## Vacuum & Bloat Phase
- **Pre-Vacuum Size:** ${INDEX_SIZE_MB_PRE_VACUUM} MB
- **Vacuum Time:** ${VAC_TIME} seconds
- **Post-Vacuum Size:** ${INDEX_SIZE_MB_POST_VACUUM} MB

## Final Verification Phase
- **Final Read TPS:** ${FINAL_TPS}
- **Final Recall@${K}:** ${FINAL_RECALL}

EOF

echo "========================================================"
echo "    Test Complete."
echo "    Summary output saved to: ${MD_REPORT}"
echo "    CSV output saved to: ${CSV_REPORT}"
echo "========================================================"
