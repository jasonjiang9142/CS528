#!/usr/bin/env bash
# ============================================================================
# cleanup.sh  –  Tear down ALL HW4 infrastructure created by setup.sh.
#
# Usage:
#   cd hw4/
#   bash cleanup.sh
# ============================================================================
set -euo pipefail

PROJECT_ID=$(gcloud config get-value project 2>/dev/null)
if [ -z "${PROJECT_ID}" ]; then
    echo "ERROR: No active GCP project." >&2
    exit 1
fi

REGION="us-central1"
ZONE="us-central1-a"
GCS_BUCKET="cs528-jx3onj-hw2"
CODE_BUCKET="${PROJECT_ID}-hw4-code"

SERVER_SA_NAME="hw4-server-sa"
SUBSCRIBER_SA_NAME="hw4-subscriber-sa"
SERVER_SA="${SERVER_SA_NAME}@${PROJECT_ID}.iam.gserviceaccount.com"
SUBSCRIBER_SA="${SUBSCRIBER_SA_NAME}@${PROJECT_ID}.iam.gserviceaccount.com"

SERVER_VM="hw4-server-vm"
SUBSCRIBER_VM="hw4-subscriber-vm"
CLIENT_VM="hw4-client-vm"
STATIC_IP_NAME="hw4-server-ip"
FIREWALL_RULE="hw4-allow-http-8080"
TOPIC_ID="forbidden-requests"
SUBSCRIPTION_ID="forbidden-requests-sub"

echo "============================================================"
echo " HW4 cleanup   project=${PROJECT_ID}"
echo "============================================================"

# ---------------------------------------------------------------------------
# 1. Delete VMs
# ---------------------------------------------------------------------------
echo "[1/7] Deleting VMs …"
for VM in "${SERVER_VM}" "${SUBSCRIBER_VM}" "${CLIENT_VM}"; do
    gcloud compute instances delete "${VM}" \
        --zone="${ZONE}" --project="${PROJECT_ID}" --quiet 2>/dev/null \
        || echo "  ${VM} not found or already deleted"
done

# ---------------------------------------------------------------------------
# 2. Delete firewall rule
# ---------------------------------------------------------------------------
echo "[2/7] Deleting firewall rule …"
gcloud compute firewall-rules delete "${FIREWALL_RULE}" \
    --project="${PROJECT_ID}" --quiet 2>/dev/null \
    || echo "  rule not found"

# ---------------------------------------------------------------------------
# 3. Release static IP
# ---------------------------------------------------------------------------
echo "[3/7] Releasing static IP …"
gcloud compute addresses delete "${STATIC_IP_NAME}" \
    --region="${REGION}" --project="${PROJECT_ID}" --quiet 2>/dev/null \
    || echo "  IP not found"

# ---------------------------------------------------------------------------
# 4. Delete Pub/Sub resources
# ---------------------------------------------------------------------------
echo "[4/7] Deleting Pub/Sub resources …"
gcloud pubsub subscriptions delete "${SUBSCRIPTION_ID}" \
    --project="${PROJECT_ID}" --quiet 2>/dev/null || true
gcloud pubsub topics delete "${TOPIC_ID}" \
    --project="${PROJECT_ID}" --quiet 2>/dev/null || true

# ---------------------------------------------------------------------------
# 5. Delete staging bucket
# ---------------------------------------------------------------------------
echo "[5/7] Deleting staging bucket …"
gsutil -m rm -r "gs://${CODE_BUCKET}" 2>/dev/null \
    || echo "  bucket not found"

# ---------------------------------------------------------------------------
# 6. Remove IAM bindings
# ---------------------------------------------------------------------------
echo "[6/7] Removing IAM bindings …"

for ROLE in roles/storage.objectViewer roles/pubsub.publisher roles/logging.logWriter; do
    gcloud projects remove-iam-policy-binding "${PROJECT_ID}" \
        --member="serviceAccount:${SERVER_SA}" \
        --role="${ROLE}" --quiet 2>/dev/null || true
done

for ROLE in roles/pubsub.subscriber roles/storage.objectViewer roles/logging.logWriter; do
    gcloud projects remove-iam-policy-binding "${PROJECT_ID}" \
        --member="serviceAccount:${SUBSCRIBER_SA}" \
        --role="${ROLE}" --quiet 2>/dev/null || true
done

# Bucket-level binding
gsutil iam ch -d \
    "serviceAccount:${SUBSCRIBER_SA}:roles/storage.objectAdmin" \
    "gs://${GCS_BUCKET}" 2>/dev/null || true

# ---------------------------------------------------------------------------
# 7. Delete service accounts
# ---------------------------------------------------------------------------
echo "[7/7] Deleting service accounts …"
gcloud iam service-accounts delete "${SERVER_SA}" \
    --project="${PROJECT_ID}" --quiet 2>/dev/null \
    || echo "  server SA not found"

gcloud iam service-accounts delete "${SUBSCRIBER_SA}" \
    --project="${PROJECT_ID}" --quiet 2>/dev/null \
    || echo "  subscriber SA not found"

echo ""
echo "============================================================"
echo " Cleanup complete."
echo "============================================================"
