# CS528 HW9 — Report

**Student:** jx3onj (Jason Jiang)
**Project:** `serious-music-485622-t8`
**Region / zone:** `us-central1` / `us-central1-a`
**GKE cluster:** `hw9-cluster`
**Artifact Registry:** `us-central1-docker.pkg.dev/serious-music-485622-t8/hw9`
**GCS bucket:** `cs528-jx3onj-hw2` (20 000 `pages/page_*.json` files, re-used from HW2–HW4)
**External IP (current deploy):** `136.111.172.38:8080`

## 1. Architecture

Two-service system that ports the HW4 VM-based design into a container on
GKE plus a second VM-based subscriber:

```
        ┌──────────┐  HTTP :8080   ┌────────────────────────────┐   reads pages/*.json   ┌─────────────┐
        │  client  │ ────────────▶ │ GKE Deployment: hw9-server │ ─────────────────────▶ │ GCS bucket  │
        │  (VM /   │               │ Service: LoadBalancer      │                        │ cs528-...   │
        │  curl /  │ ◀──── 200/    │ 1 replica, WI → hw9-gke-   │                        └─────────────┘
        │  browser)│   404/501/400 │ server@...iam.gsa          │
        └──────────┘               │                            │
                                   │  structured JSON logs      │ ──▶ Cloud Logging
                                   │  (404 / 501 WARNING,       │
                                   │   400 CRITICAL)            │
                                   │                            │
                                   │  forbidden-country:        │ ──▶ Pub/Sub topic
                                   │  publish(JSON)             │     forbidden-requests
                                   └────────────────────────────┘
                                                                         │
                                                                         ▼
                                                           ┌──────────────────────┐
                                                           │ GCE VM: subscriber   │
                                                           │ subscriber.py        │
                                                           │ → stdout (+ GCS log) │
                                                           └──────────────────────┘
```

Why this design satisfies the assignment:

| Requirement from the assignment                                    | Where it lives                               |
| ------------------------------------------------------------------ | --------------------------------------------- |
| Port HW4 web server so it runs inside a container image under GKE  | `Dockerfile`, `server.py`, `k8s/hw9-manifest.yaml` |
| 404 for non-existent files, logged to Cloud Logging                | `server.py` `do_GET`                          |
| 501 for PUT/POST/DELETE/HEAD/CONNECT/OPTIONS/TRACE/PATCH, logged   | `server.py` `_unsupported`                    |
| Demo functionality using the provided HTTP client, run on a VM     | `http_client.py` (step 4)                     |
| curl demos for 404 / 501                                           | `demo_curl.sh` (step 5)                       |
| Browser demo for each status                                       | step 6                                        |
| Previously-created second app tracks banned-country requests       | `subscriber.py` + `run_subscriber_on_vm.sh`   |
| Second app runs on a VM                                            | step 7                                        |

## 2. Prerequisites (one-time GCP setup)

Done once; idempotent.

```bash
# 2.1 Project + region defaults
gcloud config set project serious-music-485622-t8
gcloud config set compute/region us-central1

# 2.2 APIs used by HW9 (deploy.sh also calls this; listed for completeness)
gcloud services enable \
  artifactregistry.googleapis.com \
  container.googleapis.com \
  cloudbuild.googleapis.com \
  pubsub.googleapis.com \
  logging.googleapis.com \
  storage.googleapis.com

# 2.3 Pub/Sub topic + subscription for the forbidden-country channel
gcloud pubsub topics create forbidden-requests               # ok if it already exists
gcloud pubsub subscriptions create forbidden-requests-sub \
  --topic=forbidden-requests

# 2.4 GKE cluster (Workload Identity is the important part)
gcloud container clusters create hw9-cluster \
  --zone=us-central1-a \
  --num-nodes=1 --machine-type=e2-small \
  --workload-pool=serious-music-485622-t8.svc.id.goog \
  --release-channel=regular
```

The bucket `cs528-jx3onj-hw2` and its 20 000 `pages/page_NNNNN.json`
files were created in HW2; no new data was uploaded for HW9.

## 3. Files in `hw9/`

```
hw9/
├── Dockerfile                   # Python 3.12-slim container image
├── requirements_server.txt      # google-cloud-{storage,logging,pubsub}
├── server.py                    # Service 1: containerized web server
├── k8s/
│   └── hw9-manifest.yaml        # ServiceAccount + Deployment + LoadBalancer
├── deploy.sh                    # build + push + IAM + apply + wait-for-Ready
├── diagnose.sh                  # on-demand cluster / pod / events dump
├── k                            # kubectl wrapper (falls back to Cloud SDK)
├── demo_curl.sh                 # 200/404/501/400 curl demos
├── http_client.py               # run on a VM; issues hundreds of GETs
├── run_subscriber_on_vm.sh      # venv + install + run subscriber on VM
├── requirements_subscriber.txt  # google-cloud-{pubsub,storage}
├── subscriber.py                # Service 2: Pub/Sub subscriber → stdout
└── REPORT.md / README.md
```

## 4. Build and deploy (single command)

From the repo root:

```bash
cd hw9
export CLUSTER=hw9-cluster
./deploy.sh
```

`deploy.sh` executes in this order (real terminal output is in step 9):

1. Resolves the cluster's location (`us-central1-a`) and verifies it exists.
2. Enables Artifact Registry / GKE / Cloud Build APIs and creates the
   `hw9` Artifact Registry repo.
3. Builds the container image and pushes it. Uses local Docker if
   present, otherwise falls back to Cloud Build (`gcloud builds submit`).
   Image tag is a timestamp, e.g.
   `us-central1-docker.pkg.dev/.../hw9/hw9-server:20260419-150817`.
4. Fetches cluster credentials (`kubectl`) and creates the Google
   service account **`hw9-gke-server`**. Binds:

   | Role                        | Why                                           |
   | --------------------------- | --------------------------------------------- |
   | `roles/storage.objectViewer`| read `pages/*.json` from the bucket           |
   | `roles/logging.logWriter`   | emit the 404/501/400 structured log entries   |
   | `roles/pubsub.publisher`    | publish forbidden-country events              |

   And the Workload Identity binding:
   ```
   serviceAccount:serious-music-485622-t8.svc.id.goog[default/hw9-server]
     → roles/iam.workloadIdentityUser on hw9-gke-server
   ```

5. Pre-flight: verifies at least one node is `Ready`.
6. Deletes any stale `hw9-server` Deployment so leftover ReplicaSets
   from earlier tries can't pin a `Pending` Pod on the single-node
   cluster.
7. Renders `k8s/hw9-manifest.yaml` (substitutes `__IMAGE__`,
   `__GCP_PROJECT__`, `__GCS_BUCKET__`, `__GSA_EMAIL__`) and runs
   `kubectl apply -f`.
8. Waits for `deployment/hw9-server` to be Ready (`strategy: Recreate`,
   5-min timeout). Auto-resizes node pool to 2 nodes and retries once
   if the Pod is `Unschedulable`.
9. Polls the Service for its `EXTERNAL-IP` and prints the ready-to-use
   client commands.

### Manifest summary (`k8s/hw9-manifest.yaml`)

- `ServiceAccount/hw9-server` in `default`, annotated with
  `iam.gke.io/gcp-service-account: hw9-gke-server@...` (Workload Identity).
- `Deployment/hw9-server`: 1 replica, `strategy: Recreate` (single-node
  friendly), image from Artifact Registry, env `GCP_PROJECT`,
  `GCS_BUCKET`, `PUBSUB_TOPIC=forbidden-requests`, `PORT=8080`;
  tiny resource requests (`cpu=10m`, `memory=64Mi`) and a TCP liveness
  probe; GCP clients are lazy-initialised inside `server.py` so the
  socket binds immediately on startup.
- `Service/hw9-server`: `type: LoadBalancer`, exposes `8080/TCP`.

## 5. Run the second app (subscriber) on a VM

The second service is the same Pub/Sub subscriber pattern from HW4; it
runs on a GCE VM so it satisfies "Run your second app on a VM".

```bash
# One-time: make sure the VM's default service account can subscribe
# and write to the log bucket. (Already true for this project from HW4.)
gcloud projects add-iam-policy-binding serious-music-485622-t8 \
  --member="serviceAccount:106019437761-compute@developer.gserviceaccount.com" \
  --role="roles/pubsub.subscriber" --quiet
gcloud storage buckets add-iam-policy-binding gs://cs528-jx3onj-hw2 \
  --member="serviceAccount:106019437761-compute@developer.gserviceaccount.com" \
  --role="roles/storage.objectAdmin" --quiet

# Copy hw9/ to the VM and launch
gcloud compute scp --recurse hw9 hw9-subscriber-vm:~/ --zone=us-central1-a
gcloud compute ssh hw9-subscriber-vm --zone=us-central1-a -- \
  'cd hw9 && ./run_subscriber_on_vm.sh'
```

`run_subscriber_on_vm.sh` creates a venv, installs
`google-cloud-pubsub` + `google-cloud-storage`, and runs
`subscriber.py`, which:

1. Prints `Listening on projects/.../subscriptions/forbidden-requests-sub …`.
2. For every message: decodes the JSON, prints `[Forbidden] <text>` on
   stdout, and appends the same line to
   `gs://cs528-jx3onj-hw2/forbidden_logs/forbidden_requests.log`.

## 6. Run the HTTP client (hundreds of requests) on a VM

```bash
gcloud compute scp hw9/http_client.py hw9-client-vm:~/ --zone=us-central1-a
gcloud compute ssh hw9-client-vm --zone=us-central1-a -- \
  'python3 http_client.py --url http://136.111.172.38:8080 --num 400 --delay 0.02'
```

Expected tail:

```
   20/400 done  (OK=20, other=0)
   ...
  400/400 done  (OK=400, other=0)
Done: 400 OK, 0 non-2xx out of 400 requests  (9.5s, ~42.1 req/s)
```

The client also accepts `--x-country random` which mixes
forbidden/allowed countries and exercises the 400 path; use this
variant to generate traffic for the subscriber screenshot.

## 7. curl demos (404, 501, 200, 400)

```bash
cd hw9
BASE=http://136.111.172.38:8080 ./demo_curl.sh
```

Expected output:

```
=== 404: missing object ===
HTTP 404
=== 501: POST ===
HTTP 501
=== 501: HEAD ===
HTTP 501
=== 200: GET (sanity) ===
HTTP 200
=== 400: forbidden country (subscriber should log) ===
HTTP 400
```

Individual calls (useful if running by hand):

```bash
curl -i "$BASE/pages/does_not_exist.json"                     # 404
curl -i -X POST "$BASE/pages/page_00001.json"                 # 501
curl -i -X DELETE "$BASE/pages/page_00001.json"               # 501
curl -i -X PUT   "$BASE/pages/page_00001.json"                # 501
curl -i -X PATCH "$BASE/pages/page_00001.json"                # 501
curl -i -H 'X-country: Iran'        "$BASE/pages/page_00001.json"  # 400
curl -i -H 'X-country: North Korea' "$BASE/pages/page_00001.json"  # 400
```

## 8. Browser demos

For each screenshot, include the browser DevTools → Network panel open
so the status code is visible.

- **200** → address bar: `http://136.111.172.38:8080/pages/page_00001.json`
  — JSON body renders in the tab; Network shows `200 OK`.
- **404** → address bar: `http://136.111.172.38:8080/pages/does_not_exist_99999.json`
  — body `Not Found`; Network shows `404 Not Found`.
- **501** → Browsers only send GET from the address bar, so use
  DevTools → Console:
  ```js
  fetch('http://136.111.172.38:8080/pages/page_00001.json', {method:'POST'})
    .then(r => console.log(r.status, r.statusText))
  ```
  Console prints `501 'Not Implemented'`; Network shows `501`.
- **400 (forbidden country)** — headers can't be set from the address
  bar either. DevTools → Console:
  ```js
  fetch('http://136.111.172.38:8080/pages/page_00001.json',
        {headers: {'X-country': 'Iran'}})
    .then(r => console.log(r.status))
  ```
  Console prints `400`.

## 9. Console views to screenshot for the write-up

All at https://console.cloud.google.com/ with project
`serious-music-485622-t8`.

### 9.1 Kubernetes Engine → Clusters

Navigate: **Kubernetes Engine → Clusters** → click `hw9-cluster`.
Screenshot the cluster summary page. Key fields to show:

- **Status:** green check.
- **Location:** `us-central1-a`.
- **Workload Identity:** `Enabled`, pool
  `serious-music-485622-t8.svc.id.goog`.
- **Node pools:** `default-pool`, 1 node, `e2-small`.

### 9.2 Kubernetes Engine → Workloads

Navigate: **Workloads**. You'll see `hw9-server` with status **OK**,
pod count **1/1**, namespace **default**, cluster **hw9-cluster**.
Click `hw9-server`:

- **Revision history** shows the container image tag
  `us-central1-docker.pkg.dev/.../hw9/hw9-server:20260419-150817`.
- **Overview → Managed pods** shows the single pod running with the
  node name `gke-hw9-cluster-default-pool-d55d5ed4-g6zs`.
- **YAML** tab shows the merged manifest with `strategy: Recreate`,
  resource requests/limits, the SA annotation, liveness probe, env
  vars.
- **Logs** tab shows the server's structured log lines as they come in.

Screenshot the Overview and YAML tabs.

### 9.3 Kubernetes Engine → Services & Ingress

Navigate: **Services & Ingress**. Find `hw9-server`, status **OK**,
type **External load balancer**, endpoints
`136.111.172.38:8080`. Click it for the Service detail:

- Kind `Service`, external endpoints `136.111.172.38:8080`.
- Selector `app=hw9-server`, target port `8080`.

### 9.4 Artifact Registry

Navigate: **Artifact Registry → Repositories → hw9**. You'll see the
image `hw9-server` with one or more tags
(`20260419-150817`, etc.). Click the latest tag → Details →
**Manifest** shows the image layers and digest
`sha256:0e64570d733a4249713b187e294ebe581af2f0368cbd8db048a323a097bdd1c6`.

### 9.5 Cloud Logging — 404, 501, 400 entries

Navigate: **Logging → Logs Explorer**. Paste these queries one at a
time and screenshot each result list.

```
# All hw9-server logs
resource.type="k8s_container"
resource.labels.cluster_name="hw9-cluster"
resource.labels.container_name="server"
```

```
# Just the 404s (WARNING)
resource.type="k8s_container"
resource.labels.cluster_name="hw9-cluster"
resource.labels.container_name="server"
jsonPayload.status_code=404
```

```
# Just the 501s (WARNING)
resource.type="k8s_container"
resource.labels.cluster_name="hw9-cluster"
resource.labels.container_name="server"
jsonPayload.status_code=501
```

```
# Just the forbidden-country 400s (CRITICAL)
resource.type="k8s_container"
resource.labels.cluster_name="hw9-cluster"
resource.labels.container_name="server"
severity=CRITICAL
jsonPayload.error_type="forbidden_country"
```

Click one entry in each query to expand the payload and show the
structured `json_fields` (`status_code`, `error_type`, `method`,
`path`, `country`, …).

### 9.6 Pub/Sub — forbidden-requests topic

Navigate: **Pub/Sub → Topics → forbidden-requests**. Show:

- Topic name, subscription count = 1 (`forbidden-requests-sub`).
- The subscription page: ACK deadline, unacked messages, recent
  delivery rate — after you run the 400 curl tests you'll see a small
  blip.

### 9.7 GCE → VM instances

Navigate: **Compute Engine → VM instances**. Highlight the two VMs
used for the demo:

- `hw9-subscriber-vm` — runs `subscriber.py`.
- `hw9-client-vm` — runs `http_client.py`.

Include SSH terminal screenshots from each VM showing their respective
output (the subscriber's `[Forbidden] …` lines, and the client's
`Done: 400 OK, …` summary).

## 10. Actual deploy run (annotated excerpt of terminal)

```
Project:     serious-music-485622-t8
Cluster:     hw9-cluster  (location us-central1-a, autopilot=)
Image:       us-central1-docker.pkg.dev/serious-music-485622-t8/hw9/hw9-server:20260419-150817
GSA:         hw9-gke-server@serious-music-485622-t8.iam.gserviceaccount.com
GCS bucket:  cs528-jx3onj-hw2
kubectl:     /opt/homebrew/share/google-cloud-sdk/bin/kubectl

...Cloud Build output (42s) finishing with:
  us-central1-docker.pkg.dev/.../hw9/hw9-server:20260419-150817  SUCCESS

--- Pre-flight: nodes ---
NAME                                         STATUS   ROLES    AGE   VERSION
gke-hw9-cluster-default-pool-d55d5ed4-g6zs   Ready    <none>   20h   v1.35.1-gke.1396002

--- Cleaning stale Deployment state (if any) ---
deployment.apps "hw9-server" deleted from default namespace
No resources found

--- Applying manifest ---
serviceaccount/hw9-server unchanged
deployment.apps/hw9-server created
service/hw9-server unchanged

--- Waiting for rollout (300s) ---
Waiting for deployment "hw9-server" rollout to finish: 0 of 1 updated replicas are available...
deployment "hw9-server" successfully rolled out

--- Service ---
NAME         TYPE           CLUSTER-IP       EXTERNAL-IP      PORT(S)          AGE
hw9-server   LoadBalancer   34.118.225.127   136.111.172.38   8080:30177/TCP   39m

============================================================
 HW9 is up.  EXTERNAL-IP: 136.111.172.38
============================================================
```

## 11. Cleanup (when the demo is submitted)

```bash
cd hw9
# Delete the Deployment + Service (keeps image + cluster)
./k delete deployment/hw9-server service/hw9-server serviceaccount/hw9-server

# Or tear down everything
gcloud container clusters delete hw9-cluster --zone=us-central1-a --quiet
gcloud artifacts repositories delete hw9 --location=us-central1 --quiet
gcloud iam service-accounts delete \
  hw9-gke-server@serious-music-485622-t8.iam.gserviceaccount.com --quiet

# Delete VMs
gcloud compute instances delete hw9-subscriber-vm hw9-client-vm \
  --zone=us-central1-a --quiet
```
