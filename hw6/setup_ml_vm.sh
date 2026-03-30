#!/usr/bin/env bash
# ============================================================================
# setup_ml_vm.sh — Create a small VM to run HW6 train_models.py against
# Cloud SQL (private IP). Adjust network / subnet / tags for your project.
#
# Prerequisites:
#   - gcloud authenticated; project set
#   - Same VPC as Cloud SQL (default network usually works if SQL is on default)
#   - Service account with: roles/cloudsql.client, roles/storage.objectAdmin (for GCS upload)
#
# Usage:
#   cd hw6/
#   bash setup_ml_vm.sh
# ============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ID="${PROJECT_ID:-$(gcloud config get-value project)}"
ZONE="${ZONE:-us-central1-a}"
VM_NAME="${VM_NAME:-hw6-ml-vm}"
REGION="${REGION:-us-central1}"
# Reuse HW5 server SA if it exists (has cloudsql.client + storage)
SA_EMAIL="${SA_EMAIL:-hw5-server-sa@${PROJECT_ID}.iam.gserviceaccount.com}"

echo "Creating ${VM_NAME} in ${ZONE} (project=${PROJECT_ID}) …"

if gcloud compute instances describe "${VM_NAME}" --zone="${ZONE}" --project="${PROJECT_ID}" &>/dev/null; then
  echo "Instance ${VM_NAME} already exists. Skipping create."
else
  gcloud compute instances create "${VM_NAME}" \
    --project="${PROJECT_ID}" \
    --zone="${ZONE}" \
    --machine-type=e2-small \
    --service-account="${SA_EMAIL}" \
    --scopes=https://www.googleapis.com/auth/cloud-platform \
    --image-family=debian-12 \
    --image-project=debian-cloud \
    --tags=hw6-ml \
    --metadata-from-file=startup-script="${SCRIPT_DIR}/vm_startup.sh"
fi

echo ""
echo "Next steps:"
echo "  1. gsutil -m cp -r \"${SCRIPT_DIR}\" gs://${PROJECT_ID}-hw5-code/hw6/   # or: gcloud compute scp -r ${SCRIPT_DIR} jasonjiang@${VM_NAME}:/opt/hw6 --zone=${ZONE}"
echo "  2. gcloud compute ssh ${VM_NAME} --zone=${ZONE} --tunnel-through-iap"
echo "  3. On VM: install deps, set DB_* and GCS_BUCKET, run train_models.py"
echo ""
