#!/usr/bin/env bash
# ============================================================================
# setup.sh — End-to-end provisioning for HW9 from a fresh clone.
#
# Creates (idempotent; safe to re-run):
#   1. APIs:       artifactregistry, container, cloudbuild, pubsub,
#                  logging, storage, compute
#   2. Pub/Sub:    topic  forbidden-requests,
#                  subscription  forbidden-requests-sub
#   3. GKE:        zonal cluster  hw9-cluster  with Workload Identity on
#   4. VMs:        hw9-client-vm, hw9-subscriber-vm
#                  (both with cloud-platform scope for ADC access)
#   5. Deploy:     runs ./deploy.sh  (builds image, applies manifest,
#                  waits for the LoadBalancer EXTERNAL-IP)
#
# Usage:
#   cd hw9/
#   ./setup.sh                 # do everything
#   ./setup.sh --skip-cluster  # assume hw9-cluster already exists
#   ./setup.sh --skip-vms      # don't create client / subscriber VMs
#   ./setup.sh --skip-deploy   # only provision, don't run deploy.sh
#   ./setup.sh --dry-run       # print what would happen
# ============================================================================

set -uo pipefail

# -------- configuration ------------------------------------------------------

PROJECT_ID="${PROJECT_ID:-$(gcloud config get-value project 2>/dev/null || true)}"
REGION="${REGION:-us-central1}"
ZONE="${ZONE:-us-central1-a}"

CLUSTER="${CLUSTER:-hw9-cluster}"
MACHINE="${MACHINE:-e2-small}"
NUM_NODES="${NUM_NODES:-1}"

TOPIC="${TOPIC:-forbidden-requests}"
SUBSCRIPTION="${SUBSCRIPTION:-forbidden-requests-sub}"

CLIENT_VM="${CLIENT_VM:-hw9-client-vm}"
SUBSCRIBER_VM="${SUBSCRIBER_VM:-hw9-subscriber-vm}"
VM_MACHINE="${VM_MACHINE:-e2-small}"
VM_IMAGE_FAMILY="${VM_IMAGE_FAMILY:-debian-12}"
VM_IMAGE_PROJECT="${VM_IMAGE_PROJECT:-debian-cloud}"

SKIP_CLUSTER=0
SKIP_VMS=0
SKIP_DEPLOY=0
DRY_RUN=0
for arg in "$@"; do
  case "${arg}" in
    --skip-cluster) SKIP_CLUSTER=1 ;;
    --skip-vms)     SKIP_VMS=1 ;;
    --skip-deploy)  SKIP_DEPLOY=1 ;;
    --dry-run)      DRY_RUN=1 ;;
    -h|--help)
      sed -n '2,25p' "$0"
      exit 0
      ;;
    *)
      echo "Unknown flag: ${arg}" >&2
      exit 2
      ;;
  esac
done

if [[ -z "${PROJECT_ID}" || "${PROJECT_ID}" == "(unset)" ]]; then
  echo "ERROR: no active GCP project. Run:" >&2
  echo "  gcloud config set project YOUR_PROJECT" >&2
  exit 1
fi

run() {
  if [[ "${DRY_RUN}" == "1" ]]; then
    printf '  DRY-RUN: %s\n' "$*"
    return 0
  fi
  "$@"
}

step() {
  echo ""
  echo "[$1] $2"
}

exists_or_create() {
  # $1 = human description, rest = check command (returns 0 if exists)
  # side effect: caller will create if we echo "create"
  :
}

ROOT="$(cd "$(dirname "$0")" && pwd)"

echo "============================================================"
echo " HW9 setup"
echo "   project:       ${PROJECT_ID}"
echo "   region / zone: ${REGION} / ${ZONE}"
echo "   cluster:       ${CLUSTER}   (skip=${SKIP_CLUSTER})"
echo "   VMs:           ${CLIENT_VM}, ${SUBSCRIBER_VM}   (skip=${SKIP_VMS})"
echo "   deploy:        $([[ ${SKIP_DEPLOY} == 1 ]] && echo skip || echo yes)"
echo "   dry run:       $([[ ${DRY_RUN} == 1 ]] && echo yes || echo no)"
echo "============================================================"

# -------- 1. APIs -----------------------------------------------------------

step "1/5" "Enabling required APIs..."
run gcloud services enable \
  artifactregistry.googleapis.com \
  container.googleapis.com \
  cloudbuild.googleapis.com \
  pubsub.googleapis.com \
  logging.googleapis.com \
  storage.googleapis.com \
  compute.googleapis.com \
  --project="${PROJECT_ID}"

# -------- 2. Pub/Sub topic + subscription ----------------------------------

step "2/5" "Creating Pub/Sub topic '${TOPIC}' and subscription '${SUBSCRIPTION}'..."

if gcloud pubsub topics describe "${TOPIC}" --project="${PROJECT_ID}" &>/dev/null; then
  echo "  topic ${TOPIC} already exists"
else
  run gcloud pubsub topics create "${TOPIC}" --project="${PROJECT_ID}"
fi

if gcloud pubsub subscriptions describe "${SUBSCRIPTION}" --project="${PROJECT_ID}" &>/dev/null; then
  echo "  subscription ${SUBSCRIPTION} already exists"
else
  run gcloud pubsub subscriptions create "${SUBSCRIPTION}" \
    --topic="${TOPIC}" --project="${PROJECT_ID}"
fi

# -------- 3. GKE cluster ----------------------------------------------------

step "3/5" "Ensuring GKE cluster '${CLUSTER}' exists..."
if [[ "${SKIP_CLUSTER}" == "1" ]]; then
  echo "  --skip-cluster set; not touching the cluster."
else
  if gcloud container clusters describe "${CLUSTER}" \
       --zone="${ZONE}" --project="${PROJECT_ID}" &>/dev/null; then
    echo "  cluster ${CLUSTER} already exists in ${ZONE}"
  else
    run gcloud container clusters create "${CLUSTER}" \
      --zone="${ZONE}" \
      --num-nodes="${NUM_NODES}" --machine-type="${MACHINE}" \
      --workload-pool="${PROJECT_ID}.svc.id.goog" \
      --release-channel=regular \
      --project="${PROJECT_ID}"
  fi
fi

# -------- 4. Demo VMs -------------------------------------------------------

step "4/5" "Ensuring demo VMs exist..."
if [[ "${SKIP_VMS}" == "1" ]]; then
  echo "  --skip-vms set; not creating VMs."
else
  for vm in "${CLIENT_VM}" "${SUBSCRIBER_VM}"; do
    if gcloud compute instances describe "${vm}" \
         --zone="${ZONE}" --project="${PROJECT_ID}" &>/dev/null; then
      echo "  VM ${vm} already exists"
    else
      run gcloud compute instances create "${vm}" \
        --zone="${ZONE}" \
        --machine-type="${VM_MACHINE}" \
        --image-family="${VM_IMAGE_FAMILY}" \
        --image-project="${VM_IMAGE_PROJECT}" \
        --scopes=cloud-platform \
        --project="${PROJECT_ID}"
    fi
  done

  # The subscriber VM's default compute SA needs pubsub.subscriber +
  # storage.objectAdmin on the bucket; add them only if missing.
  COMPUTE_SA_NUM="$(gcloud projects describe "${PROJECT_ID}" \
    --format='value(projectNumber)')"
  COMPUTE_SA="${COMPUTE_SA_NUM}-compute@developer.gserviceaccount.com"

  echo "  binding pubsub.subscriber to ${COMPUTE_SA}..."
  run gcloud projects add-iam-policy-binding "${PROJECT_ID}" \
    --member="serviceAccount:${COMPUTE_SA}" \
    --role="roles/pubsub.subscriber" --quiet >/dev/null

  # storage.objectViewer is usually enough to read pages/*.json on the
  # bucket; the subscriber also writes a log blob so objectAdmin is
  # convenient. Scope to the bucket only.
  if [[ -n "${GCS_BUCKET:-cs528-jx3onj-hw2}" ]]; then
    echo "  binding storage.objectAdmin on gs://cs528-jx3onj-hw2 to ${COMPUTE_SA}..."
    run gcloud storage buckets add-iam-policy-binding \
      gs://cs528-jx3onj-hw2 \
      --member="serviceAccount:${COMPUTE_SA}" \
      --role="roles/storage.objectAdmin" --quiet >/dev/null || true
  fi
fi

# -------- 5. Build + deploy the app -----------------------------------------

step "5/5" "Deploying the app to GKE..."
if [[ "${SKIP_DEPLOY}" == "1" ]]; then
  echo "  --skip-deploy set; run ./deploy.sh manually when ready."
else
  if [[ "${DRY_RUN}" == "1" ]]; then
    echo "  DRY-RUN: CLUSTER=${CLUSTER} ${ROOT}/deploy.sh"
  else
    CLUSTER="${CLUSTER}" "${ROOT}/deploy.sh"
  fi
fi

echo ""
echo "============================================================"
echo " HW9 setup complete."
echo "============================================================"
echo ""
echo "Next steps:"
echo "  ./run_tests.sh           # run all assignment demos end-to-end"
echo "  ./cleanup.sh             # tear everything down"
