#!/usr/bin/env bash
# ============================================================================
# run_dataflow.sh — Enable APIs (once) and submit hw7/pipeline.py to Dataflow.
#
# Prerequisites:
#   - gcloud installed and authenticated: gcloud auth login && gcloud auth application-default login
#   - gcloud config set project <PROJECT_ID>
#   - Page JSON files already in GCS (default glob: gs://$GCS_BUCKET/pages/*.json)
#
# Usage:
#   cd /path/to/cs528/hw7
#   bash run_dataflow.sh
#
# Optional env:
#   PROJECT_ID   — default: current gcloud project
#   REGION       — default: us-central1
#   GCS_BUCKET   — default: cs528-jx3onj-hw2 (same default as hw6/train_models.py)
#   INPUT_GLOB   — default: gs://$GCS_BUCKET/pages/*.json
#   SKIP_ENABLE  — set to 1 to skip gcloud services enable (faster re-runs)
#   PYTHON_BIN   — optional path to python3.10–3.13 (Dataflow-supported; default: first of 3.13…3.10 on PATH)
#   WORKER_ZONE    — e.g. us-central1-f (see MACHINE_TYPE; change zone if ZONE_RESOURCE_POOL_EXHAUSTED)
#   MACHINE_TYPE   — default: e2-medium (smaller than default n1; often easier to schedule)
#
# If the job fails with "1/0 in-use IP addresses", the project has no external IP quota.
# This script passes --no_use_public_ips so workers do not need a public IP (uses Private
# Google Access on the default VPC). To force public IPs instead, run pipeline.py manually
# without --no_use_public_ips and request a quota increase for "In-use IP addresses".
#
# If you see "does not have Private Google Access", enable it once on the regional subnet:
#   gcloud compute networks subnets update default --region="${REGION}" \\
#     --project="${PROJECT_ID}" --enable-private-ip-google-access
# ============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "${SCRIPT_DIR}"

PROJECT_ID="${PROJECT_ID:-$(gcloud config get-value project 2>/dev/null)}"
REGION="${REGION:-us-central1}"
# ZONE_RESOURCE_POOL_EXHAUSTED: try another zone (a/b/c often busy; f is a common fallback).
WORKER_ZONE="${WORKER_ZONE:-}"
if [ -z "${WORKER_ZONE}" ] && [ "${REGION}" = "us-central1" ]; then
  WORKER_ZONE="us-central1-f"
fi
MACHINE_TYPE="${MACHINE_TYPE:-e2-medium}"
GCS_BUCKET="${GCS_BUCKET:-cs528-jx3onj-hw2}"
INPUT_GLOB="${INPUT_GLOB:-gs://${GCS_BUCKET}/pages/*.json}"
SKIP_ENABLE="${SKIP_ENABLE:-0}"

if [ -z "${PROJECT_ID}" ] || [ "${PROJECT_ID}" = "(unset)" ]; then
  echo "ERROR: No GCP project. Run: gcloud config set project YOUR_PROJECT_ID" >&2
  exit 1
fi

if ! command -v gcloud &>/dev/null; then
  echo "ERROR: gcloud not found. Install Google Cloud SDK." >&2
  exit 1
fi

# Dataflow Python workers support 3.10–3.13 (Apache Beam check). Avoid 3.14+ for the driver venv.
resolve_dataflow_python() {
  if [ -n "${PYTHON_BIN:-}" ] && [ -x "${PYTHON_BIN}" ]; then
    echo "${PYTHON_BIN}"
    return
  fi
  local cand
  for cand in python3.12 python3.11 python3.10 python3.13; do
    if command -v "${cand}" &>/dev/null; then
      command -v "${cand}"
      return
    fi
  done
  echo ""
}

PY_BIN="$(resolve_dataflow_python)"
EXTRA_BEAM_ARGS=()
if [ -z "${PY_BIN}" ]; then
  if command -v python3 &>/dev/null; then
    PY_BIN="$(command -v python3)"
    echo "WARNING: No python3.10–3.13 on PATH. Using ${PY_BIN} with --experiment use_unsupported_python_version (may fail on workers)." >&2
    EXTRA_BEAM_ARGS+=(--experiment use_unsupported_python_version)
  else
    echo "ERROR: Install Python 3.10–3.13 for Dataflow (e.g. brew install python@3.12)." >&2
    exit 1
  fi
fi

want_ver="$("${PY_BIN}" -c 'import sys; print(f"{sys.version_info.major}.{sys.version_info.minor}")')"
venv_py="${SCRIPT_DIR}/.venv/bin/python"
need_venv=1
if [ -x "${venv_py}" ]; then
  have_ver="$("${venv_py}" -c 'import sys; print(f"{sys.version_info.major}.{sys.version_info.minor}")')"
  if [ "${have_ver}" = "${want_ver}" ]; then
    need_venv=0
  fi
fi

if [ "${need_venv}" -eq 1 ]; then
  echo "Creating venv with ${PY_BIN} (${want_ver}) and installing requirements …"
  rm -rf "${SCRIPT_DIR}/.venv"
  "${PY_BIN}" -m venv "${SCRIPT_DIR}/.venv"
  "${SCRIPT_DIR}/.venv/bin/pip" install -q -r "${SCRIPT_DIR}/requirements.txt"
fi
PYTHON="${SCRIPT_DIR}/.venv/bin/python"

echo "============================================================"
echo " HW7 Dataflow  project=${PROJECT_ID}  region=${REGION}"
if [ -n "${WORKER_ZONE}" ]; then
  echo " worker zone: ${WORKER_ZONE}"
else
  echo " worker zone: (Dataflow auto)"
fi
echo " machine type: ${MACHINE_TYPE}"
echo " input: ${INPUT_GLOB}"
echo " temp:  gs://${GCS_BUCKET}/tmp/beam/"
echo " stage: gs://${GCS_BUCKET}/staging/"
echo "============================================================"

if [ "${SKIP_ENABLE}" != "1" ]; then
  echo "[1/3] Enabling required APIs (safe to re-run) …"
  gcloud services enable \
    dataflow.googleapis.com \
    storage.googleapis.com \
    compute.googleapis.com \
    --project="${PROJECT_ID}" \
    --quiet
else
  echo "[1/3] SKIP_ENABLE=1 — skipping gcloud services enable."
fi

echo "[2/3] Verifying bucket is reachable …"
if ! gsutil ls "gs://${GCS_BUCKET}/" &>/dev/null; then
  echo "ERROR: Cannot list gs://${GCS_BUCKET}/ — check bucket name and IAM." >&2
  exit 1
fi

JOB_NAME="hw7-beam-$(date +%Y%m%d-%H%M%S)"
echo "[3/3] Submitting Dataflow job '${JOB_NAME}' …"

ZONE_ARGS=()
if [ -n "${WORKER_ZONE}" ]; then
  ZONE_ARGS+=(--worker_zone "${WORKER_ZONE}")
fi

exec "${PYTHON}" "${SCRIPT_DIR}/pipeline.py" \
  --runner DataflowRunner \
  --project "${PROJECT_ID}" \
  --region "${REGION}" \
  --job_name "${JOB_NAME}" \
  --temp_location "gs://${GCS_BUCKET}/tmp/beam" \
  --staging_location "gs://${GCS_BUCKET}/staging" \
  --input_glob "${INPUT_GLOB}" \
  --requirements_file "${SCRIPT_DIR}/requirements.txt" \
  --save_main_session \
  --no_use_public_ips \
  --machine_type "${MACHINE_TYPE}" \
  "${ZONE_ARGS[@]+"${ZONE_ARGS[@]}"}" \
  "${EXTRA_BEAM_ARGS[@]+"${EXTRA_BEAM_ARGS[@]}"}" \
  "$@"
