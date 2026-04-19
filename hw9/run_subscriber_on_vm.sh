#!/usr/bin/env bash
# Run on a GCE VM with the default service account (or ADC) that can subscribe
# and write to the log bucket. From the repo root or after copying hw9/:
#
#   ./run_subscriber_on_vm.sh
#
# Defaults match server.py / HW4 (override with export ...):
#   GCP_PROJECT=serious-music-485622-t8
#   GCS_BUCKET=cs528-jx3onj-hw2
#   PUBSUB_SUBSCRIPTION=forbidden-requests-sub

set -euo pipefail
export GCP_PROJECT="${GCP_PROJECT:-serious-music-485622-t8}"
export GCS_BUCKET="${GCS_BUCKET:-cs528-jx3onj-hw2}"
export PUBSUB_SUBSCRIPTION="${PUBSUB_SUBSCRIPTION:-forbidden-requests-sub}"

DIR="$(cd "$(dirname "$0")" && pwd)"
python3 -m venv "${DIR}/.venv-sub"
"${DIR}/.venv-sub/bin/pip" install -q --upgrade pip
"${DIR}/.venv-sub/bin/pip" install -q -r "${DIR}/requirements_subscriber.txt"
exec "${DIR}/.venv-sub/bin/python" "${DIR}/subscriber.py"
