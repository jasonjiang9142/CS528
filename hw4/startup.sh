#!/usr/bin/env bash
# ============================================================================
# startup.sh  –  Unified VM startup script (passed via --metadata-from-file).
#
# The script reads the "vm-role" instance metadata attribute to decide what
# software to install and which systemd service to create.
#
# Roles:
#   server      – installs & starts the HW4 Python web server (Service 1)
#   subscriber  – installs & starts the Pub/Sub subscriber   (Service 2)
#   client      – installs Python deps so the HTTP client is ready to run
# ============================================================================
set -euo pipefail

# ---- run-once guard (persists across reboots) -----------------------------
if [ -f /var/log/startup_already_done ]; then
    echo "Startup script already ran once. Skipping."
    exit 0
fi

# ---- helper: read a single instance-metadata attribute --------------------
meta() {
    curl -sf "http://metadata.google.internal/computeMetadata/v1/instance/attributes/$1" \
         -H "Metadata-Flavor: Google" 2>/dev/null || echo ""
}

ROLE=$(meta vm-role)
CODE_BUCKET=$(meta code-bucket)
GCS_BUCKET=$(meta gcs-bucket)
GCP_PROJECT=$(meta gcp-project)
PUBSUB_TOPIC=$(meta pubsub-topic)
PUBSUB_SUBSCRIPTION=$(meta pubsub-subscription)
SERVER_IP=$(meta server-ip)

echo "=========================================="
echo " HW4 startup  role=${ROLE}"
echo "=========================================="

# ---- install OS packages --------------------------------------------------
apt-get update -y
apt-get install -y python3 python3-pip python3-venv

# ---- download application code from staging bucket -------------------------
mkdir -p /opt/hw4
gsutil -m cp "gs://${CODE_BUCKET}/hw4/*" /opt/hw4/
chmod +x /opt/hw4/*.sh 2>/dev/null || true

# ---- create a virtualenv so pip doesn't need --break-system-packages ------
python3 -m venv /opt/hw4/venv

# ---- role-specific setup ---------------------------------------------------
case "${ROLE}" in

# ===== SERVER ==============================================================
server)
    /opt/hw4/venv/bin/pip install -r /opt/hw4/requirements_server.txt

    cat > /etc/systemd/system/hw4-server.service <<UNIT
[Unit]
Description=HW4 Web Server (Service 1)
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=/opt/hw4/venv/bin/python /opt/hw4/server.py
Environment=GCS_BUCKET=${GCS_BUCKET}
Environment=GCP_PROJECT=${GCP_PROJECT}
Environment=PUBSUB_TOPIC=${PUBSUB_TOPIC}
Environment=PORT=8080
Restart=always
RestartSec=3
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
UNIT

    systemctl daemon-reload
    systemctl enable hw4-server
    systemctl start hw4-server
    echo "Server started on port 8080"
    ;;

# ===== SUBSCRIBER ==========================================================
subscriber)
    /opt/hw4/venv/bin/pip install -r /opt/hw4/requirements_subscriber.txt

    cat > /etc/systemd/system/hw4-subscriber.service <<UNIT
[Unit]
Description=HW4 Pub/Sub Subscriber (Service 2)
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=/opt/hw4/venv/bin/python /opt/hw4/subscriber.py
Environment=GCS_BUCKET=${GCS_BUCKET}
Environment=GCP_PROJECT=${GCP_PROJECT}
Environment=PUBSUB_SUBSCRIPTION=${PUBSUB_SUBSCRIPTION}
Restart=always
RestartSec=3
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
UNIT

    systemctl daemon-reload
    systemctl enable hw4-subscriber
    systemctl start hw4-subscriber
    echo "Subscriber started"
    ;;

# ===== CLIENT ==============================================================
client)
    /opt/hw4/venv/bin/pip install urllib3
    echo "${SERVER_IP}" > /opt/hw4/server_ip.txt
    echo "Client VM ready.  Server IP: ${SERVER_IP}"
    ;;

*)
    echo "Unknown role: ${ROLE}" >&2
    ;;
esac

# ---- mark done so we don't re-run on reboot --------------------------------
touch /var/log/startup_already_done
echo "Startup complete for role=${ROLE}"
