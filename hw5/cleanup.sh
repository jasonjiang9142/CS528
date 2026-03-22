#!/usr/bin/env bash
# ============================================================================
# cleanup.sh  –  Tear down ALL HW5 infrastructure.
# Usage:   cd hw5/ && bash cleanup.sh
# ============================================================================
set -euo pipefail

PROJECT_ID=$(gcloud config get-value project 2>/dev/null)
if [ -z "${PROJECT_ID}" ]; then echo "ERROR: No project." >&2; exit 1; fi

REGION="us-central1"
ZONE="us-central1-a"
GCS_BUCKET="cs528-jx3onj-hw2"
CODE_BUCKET="${PROJECT_ID}-hw5-code"

SERVER_SA_NAME="hw5-server-sa"
SUBSCRIBER_SA_NAME="hw5-subscriber-sa"
STOPPER_SA_NAME="hw5-db-stopper-sa"
SERVER_SA="${SERVER_SA_NAME}@${PROJECT_ID}.iam.gserviceaccount.com"
SUBSCRIBER_SA="${SUBSCRIBER_SA_NAME}@${PROJECT_ID}.iam.gserviceaccount.com"
STOPPER_SA="${STOPPER_SA_NAME}@${PROJECT_ID}.iam.gserviceaccount.com"

SERVER_VM="hw5-server-vm"
SUBSCRIBER_VM="hw5-subscriber-vm"
CLIENT_VM="hw5-client-vm"
STATIC_IP_NAME="hw5-server-ip"
FIREWALL_RULE="hw5-allow-http-8080"
TOPIC_ID="forbidden-requests"
SUBSCRIPTION_ID="forbidden-requests-sub"
DB_INSTANCE="hw5-db"

echo "============================================================"
echo " HW5 cleanup   project=${PROJECT_ID}"
echo "============================================================"

# 1 ─ Cloud Scheduler
echo "[1/9] Deleting Cloud Scheduler job …"
gcloud scheduler jobs delete stop-hw5-db-job \
    --location="${REGION}" --project="${PROJECT_ID}" --quiet 2>/dev/null || true

# 2 ─ Cloud Function
echo "[2/9] Deleting Cloud Function …"
gcloud functions delete stop-hw5-db --gen2 \
    --region="${REGION}" --project="${PROJECT_ID}" --quiet 2>/dev/null || true

# 3 ─ VMs
echo "[3/9] Deleting VMs …"
for VM in "${SERVER_VM}" "${SUBSCRIBER_VM}" "${CLIENT_VM}"; do
    gcloud compute instances delete "${VM}" \
        --zone="${ZONE}" --project="${PROJECT_ID}" --quiet 2>/dev/null \
        || echo "  ${VM} not found"
done

# 4 ─ Firewall + static IP
echo "[4/9] Deleting networking resources …"
gcloud compute firewall-rules delete "${FIREWALL_RULE}" \
    --project="${PROJECT_ID}" --quiet 2>/dev/null || true
gcloud compute addresses delete "${STATIC_IP_NAME}" \
    --region="${REGION}" --project="${PROJECT_ID}" --quiet 2>/dev/null || true

# 5 ─ Cloud SQL
echo "[5/9] Deleting Cloud SQL instance (this takes a few minutes) …"
gcloud sql instances delete "${DB_INSTANCE}" \
    --project="${PROJECT_ID}" --quiet 2>/dev/null || true

# 6 ─ Pub/Sub
echo "[6/9] Deleting Pub/Sub resources …"
gcloud pubsub subscriptions delete "${SUBSCRIPTION_ID}" \
    --project="${PROJECT_ID}" --quiet 2>/dev/null || true
gcloud pubsub topics delete "${TOPIC_ID}" \
    --project="${PROJECT_ID}" --quiet 2>/dev/null || true

# 7 ─ Staging bucket
echo "[7/9] Deleting staging bucket …"
gsutil -m rm -r "gs://${CODE_BUCKET}" 2>/dev/null || true

# 8 ─ IAM bindings
echo "[8/9] Removing IAM bindings …"
for ROLE in roles/storage.objectViewer roles/pubsub.publisher roles/logging.logWriter roles/cloudsql.client; do
    gcloud projects remove-iam-policy-binding "${PROJECT_ID}" \
        --member="serviceAccount:${SERVER_SA}" --role="${ROLE}" --quiet 2>/dev/null || true
done
for ROLE in roles/pubsub.subscriber roles/storage.objectViewer roles/logging.logWriter; do
    gcloud projects remove-iam-policy-binding "${PROJECT_ID}" \
        --member="serviceAccount:${SUBSCRIBER_SA}" --role="${ROLE}" --quiet 2>/dev/null || true
done
gsutil iam ch -d "serviceAccount:${SUBSCRIBER_SA}:roles/storage.objectAdmin" \
    "gs://${GCS_BUCKET}" 2>/dev/null || true
for ROLE in roles/cloudsql.admin roles/logging.logWriter; do
    gcloud projects remove-iam-policy-binding "${PROJECT_ID}" \
        --member="serviceAccount:${STOPPER_SA}" --role="${ROLE}" --quiet 2>/dev/null || true
done

# 9 ─ Service accounts
echo "[9/9] Deleting service accounts …"
for SA in "${SERVER_SA}" "${SUBSCRIBER_SA}" "${STOPPER_SA}"; do
    gcloud iam service-accounts delete "${SA}" \
        --project="${PROJECT_ID}" --quiet 2>/dev/null || true
done

echo ""
echo "============================================================"
echo " Cleanup complete."
echo "============================================================"
