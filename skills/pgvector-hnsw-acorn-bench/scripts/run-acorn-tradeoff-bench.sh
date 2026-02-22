#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../../.." && pwd)"

usage() {
  cat <<'EOF'
Usage:
  skills/pgvector-hnsw-acorn-bench/scripts/run-acorn-tradeoff-bench.sh [options]

Options:
  --mode quick|full            Benchmark mode (default: quick)
  --rows N                     Number of synthetic item rows
  --dim N                      Vector dimensions
  --query-count N              Query pool size for pgbench
  --recall-queries N           Query count for recall@k evaluation
  --io-probe-queries N         Query count for EXPLAIN BUFFERS probe
  --duration N                 pgbench duration in seconds per run
  --repeats N                  Repeats per matrix point
  --k N                        Top-k value
  --efs A,B,C                  ef_search values (comma separated)
  --clients A,B,C              Client counts (comma separated)
  --scenarios A,B,C            Scenarios: low,medium,high,range
  --methods A,B                Methods: acorn,post (where aliases acorn)
  --acorn-gamma N              HNSW acorn_gamma index option (default: 1)
  --acorn-m-beta N             HNSW acorn_m_beta index option (default: 0)
  --seed FLOAT                 setseed() value for deterministic synthetic data
  --port N                     Isolated PostgreSQL port
  --shared-buffers VALUE       PostgreSQL shared_buffers value (default: 64MB)
  --skip-build                 Skip make/make install
  --keep-data                  Keep benchmark data directory
  -h, --help                   Show this help

Environment overrides:
  PGVECTOR_BENCH_MODE
  PGVECTOR_BENCH_PORT
  PGVECTOR_BENCH_USER
  PGVECTOR_BENCH_SKIP_BUILD
  PGVECTOR_BENCH_KEEP_DATA
  PGVECTOR_BENCH_SHARED_BUFFERS
  PGVECTOR_BENCH_ACORN_GAMMA
  PGVECTOR_BENCH_ACORN_M_BETA
  PGVECTOR_BENCH_SEED
EOF
}

set_mode_defaults() {
  local mode="$1"

  case "$mode" in
    quick)
      ROWS=120000
      DIM=96
      QUERY_COUNT=3000
      RECALL_QUERIES=150
      IO_PROBE_QUERIES=12
      DURATION=8
      REPEATS=1
      K=20
      EF_LIST="40,80,160"
      CLIENT_LIST="1,8"
      SCENARIO_LIST="low,medium,high,range"
      METHOD_LIST="acorn,post"
      ;;
    full)
      ROWS=400000
      DIM=128
      QUERY_COUNT=12000
      RECALL_QUERIES=400
      IO_PROBE_QUERIES=40
      DURATION=20
      REPEATS=2
      K=20
      EF_LIST="40,80,160"
      CLIENT_LIST="1,8,32"
      SCENARIO_LIST="low,medium,high,range"
      METHOD_LIST="acorn,post"
      ;;
    *)
      echo "Unknown mode: $mode" >&2
      exit 1
      ;;
  esac
}

scenario_where_clause() {
  local scenario="$1"
  local item_alias="${2:-i}"
  local query_alias="${3:-q}"

  case "$scenario" in
    low)
      echo "${item_alias}.cat_low = ${query_alias}.cat_low"
      ;;
    medium)
      echo "${item_alias}.cat_med = ${query_alias}.cat_med"
      ;;
    high)
      echo "${item_alias}.cat_high = ${query_alias}.cat_high"
      ;;
    range)
      echo "${item_alias}.score BETWEEN ${query_alias}.score_lo AND ${query_alias}.score_hi"
      ;;
    *)
      echo "Invalid scenario: $scenario" >&2
      exit 1
      ;;
  esac
}

post_multiplier() {
  local scenario="$1"

  case "$scenario" in
    low)
      echo 10
      ;;
    medium)
      echo 80
      ;;
    high)
      echo 800
      ;;
    range)
      echo 80
      ;;
    *)
      echo "Invalid scenario: $scenario" >&2
      exit 1
      ;;
  esac
}

post_limit_for_scenario() {
  local scenario="$1"
  local multiplier
  local limit

  multiplier="$(post_multiplier "$scenario")"
  limit=$((K * multiplier))

  if [ "$limit" -gt "$ROWS" ]; then
    limit="$ROWS"
  fi

  echo "$limit"
}

now_epoch() {
  perl -MTime::HiRes=time -e 'printf "%.6f\n", time'
}

elapsed_secs() {
  perl -e 'printf "%.6f\n", $ARGV[1] - $ARGV[0]' "$1" "$2"
}

avg_or_nan() {
  local sum="$1"
  local count="$2"

  if [ "$count" -eq 0 ]; then
    echo "nan"
    return
  fi

  perl -e 'printf "%.6f\n", $ARGV[0] / $ARGV[1]' "$sum" "$count"
}

write_workload_script() {
  local method="$1"
  local scenario="$2"
  local out_path="$3"
  local acorn_pred
  local post_pred

  acorn_pred="$(scenario_where_clause "$scenario" "i" "q")"
  post_pred="$(scenario_where_clause "$scenario" "ann" "q")"

  if [ "$method" = "acorn" ]; then
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
  SELECT i.id
  FROM acorn_items i
  WHERE ${acorn_pred}
  ORDER BY i.embedding <-> q.embedding
  LIMIT :k
) nn;
COMMIT;
EOF
    return
  fi

  if [ "$method" = "post" ]; then
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
SELECT ann.id
FROM q, LATERAL (
  SELECT i.id, i.embedding, i.cat_low, i.cat_med, i.cat_high, i.score
  FROM acorn_items i
  ORDER BY i.embedding <-> q.embedding
  LIMIT :post_limit
) ann
WHERE ${post_pred}
ORDER BY ann.embedding <-> q.embedding
LIMIT :k;
COMMIT;
EOF
    return
  fi

  echo "Invalid method: $method" >&2
  exit 1
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

record_index_metrics() {
  local variant="$1"
  local index_name="$2"
  local build_seconds="$3"
  local size_row
  local index_bytes
  local index_pretty

  size_row="$(PGHOST="$SOCKET_DIR" PGPORT="$PORT" PGUSER="$PGUSER_NAME" "$PSQL_BIN" -X -q -At -F ',' -v ON_ERROR_STOP=1 -h "$SOCKET_DIR" -p "$PORT" -U "$PGUSER_NAME" "$DB_NAME" -c "SELECT pg_relation_size('${index_name}')::bigint, pg_size_pretty(pg_relation_size('${index_name}'))")"

  IFS=',' read -r index_bytes index_pretty <<< "$size_row"

  echo "${RUN_ID},${MODE},${variant},${build_seconds},${index_bytes},${index_pretty},${TABLE_BYTES},${TABLE_PRETTY}" >> "$INDEX_BUILD_CSV"
}

run_recall_case() {
  local method="$1"
  local scenario="$2"
  local ef="$3"
  local acorn_pred
  local post_pred
  local post_limit
  local exact_select
  local actual_select
  local sql
  local row
  local recall
  local avg_exact
  local query_rows

  acorn_pred="$(scenario_where_clause "$scenario" "i" "q")"
  post_pred="$(scenario_where_clause "$scenario" "ann" "q")"
  post_limit="$(post_limit_for_scenario "$scenario")"

  exact_select="SELECT q.id AS qid, r.id AS item_id FROM acorn_queries q CROSS JOIN LATERAL (SELECT i.id FROM acorn_items i WHERE ${acorn_pred} ORDER BY i.embedding <-> q.embedding LIMIT ${K}) r WHERE q.id <= ${RECALL_QUERIES}"

  if [ "$method" = "acorn" ]; then
    actual_select="SELECT q.id AS qid, r.id AS item_id FROM acorn_queries q CROSS JOIN LATERAL (SELECT i.id FROM acorn_items i WHERE ${acorn_pred} ORDER BY i.embedding <-> q.embedding LIMIT ${K}) r WHERE q.id <= ${RECALL_QUERIES}"
  else
    actual_select="SELECT q.id AS qid, r.id AS item_id FROM acorn_queries q CROSS JOIN LATERAL (SELECT ann.id FROM (SELECT i.id, i.embedding, i.cat_low, i.cat_med, i.cat_high, i.score FROM acorn_items i ORDER BY i.embedding <-> q.embedding LIMIT ${post_limit}) ann WHERE ${post_pred} ORDER BY ann.embedding <-> q.embedding LIMIT ${K}) r WHERE q.id <= ${RECALL_QUERIES}"
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
  local post_limit
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

  post_limit="$(post_limit_for_scenario "$scenario")"
  tag="${method}_${scenario}_ef${ef}_c${clients}_r${repeat}"
  out_file="${RUN_DIR}/${tag}.out"
  script_path="${WORKLOAD_DIR}/${method}_${scenario}.sql"

  rm -f "${PGBENCH_LOG_DIR}/${tag}_"*

  (
    cd "$PGBENCH_LOG_DIR"
    PGHOST="$SOCKET_DIR" PGPORT="$PORT" PGUSER="$PGUSER_NAME" \
      "$PGBENCH_BIN" -n -M simple -r -l --log-prefix="${tag}_" \
      -c "$clients" -j "$clients" -T "$DURATION" \
      -D query_count="$QUERY_COUNT" -D ef_search="$ef" -D k="$K" -D post_limit="$post_limit" \
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

io_build_expr() {
  local method="$1"
  local scenario="$2"
  local post_limit="$3"

  if [ "$method" = "acorn" ]; then
    case "$scenario" in
      low)
        echo "format('SELECT i.id FROM acorn_items i WHERE i.cat_low = %s ORDER BY i.embedding <-> %L::vector LIMIT %s', q.cat_low, q.embedding::text, ${K})"
        ;;
      medium)
        echo "format('SELECT i.id FROM acorn_items i WHERE i.cat_med = %s ORDER BY i.embedding <-> %L::vector LIMIT %s', q.cat_med, q.embedding::text, ${K})"
        ;;
      high)
        echo "format('SELECT i.id FROM acorn_items i WHERE i.cat_high = %s ORDER BY i.embedding <-> %L::vector LIMIT %s', q.cat_high, q.embedding::text, ${K})"
        ;;
      range)
        echo "format('SELECT i.id FROM acorn_items i WHERE i.score BETWEEN %s AND %s ORDER BY i.embedding <-> %L::vector LIMIT %s', q.score_lo, q.score_hi, q.embedding::text, ${K})"
        ;;
      *)
        echo "Invalid scenario: $scenario" >&2
        exit 1
        ;;
    esac

    return
  fi

  if [ "$method" = "post" ]; then
    case "$scenario" in
      low)
        echo "format('SELECT ann.id FROM (SELECT i.id, i.embedding, i.cat_low, i.cat_med, i.cat_high, i.score FROM acorn_items i ORDER BY i.embedding <-> %L::vector LIMIT ${post_limit}) ann WHERE ann.cat_low = %s ORDER BY ann.embedding <-> %L::vector LIMIT %s', q.embedding::text, q.cat_low, q.embedding::text, ${K})"
        ;;
      medium)
        echo "format('SELECT ann.id FROM (SELECT i.id, i.embedding, i.cat_low, i.cat_med, i.cat_high, i.score FROM acorn_items i ORDER BY i.embedding <-> %L::vector LIMIT ${post_limit}) ann WHERE ann.cat_med = %s ORDER BY ann.embedding <-> %L::vector LIMIT %s', q.embedding::text, q.cat_med, q.embedding::text, ${K})"
        ;;
      high)
        echo "format('SELECT ann.id FROM (SELECT i.id, i.embedding, i.cat_low, i.cat_med, i.cat_high, i.score FROM acorn_items i ORDER BY i.embedding <-> %L::vector LIMIT ${post_limit}) ann WHERE ann.cat_high = %s ORDER BY ann.embedding <-> %L::vector LIMIT %s', q.embedding::text, q.cat_high, q.embedding::text, ${K})"
        ;;
      range)
        echo "format('SELECT ann.id FROM (SELECT i.id, i.embedding, i.cat_low, i.cat_med, i.cat_high, i.score FROM acorn_items i ORDER BY i.embedding <-> %L::vector LIMIT ${post_limit}) ann WHERE ann.score BETWEEN %s AND %s ORDER BY ann.embedding <-> %L::vector LIMIT %s', q.embedding::text, q.score_lo, q.score_hi, q.embedding::text, ${K})"
        ;;
      *)
        echo "Invalid scenario: $scenario" >&2
        exit 1
        ;;
    esac

    return
  fi

  echo "Invalid method: $method" >&2
  exit 1
}

run_io_probe_case() {
  local method="$1"
  local scenario="$2"
  local ef="$3"
  local post_limit
  local sql_expr
  local samples
  local step
  local qid
  local row
  local exec_ms
  local hit_blocks
  local read_blocks
  local sum_exec=0
  local sum_hit=0
  local sum_read=0
  local max_read=0
  local count=0

  post_limit="$(post_limit_for_scenario "$scenario")"
  sql_expr="$(io_build_expr "$method" "$scenario" "$post_limit")"
  samples="$IO_PROBE_QUERIES"

  if [ "$samples" -gt "$QUERY_COUNT" ]; then
    samples="$QUERY_COUNT"
  fi

  if [ "$samples" -lt 1 ]; then
    echo "${RUN_ID},${MODE},${method},${scenario},${ef},0,nan,nan,nan,nan" >> "$IO_PROBE_CSV"
    return
  fi

  step=$(( QUERY_COUNT / samples ))
  if [ "$step" -lt 1 ]; then
    step=1
  fi

  for ((i = 1; i <= samples; i++)); do
    qid=$((1 + (i - 1) * step))

    if [ "$qid" -gt "$QUERY_COUNT" ]; then
      qid="$QUERY_COUNT"
    fi

    row="$(PGHOST="$SOCKET_DIR" PGPORT="$PORT" PGUSER="$PGUSER_NAME" "$PSQL_BIN" -X -q -At -F ',' -v ON_ERROR_STOP=1 -h "$SOCKET_DIR" -p "$PORT" -U "$PGUSER_NAME" "$DB_NAME" -c "SET jit = off; SET hnsw.ef_search = ${ef}; WITH q AS (SELECT embedding, cat_low, cat_med, cat_high, score_lo, score_hi FROM acorn_queries WHERE id = ${qid}), stmt AS (SELECT ${sql_expr} AS query_sql FROM q), plan AS (SELECT acorn_bench_explain_json(query_sql) AS p FROM stmt) SELECT COALESCE((p->0->>'Execution Time')::float8, 0), COALESCE((p->0->'Plan'->>'Shared Hit Blocks')::float8, 0), COALESCE((p->0->'Plan'->>'Shared Read Blocks')::float8, 0) FROM plan;" | awk -F',' '/^[0-9]+(\.[0-9]+)?,/ {print; exit}')"

    if [ -z "$row" ]; then
      continue
    fi

    IFS=',' read -r exec_ms hit_blocks read_blocks <<< "$row"

    sum_exec="$(awk "BEGIN {print ${sum_exec} + ${exec_ms}}")"
    sum_hit="$(awk "BEGIN {print ${sum_hit} + ${hit_blocks}}")"
    sum_read="$(awk "BEGIN {print ${sum_read} + ${read_blocks}}")"

    if awk "BEGIN {exit !(${read_blocks} > ${max_read})}"; then
      max_read="$read_blocks"
    fi

    count=$((count + 1))
  done

  echo "${RUN_ID},${MODE},${method},${scenario},${ef},${count},$(avg_or_nan "$sum_exec" "$count"),$(avg_or_nan "$sum_hit" "$count"),$(avg_or_nan "$sum_read" "$count"),${max_read}" >> "$IO_PROBE_CSV"
}

write_summary() {
  {
    echo "# ACORN Tradeoff Benchmark Summary"
    echo
    echo "- Run ID: ${RUN_ID}"
    echo "- Mode: ${MODE}"
    echo "- Rows: ${ROWS}"
    echo "- Dimensions: ${DIM}"
    echo "- Query count: ${QUERY_COUNT}"
    echo "- Recall queries: ${RECALL_QUERIES}"
    echo "- IO probe queries: ${IO_PROBE_QUERIES}"
    echo "- k: ${K}"
    echo "- Duration per run (s): ${DURATION}"
    echo "- Repeats: ${REPEATS}"
    echo "- Shared buffers: ${SHARED_BUFFERS}"
    echo
    echo "## Index Build and Size"
    echo
    echo "index_variant,build_seconds,index_bytes,index_pretty,table_bytes,table_pretty"
    awk -F',' 'NR > 1 {printf "%s,%s,%s,%s,%s,%s\n", $3, $4, $5, $6, $7, $8}' "$INDEX_BUILD_CSV"
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
    echo "## Buffer Probe (EXPLAIN ANALYZE, BUFFERS average)"
    echo
    echo "method,scenario,ef_search,samples,avg_exec_ms,avg_shared_hit_blocks,avg_shared_read_blocks,max_shared_read_blocks"
    awk -F',' 'NR > 1 {printf "%s,%s,%s,%s,%s,%s,%s,%s\n", $3, $4, $5, $6, $7, $8, $9, $10}' "$IO_PROBE_CSV" | sort
    echo
    echo "## Artifacts"
    echo
    echo "- env: ${ENV_TXT}"
    echo "- index_build: ${INDEX_BUILD_CSV}"
    echo "- metrics: ${METRICS_CSV}"
    echo "- recall: ${RECALL_CSV}"
    echo "- io_probe: ${IO_PROBE_CSV}"
    echo "- pgbench logs: ${PGBENCH_LOG_DIR}"
    echo "- workloads: ${WORKLOAD_DIR}"
  } > "$SUMMARY_MD"
}

MODE_OVERRIDE=""
ROWS_OVERRIDE=""
DIM_OVERRIDE=""
QUERY_COUNT_OVERRIDE=""
RECALL_QUERIES_OVERRIDE=""
IO_PROBE_QUERIES_OVERRIDE=""
DURATION_OVERRIDE=""
REPEATS_OVERRIDE=""
K_OVERRIDE=""
EF_LIST_OVERRIDE=""
CLIENT_LIST_OVERRIDE=""
SCENARIO_LIST_OVERRIDE=""
METHOD_LIST_OVERRIDE=""
PORT_OVERRIDE=""
SHARED_BUFFERS_OVERRIDE=""
SEED_OVERRIDE=""
ACORN_GAMMA_OVERRIDE=""
ACORN_M_BETA_OVERRIDE=""

SKIP_BUILD="${PGVECTOR_BENCH_SKIP_BUILD:-0}"
KEEP_DATA="${PGVECTOR_BENCH_KEEP_DATA:-0}"
PORT="${PGVECTOR_BENCH_PORT:-6546}"
PGUSER_NAME="${PGVECTOR_BENCH_USER:-${USER}}"
SHARED_BUFFERS="${PGVECTOR_BENCH_SHARED_BUFFERS:-64MB}"
ACORN_GAMMA="${PGVECTOR_BENCH_ACORN_GAMMA:-1}"
ACORN_M_BETA="${PGVECTOR_BENCH_ACORN_M_BETA:-0}"
SEED="${PGVECTOR_BENCH_SEED:-0.42}"

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
    --io-probe-queries)
      IO_PROBE_QUERIES_OVERRIDE="$2"
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
    --acorn-gamma)
      ACORN_GAMMA_OVERRIDE="$2"
      shift 2
      ;;
    --acorn-m-beta)
      ACORN_M_BETA_OVERRIDE="$2"
      shift 2
      ;;
    --port)
      PORT_OVERRIDE="$2"
      shift 2
      ;;
    --seed)
      SEED_OVERRIDE="$2"
      shift 2
      ;;
    --shared-buffers)
      SHARED_BUFFERS_OVERRIDE="$2"
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

if [ -n "$IO_PROBE_QUERIES_OVERRIDE" ]; then
  IO_PROBE_QUERIES="$IO_PROBE_QUERIES_OVERRIDE"
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

if [ -n "$ACORN_GAMMA_OVERRIDE" ]; then
  ACORN_GAMMA="$ACORN_GAMMA_OVERRIDE"
fi

if [ -n "$ACORN_M_BETA_OVERRIDE" ]; then
  ACORN_M_BETA="$ACORN_M_BETA_OVERRIDE"
fi

if [ -n "$SEED_OVERRIDE" ]; then
  SEED="$SEED_OVERRIDE"
fi

if [ -n "$SHARED_BUFFERS_OVERRIDE" ]; then
  SHARED_BUFFERS="$SHARED_BUFFERS_OVERRIDE"
fi

EF_LIST="$(echo "$EF_LIST" | tr -d ' ')"
CLIENT_LIST="$(echo "$CLIENT_LIST" | tr -d ' ')"
SCENARIO_LIST="$(echo "$SCENARIO_LIST" | tr -d ' ')"
METHOD_LIST="$(echo "$METHOD_LIST" | tr -d ' ')"

IFS=',' read -r -a EF_VALUES <<< "$EF_LIST"
IFS=',' read -r -a CLIENTS <<< "$CLIENT_LIST"
IFS=',' read -r -a SCENARIOS <<< "$SCENARIO_LIST"
IFS=',' read -r -a METHODS_IN <<< "$METHOD_LIST"

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

METHODS=()
for method in "${METHODS_IN[@]}"; do
  case "$method" in
    where)
      method="acorn"
      ;;
    acorn|post)
      ;;
    *)
      echo "Invalid method: $method" >&2
      exit 1
      ;;
  esac

  add_method=1
  for existing in "${METHODS[@]:-}"; do
    if [ "$existing" = "$method" ]; then
      add_method=0
      break
    fi
  done

  if [ "$add_method" -eq 1 ]; then
    METHODS+=("$method")
  fi
done

if [ "${#METHODS[@]}" -eq 0 ]; then
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

if [ "$RECALL_QUERIES" -gt "$QUERY_COUNT" ]; then
  RECALL_QUERIES="$QUERY_COUNT"
fi

if [ "$IO_PROBE_QUERIES" -gt "$QUERY_COUNT" ]; then
  IO_PROBE_QUERIES="$QUERY_COUNT"
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
INDEX_BUILD_CSV="${RUN_DIR}/index_build.csv"
METRICS_CSV="${RUN_DIR}/metrics.csv"
RECALL_CSV="${RUN_DIR}/recall.csv"
IO_PROBE_CSV="${RUN_DIR}/io_probe.csv"
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
shared_buffers = ${SHARED_BUFFERS}
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

DB_NAME="acorn_tradeoff_bench"

PGHOST="$SOCKET_DIR" PGPORT="$PORT" PGUSER="$PGUSER_NAME" "$DROPDB_BIN" --if-exists "$DB_NAME" >/dev/null 2>&1 || true
PGHOST="$SOCKET_DIR" PGPORT="$PORT" PGUSER="$PGUSER_NAME" "$CREATEDB_BIN" "$DB_NAME"

ARRAY_SQL="$(perl -e 'my $d = shift; print join(",", ("random()") x $d);' "$DIM")"

LOW_CARD=5
MED_CARD=50
HIGH_CARD=500
SCORE_CARD=1000
SCORE_BAND=10
MAINTENANCE_WORK_MEM="${PGVECTOR_BENCH_MAINTENANCE_WORK_MEM:-1GB}"

echo "Preparing synthetic dataset"
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

SELECT setseed(${SEED});

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

ANALYZE acorn_items;
ANALYZE acorn_queries;
SQL

ACORN_SUPPORTED="$(PGHOST="$SOCKET_DIR" PGPORT="$PORT" PGUSER="$PGUSER_NAME" "$PSQL_BIN" -X -q -At -v ON_ERROR_STOP=1 -h "$SOCKET_DIR" -p "$PORT" -U "$PGUSER_NAME" "$DB_NAME" -c "SELECT COALESCE(pg_indexam_has_property(oid, 'can_multi_col'), false) FROM pg_am WHERE amname = 'hnsw'")"

if [ "$ACORN_SUPPORTED" != "t" ]; then
  echo "This branch does not expose multicolumn HNSW predicates (can_multi_col=false)" >&2
  exit 1
fi

table_size_row="$(PGHOST="$SOCKET_DIR" PGPORT="$PORT" PGUSER="$PGUSER_NAME" "$PSQL_BIN" -X -q -At -F ',' -v ON_ERROR_STOP=1 -h "$SOCKET_DIR" -p "$PORT" -U "$PGUSER_NAME" "$DB_NAME" -c "SELECT pg_total_relation_size('acorn_items')::bigint, pg_size_pretty(pg_total_relation_size('acorn_items'))")"
IFS=',' read -r TABLE_BYTES TABLE_PRETTY <<< "$table_size_row"

echo "run_id,mode,index_variant,build_seconds,index_bytes,index_pretty,table_bytes,table_pretty" > "$INDEX_BUILD_CSV"
echo "run_id,mode,method,scenario,ef_search,clients,duration_s,repeat,transactions,tps,latency_avg_ms,latency_log_avg_ms,p50_ms,p95_ms,p99_ms" > "$METRICS_CSV"
echo "run_id,mode,method,scenario,ef_search,recall_at_k,avg_exact_candidates,queries" > "$RECALL_CSV"
echo "run_id,mode,method,scenario,ef_search,samples,avg_exec_ms,avg_shared_hit_blocks,avg_shared_read_blocks,max_shared_read_blocks" > "$IO_PROBE_CSV"

echo "Measuring index build and storage"
PGHOST="$SOCKET_DIR" PGPORT="$PORT" PGUSER="$PGUSER_NAME" "$PSQL_BIN" -X -v ON_ERROR_STOP=1 -h "$SOCKET_DIR" -p "$PORT" -U "$PGUSER_NAME" "$DB_NAME" -c "DROP INDEX IF EXISTS acorn_hnsw_idx; DROP INDEX IF EXISTS acorn_hnsw_vector_only_idx;"

start_time="$(now_epoch)"
PGHOST="$SOCKET_DIR" PGPORT="$PORT" PGUSER="$PGUSER_NAME" "$PSQL_BIN" -X -v ON_ERROR_STOP=1 -h "$SOCKET_DIR" -p "$PORT" -U "$PGUSER_NAME" "$DB_NAME" -c "SET maintenance_work_mem = '${MAINTENANCE_WORK_MEM}'; CREATE INDEX acorn_hnsw_vector_only_idx ON acorn_items USING hnsw (embedding vector_l2_ops);"
end_time="$(now_epoch)"
record_index_metrics "vector_only" "acorn_hnsw_vector_only_idx" "$(elapsed_secs "$start_time" "$end_time")"

PGHOST="$SOCKET_DIR" PGPORT="$PORT" PGUSER="$PGUSER_NAME" "$PSQL_BIN" -X -v ON_ERROR_STOP=1 -h "$SOCKET_DIR" -p "$PORT" -U "$PGUSER_NAME" "$DB_NAME" -c "DROP INDEX IF EXISTS acorn_hnsw_vector_only_idx;"

start_time="$(now_epoch)"
PGHOST="$SOCKET_DIR" PGPORT="$PORT" PGUSER="$PGUSER_NAME" "$PSQL_BIN" -X -v ON_ERROR_STOP=1 -h "$SOCKET_DIR" -p "$PORT" -U "$PGUSER_NAME" "$DB_NAME" -c "SET maintenance_work_mem = '${MAINTENANCE_WORK_MEM}'; CREATE INDEX acorn_hnsw_idx ON acorn_items USING hnsw (embedding vector_l2_ops, cat_low vector_integer_ops, cat_med vector_integer_ops, cat_high vector_integer_ops, score vector_integer_ops) WITH (acorn_gamma = ${ACORN_GAMMA}, acorn_m_beta = ${ACORN_M_BETA});"
end_time="$(now_epoch)"
record_index_metrics "acorn_multicol" "acorn_hnsw_idx" "$(elapsed_secs "$start_time" "$end_time")"

PGHOST="$SOCKET_DIR" PGPORT="$PORT" PGUSER="$PGUSER_NAME" "$PSQL_BIN" -X -v ON_ERROR_STOP=1 -h "$SOCKET_DIR" -p "$PORT" -U "$PGUSER_NAME" "$DB_NAME" <<SQL
ANALYZE acorn_items;
ANALYZE acorn_queries;

CREATE OR REPLACE FUNCTION acorn_bench_explain_json(sql text)
RETURNS jsonb
LANGUAGE plpgsql
AS \$\$
DECLARE
  p jsonb;
BEGIN
  EXECUTE 'EXPLAIN (ANALYZE, BUFFERS, FORMAT JSON) ' || sql INTO p;
  RETURN p;
END;
\$\$;
SQL

METHOD_LIST="$(IFS=,; echo "${METHODS[*]}")"

{
  echo "run_id=${RUN_ID}"
  echo "mode=${MODE}"
  echo "rows=${ROWS}"
  echo "dim=${DIM}"
  echo "query_count=${QUERY_COUNT}"
  echo "recall_queries=${RECALL_QUERIES}"
  echo "io_probe_queries=${IO_PROBE_QUERIES}"
  echo "duration=${DURATION}"
  echo "repeats=${REPEATS}"
  echo "k=${K}"
  echo "efs=${EF_LIST}"
  echo "clients=${CLIENT_LIST}"
  echo "scenarios=${SCENARIO_LIST}"
  echo "methods=${METHOD_LIST}"
  echo "acorn_supported=${ACORN_SUPPORTED}"
  echo "acorn_gamma=${ACORN_GAMMA}"
  echo "acorn_m_beta=${ACORN_M_BETA}"
  echo "shared_buffers=${SHARED_BUFFERS}"
  echo "seed=${SEED}"
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

echo "Running EXPLAIN BUFFERS probe"
for method in "${METHODS[@]}"; do
  for scenario in "${SCENARIOS[@]}"; do
    for ef in "${EF_VALUES[@]}"; do
      echo "  io-probe method=${method} scenario=${scenario} ef=${ef}"
      run_io_probe_case "$method" "$scenario" "$ef"
    done
  done
done

write_summary

echo
echo "Tradeoff benchmark complete"
echo "- Summary: ${SUMMARY_MD}"
echo "- Index build: ${INDEX_BUILD_CSV}"
echo "- Metrics: ${METRICS_CSV}"
echo "- Recall: ${RECALL_CSV}"
echo "- IO probe: ${IO_PROBE_CSV}"
echo "- Run dir: ${RUN_DIR}"
