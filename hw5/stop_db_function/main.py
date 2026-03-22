"""
CS528 HW5 – Cloud Function: auto-stop the Cloud SQL instance.
Triggered by Cloud Scheduler every hour.
If the instance is RUNNABLE it is stopped (activation_policy → NEVER).
"""

import os
import functions_framework
from googleapiclient.discovery import build

PROJECT_ID    = os.environ.get("GCP_PROJECT", "serious-music-485622-t8")
INSTANCE_NAME = os.environ.get("DB_INSTANCE_NAME", "hw5-db")


@functions_framework.http
def stop_db(request):
    service = build("sqladmin", "v1beta4", cache_discovery=False)

    instance = (
        service.instances()
        .get(project=PROJECT_ID, instance=INSTANCE_NAME)
        .execute()
    )
    state = instance.get("state", "UNKNOWN")

    if state == "RUNNABLE":
        service.instances().patch(
            project=PROJECT_ID,
            instance=INSTANCE_NAME,
            body={"settings": {"activationPolicy": "NEVER"}},
        ).execute()
        msg = f"Stopped Cloud SQL instance '{INSTANCE_NAME}'"
        print(msg)
        return (msg, 200)

    msg = f"Instance '{INSTANCE_NAME}' is in state {state} – no action taken"
    print(msg)
    return (msg, 200)
