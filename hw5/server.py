"""
CS528 HW5 – Service 1: Python web server with Cloud SQL integration.
Serves files from a GCS bucket over HTTP and logs every request to PostgreSQL.

Tables
  requests        – successful (200) requests with full metadata
  failed_requests – non-200 responses (time, file, error code)
"""

import os
import json
import logging
import threading
import time
from http.server import BaseHTTPRequestHandler, HTTPServer
from socketserver import ThreadingMixIn
from urllib.parse import urlparse
from datetime import datetime, timezone

import pg8000
from google.cloud import storage, pubsub_v1
from google.cloud import logging as cloud_logging

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------
BUCKET_NAME  = os.environ.get("GCS_BUCKET", "cs528-jx3onj-hw2")
PROJECT_ID   = os.environ.get("GCP_PROJECT", "serious-music-485622-t8")
TOPIC_ID     = os.environ.get("PUBSUB_TOPIC", "forbidden-requests")
PORT         = int(os.environ.get("PORT", "8080"))
GCS_PREFIX   = "pages/"

DB_HOST = os.environ.get("DB_HOST", "127.0.0.1")
DB_PORT = int(os.environ.get("DB_PORT", "5432"))
DB_NAME = os.environ.get("DB_NAME", "hw5db")
DB_USER = os.environ.get("DB_USER", "hw5user")
DB_PASS = os.environ.get("DB_PASS", "")

FORBIDDEN_COUNTRIES = frozenset([
    "north korea", "iran", "cuba", "myanmar",
    "iraq", "libya", "sudan", "zimbabwe", "syria",
])

# ---------------------------------------------------------------------------
# Global clients (created once)
# ---------------------------------------------------------------------------
_log_client = cloud_logging.Client(project=PROJECT_ID)
_log_client.setup_logging()

_storage_client = storage.Client(project=PROJECT_ID)
_publisher = pubsub_v1.PublisherClient()
_topic_path = _publisher.topic_path(PROJECT_ID, TOPIC_ID)

# ---------------------------------------------------------------------------
# Database helpers  (thread-local connections, auto-reconnect)
# ---------------------------------------------------------------------------
_local = threading.local()


def _new_db_conn():
    conn = pg8000.connect(
        host=DB_HOST, port=DB_PORT,
        database=DB_NAME, user=DB_USER, password=DB_PASS,
    )
    conn.autocommit = True
    return conn


def get_db_conn():
    conn = getattr(_local, "conn", None)
    if conn is None:
        try:
            _local.conn = _new_db_conn()
        except Exception as exc:
            logging.error("DB connect failed: %s", exc)
            _local.conn = None
    return _local.conn


def init_db():
    """Create tables if they don't exist (called once at startup)."""
    conn = _new_db_conn()
    cur = conn.cursor()
    cur.execute("""
        CREATE TABLE IF NOT EXISTS requests (
            id             SERIAL PRIMARY KEY,
            country        VARCHAR(100),
            client_ip      VARCHAR(45),
            gender         VARCHAR(20),
            age            INTEGER,
            income         VARCHAR(50),
            is_banned      BOOLEAN DEFAULT FALSE,
            time_of_day    TIMESTAMP DEFAULT NOW(),
            requested_file VARCHAR(500)
        )
    """)
    cur.execute("""
        CREATE TABLE IF NOT EXISTS failed_requests (
            id              SERIAL PRIMARY KEY,
            time_of_request TIMESTAMP DEFAULT NOW(),
            requested_file  VARCHAR(500),
            error_code      INTEGER
        )
    """)
    cur.close()
    conn.close()


def db_log_success(country, client_ip, gender, age, income, is_banned, requested_file):
    conn = get_db_conn()
    if conn is None:
        return
    try:
        cur = conn.cursor()
        cur.execute(
            "INSERT INTO requests "
            "(country, client_ip, gender, age, income, is_banned, time_of_day, requested_file) "
            "VALUES (%s,%s,%s,%s,%s,%s,%s,%s)",
            (country, client_ip, gender, age, income, is_banned,
             datetime.now(timezone.utc), requested_file),
        )
        cur.close()
    except Exception as exc:
        logging.error("DB insert (requests) failed: %s", exc)
        _local.conn = None


def db_log_failure(requested_file, error_code):
    conn = get_db_conn()
    if conn is None:
        return
    try:
        cur = conn.cursor()
        cur.execute(
            "INSERT INTO failed_requests (time_of_request, requested_file, error_code) "
            "VALUES (%s,%s,%s)",
            (datetime.now(timezone.utc), requested_file, error_code),
        )
        cur.close()
    except Exception as exc:
        logging.error("DB insert (failed_requests) failed: %s", exc)
        _local.conn = None


# ---------------------------------------------------------------------------
# Timing instrumentation  (time.perf_counter for high-accuracy)
# ---------------------------------------------------------------------------
_timing_lock = threading.Lock()
_timing_data = {
    "parse_headers": [],
    "gcs_read":      [],
    "db_write":      [],
    "send_response": [],
}
_TIMING_LOG_INTERVAL = 1000
_timing_count = 0


def _record_timing(category, elapsed_sec):
    global _timing_count
    with _timing_lock:
        _timing_data[category].append(elapsed_sec)
        _timing_count += 1
        if _timing_count % _TIMING_LOG_INTERVAL == 0:
            _print_timing_summary()


def _print_timing_summary():
    """Print average timings per category (called under lock)."""
    print(f"\n{'='*65}", flush=True)
    print(f" Timing summary  ({_timing_count} total events)", flush=True)
    print(f" {'Category':<20s} {'Count':>8s} {'Avg (ms)':>10s} {'Min (ms)':>10s} {'Max (ms)':>10s}", flush=True)
    print(f" {'-'*58}", flush=True)
    for cat in ("parse_headers", "gcs_read", "db_write", "send_response"):
        samples = _timing_data[cat]
        if samples:
            avg = sum(samples) / len(samples) * 1000
            mn  = min(samples) * 1000
            mx  = max(samples) * 1000
            print(f" {cat:<20s} {len(samples):>8d} {avg:>10.3f} {mn:>10.3f} {mx:>10.3f}", flush=True)
        else:
            print(f" {cat:<20s} {'—':>8s}", flush=True)
    print(f"{'='*65}\n", flush=True)
    for cat in _timing_data:
        _timing_data[cat].clear()


def _log_request_timing(path, code, timings):
    """Log per-request timing breakdown using high-accuracy perf_counter data."""
    parts = []
    for label, elapsed in timings:
        parts.append(f"{label}={elapsed*1000:.3f}ms")
    total = sum(e for _, e in timings)
    msg = f"TIMING path=/{path} status={code} total={total*1000:.3f}ms | {'  '.join(parts)}"
    print(msg, flush=True)
    logging.info(msg)


# ---------------------------------------------------------------------------
# HTTP server
# ---------------------------------------------------------------------------
class ThreadedHTTPServer(ThreadingMixIn, HTTPServer):
    daemon_threads = True


class RequestHandler(BaseHTTPRequestHandler):

    # -- instrumented helpers -----------------------------------------------

    def _send_response_timed(self, code, body, content_type="text/plain; charset=utf-8"):
        """Send full HTTP response to the client."""
        encoded = body.encode("utf-8") if isinstance(body, str) else body
        t0 = time.perf_counter()
        self.send_response(code)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(encoded)))
        self.end_headers()
        self.wfile.write(encoded)
        elapsed = time.perf_counter() - t0
        _record_timing("send_response", elapsed)
        return elapsed

    def _parse_request_headers(self):
        """Parse the incoming request and extract all custom headers."""
        t0 = time.perf_counter()
        info = {
            "path":      urlparse(self.path).path.strip("/"),
            "country":   (self.headers.get("X-country") or "").strip(),
            "gender":    (self.headers.get("X-gender") or "").strip(),
            "income":    (self.headers.get("X-income") or "").strip(),
            "client_ip": self.client_address[0],
        }
        try:
            info["age"] = int(self.headers.get("X-age", "0"))
        except (ValueError, TypeError):
            info["age"] = 0
        info["is_banned"] = bool(
            info["country"] and info["country"].lower() in FORBIDDEN_COUNTRIES
        )
        elapsed = time.perf_counter() - t0
        _record_timing("parse_headers", elapsed)
        return info, elapsed

    def _read_from_gcs(self, obj_name):
        """Read a file from Cloud Storage. Returns (content_or_None, elapsed)."""
        t0 = time.perf_counter()
        try:
            bucket = _storage_client.bucket(BUCKET_NAME)
            blob = bucket.blob(obj_name)
            if not blob.exists():
                elapsed = time.perf_counter() - t0
                _record_timing("gcs_read", elapsed)
                return None, elapsed
            content = blob.download_as_text()
            elapsed = time.perf_counter() - t0
            _record_timing("gcs_read", elapsed)
            return content, elapsed
        except Exception:
            elapsed = time.perf_counter() - t0
            _record_timing("gcs_read", elapsed)
            return None, elapsed

    def _db_insert_success(self, info):
        """Insert a successful request row into the database."""
        t0 = time.perf_counter()
        db_log_success(
            info["country"], info["client_ip"], info["gender"],
            info["age"], info["income"], info["is_banned"], info["path"],
        )
        elapsed = time.perf_counter() - t0
        _record_timing("db_write", elapsed)
        return elapsed

    def _db_insert_failure(self, path, code):
        """Insert a failed-request row into the database."""
        t0 = time.perf_counter()
        db_log_failure(path, code)
        elapsed = time.perf_counter() - t0
        _record_timing("db_write", elapsed)
        return elapsed

    @staticmethod
    def _object_name(raw_path):
        path = raw_path.strip("/")
        if not path:
            return ""
        return path if path.startswith("pages/") else GCS_PREFIX + path

    # -- GET ----------------------------------------------------------------

    def do_GET(self):
        info, t_parse = self._parse_request_headers()
        path = info["path"]

        # -- forbidden country (CRITICAL + Pub/Sub + DB fail log) -----------
        if info["is_banned"]:
            logging.critical(
                "Forbidden country request: country=%s path=%s",
                info["country"], path,
                extra={"json_fields": {
                    "status_code": 400, "error_type": "forbidden_country",
                    "country": info["country"], "path": path,
                }},
            )
            try:
                payload = json.dumps({
                    "country": info["country"], "path": path,
                    "message": (
                        f"Permission denied: request from forbidden country "
                        f"'{info['country']}' for /{path}"
                    ),
                }).encode("utf-8")
                _publisher.publish(_topic_path, payload).result(timeout=10)
            except Exception as exc:
                logging.error("Pub/Sub publish failed: %s", exc)
            t_db = self._db_insert_failure(path, 400)
            t_send = self._send_response_timed(400, "Permission denied: export to this country is not allowed")
            _log_request_timing(path, 400, [
                ("parse_headers", t_parse), ("db_write", t_db),
                ("send_response", t_send),
            ])
            return

        # -- resolve GCS object name ----------------------------------------
        obj_name = self._object_name(path)
        if not obj_name or not obj_name.endswith(".json"):
            logging.warning(
                "404 Not Found: path=%s", path,
                extra={"json_fields": {"status_code": 404, "path": path}},
            )
            t_db = self._db_insert_failure(path, 404)
            t_send = self._send_response_timed(404, "Not Found")
            _log_request_timing(path, 404, [
                ("parse_headers", t_parse), ("db_write", t_db),
                ("send_response", t_send),
            ])
            return

        # -- fetch from GCS -------------------------------------------------
        content, t_gcs = self._read_from_gcs(obj_name)
        if content is None:
            logging.warning(
                "404 Not Found: gs://%s/%s", BUCKET_NAME, obj_name,
                extra={"json_fields": {"status_code": 404, "path": path}},
            )
            t_db = self._db_insert_failure(path, 404)
            t_send = self._send_response_timed(404, "Not Found")
            _log_request_timing(path, 404, [
                ("parse_headers", t_parse), ("gcs_read", t_gcs),
                ("db_write", t_db), ("send_response", t_send),
            ])
            return

        t_db = self._db_insert_success(info)
        t_send = self._send_response_timed(200, content, "application/json; charset=utf-8")
        _log_request_timing(path, 200, [
            ("parse_headers", t_parse), ("gcs_read", t_gcs),
            ("db_write", t_db), ("send_response", t_send),
        ])

    # -- all other methods → 501 --------------------------------------------

    def _unsupported(self):
        method = self.command
        path = urlparse(self.path).path.strip("/")
        logging.warning(
            "501 Not Implemented: method=%s path=%s", method, path,
            extra={"json_fields": {"status_code": 501, "method": method, "path": path}},
        )
        t_db = self._db_insert_failure(path, 501)
        t_send = self._send_response_timed(501, "Method Not Implemented")
        _log_request_timing(path, 501, [
            ("db_write", t_db), ("send_response", t_send),
        ])

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


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
if __name__ == "__main__":
    print("Initializing database tables …", flush=True)
    init_db()
    server = ThreadedHTTPServer(("0.0.0.0", PORT), RequestHandler)
    print(
        f"HW5 server on 0.0.0.0:{PORT}  bucket={BUCKET_NAME}  "
        f"db={DB_HOST}:{DB_PORT}/{DB_NAME}",
        flush=True,
    )
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    server.server_close()
