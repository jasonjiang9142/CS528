#!/bin/bash
# HW6 ML VM — minimal bootstrap (install Python tooling; you still copy hw6/ and run train_models.py)
set -euo pipefail
apt-get update -y
apt-get install -y python3 python3-pip python3-venv
mkdir -p /opt/hw6
echo "HW6 VM ready. Copy hw6/ to /opt/hw6, then run:"
echo "  python3 -m venv /opt/hw6/venv && /opt/hw6/venv/bin/pip install -r /opt/hw6/requirements.txt"
echo "  export DB_HOST=... DB_PASS=... GCS_BUCKET=... && /opt/hw6/venv/bin/python /opt/hw6/train_models.py"
