#!/usr/bin/env bash
# ============================================================================
# cleanup.sh — Tear down all HW9 infrastructure.
#
# Deletes (in order):
#   1. Kubernetes resources in the cluster (Deployment, Service, SA)
#   2. GKE cluster  hw9-cluster
#   3. Demo VMs     hw9-client-vm, hw9-subscriber-vm
#   4. Artifact Registry repo  hw9  (all images)
#   5. IAM bindings + Google service account  hw9-gke-server
#   6. Pub/Sub subscription + topic  forbidden-requests(-sub)
#   7. Local files created by run_subscriber_on_vm.sh  (.venv-sub)
#
# Does NOT delete:
#   - The GCS data bucket (cs528-jx3onj-hw2) — shared with HW2–HW4.
#   - Cloud Logging entries — they expire on their own.
#   - Cloud Build history.
#
# Usage:
#   cd hw9/
#   ./cleanup.sh                # delete everything listed above
#   ./cleanup.sh --keep-cluster # keep the GKE cluster, only remove the app
#   ./cleanup.sh --dry-run      # show what would be deleted
# ============================================================================

set -uo pipefail

# -------- configuration (override with env vars if needed) ------------------

PROJECT_ID="${PROJECT_ID:-$(gcloud config get-value project 2>/dev/null || true)}"
REGION="${REGION:-us-central1}"
ZONE="${ZONE:-us-central1-a}"

CLUSTER="${CLUSTER:-hw9-cluster}"
REPO="${REPO:-hw9}"
GSA_NAME="${GSA_NAME:-hw9-gke-server}"
TOPIC="${TOPIC:-forbidden-requests}"
SUBSCRIPTION="${SUBSCRIPTION:-forbidden-requests-sub}"
CLIENT_VM="${CLIENT_VM:-hw9-client-vm}"
SUBSCRIBER_VM="${SUBSCRIBER_VM:-hw9-subscriber-vm}"

KEEP_CLUSTER=0
DRY_RUN=0
for arg in "$@"; do
  case "${arg}" in
    --keep-cluster) KEEP_CLUSTER=1 ;;
    --dry-run)      DRY_RUN=1 ;;
    -h|--help)
      sed -n '2,30p' "$0"
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

GSA_EMAIL="${GSA_NAME}@${PROJECT_ID}.iam.gserviceaccount.com"

# -------- helpers -----------------------------------------------------------

run() {
  if [[ "${DRY_RUN}" == "1" ]]; then
    printf '  DRY-RUN: %s\n' "$*"
  else
    "$@" 2>/dev/null || echo "    (not found or already removed)"
  fi
}

step() {
  echo ""
  echo "[$1] $2"
}

# Resolve kubectl the same way deploy.sh does.
if [[ -n "${KUBECTL:-}" && -x "${KUBECTL}" ]]; then
  :
elif command -v kubectl >/dev/null 2>&1; then
  KUBECTL="$(command -v kubectl)"
else
  _sdk="$(gcloud info --format='value(installation.sdk_root)' 2>/dev/null || true)"
  if [[ -n "${_sdk}" && -x "${_sdk}/bin/kubectl" ]]; then
    KUBECTL="${_sdk}/bin/kubectl"
  fi
fi

echo "============================================================"
echo " HW9 cleanup"
echo "   project:       ${PROJECT_ID}"
echo "   cluster:       ${CLUSTER}  (${ZONE})"
echo "   keep cluster:  $([[ ${KEEP_CLUSTER} == 1 ]] && echo yes || echo no)"
echo "   dry run:       $([[ ${DRY_RUN}     == 1 ]] && echo yes || echo no)"
echo "============================================================"

# -------- 1. Kubernetes resources -------------------------------------------

step "1/7" "Deleting Kubernetes resources in cluster '${CLUSTER}'..."

if [[ -z "${KUBECTL:-}" ]]; then
  echo "  kubectl not found — skipping (cluster delete below will remove them)."
else
  # Fetch credentials; if cluster is already gone this is a no-op.
  CLUSTER_LOCATION="$(gcloud container clusters list \
    --project="${PROJECT_ID}" --filter="name=${CLUSTER}" \
    --format="value(location)" 2>/dev/null | head -1 || true)"
  if [[ -n "${CLUSTER_LOCATION}" ]]; then
    if [[ "${DRY_RUN}" == "0" ]]; then
      gcloud container clusters get-credentials "${CLUSTER}" \
        --location="${CLUSTER_LOCATION}" --project="${PROJECT_ID}" 2>/dev/null || true
    fi
    run "${KUBECTL}" delete deployment hw9-server     --ignore-not-found=true
    run "${KUBECTL}" delete service    hw9-server     --ignore-not-found=true
    run "${KUBECTL}" delete serviceaccount hw9-server --ignore-not-found=true
  else
    echo "  cluster '${CLUSTER}' not found — skipping in-cluster delete."
  fi
fi

# -------- 2. GKE cluster ----------------------------------------------------

step "2/7" "Deleting GKE cluster..."
if [[ "${KEEP_CLUSTER}" == "1" ]]; then
  echo "  --keep-cluster set; leaving '${CLUSTER}' in place."
else
  run gcloud container clusters delete "${CLUSTER}" \
    --zone="${ZONE}" --project="${PROJECT_ID}" --quiet
fi

# -------- 3. Demo VMs -------------------------------------------------------

step "3/7" "Deleting demo VMs..."
for vm in "${CLIENT_VM}" "${SUBSCRIBER_VM}"; do
  run gcloud compute instances delete "${vm}" \
    --zone="${ZONE}" --project="${PROJECT_ID}" --quiet
done

# -------- 4. Artifact Registry repo ----------------------------------------

step "4/7" "Deleting Artifact Registry repo '${REPO}' (all images)..."
run gcloud artifacts repositories delete "${REPO}" \
  --location="${REGION}" --project="${PROJECT_ID}" --quiet

# -------- 5. IAM bindings + Google service account --------------------------

step "5/7" "Removing IAM bindings and deleting service account..."
for role in roles/storage.objectViewer roles/logging.logWriter roles/pubsub.publisher; do
  run gcloud projects remove-iam-policy-binding "${PROJECT_ID}" \
    --member="serviceAccount:${GSA_EMAIL}" --role="${role}" --quiet
done
run gcloud iam service-accounts delete "${GSA_EMAIL}" \
  --project="${PROJECT_ID}" --quiet

# -------- 6. Pub/Sub subscription + topic -----------------------------------

step "6/7" "Deleting Pub/Sub subscription + topic..."
run gcloud pubsub subscriptions delete "${SUBSCRIPTION}" \
  --project="${PROJECT_ID}" --quiet
run gcloud pubsub topics delete "${TOPIC}" \
  --project="${PROJECT_ID}" --quiet

# -------- 7. Local artifacts -----------------------------------------------

step "7/7" "Removing local artifacts..."
HERE="$(cd "$(dirname "$0")" && pwd)"
if [[ "${DRY_RUN}" == "1" ]]; then
  echo "  DRY-RUN: rm -rf ${HERE}/.venv-sub ${HERE}/__pycache__"
else
  rm -rf "${HERE}/.venv-sub" "${HERE}/__pycache__"
fi

# Remove the stale kubectl context (harmless if absent).
if [[ -n "${KUBECTL:-}" ]]; then
  CTX="gke_${PROJECT_ID}_${ZONE}_${CLUSTER}"
  if [[ "${DRY_RUN}" == "1" ]]; then
    echo "  DRY-RUN: ${KUBECTL} config delete-context ${CTX}"
  else
    "${KUBECTL}" config delete-context "${CTX}" 2>/dev/null || true
  fi
fi

echo ""
echo "============================================================"
echo " HW9 cleanup complete."
echo "============================================================"
echo ""
echo "NOT deleted (intentional):"
echo "  - gs://cs528-jx3onj-hw2   (shared data bucket from HW2–HW4)"
echo "  - Cloud Logging entries   (expire on their own retention)"
echo "  - Cloud Build history"
echo ""
echo "Verify everything is gone:"
echo "  gcloud container clusters list --project=${PROJECT_ID}"
echo "  gcloud compute instances list --project=${PROJECT_ID}"
echo "  gcloud artifacts repositories list --location=${REGION} --project=${PROJECT_ID}"
echo "  gcloud pubsub topics list --project=${PROJECT_ID} | grep ${TOPIC} || echo '(none)'"
echo "  gcloud iam service-accounts list --project=${PROJECT_ID} | grep ${GSA_NAME} || echo '(none)'"
