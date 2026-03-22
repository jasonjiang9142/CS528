"""
CS528 HW5 – Service 2: Pub/Sub subscriber for forbidden-country requests.
Identical to HW4. Runs on its own VM, prints forbidden messages to stdout,
and appends them to a GCS log file.
"""

import os
import sys
import json
from datetime import datetime, timezone

from google.cloud import pubsub_v1, storage

PROJECT_ID      = os.environ.get("GCP_PROJECT", "serious-music-485622-t8")
BUCKET_NAME     = os.environ.get("GCS_BUCKET", "cs528-jx3onj-hw2")
SUBSCRIPTION_ID = os.environ.get("PUBSUB_SUBSCRIPTION", "forbidden-requests-sub")
LOG_BLOB        = "forbidden_logs/forbidden_requests.log"


def append_to_gcs_log(line):
    client = storage.Client(project=PROJECT_ID)
    bucket = client.bucket(BUCKET_NAME)
    blob = bucket.blob(LOG_BLOB)
    try:
        existing = blob.download_as_text()
    except Exception:
        existing = ""
    blob.upload_from_string(existing + line + "\n", content_type="text/plain")


def callback(message):
    try:
        data = json.loads(message.data.decode("utf-8"))
        msg_text = data.get("message", message.data.decode("utf-8"))
    except Exception:
        msg_text = message.data.decode("utf-8", errors="replace")

    timestamp = datetime.now(timezone.utc).isoformat()
    line = f"[{timestamp}] {msg_text}"
    print(f"[Forbidden] {msg_text}", flush=True)

    try:
        append_to_gcs_log(line)
    except Exception as exc:
        print(f"GCS log append failed: {exc}", file=sys.stderr)

    message.ack()


def main():
    subscriber = pubsub_v1.SubscriberClient()
    sub_path = subscriber.subscription_path(PROJECT_ID, SUBSCRIPTION_ID)
    print(f"Listening on {sub_path} …", flush=True)

    future = subscriber.subscribe(sub_path, callback=callback)
    try:
        future.result()
    except KeyboardInterrupt:
        future.cancel()
    finally:
        subscriber.close()


if __name__ == "__main__":
    main()
