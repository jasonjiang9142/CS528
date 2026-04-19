#!/usr/bin/env bash
# CS528 HW9 — one-shot deploy: build image + configure Workload Identity +
# apply manifest + wait for Ready Service with ExternalIP.
#
# Designed to be resilient: wipes stale Deployment state before applying,
# verifies node readiness + headroom, and if the initial rollout cannot
# schedule the Pod on a crowded single-node cluster, resizes the node
# pool to 2 nodes and retries once.
#
# Prereqs:
#   gcloud config set project serious-music-485622-t8
#   gcloud config set compute/region us-central1
#   Cluster already exists (see README; `gcloud container clusters create ...`).
#   Pass the real cluster name:
#     export CLUSTER=hw9-cluster
#
# Usage:  ./deploy.sh
#
# Overrides: GCS_BUCKET, REGION, CLUSTER, REPO, IMAGE_NAME, TAG, GSA_NAME,
#            AUTO_RESIZE=0   # disable automatic node-pool resize fallback

set -euo pipefail

# -------- configuration -----------------------------------------------------

REGION="${REGION:-$(gcloud config get-value compute/region 2>/dev/null || echo us-central1)}"
CLUSTER="${CLUSTER:-$(gcloud config get-value container/cluster 2>/dev/null || true)}"
REPO="${REPO:-hw9}"
IMAGE_NAME="${IMAGE_NAME:-hw9-server}"
TAG="${TAG:-$(date +%Y%m%d-%H%M%S)}"
PROJECT_ID="$(gcloud config get-value project 2>/dev/null)"
GCS_BUCKET="${GCS_BUCKET:-cs528-jx3onj-hw2}"
GSA_NAME="${GSA_NAME:-hw9-gke-server}"
AUTO_RESIZE="${AUTO_RESIZE:-1}"

ROLLOUT_TIMEOUT="${ROLLOUT_TIMEOUT:-300s}"

if [[ -z "${PROJECT_ID}" || "${PROJECT_ID}" == "(unset)" ]]; then
  echo "Set a gcloud project: gcloud config set project YOUR_PROJECT" >&2
  exit 1
fi

if [[ -z "${CLUSTER}" ]]; then
  echo "Set CLUSTER to a real GKE cluster name from:" >&2
  echo "  gcloud container clusters list --project=${PROJECT_ID}" >&2
  exit 1
fi

for bad in REAL_CLUSTER_NAME_FROM_LIST YOUR_ACTUAL_CLUSTER_NAME YOUR_CLUSTER_NAME; do
  if [[ "${CLUSTER}" == "${bad}" ]]; then
    echo "CLUSTER is still the placeholder '${CLUSTER}'." >&2
    exit 1
  fi
done

CLUSTER_LOCATION="$(gcloud container clusters list \
  --project="${PROJECT_ID}" \
  --filter="name=${CLUSTER}" \
  --format="value(location)" 2>/dev/null | head -1 || true)"

if [[ -z "${CLUSTER_LOCATION}" ]]; then
  echo "No cluster named '${CLUSTER}' in project ${PROJECT_ID}." >&2
  echo "List clusters:  gcloud container clusters list --project=${PROJECT_ID}" >&2
  exit 1
fi

CLUSTER_IS_AUTOPILOT="$(gcloud container clusters describe "${CLUSTER}" \
  --location="${CLUSTER_LOCATION}" --project="${PROJECT_ID}" \
  --format='value(autopilot.enabled)' 2>/dev/null || echo "")"

ROOT="$(cd "$(dirname "$0")" && pwd)"
IMAGE="${REGION}-docker.pkg.dev/${PROJECT_ID}/${REPO}/${IMAGE_NAME}:${TAG}"
GSA_EMAIL="${GSA_NAME}@${PROJECT_ID}.iam.gserviceaccount.com"

echo "Project:     ${PROJECT_ID}"
echo "Cluster:     ${CLUSTER}  (location ${CLUSTER_LOCATION}, autopilot=${CLUSTER_IS_AUTOPILOT:-false})"
echo "Image:       ${IMAGE}"
echo "GSA:         ${GSA_EMAIL}"
echo "GCS bucket:  ${GCS_BUCKET}"

# -------- locate kubectl ----------------------------------------------------

if [[ -n "${KUBECTL:-}" ]]; then
  if [[ ! -x "${KUBECTL}" ]]; then
    echo "KUBECTL=${KUBECTL} is not an executable file." >&2
    exit 1
  fi
elif command -v kubectl >/dev/null 2>&1; then
  KUBECTL="$(command -v kubectl)"
else
  _sdk_root="$(gcloud info --format='value(installation.sdk_root)' 2>/dev/null || true)"
  if [[ -n "${_sdk_root}" && -x "${_sdk_root}/bin/kubectl" ]]; then
    KUBECTL="${_sdk_root}/bin/kubectl"
  fi
fi
if [[ -z "${KUBECTL:-}" ]]; then
  echo "kubectl not found. Run:  gcloud components install kubectl" >&2
  exit 1
fi
echo "kubectl:     ${KUBECTL}"

k() { "${KUBECTL}" "$@"; }

# -------- enable APIs + Artifact Registry repo ------------------------------

gcloud services enable \
  artifactregistry.googleapis.com \
  container.googleapis.com \
  cloudbuild.googleapis.com \
  --project="${PROJECT_ID}"

if ! gcloud artifacts repositories describe "${REPO}" --location="${REGION}" --project="${PROJECT_ID}" &>/dev/null; then
  gcloud artifacts repositories create "${REPO}" \
    --repository-format=docker --location="${REGION}" --project="${PROJECT_ID}" \
    --description="HW9 container images"
fi

# -------- build + push image ------------------------------------------------

if command -v docker >/dev/null 2>&1; then
  gcloud auth configure-docker "${REGION}-docker.pkg.dev" --quiet
  docker build --platform linux/amd64 -t "${IMAGE}" "${ROOT}"
  docker push "${IMAGE}"
else
  echo "docker not in PATH — building and pushing with Cloud Build." >&2
  gcloud builds submit "${ROOT}" --tag="${IMAGE}" --project="${PROJECT_ID}"
fi

# -------- cluster credentials + IAM ----------------------------------------

gcloud container clusters get-credentials "${CLUSTER}" \
  --location="${CLUSTER_LOCATION}" --project="${PROJECT_ID}"

if ! gcloud iam service-accounts describe "${GSA_EMAIL}" --project="${PROJECT_ID}" &>/dev/null; then
  gcloud iam service-accounts create "${GSA_NAME}" \
    --display-name="HW9 GKE web server" --project="${PROJECT_ID}"
fi

for role in roles/storage.objectViewer roles/logging.logWriter roles/pubsub.publisher; do
  gcloud projects add-iam-policy-binding "${PROJECT_ID}" \
    --member="serviceAccount:${GSA_EMAIL}" --role="${role}" --quiet >/dev/null
done

gcloud iam service-accounts add-iam-policy-binding "${GSA_EMAIL}" \
  --project="${PROJECT_ID}" \
  --role="roles/iam.workloadIdentityUser" \
  --member="serviceAccount:${PROJECT_ID}.svc.id.goog[default/hw9-server]" >/dev/null

# -------- pre-flight: cluster + node readiness ------------------------------

echo ""
echo "--- Pre-flight: nodes ---"
if ! k get nodes --no-headers 2>/dev/null | grep -q ' Ready '; then
  echo "No Ready nodes in '${CLUSTER}'. Current state:" >&2
  k get nodes -o wide >&2 || true
  echo "Fix with:   gcloud container clusters resize ${CLUSTER} \\" >&2
  echo "              --location=${CLUSTER_LOCATION} --num-nodes=1 --quiet" >&2
  exit 1
fi
k get nodes -o wide

# -------- wipe stale Deployment so old ReplicaSets don't hold slots ---------
# The hw9-server name is reused; stale ReplicaSets from prior tries can pin
# a Pending Pod on a crowded 1-node cluster.

echo ""
echo "--- Cleaning stale Deployment state (if any) ---"
k delete deployment hw9-server --ignore-not-found=true --wait=true
k delete pod -l app=hw9-server --ignore-not-found=true --wait=true --grace-period=0 --force 2>/dev/null || true

# -------- render + apply manifest -------------------------------------------

MANIFEST="$(mktemp)"
trap 'rm -f "${MANIFEST}"' EXIT
sed -e "s|__IMAGE__|${IMAGE}|g" \
    -e "s|__GCP_PROJECT__|${PROJECT_ID}|g" \
    -e "s|__GCS_BUCKET__|${GCS_BUCKET}|g" \
    -e "s|__GSA_EMAIL__|${GSA_EMAIL}|g" \
    "${ROOT}/k8s/hw9-manifest.yaml" > "${MANIFEST}"

echo ""
echo "--- Applying manifest ---"
k apply -f "${MANIFEST}"

# -------- dump_diagnostics: everything the reader needs on failure ----------

dump_diagnostics() {
  echo ""
  echo "--- Nodes ---" >&2
  k get nodes -o wide >&2 || true

  echo ""
  echo "--- Node allocatable vs requests ---" >&2
  k describe nodes | awk '
    /^Name:/              {name=$2}
    /^Allocatable:/       {inalloc=1; print "\n"name; next}
    inalloc && /^[^ ]/    {inalloc=0}
    inalloc               {print}
    /Allocated resources/ {inreq=1; print}
    inreq && /^Events:/   {inreq=0}
    inreq                 {print}
  ' >&2 || true

  echo ""
  echo "--- Pods (app=hw9-server) ---" >&2
  k get pods -l app=hw9-server -o wide >&2 || true

  local pod
  pod="$(k get pods -l app=hw9-server -o name 2>/dev/null | head -1 || true)"
  if [[ -n "${pod}" ]]; then
    echo ""
    echo "--- describe ${pod} (Events section shows WHY) ---" >&2
    k describe "${pod}" >&2 || true
    echo ""
    echo "--- logs ${pod} (if container started) ---" >&2
    k logs "${pod}" --all-containers --tail=200 >&2 || true
  fi

  echo ""
  echo "--- Recent Warning events ---" >&2
  k get events --sort-by=.lastTimestamp \
    --field-selector type=Warning 2>/dev/null | tail -30 >&2 || true
}

# -------- wait for rollout, with one auto-resize fallback -------------------

try_rollout() {
  k rollout status deployment/hw9-server --timeout="${ROLLOUT_TIMEOUT}"
}

echo ""
echo "--- Waiting for rollout (${ROLLOUT_TIMEOUT}) ---"
if ! try_rollout; then
  echo ""
  echo "Initial rollout failed. First diagnostic pass:" >&2
  dump_diagnostics

  # Check for Pod Pending with FailedScheduling → likely node pressure.
  pod="$(k get pods -l app=hw9-server -o name 2>/dev/null | head -1 || true)"
  reason=""
  if [[ -n "${pod}" ]]; then
    reason="$(k get "${pod}" \
      -o jsonpath='{.status.conditions[?(@.type=="PodScheduled")].reason}' 2>/dev/null || true)"
  fi

  if [[ "${AUTO_RESIZE}" == "1" \
        && "${CLUSTER_IS_AUTOPILOT}" != "True" \
        && ( "${reason}" == "Unschedulable" || -z "${reason}" ) ]]; then
    echo ""
    echo "Pod is Unschedulable. Attempting to grow the default node pool to 2 nodes..." >&2
    CUR_NODES="$(gcloud container clusters describe "${CLUSTER}" \
      --location="${CLUSTER_LOCATION}" --project="${PROJECT_ID}" \
      --format='value(currentNodeCount)' 2>/dev/null || echo 1)"
    if [[ "${CUR_NODES}" -lt 2 ]]; then
      gcloud container clusters resize "${CLUSTER}" \
        --location="${CLUSTER_LOCATION}" --project="${PROJECT_ID}" \
        --num-nodes=2 --quiet
    else
      echo "Node count is already ${CUR_NODES}; not resizing further." >&2
    fi

    echo "Restarting rollout and waiting again..." >&2
    k rollout restart deployment/hw9-server
    if ! try_rollout; then
      echo ""
      echo "Rollout still failed after node-pool resize. Final diagnostics:" >&2
      dump_diagnostics
      exit 1
    fi
  else
    exit 1
  fi
fi

# -------- service + external IP --------------------------------------------

echo ""
echo "--- Service ---"
k get svc hw9-server

echo ""
echo "Waiting up to 3 minutes for the LoadBalancer to get an EXTERNAL-IP..."
EXTERNAL_IP=""
for _ in $(seq 1 36); do
  EXTERNAL_IP="$(k get svc hw9-server -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || true)"
  [[ -n "${EXTERNAL_IP}" ]] && break
  sleep 5
done

if [[ -z "${EXTERNAL_IP}" ]]; then
  echo "EXTERNAL-IP still pending. Re-check later with:  ./k get svc hw9-server" >&2
else
  echo ""
  echo "============================================================"
  echo " HW9 is up.  EXTERNAL-IP: ${EXTERNAL_IP}"
  echo "============================================================"
  echo "From a VM:"
  echo "  python3 http_client.py --url http://${EXTERNAL_IP}:8080 --num 400 --delay 0.02"
  echo ""
  echo "Quick 404/501/400 demos:"
  echo "  BASE=http://${EXTERNAL_IP}:8080 ./demo_curl.sh"
fi
