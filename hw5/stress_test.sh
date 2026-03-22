#!/usr/bin/env bash
# ============================================================================
# stress_test.sh  –  2 concurrent clients × 50 000 requests (same seed)
#
# Usage (from client VM):
#   bash /opt/hw5/stress_test.sh <server_ip> [seed] [num_requests]
#
# Example:
#   bash /opt/hw5/stress_test.sh 10.128.0.7 42 50000
# ============================================================================
set -euo pipefail

SERVER_IP="${1:?Usage: stress_test.sh <server_ip> [seed] [requests_per_client]}"
SEED="${2:-42}"
NUM="${3:-50000}"
URL="http://${SERVER_IP}:8080"
LOG_DIR="/opt/hw5/stress_logs"

mkdir -p "${LOG_DIR}"

echo "=== Stress test: 2 clients × ${NUM} requests  seed=${SEED}  → ${URL} ==="
echo "Started at $(date -u)"

/opt/hw5/venv/bin/python /opt/hw5/http_client.py \
    --url "${URL}" --num "${NUM}" --seed "${SEED}" --delay 0 \
    > "${LOG_DIR}/client_1.log" 2>&1 &

/opt/hw5/venv/bin/python /opt/hw5/http_client.py \
    --url "${URL}" --num "${NUM}" --seed "${SEED}" --delay 0 \
    > "${LOG_DIR}/client_2.log" 2>&1 &

echo "Both clients launched. Waiting …"
wait
echo "Finished at $(date -u)"
echo ""
echo "=== Results ==="
echo "--- Client 1 ---"
tail -3 "${LOG_DIR}/client_1.log"
echo ""
echo "--- Client 2 ---"
tail -3 "${LOG_DIR}/client_2.log"
