#!/usr/bin/env bash
# ============================================================================
# setup.sh  –  Provision ALL HW5 infrastructure in one command.
#
# What it creates:
#   - Service accounts (server, subscriber, db-stopper)
#   - Pub/Sub topic + subscription
#   - Cloud SQL PostgreSQL instance (private IP) + database + user
#   - Staging bucket with application code
#   - Static IP + firewall rule
#   - 3 VMs (server, subscriber, client)
#   - Cloud Function (stop-db) + Cloud Scheduler job (hourly)
#
# Prerequisites:
#   - gcloud CLI authenticated and project set
#   - HW2 bucket gs://cs528-jx3onj-hw2 with pages/*.json
#
# Usage:   cd hw5/ && bash setup.sh
# ============================================================================
set -euo pipefail

PROJECT_ID=$(gcloud config get-value project 2>/dev/null)
if [ -z "${PROJECT_ID}" ]; then
    echo "ERROR: No active GCP project." >&2; exit 1
fi

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
DB_NAME="hw5db"
DB_USER="hw5user"
DB_PASS="${DB_PASS:-hw5pass123}"
DB_TIER="db-f1-micro"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "============================================================"
echo " HW5 setup   project=${PROJECT_ID}"
echo "============================================================"

# ---- 1. Enable APIs -------------------------------------------------------
echo "[1/14] Enabling APIs …"
gcloud services enable \
    compute.googleapis.com \
    pubsub.googleapis.com \
    logging.googleapis.com \
    storage.googleapis.com \
    sqladmin.googleapis.com \
    servicenetworking.googleapis.com \
    cloudfunctions.googleapis.com \
    cloudscheduler.googleapis.com \
    cloudbuild.googleapis.com \
    run.googleapis.com \
    --project="${PROJECT_ID}" --quiet

# ---- 2. Service accounts ---------------------------------------------------
echo "[2/14] Creating service accounts …"
for SA in "${SERVER_SA_NAME}" "${SUBSCRIBER_SA_NAME}" "${STOPPER_SA_NAME}"; do
    gcloud iam service-accounts create "${SA}" \
        --display-name="HW5 ${SA}" \
        --project="${PROJECT_ID}" 2>/dev/null || echo "  (${SA} exists)"
done

# ---- 3. IAM roles -----------------------------------------------------------
echo "[3/14] Granting IAM roles …"
for ROLE in roles/storage.objectViewer roles/pubsub.publisher roles/logging.logWriter roles/cloudsql.client; do
    gcloud projects add-iam-policy-binding "${PROJECT_ID}" \
        --member="serviceAccount:${SERVER_SA}" --role="${ROLE}" --quiet >/dev/null
done

for ROLE in roles/pubsub.subscriber roles/storage.objectViewer roles/logging.logWriter; do
    gcloud projects add-iam-policy-binding "${PROJECT_ID}" \
        --member="serviceAccount:${SUBSCRIBER_SA}" --role="${ROLE}" --quiet >/dev/null
done
gsutil iam ch "serviceAccount:${SUBSCRIBER_SA}:roles/storage.objectAdmin" \
    "gs://${GCS_BUCKET}" 2>/dev/null || true

for ROLE in roles/cloudsql.admin roles/logging.logWriter; do
    gcloud projects add-iam-policy-binding "${PROJECT_ID}" \
        --member="serviceAccount:${STOPPER_SA}" --role="${ROLE}" --quiet >/dev/null
done

# ---- 4. Pub/Sub -------------------------------------------------------------
echo "[4/14] Creating Pub/Sub resources …"
gcloud pubsub topics create "${TOPIC_ID}" --project="${PROJECT_ID}" 2>/dev/null || true
gcloud pubsub subscriptions create "${SUBSCRIPTION_ID}" \
    --topic="${TOPIC_ID}" --project="${PROJECT_ID}" 2>/dev/null || true

# ---- 5. VPC peering for Cloud SQL private IP --------------------------------
echo "[5/14] Setting up VPC peering for Cloud SQL …"
gcloud compute addresses create google-managed-services-default \
    --global --purpose=VPC_PEERING --prefix-length=16 \
    --network=default --project="${PROJECT_ID}" 2>/dev/null \
    || echo "  (peering range exists)"

gcloud services vpc-peerings connect \
    --service=servicenetworking.googleapis.com \
    --ranges=google-managed-services-default \
    --network=default --project="${PROJECT_ID}" 2>/dev/null \
    || echo "  (peering exists)"

# ---- 6. Cloud SQL instance --------------------------------------------------
echo "[6/14] Creating Cloud SQL instance (this takes ~5-10 min) …"
if gcloud sql instances describe "${DB_INSTANCE}" --project="${PROJECT_ID}" &>/dev/null; then
    echo "  (instance exists – starting if stopped)"
    gcloud sql instances patch "${DB_INSTANCE}" \
        --activation-policy=ALWAYS --project="${PROJECT_ID}" --quiet 2>/dev/null || true
else
    gcloud sql instances create "${DB_INSTANCE}" \
        --database-version=POSTGRES_14 \
        --tier="${DB_TIER}" \
        --region="${REGION}" \
        --network=default \
        --no-assign-ip \
        --availability-type=zonal \
        --storage-size=10GB \
        --storage-type=HDD \
        --project="${PROJECT_ID}" --quiet
fi

# ---- 7. Database + user -----------------------------------------------------
echo "[7/14] Creating database and user …"
gcloud sql databases create "${DB_NAME}" \
    --instance="${DB_INSTANCE}" --project="${PROJECT_ID}" 2>/dev/null \
    || echo "  (database exists)"

gcloud sql users create "${DB_USER}" \
    --instance="${DB_INSTANCE}" \
    --password="${DB_PASS}" \
    --project="${PROJECT_ID}" 2>/dev/null \
    || echo "  (user exists)"

DB_PRIVATE_IP=$(gcloud sql instances describe "${DB_INSTANCE}" \
    --project="${PROJECT_ID}" --format="value(ipAddresses[0].ipAddress)")
echo "  Cloud SQL private IP = ${DB_PRIVATE_IP}"

# ---- 8. Upload code ---------------------------------------------------------
echo "[8/14] Uploading code to gs://${CODE_BUCKET}/hw5/ …"
gsutil mb -p "${PROJECT_ID}" -l "${REGION}" "gs://${CODE_BUCKET}" 2>/dev/null || true
gsutil -m cp \
    "${SCRIPT_DIR}/server.py" \
    "${SCRIPT_DIR}/subscriber.py" \
    "${SCRIPT_DIR}/http_client.py" \
    "${SCRIPT_DIR}/compute_stats.py" \
    "${SCRIPT_DIR}/stress_test.sh" \
    "${SCRIPT_DIR}/requirements_server.txt" \
    "${SCRIPT_DIR}/requirements_subscriber.txt" \
    "gs://${CODE_BUCKET}/hw5/"

# ---- 9. Static IP -----------------------------------------------------------
echo "[9/14] Reserving static IP …"
gcloud compute addresses create "${STATIC_IP_NAME}" \
    --region="${REGION}" --project="${PROJECT_ID}" 2>/dev/null || true
STATIC_IP=$(gcloud compute addresses describe "${STATIC_IP_NAME}" \
    --region="${REGION}" --project="${PROJECT_ID}" --format="value(address)")
echo "  Static IP = ${STATIC_IP}"

# ---- 10. Firewall rule -------------------------------------------------------
echo "[10/14] Creating firewall rule …"
gcloud compute firewall-rules create "${FIREWALL_RULE}" \
    --allow=tcp:8080 --target-tags=hw5-server \
    --source-ranges=0.0.0.0/0 \
    --project="${PROJECT_ID}" 2>/dev/null || true

# ---- 11. Private Google Access ------------------------------------------------
echo "[11/14] Enabling Private Google Access …"
gcloud compute networks subnets update default \
    --region="${REGION}" --enable-private-google-access \
    --project="${PROJECT_ID}" --quiet 2>/dev/null || true

# ---- 12. Create VMs ----------------------------------------------------------
echo "[12/14] Creating VMs …"

DB_META="db-host=${DB_PRIVATE_IP},db-port=5432,db-name=${DB_NAME},db-user=${DB_USER},db-pass=${DB_PASS}"

# Server (e2-small to handle 2 concurrent clients + DB writes)
echo "  Creating ${SERVER_VM} …"
if gcloud compute instances describe "${SERVER_VM}" --zone="${ZONE}" --project="${PROJECT_ID}" &>/dev/null; then
    echo "    (already exists)"
else
    gcloud compute instances create "${SERVER_VM}" \
        --zone="${ZONE}" \
        --machine-type=e2-small \
        --service-account="${SERVER_SA}" \
        --scopes=cloud-platform \
        --address="${STATIC_IP}" \
        --tags=hw5-server \
        --image-family=debian-12 --image-project=debian-cloud \
        --metadata="vm-role=server,code-bucket=${CODE_BUCKET},gcs-bucket=${GCS_BUCKET},gcp-project=${PROJECT_ID},pubsub-topic=${TOPIC_ID},${DB_META}" \
        --metadata-from-file="startup-script=${SCRIPT_DIR}/startup.sh" \
        --project="${PROJECT_ID}"
fi

SERVER_INTERNAL_IP=$(gcloud compute instances describe "${SERVER_VM}" \
    --zone="${ZONE}" --project="${PROJECT_ID}" \
    --format="value(networkInterfaces[0].networkIP)")

# Subscriber (e2-micro, no external IP)
echo "  Creating ${SUBSCRIBER_VM} …"
if gcloud compute instances describe "${SUBSCRIBER_VM}" --zone="${ZONE}" --project="${PROJECT_ID}" &>/dev/null; then
    echo "    (already exists)"
else
    gcloud compute instances create "${SUBSCRIBER_VM}" \
        --zone="${ZONE}" \
        --machine-type=e2-micro \
        --service-account="${SUBSCRIBER_SA}" \
        --scopes=cloud-platform \
        --no-address \
        --image-family=debian-12 --image-project=debian-cloud \
        --metadata="vm-role=subscriber,code-bucket=${CODE_BUCKET},gcs-bucket=${GCS_BUCKET},gcp-project=${PROJECT_ID},pubsub-subscription=${SUBSCRIPTION_ID}" \
        --metadata-from-file="startup-script=${SCRIPT_DIR}/startup.sh" \
        --project="${PROJECT_ID}"
fi

# Client (e2-micro, no external IP)
echo "  Creating ${CLIENT_VM} …"
if gcloud compute instances describe "${CLIENT_VM}" --zone="${ZONE}" --project="${PROJECT_ID}" &>/dev/null; then
    echo "    (already exists)"
else
    gcloud compute instances create "${CLIENT_VM}" \
        --zone="${ZONE}" \
        --machine-type=e2-micro \
        --scopes=storage-ro \
        --no-address \
        --image-family=debian-12 --image-project=debian-cloud \
        --metadata="vm-role=client,code-bucket=${CODE_BUCKET},server-ip=${SERVER_INTERNAL_IP}" \
        --metadata-from-file="startup-script=${SCRIPT_DIR}/startup.sh" \
        --project="${PROJECT_ID}"
fi

# ---- 13. Deploy Cloud Function (stop-db) -------------------------------------
echo "[13/14] Deploying stop-db Cloud Function …"
gcloud functions deploy stop-hw5-db \
    --gen2 \
    --runtime=python312 \
    --region="${REGION}" \
    --source="${SCRIPT_DIR}/stop_db_function" \
    --entry-point=stop_db \
    --trigger-http \
    --allow-unauthenticated \
    --service-account="${STOPPER_SA}" \
    --set-env-vars="GCP_PROJECT=${PROJECT_ID},DB_INSTANCE_NAME=${DB_INSTANCE}" \
    --project="${PROJECT_ID}" --quiet 2>/dev/null || echo "  (deploy may need Cloud Build – check logs)"

FUNCTION_URL=$(gcloud functions describe stop-hw5-db --gen2 \
    --region="${REGION}" --project="${PROJECT_ID}" \
    --format="value(serviceConfig.uri)" 2>/dev/null || echo "")

# ---- 14. Cloud Scheduler (hourly stop) ----------------------------------------
echo "[14/14] Creating Cloud Scheduler job …"
gcloud app create --region="${REGION}" 2>/dev/null || true

if [ -n "${FUNCTION_URL}" ]; then
    gcloud scheduler jobs create http stop-hw5-db-job \
        --schedule="0 * * * *" \
        --uri="${FUNCTION_URL}" \
        --http-method=GET \
        --location="${REGION}" \
        --project="${PROJECT_ID}" 2>/dev/null \
        || echo "  (scheduler job exists)"
    echo "  Scheduler → ${FUNCTION_URL}"
else
    echo "  WARNING: Could not get function URL; create scheduler job manually."
fi

# ---- Summary ------------------------------------------------------------------
echo ""
echo "============================================================"
echo " Setup complete!"
echo "============================================================"
echo ""
echo "Server VM  : ${SERVER_VM}  →  http://${STATIC_IP}:8080"
echo "Subscriber : ${SUBSCRIBER_VM}"
echo "Client     : ${CLIENT_VM}"
echo "Cloud SQL  : ${DB_INSTANCE}  →  ${DB_PRIVATE_IP}:5432/${DB_NAME}"
echo ""
echo "Wait ~3-5 min for startup scripts, then test:"
echo ""
echo "  curl -i http://${STATIC_IP}:8080/pages/page_00001.json"
echo "  curl -i http://${STATIC_IP}:8080/pages/nonexistent.json"
echo "  curl -i -X PUT http://${STATIC_IP}:8080/pages/page_00001.json"
echo "  curl -i -H 'X-country: Iran' http://${STATIC_IP}:8080/pages/page_00001.json"
echo ""
echo "Run 2×50k stress test from client VM:"
echo "  gcloud compute ssh ${CLIENT_VM} --zone=${ZONE} --tunnel-through-iap"
echo "  bash /opt/hw5/stress_test.sh ${SERVER_INTERNAL_IP} 42 50000"
echo ""
echo "Compute statistics (from server VM):"
echo "  gcloud compute ssh ${SERVER_VM} --zone=${ZONE}"
echo "  sudo -E /opt/hw5/venv/bin/python /opt/hw5/compute_stats.py"
