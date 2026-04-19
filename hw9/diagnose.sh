#!/usr/bin/env bash
# HW9 diagnostic helper.
# Run this any time `hw9-server` is stuck (Pending, CrashLoopBackOff,
# ImagePullBackOff, etc). It prints the cluster / pod state and the events
# that actually explain why the deployment is unhealthy.
#
# Usage:   ./diagnose.sh

set -uo pipefail

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
if [[ -z "${KUBECTL:-}" ]]; then
  echo "kubectl not found. Try:  gcloud components install kubectl" >&2
  exit 1
fi

hdr() { printf '\n========== %s ==========\n' "$*"; }

hdr "kubectl context"
"${KUBECTL}" config current-context || true

hdr "Nodes"
"${KUBECTL}" get nodes -o wide || true

hdr "Node capacity / allocatable"
"${KUBECTL}" describe nodes | \
  awk '/^Name:/ || /Capacity:/,/System Info:/ {print}' || true

hdr "All pods in default namespace"
"${KUBECTL}" get pods -o wide || true

hdr "hw9-server deployment"
"${KUBECTL}" get deploy hw9-server -o wide || true
"${KUBECTL}" rollout status deploy/hw9-server --timeout=5s || true

hdr "hw9-server service"
"${KUBECTL}" get svc hw9-server -o wide || true

POD="$("${KUBECTL}" get pods -l app=hw9-server -o name 2>/dev/null | head -1 || true)"
if [[ -n "${POD}" ]]; then
  hdr "describe ${POD}"
  "${KUBECTL}" describe "${POD}" || true

  hdr "logs ${POD} (tail 200)"
  "${KUBECTL}" logs "${POD}" --all-containers --tail=200 || true
else
  hdr "No pods matching app=hw9-server"
fi

hdr "Recent Warning events"
"${KUBECTL}" get events --sort-by=.lastTimestamp \
  --field-selector type=Warning 2>/dev/null | tail -40 || true

hdr "Done"
echo "Look first at: describe pod -> Events (why Pending? Insufficient cpu/memory?"
echo "ImagePullBackOff? Node NotReady?) and at node allocatable vs requests."
