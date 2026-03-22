#!/usr/bin/env bash
# ============================================================================
# start_all.sh  –  Start the Cloud SQL database, create (or start) the
#                   server and subscriber VMs, and launch their services.
#
# Prerequisites (one-time, already done by setup.sh):
#   1. gcloud CLI installed and authenticated:
#        gcloud auth login
#        gcloud config set project <YOUR_PROJECT_ID>
#
#   2. Service accounts exist with correct IAM roles:
#        hw5-server-sa     – storage.objectViewer, pubsub.publisher,
#                            logging.logWriter, cloudsql.client
#        hw5-subscriber-sa – pubsub.subscriber, storage.objectViewer,
#                            logging.logWriter, plus objectAdmin on the
#                            GCS bucket
#        hw5-db-stopper-sa – cloudsql.admin, logging.logWriter
#
#   3. Pub/Sub topic "forbidden-requests" and subscription
#      "forbidden-requests-sub" exist.
#
#   4. Cloud SQL instance "hw5-db" exists (can be stopped).
#
#   5. Code bucket gs://<PROJECT_ID>-hw5-code/hw5/ contains the latest
#      server.py, subscriber.py, and requirements files.
#      To refresh:  cd hw5/ && bash setup.sh   (or manually gsutil cp)
#
#   6. Static IP "hw5-server-ip" and firewall rule "hw5-allow-http-8080"
#      exist.
#
# Usage:
#   cd hw5/
#   bash start_all.sh
#
# The script is idempotent — safe to run multiple times.
# ============================================================================
set -euo pipefail

PROJECT_ID=$(gcloud config get-value project 2>/dev/null)
if [ -z "${PROJECT_ID}" ]; then
    echo "ERROR: No active GCP project. Run: gcloud config set project <ID>" >&2
    exit 1
fi

REGION="us-central1"
ZONE="us-central1-a"

GCS_BUCKET="cs528-jx3onj-hw2"
CODE_BUCKET="${PROJECT_ID}-hw5-code"

SERVER_SA="hw5-server-sa@${PROJECT_ID}.iam.gserviceaccount.com"
SUBSCRIBER_SA="hw5-subscriber-sa@${PROJECT_ID}.iam.gserviceaccount.com"

SERVER_VM="hw5-server-vm"
SUBSCRIBER_VM="hw5-subscriber-vm"
CLIENT_VM="hw5-client-vm"

STATIC_IP_NAME="hw5-server-ip"
TOPIC_ID="forbidden-requests"
SUBSCRIPTION_ID="forbidden-requests-sub"

DB_INSTANCE="hw5-db"
DB_NAME="hw5db"
DB_USER="hw5user"
DB_PASS="${DB_PASS:-hw5pass123}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "============================================================"
echo " HW5 start_all   project=${PROJECT_ID}"
echo "============================================================"

# ---- 1. Upload latest code ---------------------------------------------------
echo "[1/5] Uploading latest code to gs://${CODE_BUCKET}/hw5/ …"
gsutil -m cp \
    "${SCRIPT_DIR}/server.py" \
    "${SCRIPT_DIR}/subscriber.py" \
    "${SCRIPT_DIR}/http_client.py" \
    "${SCRIPT_DIR}/stress_test.sh" \
    "${SCRIPT_DIR}/requirements_server.txt" \
    "${SCRIPT_DIR}/requirements_subscriber.txt" \
    "gs://${CODE_BUCKET}/hw5/" 2>&1 | tail -1

# ---- 2. Start Cloud SQL ------------------------------------------------------
echo "[2/5] Starting Cloud SQL instance '${DB_INSTANCE}' …"
DB_STATE=$(gcloud sql instances describe "${DB_INSTANCE}" \
    --project="${PROJECT_ID}" --format="value(state)" 2>/dev/null || echo "MISSING")

if [ "${DB_STATE}" = "RUNNABLE" ]; then
    echo "  Already running."
elif [ "${DB_STATE}" = "MISSING" ]; then
    echo "  ERROR: Instance '${DB_INSTANCE}' not found. Run setup.sh first." >&2
    exit 1
else
    gcloud sql instances patch "${DB_INSTANCE}" \
        --activation-policy=ALWAYS --project="${PROJECT_ID}" --quiet 2>/dev/null || true
    echo "  Activation policy set to ALWAYS. Waiting for RUNNABLE …"
    while true; do
        S=$(gcloud sql instances describe "${DB_INSTANCE}" \
            --project="${PROJECT_ID}" --format="value(state)" 2>/dev/null)
        [ "${S}" = "RUNNABLE" ] && break
        printf "."
        sleep 10
    done
    echo "  Running."
fi

DB_PRIVATE_IP=$(gcloud sql instances describe "${DB_INSTANCE}" \
    --project="${PROJECT_ID}" --format="value(ipAddresses[0].ipAddress)")
echo "  Cloud SQL private IP = ${DB_PRIVATE_IP}"

DB_META="db-host=${DB_PRIVATE_IP},db-port=5432,db-name=${DB_NAME},db-user=${DB_USER},db-pass=${DB_PASS}"

# ---- 3. Pause the hourly DB-stopper so it doesn't kill the DB ----------------
echo "[3/5] Pausing Cloud Scheduler stop-db job …"
gcloud scheduler jobs pause stop-hw5-db-job \
    --location="${REGION}" --project="${PROJECT_ID}" 2>/dev/null \
    || echo "  (job not found or already paused)"

# ---- 4. Get static IP --------------------------------------------------------
STATIC_IP=$(gcloud compute addresses describe "${STATIC_IP_NAME}" \
    --region="${REGION}" --project="${PROJECT_ID}" --format="value(address)" 2>/dev/null || echo "")

# ---- 5. Create or start VMs --------------------------------------------------
echo "[4/5] Starting VMs …"

start_or_create_vm() {
    local VM_NAME="$1"; shift
    if gcloud compute instances describe "${VM_NAME}" --zone="${ZONE}" --project="${PROJECT_ID}" &>/dev/null; then
        local STATUS
        STATUS=$(gcloud compute instances describe "${VM_NAME}" \
            --zone="${ZONE}" --project="${PROJECT_ID}" --format="value(status)")
        if [ "${STATUS}" = "RUNNING" ]; then
            echo "  ${VM_NAME}: already running"
        else
            echo "  ${VM_NAME}: starting …"
            gcloud compute instances start "${VM_NAME}" \
                --zone="${ZONE}" --project="${PROJECT_ID}" --quiet
        fi
    else
        echo "  ${VM_NAME}: creating …"
        gcloud compute instances create "${VM_NAME}" \
            --zone="${ZONE}" --project="${PROJECT_ID}" "$@"
    fi
}

# Server VM
start_or_create_vm "${SERVER_VM}" \
    --machine-type=e2-small \
    --service-account="${SERVER_SA}" \
    --scopes=cloud-platform \
    --address="${STATIC_IP}" \
    --tags=hw5-server \
    --image-family=debian-12 --image-project=debian-cloud \
    --metadata="vm-role=server,code-bucket=${CODE_BUCKET},gcs-bucket=${GCS_BUCKET},gcp-project=${PROJECT_ID},pubsub-topic=${TOPIC_ID},${DB_META}" \
    --metadata-from-file="startup-script=${SCRIPT_DIR}/startup.sh"

SERVER_INTERNAL_IP=$(gcloud compute instances describe "${SERVER_VM}" \
    --zone="${ZONE}" --project="${PROJECT_ID}" \
    --format="value(networkInterfaces[0].networkIP)")

# Subscriber VM
start_or_create_vm "${SUBSCRIBER_VM}" \
    --machine-type=e2-micro \
    --service-account="${SUBSCRIBER_SA}" \
    --scopes=cloud-platform \
    --no-address \
    --image-family=debian-12 --image-project=debian-cloud \
    --metadata="vm-role=subscriber,code-bucket=${CODE_BUCKET},gcs-bucket=${GCS_BUCKET},gcp-project=${PROJECT_ID},pubsub-subscription=${SUBSCRIPTION_ID}" \
    --metadata-from-file="startup-script=${SCRIPT_DIR}/startup.sh"

# Client VM
start_or_create_vm "${CLIENT_VM}" \
    --machine-type=e2-micro \
    --scopes=storage-ro \
    --no-address \
    --image-family=debian-12 --image-project=debian-cloud \
    --metadata="vm-role=client,code-bucket=${CODE_BUCKET},server-ip=${SERVER_INTERNAL_IP}" \
    --metadata-from-file="startup-script=${SCRIPT_DIR}/startup.sh"

# ---- 6. Ensure services are running on existing VMs --------------------------
echo "[5/5] Ensuring services are running on VMs …"

# For VMs that already had the startup script run, restart the systemd services
# and pull the latest code from the bucket.  Timeout after 60s per VM since
# IAP tunneling to no-external-IP VMs can be slow.
timeout 60 gcloud compute ssh "${SERVER_VM}" --zone="${ZONE}" --project="${PROJECT_ID}" \
    --command="
        sudo gsutil -m cp 'gs://${CODE_BUCKET}/hw5/*' /opt/hw5/ 2>/dev/null || true
        sudo systemctl restart hw5-server 2>/dev/null || true
        echo 'hw5-server restarted'
    " 2>/dev/null || echo "  (server VM not reachable via SSH — startup script will handle it)"

timeout 60 gcloud compute ssh "${SUBSCRIBER_VM}" --zone="${ZONE}" --project="${PROJECT_ID}" \
    --command="
        sudo gsutil -m cp 'gs://${CODE_BUCKET}/hw5/*' /opt/hw5/ 2>/dev/null || true
        sudo systemctl restart hw5-subscriber 2>/dev/null || true
        echo 'hw5-subscriber restarted'
    " 2>/dev/null || echo "  (subscriber VM not reachable via SSH — startup script will handle it)"

# ---- Summary ------------------------------------------------------------------
echo ""
echo "============================================================"
echo " All services started!"
echo "============================================================"
echo ""
echo " Cloud SQL : ${DB_INSTANCE} → ${DB_PRIVATE_IP}:5432/${DB_NAME}"
echo " Server VM : ${SERVER_VM} → http://${STATIC_IP:-<pending>}:8080"
echo " Subscriber: ${SUBSCRIBER_VM}"
echo " Client    : ${CLIENT_VM}"
echo ""
echo " If VMs were just created, wait ~3-5 min for startup scripts."
echo ""
echo " Test:"
echo "   curl -i http://${STATIC_IP:-<IP>}:8080/pages/page_00001.json"
echo ""
echo " Stress test (from client VM):"
echo "   gcloud compute ssh ${CLIENT_VM} --zone=${ZONE} --tunnel-through-iap"
echo "   bash /opt/hw5/stress_test.sh ${SERVER_INTERNAL_IP} 42 50000"
echo ""
