#!/usr/bin/env bash
# ============================================================================
# run_local.sh — Run HW7 Beam pipeline locally (DirectRunner) on HW2 page JSONs.
#
# Uses the same JSON as HW2: page_id + outgoing_links (copy from repo ../pages into
# ./pages here, or generate with hw2.py into ./pages).
# Bigrams are computed from the raw JSON text (HW2 files have no body text, so bigrams
# reflect JSON keys and page_*.json tokens).
#
# Usage:
#   cd /path/to/cs528/hw7
#   bash run_local.sh
#
# If ./pages is empty, copy from the repo or generate:
#   rsync -a ../pages/ ./pages/
#   # or: cd .. && python hw2.py generate --output-dir ./hw7/pages ...
#
# Optional env:
#   PAGES_DIR — directory containing *.json (default: <hw7>/pages)
# ============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
PAGES_DIR="${PAGES_DIR:-${SCRIPT_DIR}/pages}"

if [ ! -d "${PAGES_DIR}" ]; then
  echo "ERROR: Directory not found: ${PAGES_DIR}" >&2
  echo "  Copy from HW2 corpus: rsync -a ${REPO_ROOT}/pages/ ${SCRIPT_DIR}/pages/" >&2
  echo "  Or generate: cd ${REPO_ROOT} && python hw2.py generate --output-dir ${SCRIPT_DIR}/pages ..." >&2
  exit 1
fi

# MatchFiles needs a glob string; do not let the shell expand it.
GLOB="${PAGES_DIR}/*.json"

PYTHON="${SCRIPT_DIR}/.venv/bin/python"
if [ ! -x "${PYTHON}" ]; then
  echo "Creating venv and installing requirements …"
  python3 -m venv "${SCRIPT_DIR}/.venv"
  "${SCRIPT_DIR}/.venv/bin/pip" install -q -r "${SCRIPT_DIR}/requirements.txt"
  PYTHON="${SCRIPT_DIR}/.venv/bin/python"
fi

echo "============================================================"
echo " HW7 DirectRunner (local)"
echo " input glob: ${GLOB}"
echo "============================================================"

exec "${PYTHON}" "${SCRIPT_DIR}/pipeline.py" \
  --runner DirectRunner \
  --input_glob "${GLOB}" \
  "$@"
