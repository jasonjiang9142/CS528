#!/usr/bin/env bash
# ============================================================================
# cleanup.sh – Tear down all HW8 infrastructure.
#
# Usage:
#   cd hw8/
#   bash cleanup.sh
# ============================================================================
set -euo pipefail

PROJECT_ID=$(gcloud config get-value project 2>/dev/null)
if [ -z "${PROJECT_ID}" ]; then
    echo "ERROR: No active GCP project." >&2
    exit 1
fi

REGION="us-central1"
ZONE_A="us-central1-a"
ZONE_B="us-central1-b"

VM_A="hw8-server-a"
VM_B="hw8-server-b"
FIREWALL_RULE="hw8-allow-http-8080"
HEALTH_CHECK="hw8-http-health-check"
TARGET_POOL="hw8-target-pool"
FORWARDING_RULE="hw8-forwarding-rule"

echo "============================================================"
echo " HW8 cleanup   project=${PROJECT_ID}"
echo "============================================================"

echo "[1/5] Deleting forwarding rule …"
gcloud compute forwarding-rules delete "${FORWARDING_RULE}" \
    --region="${REGION}" --project="${PROJECT_ID}" --quiet 2>/dev/null \
    || echo "  not found"

echo "[2/5] Deleting target pool …"
gcloud compute target-pools delete "${TARGET_POOL}" \
    --region="${REGION}" --project="${PROJECT_ID}" --quiet 2>/dev/null \
    || echo "  not found"

echo "[3/5] Deleting health check …"
gcloud compute http-health-checks delete "${HEALTH_CHECK}" \
    --project="${PROJECT_ID}" --quiet 2>/dev/null \
    || echo "  not found"

echo "[4/5] Deleting VMs …"
gcloud compute instances delete "${VM_A}" \
    --zone="${ZONE_A}" --project="${PROJECT_ID}" --quiet 2>/dev/null \
    || echo "  ${VM_A} not found"
gcloud compute instances delete "${VM_B}" \
    --zone="${ZONE_B}" --project="${PROJECT_ID}" --quiet 2>/dev/null \
    || echo "  ${VM_B} not found"

echo "[5/5] Deleting firewall rule …"
gcloud compute firewall-rules delete "${FIREWALL_RULE}" \
    --project="${PROJECT_ID}" --quiet 2>/dev/null \
    || echo "  not found"

echo ""
echo "============================================================"
echo " HW8 cleanup complete."
echo "============================================================"
echo ""
echo "Note: HW4 shared resources (service accounts, Pub/Sub, data"
echo "bucket, staging bucket) are NOT deleted. Run hw4/cleanup.sh"
echo "to remove those."
