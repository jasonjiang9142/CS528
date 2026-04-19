#!/usr/bin/env bash
# ============================================================================
# run_tests.sh — End-to-end demo runner for HW9.
#
# Requires the app to already be deployed (./setup.sh or ./deploy.sh).
# Produces everything the assignment asks for:
#
#   1. 200 / 404 / 501 / 400 curl demos (captured to logs/curl.log)
#   2. Hundreds of requests from hw9-client-vm           (logs/http_client.log)
#   3. Forbidden-country requests, subscriber proof      (logs/subscriber.log)
#
# Usage:
#   cd hw9/
#   ./run_tests.sh                  # run all tests
#   ./run_tests.sh --num 400        # change number of HTTP-client requests
#   ./run_tests.sh --ip 1.2.3.4     # override the LoadBalancer IP
#   ./run_tests.sh --skip-client    # skip the on-VM HTTP client test
#   ./run_tests.sh --skip-subscriber# skip the subscriber test
# ============================================================================

set -uo pipefail

# -------- configuration -----------------------------------------------------

PROJECT_ID="${PROJECT_ID:-$(gcloud config get-value project 2>/dev/null || true)}"
ZONE="${ZONE:-us-central1-a}"
CLUSTER="${CLUSTER:-hw9-cluster}"

CLIENT_VM="${CLIENT_VM:-hw9-client-vm}"
SUBSCRIBER_VM="${SUBSCRIBER_VM:-hw9-subscriber-vm}"

NUM_REQUESTS="${NUM_REQUESTS:-400}"
DELAY="${DELAY:-0.02}"
EXTERNAL_IP="${EXTERNAL_IP:-}"

SKIP_CURL=0
SKIP_CLIENT=0
SKIP_SUBSCRIBER=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --num)             NUM_REQUESTS="$2"; shift 2 ;;
    --delay)           DELAY="$2"; shift 2 ;;
    --ip)              EXTERNAL_IP="$2"; shift 2 ;;
    --skip-curl)       SKIP_CURL=1; shift ;;
    --skip-client)     SKIP_CLIENT=1; shift ;;
    --skip-subscriber) SKIP_SUBSCRIBER=1; shift ;;
    -h|--help)
      sed -n '2,20p' "$0"; exit 0 ;;
    *)
      echo "Unknown flag: $1" >&2; exit 2 ;;
  esac
done

if [[ -z "${PROJECT_ID}" || "${PROJECT_ID}" == "(unset)" ]]; then
  echo "ERROR: no active GCP project." >&2
  exit 1
fi

ROOT="$(cd "$(dirname "$0")" && pwd)"
LOGDIR="${ROOT}/logs"
mkdir -p "${LOGDIR}"

# -------- locate kubectl (for fetching the Service IP) ---------------------

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

# -------- resolve EXTERNAL-IP ----------------------------------------------

if [[ -z "${EXTERNAL_IP}" ]]; then
  if [[ -z "${KUBECTL:-}" ]]; then
    echo "ERROR: kubectl not found and --ip not given. Pass --ip X.Y.Z.W." >&2
    exit 1
  fi
  gcloud container clusters get-credentials "${CLUSTER}" \
    --zone="${ZONE}" --project="${PROJECT_ID}" >/dev/null 2>&1 || true
  EXTERNAL_IP="$("${KUBECTL}" get svc hw9-server \
    -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || true)"
fi

if [[ -z "${EXTERNAL_IP}" ]]; then
  echo "ERROR: could not determine hw9-server EXTERNAL-IP." >&2
  echo "       Run  ./k get svc hw9-server  or pass  --ip X.Y.Z.W" >&2
  exit 1
fi

BASE="http://${EXTERNAL_IP}:8080"

echo "============================================================"
echo " HW9 end-to-end tests"
echo "   project:   ${PROJECT_ID}"
echo "   BASE:      ${BASE}"
echo "   requests:  ${NUM_REQUESTS}  (delay ${DELAY}s)"
echo "   logs:      ${LOGDIR}/"
echo "============================================================"

# -------- 1. curl demos (local) --------------------------------------------

if [[ "${SKIP_CURL}" == "0" ]]; then
  echo ""
  echo "[1/3] curl demos against ${BASE}"
  LOG="${LOGDIR}/curl.log"
  {
    echo "## curl demos  $(date -u +%FT%TZ)"
    echo "## BASE=${BASE}"
    echo ""
    for line in \
      "200 GET ${BASE}/pages/page_00001.json" \
      "404 GET ${BASE}/pages/does_not_exist_99999.json" \
      "501 POST ${BASE}/pages/page_00001.json" \
      "501 PUT ${BASE}/pages/page_00001.json" \
      "501 DELETE ${BASE}/pages/page_00001.json" \
      "501 HEAD ${BASE}/pages/page_00001.json" \
      "501 OPTIONS ${BASE}/pages/page_00001.json" \
      "501 PATCH ${BASE}/pages/page_00001.json"; do
      exp="${line%% *}"; rest="${line#* }"
      method="${rest%% *}"; url="${rest#* }"
      code="$(curl -sS -o /dev/null -w '%{http_code}' -X "${method}" "${url}" || echo '---')"
      printf '  expect=%s  got=%s  %-7s  %s\n' "${exp}" "${code}" "${method}" "${url}"
    done
    echo ""
    echo "## forbidden-country (expect 400):"
    for c in "North Korea" "Iran" "Cuba" "Syria" "Myanmar"; do
      code="$(curl -sS -o /dev/null -w '%{http_code}' \
        -H "X-country: $c" "${BASE}/pages/page_00001.json" || echo '---')"
      printf '  got=%s  X-country=%-12s\n' "${code}" "${c}"
    done
  } | tee "${LOG}"
  echo "Wrote ${LOG}"
fi

# -------- 2. HTTP client on hw9-client-vm ----------------------------------

if [[ "${SKIP_CLIENT}" == "0" ]]; then
  echo ""
  echo "[2/3] Hundreds of requests from ${CLIENT_VM}"
  LOG="${LOGDIR}/http_client.log"

  if ! gcloud compute instances describe "${CLIENT_VM}" \
        --zone="${ZONE}" --project="${PROJECT_ID}" &>/dev/null; then
    echo "  VM '${CLIENT_VM}' not found. Run ./setup.sh or create it, then re-run."
  else
    echo "  Copying http_client.py to ${CLIENT_VM}..."
    gcloud compute scp "${ROOT}/http_client.py" \
      "${CLIENT_VM}:~/http_client.py" \
      --zone="${ZONE}" --project="${PROJECT_ID}" --quiet

    echo "  Ensuring python3 is installed and running ${NUM_REQUESTS} requests..."
    gcloud compute ssh "${CLIENT_VM}" \
      --zone="${ZONE}" --project="${PROJECT_ID}" --quiet \
      --command "
        set -e
        command -v python3 >/dev/null || sudo apt-get update -y >/dev/null && sudo apt-get install -y python3 >/dev/null
        python3 ~/http_client.py --url ${BASE} --num ${NUM_REQUESTS} --delay ${DELAY}
      " 2>&1 | tee "${LOG}"
    echo "Wrote ${LOG}"
  fi
fi

# -------- 3. Subscriber proof from hw9-subscriber-vm -----------------------

if [[ "${SKIP_SUBSCRIBER}" == "0" ]]; then
  echo ""
  echo "[3/3] Subscriber end-to-end on ${SUBSCRIBER_VM}"
  LOG="${LOGDIR}/subscriber.log"

  if ! gcloud compute instances describe "${SUBSCRIBER_VM}" \
        --zone="${ZONE}" --project="${PROJECT_ID}" &>/dev/null; then
    echo "  VM '${SUBSCRIBER_VM}' not found. Run ./setup.sh or create it, then re-run."
  else
    echo "  Copying hw9/ to ${SUBSCRIBER_VM}..."
    gcloud compute scp --recurse "${ROOT}" \
      "${SUBSCRIBER_VM}:~/hw9" \
      --zone="${ZONE}" --project="${PROJECT_ID}" --quiet

    echo "  Starting subscriber.py in the background on the VM..."
    # Stop any previous run, then start fresh and redirect output to a file.
    gcloud compute ssh "${SUBSCRIBER_VM}" \
      --zone="${ZONE}" --project="${PROJECT_ID}" --quiet \
      --command '
        set -e
        pkill -f subscriber.py 2>/dev/null || true
        command -v python3 >/dev/null || { sudo apt-get update -y >/dev/null; sudo apt-get install -y python3 python3-venv python3-pip >/dev/null; }
        cd ~/hw9
        nohup ./run_subscriber_on_vm.sh > ~/subscriber.out 2>&1 &
        echo "  subscriber pid=$!"
        sleep 6
        tail -n 5 ~/subscriber.out || true
      '

    echo ""
    echo "  Triggering forbidden-country requests from local curl..."
    for c in "North Korea" "Iran" "Cuba" "Syria" "Myanmar" "Iraq" "Libya" "Sudan" "Zimbabwe"; do
      curl -sS -o /dev/null -w "    trigger %{http_code}  X-country=$c\n" \
        -H "X-country: $c" "${BASE}/pages/page_00001.json" \
        || echo "    curl failed for $c"
    done

    echo ""
    echo "  Giving the subscriber a moment to ack each message..."
    sleep 8

    echo ""
    echo "  Fetching subscriber stdout from the VM..."
    gcloud compute ssh "${SUBSCRIBER_VM}" \
      --zone="${ZONE}" --project="${PROJECT_ID}" --quiet \
      --command 'tail -n 60 ~/subscriber.out' 2>&1 | tee "${LOG}"

    echo ""
    echo "  (The subscriber keeps running on the VM. To stop it: "
    echo "     gcloud compute ssh ${SUBSCRIBER_VM} --zone=${ZONE} --command 'pkill -f subscriber.py')"
    echo ""
    echo "Wrote ${LOG}"
  fi
fi

echo ""
echo "============================================================"
echo " Tests complete.  Artifacts saved in ${LOGDIR}/"
echo "============================================================"
echo ""
echo "Console views to screenshot (for REPORT.md §9):"
echo "  Workloads:   https://console.cloud.google.com/kubernetes/deployment/${ZONE}/${CLUSTER}/default/hw9-server/overview?project=${PROJECT_ID}"
echo "  Service:     https://console.cloud.google.com/kubernetes/service/${ZONE}/${CLUSTER}/default/hw9-server?project=${PROJECT_ID}"
echo "  Cluster:     https://console.cloud.google.com/kubernetes/clusters/details/${ZONE}/${CLUSTER}/details?project=${PROJECT_ID}"
echo "  Logs:        https://console.cloud.google.com/logs/query;query=resource.type%3D%22k8s_container%22%0Aresource.labels.cluster_name%3D%22${CLUSTER}%22?project=${PROJECT_ID}"
