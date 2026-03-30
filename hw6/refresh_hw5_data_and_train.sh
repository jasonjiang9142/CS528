#!/usr/bin/env bash
# Upload server.py → GCS, restart hw5-server, truncate requests, load data via http_client,
# then run run_hw6_pipeline.sh. Requires gcloud + gsutil; DB_PASS for pipeline.
#
# Optional: USE_IAP_SSH=1  if gcloud compute ssh needs --tunnel-through-iap
# Optional: SKIP_TRUNCATE=1  if TRUNCATE fails (wrong DB_PASS) — run in Cloud Console SQL:
#   TRUNCATE requests RESTART IDENTITY CASCADE;
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# macOS bash 3.2 + set -u: do not use empty "${arr[@]}"
SSH_IAP_FLAG=""
[ "${USE_IAP_SSH:-0}" = "1" ] && SSH_IAP_FLAG="--tunnel-through-iap"
HW5_DIR="$(cd "${SCRIPT_DIR}/../hw5" && pwd)"
PROJECT_ID="${PROJECT_ID:-$(gcloud config get-value project 2>/dev/null)}"
ZONE="${ZONE:-us-central1-a}"
REGION="${REGION:-us-central1}"
CODE_BUCKET="${PROJECT_ID}-hw5-code"
SERVER_VM="${SERVER_VM:-hw5-server-vm}"
DB_PASS="${DB_PASS:-hw5pass123}"
# Enough rows for stratified split; increase if model 2 is below 40%
STRESS_NUM="${STRESS_NUM:-20000}"
STRESS_SEED="${STRESS_SEED:-42}"

echo "=== [0/5] Ensure Cloud SQL RUNNABLE + server VM running ==="
gcloud sql instances patch hw5-db --activation-policy=ALWAYS --project="${PROJECT_ID}" --quiet 2>/dev/null || true
while [ "$(gcloud sql instances describe hw5-db --project="${PROJECT_ID}" --format="value(state)" 2>/dev/null)" != "RUNNABLE" ]; do
  echo "  Waiting for Cloud SQL RUNNABLE …"
  sleep 10
done
gcloud compute instances start "${SERVER_VM}" --zone="${ZONE}" --project="${PROJECT_ID}" --quiet 2>/dev/null || true
sleep 8

echo "=== [1/5] Upload server.py to gs://${CODE_BUCKET}/hw5/ ==="
gsutil -m cp "${HW5_DIR}/server.py" "gs://${CODE_BUCKET}/hw5/server.py"

echo "=== [2/5] Pull code + restart hw5-server on ${SERVER_VM} ==="
gcloud compute ssh "${SERVER_VM}" --zone="${ZONE}" --project="${PROJECT_ID}" \
  ${SSH_IAP_FLAG} \
  --command="sudo gsutil -m cp 'gs://${CODE_BUCKET}/hw5/*' /opt/hw5/ && sudo systemctl restart hw5-server && sleep 2 && sudo systemctl is-active hw5-server"

echo "=== [3/5] Truncate legacy requests (needs DB_PASS = Cloud SQL hw5user password) ==="
if [ "${SKIP_TRUNCATE:-0}" = "1" ]; then
  echo "  SKIP_TRUNCATE=1 — not truncating. Clear 'requests' in Cloud Console if you need a clean table."
else
  DB_PRIVATE_IP=$(gcloud sql instances describe hw5-db --project="${PROJECT_ID}" --format="value(ipAddresses[0].ipAddress)")
  DB_PASS_Q=$(printf '%q' "${DB_PASS}")
  if ! gcloud compute ssh "${SERVER_VM}" --zone="${ZONE}" --project="${PROJECT_ID}" \
    ${SSH_IAP_FLAG} \
    --command="sudo env DB_HOST=$(printf '%q' "${DB_PRIVATE_IP}") DB_PASS=${DB_PASS_Q} /opt/hw5/venv/bin/python3 -c 'import os, pg8000; c=pg8000.connect(host=os.environ[\"DB_HOST\"], port=5432, database=\"hw5db\", user=\"hw5user\", password=os.environ[\"DB_PASS\"]); c.autocommit=True; c.cursor().execute(\"TRUNCATE requests RESTART IDENTITY CASCADE\"); c.close(); print(\"TRUNCATE requests: ok\")'"; then
    echo "ERROR: TRUNCATE failed (wrong DB_PASS?). Fix password:" >&2
    echo "  gcloud sql users set-password hw5user --instance=hw5-db --project=${PROJECT_ID} --password='YOUR_PASSWORD'" >&2
    echo "  export DB_PASS='YOUR_PASSWORD'" >&2
    echo "Or skip: SKIP_TRUNCATE=1 $0 (old + new rows mixed — model 1 may stay poor)." >&2
    exit 1
  fi
fi

STATIC_IP=$(gcloud compute addresses describe hw5-server-ip \
  --region="${REGION}" --project="${PROJECT_ID}" --format="value(address)" 2>/dev/null || echo "")
if [ -z "${STATIC_IP}" ]; then
  echo "ERROR: Could not read hw5-server-ip. Set STATIC_IP or create the address." >&2
  exit 1
fi

echo "=== [4/5] Load ${STRESS_NUM} requests from this machine → http://${STATIC_IP}:8080 ==="
if ! command -v python3 &>/dev/null; then
  echo "ERROR: python3 required for http_client" >&2
  exit 1
fi
python3 "${HW5_DIR}/http_client.py" --url "http://${STATIC_IP}:8080" --num "${STRESS_NUM}" --seed "${STRESS_SEED}" --delay 0

echo "=== [5/5] Run HW6 pipeline (train + GCS) ==="
export DB_PASS
cd "${SCRIPT_DIR}"
bash ./run_hw6_pipeline.sh

echo "=== Done. Check GCS metrics and console output for model accuracies. ==="
