#!/usr/bin/env bash

set -euo pipefail

usage() {
  cat <<'EOF'
Usage:
  skills/pgvector-hnsw-acorn-bench/scripts/compare-e2e-runs.sh <baseline-run-dir> <candidate-run-dir>

Example:
  skills/pgvector-hnsw-acorn-bench/scripts/compare-e2e-runs.sh \
    tmp_check/pgvector-e2e-bench/runs/20260222-120000 \
    tmp_check/pgvector-e2e-bench/runs/20260223-090000
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
  if [ ! -f "${dir}/report.csv" ]; then
    echo "Missing file: ${dir}/report.csv" >&2
    exit 1
  fi
done

echo "========================================================"
echo "    pgvector HNSW ACORN E2E Compare Suite v2"
echo "========================================================"
echo "Baseline: ${BASE_DIR}"
echo "Candidate: ${CAND_DIR}"
echo "--------------------------------------------------------"

base_data=$(tail -n 1 "${BASE_DIR}/report.csv")
cand_data=$(tail -n 1 "${CAND_DIR}/report.csv")

IFS=',' read -r b_run_id b_rows b_dim b_skew b_m b_aux_m b_ef_cons b_clients b_build_time_s b_idx_initial_mb b_initial_tps b_initial_recall b_churn_tps b_wal_mb b_idx_prevac_mb b_vac_time_s b_idx_postvac_mb b_final_tps b_final_recall <<< "$base_data"
IFS=',' read -r c_run_id c_rows c_dim c_skew c_m c_aux_m c_ef_cons c_clients c_build_time_s c_idx_initial_mb c_initial_tps c_initial_recall c_churn_tps c_wal_mb c_idx_prevac_mb c_vac_time_s c_idx_postvac_mb c_final_tps c_final_recall <<< "$cand_data"

calc_diff_pct() {
  local base="$1"
  local cand="$2"
  if awk "BEGIN {exit !($base == 0)}"; then
    echo "N/A"
  else
    awk "BEGIN {printf \"%+.2f%%\", (($cand - $base) / $base) * 100}"
  fi
}

echo "1. Build Time (s):        ${b_build_time_s} -> ${c_build_time_s} ($(calc_diff_pct "$b_build_time_s" "$c_build_time_s"))"
echo "2. Initial Size (MB):     ${b_idx_initial_mb} -> ${c_idx_initial_mb} ($(calc_diff_pct "$b_idx_initial_mb" "$c_idx_initial_mb"))"
echo "3. Initial Recall@k:      ${b_initial_recall} -> ${c_initial_recall} ($(calc_diff_pct "$b_initial_recall" "$c_initial_recall"))"
echo "4. Initial Read TPS:      ${b_initial_tps} -> ${c_initial_tps} ($(calc_diff_pct "$b_initial_tps" "$c_initial_tps"))"
echo "5. Mixed Churn TPS:       ${b_churn_tps} -> ${c_churn_tps} ($(calc_diff_pct "$b_churn_tps" "$c_churn_tps"))"
echo "6. WAL Generated (MB):    ${b_wal_mb} -> ${c_wal_mb} ($(calc_diff_pct "$b_wal_mb" "$c_wal_mb"))"
echo "7. Pre-Vacuum Size (MB):  ${b_idx_prevac_mb} -> ${c_idx_prevac_mb} ($(calc_diff_pct "$b_idx_prevac_mb" "$c_idx_prevac_mb"))"
echo "8. Vacuum Time (s):       ${b_vac_time_s} -> ${c_vac_time_s} ($(calc_diff_pct "$b_vac_time_s" "$c_vac_time_s"))"
echo "9. Post-Vacuum Size (MB): ${b_idx_postvac_mb} -> ${c_idx_postvac_mb} ($(calc_diff_pct "$b_idx_postvac_mb" "$c_idx_postvac_mb"))"
echo "10. Final Recall@k:       ${b_final_recall} -> ${c_final_recall} ($(calc_diff_pct "$b_final_recall" "$c_final_recall"))"
echo "11. Final Read TPS:       ${b_final_tps} -> ${c_final_tps} ($(calc_diff_pct "$b_final_tps" "$c_final_tps"))"

echo "========================================================"
