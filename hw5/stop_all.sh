#!/usr/bin/env bash
# ============================================================================
# stop_all.sh  –  Stop the Cloud SQL database, all VMs, and re-enable the
#                  hourly DB-stopper scheduler job as a safety net.
#
# This does NOT delete any resources — it only stops them so they stop
# incurring charges.  Run start_all.sh to bring everything back up.
#
# Usage:
#   cd hw5/
#   bash stop_all.sh
# ============================================================================
set -euo pipefail

PROJECT_ID=$(gcloud config get-value project 2>/dev/null)
if [ -z "${PROJECT_ID}" ]; then
    echo "ERROR: No active GCP project. Run: gcloud config set project <ID>" >&2
    exit 1
fi

REGION="us-central1"
ZONE="us-central1-a"

SERVER_VM="hw5-server-vm"
SUBSCRIBER_VM="hw5-subscriber-vm"
CLIENT_VM="hw5-client-vm"

DB_INSTANCE="hw5-db"

echo "============================================================"
echo " HW5 stop_all   project=${PROJECT_ID}"
echo "============================================================"

# ---- 1. Stop VMs -------------------------------------------------------------
echo "[1/3] Stopping VMs …"
for VM in "${SERVER_VM}" "${SUBSCRIBER_VM}" "${CLIENT_VM}"; do
    STATUS=$(gcloud compute instances describe "${VM}" \
        --zone="${ZONE}" --project="${PROJECT_ID}" \
        --format="value(status)" 2>/dev/null || echo "NOT_FOUND")
    if [ "${STATUS}" = "RUNNING" ]; then
        echo "  Stopping ${VM} …"
        gcloud compute instances stop "${VM}" \
            --zone="${ZONE}" --project="${PROJECT_ID}" --quiet &
    elif [ "${STATUS}" = "NOT_FOUND" ]; then
        echo "  ${VM}: does not exist (skipping)"
    else
        echo "  ${VM}: already ${STATUS}"
    fi
done
wait
echo "  All VMs stopped."

# ---- 2. Stop Cloud SQL -------------------------------------------------------
echo "[2/3] Stopping Cloud SQL instance '${DB_INSTANCE}' …"
DB_STATE=$(gcloud sql instances describe "${DB_INSTANCE}" \
    --project="${PROJECT_ID}" --format="value(state)" 2>/dev/null || echo "NOT_FOUND")

if [ "${DB_STATE}" = "RUNNABLE" ]; then
    gcloud sql instances patch "${DB_INSTANCE}" \
        --activation-policy=NEVER --project="${PROJECT_ID}" --quiet
    echo "  Stopped (activation-policy=NEVER)."
elif [ "${DB_STATE}" = "NOT_FOUND" ]; then
    echo "  Instance not found (skipping)."
else
    echo "  Already ${DB_STATE}."
fi

# ---- 3. Resume the hourly DB-stopper -----------------------------------------
echo "[3/3] Resuming Cloud Scheduler stop-db job (safety net) …"
gcloud scheduler jobs resume stop-hw5-db-job \
    --location="${REGION}" --project="${PROJECT_ID}" 2>/dev/null \
    || echo "  (job not found — skipping)"

echo ""
echo "============================================================"
echo " Everything stopped."
echo "============================================================"
echo ""
echo " To restart later:  bash start_all.sh"
echo ""
