#!/usr/bin/env bash
# ============================================================================
# setup.sh  –  Provision ALL HW4 infrastructure in one command.
#
# Prerequisites:
#   - gcloud CLI authenticated  (gcloud auth login)
#   - A GCP project set          (gcloud config set project PROJECT_ID)
#   - HW2 bucket already exists  (gs://cs528-jx3onj-hw2  with pages/*.json)
#
# Usage:
#   cd hw4/
#   bash setup.sh
# ============================================================================
set -euo pipefail

# ---------------------------------------------------------------------------
# Variables  (auto-detected where possible)
# ---------------------------------------------------------------------------
PROJECT_ID=$(gcloud config get-value project 2>/dev/null)
if [ -z "${PROJECT_ID}" ]; then
    echo "ERROR: No active GCP project. Run:  gcloud config set project YOUR_PROJECT_ID" >&2
    exit 1
fi

REGION="us-central1"
ZONE="us-central1-a"

# Existing HW2 data bucket
GCS_BUCKET="cs528-jx3onj-hw2"

# Staging bucket for uploading code to VMs
CODE_BUCKET="${PROJECT_ID}-hw4-code"

# Service account names
SERVER_SA_NAME="hw4-server-sa"
SUBSCRIBER_SA_NAME="hw4-subscriber-sa"
SERVER_SA="${SERVER_SA_NAME}@${PROJECT_ID}.iam.gserviceaccount.com"
SUBSCRIBER_SA="${SUBSCRIBER_SA_NAME}@${PROJECT_ID}.iam.gserviceaccount.com"

# VM names
SERVER_VM="hw4-server-vm"
SUBSCRIBER_VM="hw4-subscriber-vm"
CLIENT_VM="hw4-client-vm"

# Networking
STATIC_IP_NAME="hw4-server-ip"
FIREWALL_RULE="hw4-allow-http-8080"

# Pub/Sub
TOPIC_ID="forbidden-requests"
SUBSCRIPTION_ID="forbidden-requests-sub"

echo "============================================================"
echo " HW4 setup   project=${PROJECT_ID}   region=${REGION}"
echo "============================================================"

# ---------------------------------------------------------------------------
# 1. Enable required APIs
# ---------------------------------------------------------------------------
echo "[1/9] Enabling APIs …"
gcloud services enable \
    compute.googleapis.com \
    pubsub.googleapis.com \
    logging.googleapis.com \
    storage.googleapis.com \
    --project="${PROJECT_ID}" --quiet

# ---------------------------------------------------------------------------
# 2. Create service accounts
# ---------------------------------------------------------------------------
echo "[2/9] Creating service accounts …"
gcloud iam service-accounts create "${SERVER_SA_NAME}" \
    --display-name="HW4 Server SA" \
    --project="${PROJECT_ID}" 2>/dev/null || echo "  (server SA already exists)"

gcloud iam service-accounts create "${SUBSCRIBER_SA_NAME}" \
    --display-name="HW4 Subscriber SA" \
    --project="${PROJECT_ID}" 2>/dev/null || echo "  (subscriber SA already exists)"

# ---------------------------------------------------------------------------
# 3. Grant least-privilege IAM roles
# ---------------------------------------------------------------------------
echo "[3/9] Granting IAM roles …"

# Server SA: read GCS objects, publish to Pub/Sub, write logs
for ROLE in roles/storage.objectViewer roles/pubsub.publisher roles/logging.logWriter; do
    gcloud projects add-iam-policy-binding "${PROJECT_ID}" \
        --member="serviceAccount:${SERVER_SA}" \
        --role="${ROLE}" --quiet > /dev/null
done

# Subscriber SA: subscribe to Pub/Sub, read+write GCS objects, write logs
for ROLE in roles/pubsub.subscriber roles/storage.objectViewer roles/logging.logWriter; do
    gcloud projects add-iam-policy-binding "${PROJECT_ID}" \
        --member="serviceAccount:${SUBSCRIBER_SA}" \
        --role="${ROLE}" --quiet > /dev/null
done

# Bucket-level: subscriber needs objectAdmin only on the data bucket
gsutil iam ch \
    "serviceAccount:${SUBSCRIBER_SA}:roles/storage.objectAdmin" \
    "gs://${GCS_BUCKET}" 2>/dev/null || true

# ---------------------------------------------------------------------------
# 4. Create Pub/Sub topic + subscription
# ---------------------------------------------------------------------------
echo "[4/9] Creating Pub/Sub resources …"
gcloud pubsub topics create "${TOPIC_ID}" \
    --project="${PROJECT_ID}" 2>/dev/null || echo "  (topic already exists)"

gcloud pubsub subscriptions create "${SUBSCRIPTION_ID}" \
    --topic="${TOPIC_ID}" \
    --project="${PROJECT_ID}" 2>/dev/null || echo "  (subscription already exists)"

# ---------------------------------------------------------------------------
# 5. Upload application code to a staging bucket
# ---------------------------------------------------------------------------
echo "[5/9] Uploading code to gs://${CODE_BUCKET}/hw4/ …"
gsutil mb -p "${PROJECT_ID}" -l "${REGION}" "gs://${CODE_BUCKET}" 2>/dev/null \
    || echo "  (bucket already exists)"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
gsutil -m cp \
    "${SCRIPT_DIR}/server.py" \
    "${SCRIPT_DIR}/subscriber.py" \
    "${SCRIPT_DIR}/http_client.py" \
    "${SCRIPT_DIR}/stress_test.sh" \
    "${SCRIPT_DIR}/requirements_server.txt" \
    "${SCRIPT_DIR}/requirements_subscriber.txt" \
    "gs://${CODE_BUCKET}/hw4/"

# ---------------------------------------------------------------------------
# 6. Reserve a static external IP for the server
# ---------------------------------------------------------------------------
echo "[6/9] Reserving static IP …"
gcloud compute addresses create "${STATIC_IP_NAME}" \
    --region="${REGION}" \
    --project="${PROJECT_ID}" 2>/dev/null || echo "  (IP already reserved)"

STATIC_IP=$(gcloud compute addresses describe "${STATIC_IP_NAME}" \
    --region="${REGION}" --project="${PROJECT_ID}" --format="value(address)")

echo "  Static IP = ${STATIC_IP}"

# ---------------------------------------------------------------------------
# 7. Firewall rule: allow TCP 8080 to server
# ---------------------------------------------------------------------------
echo "[7/9] Creating firewall rule …"
gcloud compute firewall-rules create "${FIREWALL_RULE}" \
    --allow=tcp:8080 \
    --target-tags=hw4-server \
    --source-ranges=0.0.0.0/0 \
    --description="Allow HTTP 8080 to HW4 server" \
    --project="${PROJECT_ID}" 2>/dev/null || echo "  (rule already exists)"

# ---------------------------------------------------------------------------
# 8. Create VM instances
# ---------------------------------------------------------------------------
echo "[8/9] Creating VMs …"

# Enable Private Google Access so VMs without external IPs can reach GCS/APIs
echo "  Enabling Private Google Access on default subnet …"
gcloud compute networks subnets update default \
    --region="${REGION}" \
    --enable-private-google-access \
    --project="${PROJECT_ID}" --quiet 2>/dev/null || true

# --- Server VM (e2-micro, static IP, dedicated SA) ---
echo "  Creating ${SERVER_VM} …"
if gcloud compute instances describe "${SERVER_VM}" --zone="${ZONE}" --project="${PROJECT_ID}" &>/dev/null; then
    echo "    (already exists, skipping)"
else
    gcloud compute instances create "${SERVER_VM}" \
        --zone="${ZONE}" \
        --machine-type=e2-micro \
        --service-account="${SERVER_SA}" \
        --scopes=cloud-platform \
        --address="${STATIC_IP}" \
        --tags=hw4-server \
        --image-family=debian-12 \
        --image-project=debian-cloud \
        --metadata="vm-role=server,code-bucket=${CODE_BUCKET},gcs-bucket=${GCS_BUCKET},gcp-project=${PROJECT_ID},pubsub-topic=${TOPIC_ID}" \
        --metadata-from-file="startup-script=${SCRIPT_DIR}/startup.sh" \
        --project="${PROJECT_ID}"
fi

# Get the server's internal IP so the client can reach it within the VPC
SERVER_INTERNAL_IP=$(gcloud compute instances describe "${SERVER_VM}" \
    --zone="${ZONE}" --project="${PROJECT_ID}" \
    --format="value(networkInterfaces[0].networkIP)")
echo "  Server internal IP = ${SERVER_INTERNAL_IP}"

# --- Subscriber VM (e2-micro, dedicated SA, no external IP needed) ---
echo "  Creating ${SUBSCRIBER_VM} …"
if gcloud compute instances describe "${SUBSCRIBER_VM}" --zone="${ZONE}" --project="${PROJECT_ID}" &>/dev/null; then
    echo "    (already exists, skipping)"
else
    gcloud compute instances create "${SUBSCRIBER_VM}" \
        --zone="${ZONE}" \
        --machine-type=e2-micro \
        --service-account="${SUBSCRIBER_SA}" \
        --scopes=cloud-platform \
        --no-address \
        --image-family=debian-12 \
        --image-project=debian-cloud \
        --metadata="vm-role=subscriber,code-bucket=${CODE_BUCKET},gcs-bucket=${GCS_BUCKET},gcp-project=${PROJECT_ID},pubsub-subscription=${SUBSCRIPTION_ID}" \
        --metadata-from-file="startup-script=${SCRIPT_DIR}/startup.sh" \
        --project="${PROJECT_ID}"
fi

# --- Client VM (e2-micro, no external IP – uses internal IP to reach server) ---
echo "  Creating ${CLIENT_VM} …"
if gcloud compute instances describe "${CLIENT_VM}" --zone="${ZONE}" --project="${PROJECT_ID}" &>/dev/null; then
    echo "    (already exists, skipping)"
else
    gcloud compute instances create "${CLIENT_VM}" \
        --zone="${ZONE}" \
        --machine-type=e2-micro \
        --scopes=storage-ro \
        --no-address \
        --image-family=debian-12 \
        --image-project=debian-cloud \
        --metadata="vm-role=client,code-bucket=${CODE_BUCKET},server-ip=${SERVER_INTERNAL_IP}" \
        --metadata-from-file="startup-script=${SCRIPT_DIR}/startup.sh" \
        --project="${PROJECT_ID}"
fi

# ---------------------------------------------------------------------------
# 9. Print summary
# ---------------------------------------------------------------------------
echo ""
echo "============================================================"
echo " Setup complete!"
echo "============================================================"
echo ""
echo "Server VM  : ${SERVER_VM}  →  http://${STATIC_IP}:8080"
echo "Subscriber : ${SUBSCRIBER_VM}"
echo "Client     : ${CLIENT_VM}"
echo ""
echo "Wait ~2-3 minutes for startup scripts to finish, then test:"
echo ""
echo "  # 200 – existing file"
echo "  curl -i http://${STATIC_IP}:8080/pages/page_00001.json"
echo ""
echo "  # 404 – non-existent file"
echo "  curl -i http://${STATIC_IP}:8080/pages/nonexistent.json"
echo ""
echo "  # 501 – unsupported method"
echo "  curl -i -X PUT http://${STATIC_IP}:8080/pages/page_00001.json"
echo ""
echo "  # 400 – forbidden country"
echo "  curl -i -H 'X-country: Iran' http://${STATIC_IP}:8080/pages/page_00001.json"
echo ""
echo "SSH into the client VM to run 100 requests:"
echo "  gcloud compute ssh ${CLIENT_VM} --zone=${ZONE} --tunnel-through-iap"
echo "  python3 /opt/hw4/http_client.py --url http://${SERVER_INTERNAL_IP}:8080 --num 100"
echo ""
echo "SSH into the client VM for the stress test:"
echo "  bash /opt/hw4/stress_test.sh ${SERVER_INTERNAL_IP} 4 500"
echo ""
echo "Check subscriber output:"
echo "  gcloud compute ssh ${SUBSCRIBER_VM} --zone=${ZONE} --tunnel-through-iap"
echo "  sudo journalctl -u hw4-subscriber -f"
