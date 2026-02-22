#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../../.." && pwd)"

TESTS=("$@")
if [ ${#TESTS[@]} -eq 0 ]; then
  TESTS=(hnsw_vector hnsw_halfvec hnsw_sparsevec)
fi

PORT="${PGVECTOR_DEBUG_PORT:-6543}"
ASSERTS="${PGVECTOR_DEBUG_ASSERTS:-1}"
KEEP_DATA="${PGVECTOR_DEBUG_KEEP_DATA:-0}"
PGUSER_NAME="${PGVECTOR_DEBUG_USER:-${USER}}"

WORK_DIR="${REPO_ROOT}/tmp_check/pgvector-debug"
DATA_DIR="${PGVECTOR_DEBUG_DATA_DIR:-${WORK_DIR}/data}"
SOCKET_DIR="${PGVECTOR_DEBUG_SOCKET_DIR:-${WORK_DIR}/run}"
LOG_DIR="${PGVECTOR_DEBUG_LOG_DIR:-${WORK_DIR}/log}"
SERVER_LOG="${PGVECTOR_DEBUG_SERVER_LOG:-${LOG_DIR}/postgres.log}"
TEST_LOG="${PGVECTOR_DEBUG_TEST_LOG:-${LOG_DIR}/installcheck.log}"

mkdir -p "${WORK_DIR}" "${LOG_DIR}" "${SOCKET_DIR}"

for cmd in make pg_config; do
  if ! command -v "${cmd}" >/dev/null 2>&1; then
    echo "Missing required command: ${cmd}" >&2
    exit 1
  fi
done

PGBIN="$(pg_config --bindir)"
INITDB="${PGBIN}/initdb"
PG_CTL="${PGBIN}/pg_ctl"
PG_ISREADY="${PGBIN}/pg_isready"

for cmd in "${INITDB}" "${PG_CTL}" "${PG_ISREADY}"; do
  if [ ! -x "${cmd}" ]; then
    echo "Missing PostgreSQL binary: ${cmd}" >&2
    exit 1
  fi
done

if [ "${KEEP_DATA}" != "1" ]; then
  if [ -f "${DATA_DIR}/postmaster.pid" ]; then
    "${PG_CTL}" -D "${DATA_DIR}" -m fast stop >/dev/null 2>&1 || true
  fi
  rm -rf "${DATA_DIR}" "${SOCKET_DIR}"
  mkdir -p "${SOCKET_DIR}"
fi

if [ ! -f "${DATA_DIR}/PG_VERSION" ]; then
  rm -rf "${DATA_DIR}"
  "${INITDB}" -D "${DATA_DIR}" -A trust -U "${PGUSER_NAME}" >/dev/null
fi

DEBUG_CONF="${DATA_DIR}/debug.conf"
cat > "${DEBUG_CONF}" <<EOF
port = ${PORT}
listen_addresses = ''
unix_socket_directories = '${SOCKET_DIR}'
log_destination = 'stderr'
logging_collector = off
log_line_prefix = '%m [%p] %q%u@%d '
log_error_verbosity = verbose
log_min_messages = debug1
client_min_messages = log
log_statement = 'all'
log_duration = on
log_connections = on
log_disconnections = on
EOF

if ! grep -q "include_if_exists = 'debug.conf'" "${DATA_DIR}/postgresql.conf"; then
  echo "include_if_exists = 'debug.conf'" >> "${DATA_DIR}/postgresql.conf"
fi

STARTED_BY_SCRIPT=0

cleanup() {
  if [ "${STARTED_BY_SCRIPT}" -eq 1 ]; then
    "${PG_CTL}" -D "${DATA_DIR}" -m fast stop >/dev/null 2>&1 || true
  fi
}

trap cleanup EXIT

if ! "${PG_ISREADY}" -h "${SOCKET_DIR}" -p "${PORT}" -U "${PGUSER_NAME}" >/dev/null 2>&1; then
  "${PG_CTL}" -D "${DATA_DIR}" -l "${SERVER_LOG}" start >/dev/null
  STARTED_BY_SCRIPT=1
fi

cd "${REPO_ROOT}"

if [ "${ASSERTS}" = "1" ]; then
  make clean
  PG_CFLAGS="-DUSE_ASSERT_CHECKING" make
else
  make
fi

if ! make install; then
  echo "make install failed. If PostgreSQL is system-managed, rerun with appropriate privileges." >&2
  exit 1
fi

TEST_LIST="${TESTS[*]}"

set +e
PGHOST="${SOCKET_DIR}" PGPORT="${PORT}" PGUSER="${PGUSER_NAME}" \
  make installcheck REGRESS="${TEST_LIST}" 2>&1 | tee "${TEST_LOG}"
TEST_STATUS=${PIPESTATUS[0]}
set -e

echo
echo "Artifacts"
echo "- Server log: ${SERVER_LOG}"
echo "- installcheck log: ${TEST_LOG}"
echo "- Regression summary: ${REPO_ROOT}/regression.out"
echo "- Regression diffs: ${REPO_ROOT}/regression.diffs"

if [ -f "${SERVER_LOG}" ]; then
  echo
  echo "Server errors"
  grep -nE "ERROR|FATAL|PANIC|TRAP|assert|memory corruption|Predicate pointer is NULL|could not open file|could not read block" "${SERVER_LOG}" || true
fi

exit "${TEST_STATUS}"
