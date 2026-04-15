#!/usr/bin/env bash
# ============================================================================
# setup.sh – HW8: Two web-server VMs behind a Network Load Balancer.
#
# Builds on HW4 infrastructure (reuses service accounts, Pub/Sub, data bucket).
# Creates two server VMs in different zones, places them behind an external
# passthrough Network Load Balancer using a target pool with HTTP health checks.
#
# Prerequisites:
#   - gcloud CLI authenticated
#   - gcloud config set project <PROJECT_ID>
#   - HW4 infra already exists (service accounts, Pub/Sub, data bucket)
#     OR at minimum: the data bucket gs://cs528-jx3onj-hw2 with pages/*.json
#
# Usage:
#   cd hw8/
#   bash setup.sh
# ============================================================================
set -euo pipefail

PROJECT_ID=$(gcloud config get-value project 2>/dev/null)
if [ -z "${PROJECT_ID}" ]; then
    echo "ERROR: No active GCP project. Run: gcloud config set project YOUR_PROJECT_ID" >&2
    exit 1
fi

REGION="us-central1"
ZONE_A="us-central1-a"
ZONE_B="us-central1-b"

GCS_BUCKET="cs528-jx3onj-hw2"
CODE_BUCKET="${PROJECT_ID}-hw4-code"

SERVER_SA_NAME="hw4-server-sa"
SERVER_SA="${SERVER_SA_NAME}@${PROJECT_ID}.iam.gserviceaccount.com"

VM_A="hw8-server-a"
VM_B="hw8-server-b"

FIREWALL_RULE="hw8-allow-http-8080"
HEALTH_CHECK="hw8-http-health-check"
TARGET_POOL="hw8-target-pool"
FORWARDING_RULE="hw8-forwarding-rule"

TOPIC_ID="forbidden-requests"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "============================================================"
echo " HW8 setup   project=${PROJECT_ID}   region=${REGION}"
echo " zone-a: ${ZONE_A}   zone-b: ${ZONE_B}"
echo "============================================================"

# ---------------------------------------------------------------------------
# 1. Enable APIs
# ---------------------------------------------------------------------------
echo "[1/8] Enabling APIs …"
gcloud services enable \
    compute.googleapis.com \
    pubsub.googleapis.com \
    logging.googleapis.com \
    storage.googleapis.com \
    --project="${PROJECT_ID}" --quiet

# ---------------------------------------------------------------------------
# 2. Ensure service account + IAM (reuse from HW4)
# ---------------------------------------------------------------------------
echo "[2/8] Ensuring service account …"
gcloud iam service-accounts create "${SERVER_SA_NAME}" \
    --display-name="HW4 Server SA" \
    --project="${PROJECT_ID}" 2>/dev/null || echo "  (SA already exists)"

for ROLE in roles/storage.objectViewer roles/pubsub.publisher roles/logging.logWriter; do
    gcloud projects add-iam-policy-binding "${PROJECT_ID}" \
        --member="serviceAccount:${SERVER_SA}" \
        --role="${ROLE}" --quiet > /dev/null
done

# ---------------------------------------------------------------------------
# 3. Ensure Pub/Sub (reuse from HW4)
# ---------------------------------------------------------------------------
echo "[3/8] Ensuring Pub/Sub …"
gcloud pubsub topics create "${TOPIC_ID}" \
    --project="${PROJECT_ID}" 2>/dev/null || echo "  (topic already exists)"
gcloud pubsub subscriptions create "forbidden-requests-sub" \
    --topic="${TOPIC_ID}" \
    --project="${PROJECT_ID}" 2>/dev/null || echo "  (subscription already exists)"

# ---------------------------------------------------------------------------
# 4. Upload HW8 code to staging bucket
# ---------------------------------------------------------------------------
echo "[4/8] Uploading code to gs://${CODE_BUCKET}/hw8/ …"
gsutil mb -p "${PROJECT_ID}" -l "${REGION}" "gs://${CODE_BUCKET}" 2>/dev/null \
    || echo "  (bucket already exists)"

gsutil -m cp \
    "${SCRIPT_DIR}/server.py" \
    "${SCRIPT_DIR}/requirements_server.txt" \
    "gs://${CODE_BUCKET}/hw8/"

# ---------------------------------------------------------------------------
# 5. Firewall: allow health-check probes + external traffic on 8080
# ---------------------------------------------------------------------------
echo "[5/8] Creating firewall rule …"
# GCP health check probes come from 169.254.169.254, 35.191.0.0/16, 130.211.0.0/22
gcloud compute firewall-rules create "${FIREWALL_RULE}" \
    --allow=tcp:8080 \
    --target-tags=hw8-server \
    --source-ranges=0.0.0.0/0 \
    --description="Allow HTTP 8080 to HW8 servers (includes health check probes)" \
    --project="${PROJECT_ID}" 2>/dev/null || echo "  (rule already exists)"

# ---------------------------------------------------------------------------
# 6. Create two server VMs in different zones
# ---------------------------------------------------------------------------
echo "[6/8] Creating VMs …"

gcloud compute networks subnets update default \
    --region="${REGION}" \
    --enable-private-google-access \
    --project="${PROJECT_ID}" --quiet 2>/dev/null || true

create_server_vm() {
    local vm_name="$1" zone="$2"
    echo "  Creating ${vm_name} in ${zone} …"
    if gcloud compute instances describe "${vm_name}" --zone="${zone}" --project="${PROJECT_ID}" &>/dev/null; then
        echo "    (already exists, skipping)"
        return
    fi
    gcloud compute instances create "${vm_name}" \
        --zone="${zone}" \
        --machine-type=e2-micro \
        --service-account="${SERVER_SA}" \
        --scopes=cloud-platform \
        --tags=hw8-server \
        --image-family=debian-12 \
        --image-project=debian-cloud \
        --metadata="vm-role=server,code-bucket=${CODE_BUCKET},gcs-bucket=${GCS_BUCKET},gcp-project=${PROJECT_ID},pubsub-topic=${TOPIC_ID}" \
        --metadata-from-file="startup-script=${SCRIPT_DIR}/startup.sh" \
        --project="${PROJECT_ID}"
}

create_server_vm "${VM_A}" "${ZONE_A}"
create_server_vm "${VM_B}" "${ZONE_B}"

# ---------------------------------------------------------------------------
# 7. Create legacy HTTP health check + target pool + forwarding rule
# ---------------------------------------------------------------------------
echo "[7/8] Creating Network Load Balancer (target pool) …"

echo "  HTTP health check …"
gcloud compute http-health-checks create "${HEALTH_CHECK}" \
    --port=8080 \
    --request-path="/health" \
    --check-interval=5 \
    --timeout=5 \
    --healthy-threshold=2 \
    --unhealthy-threshold=3 \
    --project="${PROJECT_ID}" 2>/dev/null \
    || echo "  (health check already exists)"

echo "  Target pool …"
gcloud compute target-pools create "${TARGET_POOL}" \
    --region="${REGION}" \
    --http-health-check="${HEALTH_CHECK}" \
    --project="${PROJECT_ID}" 2>/dev/null \
    || echo "  (target pool already exists)"

echo "  Adding instances to target pool …"
gcloud compute target-pools add-instances "${TARGET_POOL}" \
    --instances="${VM_A}" \
    --instances-zone="${ZONE_A}" \
    --region="${REGION}" \
    --project="${PROJECT_ID}" 2>/dev/null \
    || echo "  (${VM_A} already in pool)"

gcloud compute target-pools add-instances "${TARGET_POOL}" \
    --instances="${VM_B}" \
    --instances-zone="${ZONE_B}" \
    --region="${REGION}" \
    --project="${PROJECT_ID}" 2>/dev/null \
    || echo "  (${VM_B} already in pool)"

echo "  Forwarding rule …"
gcloud compute forwarding-rules create "${FORWARDING_RULE}" \
    --region="${REGION}" \
    --ports=8080 \
    --target-pool="${TARGET_POOL}" \
    --project="${PROJECT_ID}" 2>/dev/null \
    || echo "  (forwarding rule already exists)"

# ---------------------------------------------------------------------------
# 8. Print summary
# ---------------------------------------------------------------------------
LB_IP=$(gcloud compute forwarding-rules describe "${FORWARDING_RULE}" \
    --region="${REGION}" --project="${PROJECT_ID}" --format="value(IPAddress)" 2>/dev/null || echo "???")

echo ""
echo "============================================================"
echo " HW8 setup complete!"
echo "============================================================"
echo ""
echo "  VM-A: ${VM_A} (${ZONE_A})"
echo "  VM-B: ${VM_B} (${ZONE_B})"
echo "  Load Balancer IP: ${LB_IP}:8080"
echo ""
echo "Wait ~2-3 minutes for startup scripts to finish, then test:"
echo ""
echo "  curl -i http://${LB_IP}:8080/pages/page_00001.json"
echo ""
echo "  Look for the X-Server-Zone header in the response."
echo ""
echo "Run the load-balancer client (from your laptop):"
echo ""
echo "  python3 lb_client.py --url http://${LB_IP}:8080 --duration 60"
echo ""
echo "To test failover:"
echo "  1. Keep lb_client.py running"
echo "  2. SSH into ${VM_A}: gcloud compute ssh ${VM_A} --zone=${ZONE_A}"
echo "  3. Stop the server:  sudo systemctl stop hw8-server"
echo "  4. Watch lb_client.py for zone/error changes"
echo "  5. Restart server:   sudo systemctl start hw8-server"
echo "  6. Watch lb_client.py for zone recovery"
