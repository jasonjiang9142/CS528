#!/usr/bin/env bash
# ============================================================================
# stress_test.sh  –  launch N concurrent http_client.py instances
#
# Usage (run from the client VM):
#   bash /opt/hw4/stress_test.sh <server_ip> [num_clients] [requests_per_client]
#
# Example:
#   bash /opt/hw4/stress_test.sh 34.56.78.90 4 500
# ============================================================================
set -euo pipefail

SERVER_IP="${1:?Usage: stress_test.sh <server_ip> [num_clients] [requests_per_client]}"
NUM_CLIENTS="${2:-4}"
NUM_REQUESTS="${3:-500}"
URL="http://${SERVER_IP}:8080"
LOG_DIR="/opt/hw4/stress_logs"

mkdir -p "${LOG_DIR}"

echo "=== Stress test: ${NUM_CLIENTS} clients × ${NUM_REQUESTS} requests → ${URL} ==="

for i in $(seq 1 "${NUM_CLIENTS}"); do
    echo "Starting client ${i} …"
    python3 /opt/hw4/http_client.py \
        --url "${URL}" --num "${NUM_REQUESTS}" --delay 0 \
        > "${LOG_DIR}/client_${i}.log" 2>&1 &
done

echo "All clients launched.  Waiting …"
wait
echo ""
echo "=== Results ==="

for i in $(seq 1 "${NUM_CLIENTS}"); do
    echo "--- Client ${i} ---"
    tail -3 "${LOG_DIR}/client_${i}.log"
    echo ""
done
