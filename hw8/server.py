"""
CS528 HW8 – Service 1: Python web server with zone header.

Identical to HW4 server.py, but adds an X-Server-Zone response header
containing the GCE zone the instance is running in (queried once at startup
from the instance metadata server).

Status codes:
  200 – file found and returned
  400 – request from a forbidden (export-restricted) country  (CRITICAL)
  404 – file not found                                        (WARNING)
  501 – HTTP method not implemented                           (WARNING)
"""

import os
import json
import logging
from http.server import BaseHTTPRequestHandler, HTTPServer
from socketserver import ThreadingMixIn
from urllib.parse import urlparse
from urllib.request import Request, urlopen

from google.cloud import storage, pubsub_v1
from google.cloud import logging as cloud_logging

BUCKET_NAME = os.environ.get("GCS_BUCKET", "cs528-jx3onj-hw2")
PROJECT_ID = os.environ.get("GCP_PROJECT", "serious-music-485622-t8")
TOPIC_ID = os.environ.get("PUBSUB_TOPIC", "forbidden-requests")
PORT = int(os.environ.get("PORT", "8080"))
GCS_PREFIX = "pages/"

FORBIDDEN_COUNTRIES = frozenset([
    "north korea", "iran", "cuba", "myanmar",
    "iraq", "libya", "sudan", "zimbabwe", "syria",
])


def _get_zone() -> str:
    """Fetch the instance zone from the GCE metadata server (returns e.g. 'us-central1-a')."""
    try:
        req = Request(
            "http://metadata.google.internal/computeMetadata/v1/instance/zone",
            headers={"Metadata-Flavor": "Google"},
        )
        resp = urlopen(req, timeout=5).read().decode()
        return resp.strip().split("/")[-1]
    except Exception:
        return "unknown"


INSTANCE_ZONE = _get_zone()

_log_client = cloud_logging.Client(project=PROJECT_ID)
_log_client.setup_logging()

_storage_client = storage.Client(project=PROJECT_ID)
_publisher = pubsub_v1.PublisherClient()
_topic_path = _publisher.topic_path(PROJECT_ID, TOPIC_ID)


class ThreadedHTTPServer(ThreadingMixIn, HTTPServer):
    daemon_threads = True


class RequestHandler(BaseHTTPRequestHandler):

    def _send(self, code, body, content_type="text/plain; charset=utf-8"):
        encoded = body.encode("utf-8") if isinstance(body, str) else body
        self.send_response(code)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(encoded)))
        self.send_header("X-Server-Zone", INSTANCE_ZONE)
        self.end_headers()
        self.wfile.write(encoded)

    @staticmethod
    def _object_name(raw_path):
        path = raw_path.strip("/")
        if not path:
            return ""
        return path if path.startswith("pages/") else GCS_PREFIX + path

    def do_GET(self):
        path = urlparse(self.path).path.strip("/")

        if path == "health":
            self._send(200, "ok")
            return

        country = (self.headers.get("X-country") or "").strip()
        if country and country.lower() in FORBIDDEN_COUNTRIES:
            logging.critical(
                "Forbidden country request: country=%s path=%s",
                country, path,
                extra={"json_fields": {
                    "status_code": 400, "error_type": "forbidden_country",
                    "country": country, "path": path,
                }},
            )
            try:
                payload = json.dumps({
                    "country": country,
                    "path": path,
                    "message": (
                        f"Permission denied: request from forbidden country "
                        f"'{country}' for /{path}"
                    ),
                }).encode("utf-8")
                _publisher.publish(_topic_path, payload).result(timeout=10)
            except Exception as exc:
                logging.error("Pub/Sub publish failed: %s", exc)
            self._send(400, "Permission denied: export to this country is not allowed")
            return

        obj_name = self._object_name(path)

        if not obj_name or not obj_name.endswith(".json"):
            logging.warning(
                "404 Not Found: path=%s (invalid object name)",
                path,
                extra={"json_fields": {
                    "status_code": 404, "error_type": "not_found", "path": path,
                }},
            )
            self._send(404, "Not Found")
            return

        try:
            bucket = _storage_client.bucket(BUCKET_NAME)
            blob = bucket.blob(obj_name)
            if not blob.exists():
                logging.warning(
                    "404 Not Found: gs://%s/%s does not exist",
                    BUCKET_NAME, obj_name,
                    extra={"json_fields": {
                        "status_code": 404, "error_type": "not_found",
                        "path": path, "object": obj_name,
                    }},
                )
                self._send(404, "Not Found")
                return
            content = blob.download_as_text()
            self._send(200, content, "application/json; charset=utf-8")
        except Exception as exc:
            logging.warning(
                "Error reading gs://%s/%s: %s",
                BUCKET_NAME, obj_name, exc,
                extra={"json_fields": {
                    "status_code": 404, "error_type": "not_found",
                    "path": path, "object": obj_name,
                }},
            )
            self._send(404, "Not Found")

    def _unsupported(self):
        method = self.command
        path = self.path
        logging.warning(
            "501 Not Implemented: method=%s path=%s",
            method, path,
            extra={"json_fields": {
                "status_code": 501, "error_type": "method_not_allowed",
                "method": method, "path": path,
            }},
        )
        self._send(501, "Method Not Implemented")

    do_PUT     = _unsupported
    do_POST    = _unsupported
    do_DELETE  = _unsupported
    do_HEAD    = _unsupported
    do_CONNECT = _unsupported
    do_OPTIONS = _unsupported
    do_TRACE   = _unsupported
    do_PATCH   = _unsupported

    def log_request(self, code="-", size="-"):
        pass


if __name__ == "__main__":
    server = ThreadedHTTPServer(("0.0.0.0", PORT), RequestHandler)
    print(
        f"HW8 server listening on 0.0.0.0:{PORT}  "
        f"bucket={BUCKET_NAME}  project={PROJECT_ID}  zone={INSTANCE_ZONE}",
        flush=True,
    )
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    server.server_close()
