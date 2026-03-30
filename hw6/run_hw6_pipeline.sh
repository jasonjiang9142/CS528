#!/usr/bin/env bash
# ============================================================================
# run_hw6_pipeline.sh — HW6 one-shot pipeline for grading / demo:
#
#   1. Pause hourly DB-stopper (so Cloud SQL is not stopped mid-run)
#   2. Start Cloud SQL (activation-policy ALWAYS), wait until RUNNABLE
#   3. Create hw6-ml-vm if missing, wait until SSH works
#   4. Copy this hw6/ directory to the VM and run train_models.py
#   5. Stop Cloud SQL (activation-policy NEVER)
#   6. Delete the ML VM
#   7. Resume hourly DB-stopper
#   8. Print GCS output files (metrics + sample of predictions) to the terminal
#
# Prerequisites:
#   - gcloud authenticated; project set
#   - DB_PASS: Cloud SQL password for hw5user (default hw5pass123 if unset, same as hw5/setup.sh)
#   - Same VPC as Cloud SQL (default network)
#   - Service account on VM: hw5-server-sa (or SA with cloudsql.client + storage)
#   - IAP SSH: script creates allow-iap-ssh-hw6-ml if missing (IAP range → tcp:22, tag hw6-ml).
#
# Usage:
#   export DB_PASS='your-cloud-sql-password'   # optional if still hw5pass123 from setup
#   cd /path/to/cs528/hw6
#   bash run_hw6_pipeline.sh
#
# Optional env:
#   PROJECT_ID, ZONE, VM_NAME, GCS_BUCKET, GCP_PROJECT, REGION
#   MACHINE_TYPE — default e2-medium (faster pip/uv than e2-small; set e2-small to save cost)
#   NETWORK — VPC name for the IAP firewall rule (default: default)
# ============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_PARENT="$(cd "${SCRIPT_DIR}/.." && pwd)"

PROJECT_ID="${PROJECT_ID:-$(gcloud config get-value project 2>/dev/null)}"
ZONE="${ZONE:-us-central1-a}"
REGION="${REGION:-us-central1}"
VM_NAME="${VM_NAME:-hw6-ml-vm}"
DB_INSTANCE="${DB_INSTANCE:-hw5-db}"
GCS_BUCKET="${GCS_BUCKET:-cs528-jx3onj-hw2}"
GCS_PREFIX="${GCS_PREFIX:-hw6}"
GCP_PROJECT="${GCP_PROJECT:-${PROJECT_ID}}"
SA_EMAIL="${SA_EMAIL:-hw5-server-sa@${PROJECT_ID}.iam.gserviceaccount.com}"
MACHINE_TYPE="${MACHINE_TYPE:-e2-medium}"
NETWORK="${NETWORK:-default}"

if [ -z "${PROJECT_ID}" ]; then
  echo "ERROR: Set GCP project: gcloud config set project <ID>" >&2
  exit 1
fi

# Default matches hw5/setup.sh when DB_PASS was not set during setup (hw5user password).
if [ -z "${DB_PASS:-}" ]; then
  DB_PASS="hw5pass123"
  echo "  Note: DB_PASS unset — using default hw5pass123 (hw5/setup.sh default). Export DB_PASS if yours differs."
fi

echo "============================================================"
echo " HW6 pipeline  project=${PROJECT_ID}"
echo "============================================================"

# IAP TCP forwarding to port 22 requires this rule (source = IAP proxy range).
IAP_FW_RULE="allow-iap-ssh-hw6-ml"
if ! gcloud compute firewall-rules describe "${IAP_FW_RULE}" \
    --project="${PROJECT_ID}" &>/dev/null; then
  echo "[0/8] Creating firewall rule '${IAP_FW_RULE}' (IAP → tcp:22, target tag hw6-ml) …"
  gcloud compute firewall-rules create "${IAP_FW_RULE}" \
    --project="${PROJECT_ID}" \
    --network="${NETWORK}" \
    --direction=INGRESS \
    --action=ALLOW \
    --rules=tcp:22 \
    --source-ranges=35.235.240.0/20 \
    --target-tags=hw6-ml \
    --description="IAP SSH for gcloud compute ssh --tunnel-through-iap (HW6 ML VM)" \
    --quiet
else
  echo "[0/8] Firewall rule '${IAP_FW_RULE}' already exists."
fi

echo "[1/8] Pausing Cloud Scheduler stop-db job …"
gcloud scheduler jobs pause stop-hw5-db-job \
  --location="${REGION}" --project="${PROJECT_ID}" 2>/dev/null || echo "  (already paused or missing)"

echo "[2/8] Starting Cloud SQL '${DB_INSTANCE}' …"
STATE=$(gcloud sql instances describe "${DB_INSTANCE}" --project="${PROJECT_ID}" --format="value(state)" 2>/dev/null || echo "MISSING")
if [ "${STATE}" = "RUNNABLE" ]; then
  echo "  Already RUNNABLE."
else
  echo "  Current state: ${STATE} (starting can take 5-15 minutes; maintenance is normal)"
  gcloud sql instances patch "${DB_INSTANCE}" \
    --activation-policy=ALWAYS --project="${PROJECT_ID}" --quiet 2>/dev/null || true
  echo "  Waiting for RUNNABLE …"
  while true; do
    S=$(gcloud sql instances describe "${DB_INSTANCE}" --project="${PROJECT_ID}" --format="value(state)" 2>/dev/null || echo "")
    TS=$(date -u +%Y-%m-%dT%H-%M-%SZ)
    echo "  [${TS}] state=${S}"
    [ "${S}" = "RUNNABLE" ] && break
    sleep 15
  done
fi

DB_PRIVATE_IP=$(gcloud sql instances describe "${DB_INSTANCE}" \
  --project="${PROJECT_ID}" --format="value(ipAddresses[0].ipAddress)")
echo "  Cloud SQL private IP: ${DB_PRIVATE_IP}"

echo "[3/8] Ensuring VM '${VM_NAME}' exists …"
if ! gcloud compute instances describe "${VM_NAME}" --zone="${ZONE}" --project="${PROJECT_ID}" &>/dev/null; then
  gcloud compute instances create "${VM_NAME}" \
    --project="${PROJECT_ID}" \
    --zone="${ZONE}" \
    --machine-type="${MACHINE_TYPE}" \
    --service-account="${SA_EMAIL}" \
    --scopes=https://www.googleapis.com/auth/cloud-platform \
    --image-family=debian-12 \
    --image-project=debian-cloud \
    --tags=hw6-ml \
    --metadata-from-file=startup-script="${SCRIPT_DIR}/vm_startup.sh"
else
  echo "  VM already exists (not recreated). For a new machine type or fresh disk, delete first:"
  echo "    gcloud compute instances delete ${VM_NAME} --zone=${ZONE} --project=${PROJECT_ID}"
fi

echo "[4/8] Waiting for SSH (IAP) …"
SSH_READY=0
for _ in {1..36}; do
  if gcloud compute ssh "${VM_NAME}" --zone="${ZONE}" --project="${PROJECT_ID}" \
      --tunnel-through-iap --command="echo ssh_ok" &>/dev/null; then
    SSH_READY=1
    break
  fi
  sleep 10
done
if [ "${SSH_READY}" -ne 1 ]; then
  echo "ERROR: SSH via IAP did not succeed after ~6 minutes." >&2
  echo "  Check: firewall rule ${IAP_FW_RULE}, VM tag hw6-ml, IAP permissions." >&2
  exit 1
fi

# IAP can fail transiently right after boot; retry ssh a few times.
gcloud_ssh() { gcloud compute ssh "${VM_NAME}" --zone="${ZONE}" --project="${PROJECT_ID}" \
  --tunnel-through-iap "$@"; }

retry_ssh() {
  local n=1 max=8 delay=5
  until gcloud_ssh "$@"; do
    if [ "${n}" -ge "${max}" ]; then
      return 1
    fi
    echo "  (retry ${n}/${max} in ${delay}s …)"
    n=$((n + 1))
    sleep "${delay}"
  done
}

# Do NOT use gcloud compute scp --recurse on hw6/ if a local venv exists: it uploads
# thousands of site-packages files over IAP at a few KB/s (hours). Stream a tarball
# excluding venv and __pycache__; the VM builds a fresh venv with uv.
unpack_hw6='rm -rf ~/hw6 && mkdir -p ~ && cd ~ && tar xzf -'

retry_upload_hw6() {
  local n=1 max=8 delay=5
  until \
    ( cd "${REPO_PARENT}" && tar -czf - \
        --exclude='hw6/venv' \
        --exclude='hw6/.venv' \
        --exclude='__pycache__' \
        hw6 ) \
    | gcloud compute ssh "${VM_NAME}" --zone="${ZONE}" --project="${PROJECT_ID}" \
        --tunnel-through-iap --command="${unpack_hw6}"; do
    if [ "${n}" -ge "${max}" ]; then
      return 1
    fi
    echo "  (upload retry ${n}/${max} in ${delay}s …)"
    n=$((n + 1))
    sleep "${delay}"
  done
}

echo "[5/8] Copying hw6/ to VM and running train_models.py …"
echo "  (packing hw6/ without venv/ — avoids huge IAP upload; VM installs deps with uv)"
retry_upload_hw6

# Shell-escape password for embedding in remote bash (handles quotes, spaces; base64 was fragile).
DB_PASS_SH=$(printf '%q' "${DB_PASS}")

# Multiline remote script: show progress (pip on a fresh VM can take 5–15+ minutes)
REMOTE_CMD=$(
  cat <<REMOTESCRIPT
set -euo pipefail
cd ~/hw6
echo ""
echo "=== [HW6] Installing uv (fast parallel installer; ~1–3 min vs many minutes for plain pip) ==="
curl -LsSf https://astral.sh/uv/install.sh | sh
export PATH="\${HOME}/.local/bin:\${PATH}"
echo ""
echo "=== [HW6] uv venv + install deps (pandas, numpy, scikit-learn) ==="
uv venv --clear venv
uv pip install --python ./venv/bin/python -r requirements.txt
echo ""
echo "=== [HW6] Running train_models.py ==="
export DB_HOST='${DB_PRIVATE_IP}'
export DB_PORT=5432
export DB_NAME=hw5db
export DB_USER=hw5user
export GCP_PROJECT='${GCP_PROJECT}'
export GCS_BUCKET='${GCS_BUCKET}'
export GCS_PREFIX='${GCS_PREFIX}'
export DB_PASS=${DB_PASS_SH}
./venv/bin/python train_models.py
REMOTESCRIPT
)

retry_ssh --command="${REMOTE_CMD}"

TRAIN_OK=$?

echo "[6/8] Stopping Cloud SQL …"
gcloud sql instances patch "${DB_INSTANCE}" \
  --activation-policy=NEVER --project="${PROJECT_ID}" --quiet || true

echo "[7/8] Deleting VM '${VM_NAME}' …"
gcloud compute instances delete "${VM_NAME}" \
  --zone="${ZONE}" --project="${PROJECT_ID}" --quiet || true

echo "[8/8] Resuming Cloud Scheduler stop-db job …"
gcloud scheduler jobs resume stop-hw5-db-job \
  --location="${REGION}" --project="${PROJECT_ID}" 2>/dev/null || true

echo ""
echo "============================================================"
echo " GCS outputs (${GCS_BUCKET}/${GCS_PREFIX}/)"
echo "============================================================"
if command -v gsutil &>/dev/null; then
  gsutil ls "gs://${GCS_BUCKET}/${GCS_PREFIX}/" 2>/dev/null || echo "  (could not list bucket)"
  echo ""
  echo "--- metrics_summary.csv ---"
  gsutil cat "gs://${GCS_BUCKET}/${GCS_PREFIX}/metrics_summary.csv" 2>/dev/null || echo "  (file missing)"
  echo ""
  echo "--- model1_test_predictions.csv (first 25 lines) ---"
  gsutil cat "gs://${GCS_BUCKET}/${GCS_PREFIX}/model1_test_predictions.csv" 2>/dev/null | head -25 || echo "  (file missing)"
  echo ""
  echo "--- model2_test_predictions.csv (first 25 lines) ---"
  gsutil cat "gs://${GCS_BUCKET}/${GCS_PREFIX}/model2_test_predictions.csv" 2>/dev/null | head -25 || echo "  (file missing)"
else
  echo "gsutil not found; install Google Cloud SDK or run:"
  echo "  gsutil cat gs://${GCS_BUCKET}/${GCS_PREFIX}/metrics_summary.csv"
fi

echo ""
echo "============================================================"
if [ "${TRAIN_OK}" -ne 0 ]; then
  echo " Pipeline finished with errors (train_models exit ${TRAIN_OK})."
  exit "${TRAIN_OK}"
fi
echo " Pipeline complete."
echo "============================================================"
