# CS528 HW9 — Containerized web server on GKE

Builds on HW4. The HW4 VM-based web server is repackaged as a container
image and deployed to Google Kubernetes Engine (GKE) behind a
LoadBalancer Service. A second app (the Pub/Sub subscriber from HW4)
runs on a GCE VM and prints forbidden-country events.

## TL;DR (three-script lifecycle)

```bash
cd hw9

# 0. Make sure gcloud is set up once
gcloud config set project serious-music-485622-t8
gcloud config set compute/region us-central1
gcloud config set compute/zone   us-central1-a

# 1. Provision everything and deploy (APIs + Pub/Sub + cluster + VMs + app)
./setup.sh

# 2. Run the full demo suite end-to-end (curl + HTTP-client VM + subscriber VM)
./run_tests.sh

# 3. Tear it all down
./cleanup.sh
```

Each script has `--help`, `--dry-run`, and per-stage skip flags. See
the sections below for what they actually do.

## Architecture

```
             ┌────────────────────────────┐
 client VM   │  http_client.py / curl /   │
 + browser   │  browser                   │
             └──────────────┬─────────────┘
                            │  HTTP :8080
                            ▼
             ┌──────────────────────────────┐          ┌──────────────┐
             │  GKE Deployment: hw9-server  │──reads──▶│ GCS bucket    │
             │  Service type: LoadBalancer  │          │ cs528-jx3onj  │
             │  Workload Identity → GSA     │          │ -hw2/pages/*  │
             └───────────────┬──────────────┘          └──────────────┘
                             │     ▲
                  publish    │     │ Cloud Logging
                  (forbidden)│     │ 404 / 501 / 400
                             ▼     │
             ┌──────────────────────────────┐          ┌──────────────┐
             │  Pub/Sub topic:              │          │ Cloud Logging │
             │  forbidden-requests          │          │ (structured)  │
             └───────────────┬──────────────┘          └──────────────┘
                             │
                             ▼
             ┌──────────────────────────────┐
             │  GCE VM: subscriber.py       │
             │  → stdout + GCS log blob     │
             └──────────────────────────────┘
```

## Response-status behavior

The server enforces:

| Request                                   | Status | Logged to Cloud Logging                  |
| ----------------------------------------- | ------ | ----------------------------------------- |
| `GET /pages/page_00001.json` (exists)     | 200    | —                                         |
| `GET /pages/does_not_exist.json`          | 404    | WARNING, `error_type=not_found`           |
| `PUT/POST/DELETE/HEAD/CONNECT/OPTIONS/TRACE/PATCH` | 501 | WARNING, `error_type=method_not_allowed` |
| `GET` with `X-country: <banned>`          | 400    | CRITICAL + Pub/Sub publish to `forbidden-requests` |

Banned countries (hard-coded, lowercased): North Korea, Iran, Cuba,
Myanmar, Iraq, Libya, Sudan, Zimbabwe, Syria.

## Files

| File                       | Purpose                                       |
| -------------------------- | --------------------------------------------- |
| `server.py`                | Containerized web server (Service 1)          |
| `Dockerfile`               | Python 3.12 slim image                        |
| `requirements_server.txt`  | Server Python deps                            |
| `k8s/hw9-manifest.yaml`    | GKE ServiceAccount + Deployment + LB Service  |
| `deploy.sh`                | Build + push image, create GSA + bindings, apply manifest, wait for rollout |
| `diagnose.sh`              | Prints nodes / pod describe / events / logs when something is wrong |
| `k`                        | `kubectl` wrapper (falls back to Cloud SDK)   |
| `http_client.py`           | Run on a VM; fires hundreds of random GETs    |
| `demo_curl.sh`             | curl demos for 404, 501, 200, 400             |
| `subscriber.py`            | Service 2 (runs on a VM); prints forbidden    |
| `requirements_subscriber.txt` | Subscriber Python deps                     |
| `run_subscriber_on_vm.sh`  | venv + install + run subscriber on the VM    |

## Step-by-step

All commands below assume `gcloud config set project serious-music-485622-t8`
and `gcloud config set compute/region us-central1`.

### 0. Prereqs (one-time)

```
# Pub/Sub topic + subscription (same as HW4; safe if already exist)
gcloud pubsub topics create forbidden-requests || true
gcloud pubsub subscriptions create forbidden-requests-sub \
  --topic=forbidden-requests || true

# A GKE cluster (small is fine; Workload Identity ON is the important bit)
gcloud container clusters create-auto hw9-cluster --region=us-central1
# or zonal standard:
# gcloud container clusters create hw9-cluster \
#   --zone=us-central1-a --num-nodes=1 --machine-type=e2-small \
#   --workload-pool=serious-music-485622-t8.svc.id.goog
```

### 1. Build + deploy to GKE

```
cd hw9
export CLUSTER=hw9-cluster      # real name from: gcloud container clusters list
./deploy.sh
```

`deploy.sh` does:

1. Enables Artifact Registry / GKE / Cloud Build APIs.
2. Creates the `hw9` Artifact Registry repo if missing.
3. Builds the container image. Uses local Docker if present, otherwise
   `gcloud builds submit` (Cloud Build).
4. Fetches cluster credentials for `kubectl`.
5. Creates the Google service account `hw9-gke-server` and binds:
   `roles/storage.objectViewer`, `roles/logging.logWriter`,
   `roles/pubsub.publisher`, plus the `workloadIdentityUser` binding for
   the Kubernetes SA `default/hw9-server`.
6. Pre-flight: verifies at least one node is `Ready`.
7. Deletes any stale `hw9-server` Deployment/Pod (so leftover ReplicaSets
   from earlier runs can't keep a Pending Pod pinned).
8. Renders `k8s/hw9-manifest.yaml` with the real image / project / bucket /
   GSA email and `kubectl apply`s it.
9. Waits for the Deployment to become Ready. If the Pod is `Unschedulable`
   on a crowded single-node cluster, it resizes the node pool to 2 nodes
   and retries the rollout once.
10. Waits for the LoadBalancer `EXTERNAL-IP` and prints the ready-to-use
    client commands.

When rollout still fails, `deploy.sh` dumps nodes, pod `describe` events,
container logs, and recent cluster Warning events so you can see *why*
at a glance. For an ad-hoc check any time:

```
./diagnose.sh
```

Deployment strategy: `Recreate` (old Pod is terminated before the new
one starts). On a single-node e2-small cluster this is the only
reliable strategy; `RollingUpdate` with `maxSurge:0` can still leave a
new Pod `Pending` if the node's allocatable CPU/memory is over-committed
by the time the scheduler asks to place it.

### 2. Grab the external IP

```
./k get svc hw9-server
# EXTERNAL-IP  <addr>   8080
export BASE="http://<EXTERNAL-IP>:8080"
```

### 3. Demo: hundreds of cloud-storage requests from a VM

SSH into your client VM (any small GCE VM) and copy `http_client.py`
over, then:

```
python3 http_client.py --url "$BASE" --num 400 --delay 0.02
```

Expected output: `Done: 400 OK, 0 non-2xx out of 400 requests`.

### 4. Demo: 404 / 501 with curl

```
./demo_curl.sh
# or explicitly:
curl -i "$BASE/pages/does_not_exist_99999.json"        # 404
curl -i -X POST "$BASE/pages/page_00001.json"          # 501
curl -i -X DELETE "$BASE/pages/page_00001.json"        # 501
```

Cloud Logging: GKE Workloads -> `hw9-server` -> Logs, or
`logName="projects/serious-music-485622-t8/logs/run.googleapis.com%2Fstderr"`.
Filter by `jsonPayload.status_code=404` or `...=501` to see the
structured entries.

### 5. Demo: browser

Paste into the address bar:

- 200 -> `http://<EXTERNAL-IP>:8080/pages/page_00001.json`
- 404 -> `http://<EXTERNAL-IP>:8080/pages/does_not_exist_99999.json`
- 501 -> Browsers issue GET for normal navigation. Open DevTools ->
  Network, reload, right-click a request -> "Edit and resend" -> change
  method to POST; you will see 501. (A plain HTML `<form method="POST">`
  submitted to the same URL also works.)
- 400 -> `curl -H 'X-country: Iran' "$BASE/pages/page_00001.json"`
  (the address bar can't set headers).

### 6. Demo: second app on a VM (forbidden-country tracker)

On a second GCE VM (default service account needs `roles/pubsub.subscriber`
and `roles/storage.objectAdmin` on the bucket):

```
scp -r hw9 <vm>:~/
ssh <vm>
cd hw9
./run_subscriber_on_vm.sh
# Listening on projects/.../subscriptions/forbidden-requests-sub ...
```

From anywhere, trigger a forbidden request:

```
curl -H 'X-country: North Korea' "$BASE/pages/page_00001.json"
# HTTP/1.1 400 Bad Request
```

The subscriber VM prints:

```
[Forbidden] Permission denied: request from forbidden country 'North Korea' for /pages/page_00001.json
```

and appends the same line to `gs://cs528-jx3onj-hw2/forbidden_logs/forbidden_requests.log`.

## Cleanup

```
./k delete -f k8s/hw9-manifest.yaml 2>/dev/null || true
gcloud container clusters delete hw9-cluster --region=us-central1 --quiet
gcloud artifacts repositories delete hw9 --location=us-central1 --quiet
gcloud iam service-accounts delete \
  hw9-gke-server@serious-music-485622-t8.iam.gserviceaccount.com --quiet
```
