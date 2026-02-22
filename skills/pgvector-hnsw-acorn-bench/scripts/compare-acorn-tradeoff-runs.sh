#!/usr/bin/env bash

set -euo pipefail

usage() {
  cat <<'EOF'
Usage:
  skills/pgvector-hnsw-acorn-bench/scripts/compare-acorn-tradeoff-runs.sh <baseline-run-dir> <candidate-run-dir>

Example:
  skills/pgvector-hnsw-acorn-bench/scripts/compare-acorn-tradeoff-runs.sh \
    tmp_check/pgvector-acorn-bench/runs/20260222-120000 \
    tmp_check/pgvector-acorn-bench/runs/20260223-090000
EOF
}

if [ "$#" -ne 2 ]; then
  usage
  exit 1
fi

BASE_DIR="$1"
CAND_DIR="$2"

for dir in "$BASE_DIR" "$CAND_DIR"; do
  if [ ! -d "$dir" ]; then
    echo "Missing run dir: $dir" >&2
    exit 1
  fi

  for file in index_build.csv metrics.csv recall.csv io_probe.csv; do
    if [ ! -f "${dir}/${file}" ]; then
      echo "Missing file: ${dir}/${file}" >&2
      exit 1
    fi
  done
done

echo "Comparing runs"
echo "- baseline: ${BASE_DIR}"
echo "- candidate: ${CAND_DIR}"
echo

echo "Index Build / Size"
echo "variant,baseline_build_s,candidate_build_s,delta_build_pct,baseline_size_bytes,candidate_size_bytes,delta_size_pct"
awk -F',' '
  NR == FNR && NR > 1 {
    b_build[$3] = $4 + 0;
    b_size[$3] = $5 + 0;
    next;
  }
  NR > 1 {
    c_build[$3] = $4 + 0;
    c_size[$3] = $5 + 0;
  }
  END {
    for (k in c_build) {
      if (!(k in b_build))
        continue;

      db = (b_build[k] == 0) ? 0 : ((c_build[k] - b_build[k]) / b_build[k] * 100.0);
      ds = (b_size[k] == 0) ? 0 : ((c_size[k] - b_size[k]) / b_size[k] * 100.0);
      printf "%s,%.6f,%.6f,%.2f,%.0f,%.0f,%.2f\n", k, b_build[k], c_build[k], db, b_size[k], c_size[k], ds;
    }
  }
' "${BASE_DIR}/index_build.csv" "${CAND_DIR}/index_build.csv" | sort
echo

echo "Recall@k (averaged by method+scenario+ef)"
echo "method,scenario,ef_search,baseline_recall,candidate_recall,delta_recall"
awk -F',' '
  NR == FNR && NR > 1 {
    key = $3 "," $4 "," $5;
    b_sum[key] += $6;
    b_n[key]++;
    next;
  }
  NR > 1 {
    key = $3 "," $4 "," $5;
    c_sum[key] += $6;
    c_n[key]++;
  }
  END {
    for (k in c_sum) {
      if (!(k in b_sum))
        continue;
      b = b_sum[k] / b_n[k];
      c = c_sum[k] / c_n[k];
      printf "%s,%.6f,%.6f,%.6f\n", k, b, c, c - b;
    }
  }
' "${BASE_DIR}/recall.csv" "${CAND_DIR}/recall.csv" | sort
echo

echo "Throughput (TPS averaged by method+scenario+ef+clients)"
echo "method,scenario,ef_search,clients,baseline_tps,candidate_tps,delta_tps_pct"
awk -F',' '
  NR == FNR && NR > 1 {
    key = $3 "," $4 "," $5 "," $6;
    b_sum[key] += $10;
    b_n[key]++;
    next;
  }
  NR > 1 {
    key = $3 "," $4 "," $5 "," $6;
    c_sum[key] += $10;
    c_n[key]++;
  }
  END {
    for (k in c_sum) {
      if (!(k in b_sum))
        continue;
      b = b_sum[k] / b_n[k];
      c = c_sum[k] / c_n[k];
      d = (b == 0) ? 0 : ((c - b) / b * 100.0);
      printf "%s,%.6f,%.6f,%.2f\n", k, b, c, d;
    }
  }
' "${BASE_DIR}/metrics.csv" "${CAND_DIR}/metrics.csv" | sort
echo

echo "Buffer Reads (avg shared read blocks by method+scenario+ef)"
echo "method,scenario,ef_search,baseline_avg_read_blocks,candidate_avg_read_blocks,delta_read_blocks_pct"
awk -F',' '
  NR == FNR && NR > 1 {
    key = $3 "," $4 "," $5;
    b_sum[key] += $9;
    b_n[key]++;
    next;
  }
  NR > 1 {
    key = $3 "," $4 "," $5;
    c_sum[key] += $9;
    c_n[key]++;
  }
  END {
    for (k in c_sum) {
      if (!(k in b_sum))
        continue;
      b = b_sum[k] / b_n[k];
      c = c_sum[k] / c_n[k];
      d = (b == 0) ? 0 : ((c - b) / b * 100.0);
      printf "%s,%.6f,%.6f,%.2f\n", k, b, c, d;
    }
  }
' "${BASE_DIR}/io_probe.csv" "${CAND_DIR}/io_probe.csv" | sort
