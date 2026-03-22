#!/usr/bin/env bash
# ============================================================================
# startup.sh  –  Unified HW5 VM startup (role-based via instance metadata).
# Roles: server | subscriber | client
# ============================================================================
set -euo pipefail

if [ -f /var/log/startup_already_done ]; then
    echo "Startup script already ran once. Skipping."
    exit 0
fi

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
DB_HOST=$(meta db-host)
DB_PORT=$(meta db-port)
DB_NAME=$(meta db-name)
DB_USER=$(meta db-user)
DB_PASS=$(meta db-pass)

echo "=========================================="
echo " HW5 startup  role=${ROLE}"
echo "=========================================="

apt-get update -y
apt-get install -y python3 python3-pip python3-venv

mkdir -p /opt/hw5
gsutil -m cp "gs://${CODE_BUCKET}/hw5/*" /opt/hw5/
chmod +x /opt/hw5/*.sh 2>/dev/null || true

python3 -m venv /opt/hw5/venv
/opt/hw5/venv/bin/pip install --upgrade pip

case "${ROLE}" in

# ===== SERVER ==============================================================
server)
    /opt/hw5/venv/bin/pip install --prefer-binary -r /opt/hw5/requirements_server.txt

    cat > /etc/systemd/system/hw5-server.service <<UNIT
[Unit]
Description=HW5 Web Server (Service 1)
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=/opt/hw5/venv/bin/python /opt/hw5/server.py
Environment=GCS_BUCKET=${GCS_BUCKET}
Environment=GCP_PROJECT=${GCP_PROJECT}
Environment=PUBSUB_TOPIC=${PUBSUB_TOPIC}
Environment=PORT=8080
Environment=DB_HOST=${DB_HOST}
Environment=DB_PORT=${DB_PORT}
Environment=DB_NAME=${DB_NAME}
Environment=DB_USER=${DB_USER}
Environment=DB_PASS=${DB_PASS}
Restart=always
RestartSec=3
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
UNIT

    systemctl daemon-reload
    systemctl enable hw5-server
    systemctl start hw5-server
    echo "Server started on port 8080"
    ;;

# ===== SUBSCRIBER ==========================================================
subscriber)
    /opt/hw5/venv/bin/pip install --prefer-binary -r /opt/hw5/requirements_subscriber.txt

    cat > /etc/systemd/system/hw5-subscriber.service <<UNIT
[Unit]
Description=HW5 Pub/Sub Subscriber (Service 2)
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=/opt/hw5/venv/bin/python /opt/hw5/subscriber.py
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
    systemctl enable hw5-subscriber
    systemctl start hw5-subscriber
    echo "Subscriber started"
    ;;

# ===== CLIENT ==============================================================
client)
    /opt/hw5/venv/bin/pip install --prefer-binary urllib3
    echo "${SERVER_IP}" > /opt/hw5/server_ip.txt
    echo "Client VM ready.  Server IP: ${SERVER_IP}"
    ;;

*)
    echo "Unknown role: ${ROLE}" >&2
    ;;
esac

touch /var/log/startup_already_done
echo "Startup complete for role=${ROLE}"
