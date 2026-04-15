#!/usr/bin/env bash
# ============================================================================
# startup.sh – VM startup script for HW8 (load-balanced web servers).
#
# Reads "vm-role" metadata. Only the "server" role is needed for HW8.
# Installs deps, downloads code from GCS staging bucket, starts systemd unit.
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

echo "=========================================="
echo " HW8 startup  role=${ROLE}"
echo "=========================================="

apt-get update -y
apt-get install -y python3 python3-pip python3-venv ca-certificates

update-ca-certificates

mkdir -p /opt/hw8
gsutil -m cp "gs://${CODE_BUCKET}/hw8/*" /opt/hw8/
chmod +x /opt/hw8/*.sh 2>/dev/null || true

python3 -m venv /opt/hw8/venv
/opt/hw8/venv/bin/pip install --upgrade pip
/opt/hw8/venv/bin/pip install --prefer-binary -r /opt/hw8/requirements_server.txt

case "${ROLE}" in

server)
    cat > /etc/systemd/system/hw8-server.service <<UNIT
[Unit]
Description=HW8 Web Server (Service 1 with zone header)
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=/opt/hw8/venv/bin/python /opt/hw8/server.py
Environment=GCS_BUCKET=${GCS_BUCKET}
Environment=GCP_PROJECT=${GCP_PROJECT}
Environment=PUBSUB_TOPIC=${PUBSUB_TOPIC}
Environment=PORT=8080
Environment=REQUESTS_CA_BUNDLE=/etc/ssl/certs/ca-certificates.crt
Environment=GCE_METADATA_MTLS_MODE=none
Restart=always
RestartSec=3
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
UNIT

    systemctl daemon-reload
    systemctl enable hw8-server
    systemctl start hw8-server
    echo "Server started on port 8080"
    ;;

*)
    echo "Unknown role: ${ROLE}" >&2
    ;;
esac

touch /var/log/startup_already_done
echo "Startup complete for role=${ROLE}"
