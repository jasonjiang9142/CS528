# CS528 HW5 — Configuration and Deployment Guide

**Author:** Jason Jiang  
**Project ID:** `serious-music-485622-t8`  
**Region:** `us-central1` | **Zone:** `us-central1-a`

---

## 1. Architecture Overview

The system consists of three services running on Google Cloud:

| Component | VM / Resource | Description |
|---|---|---|
| **Service 1 — Web Server** | `hw5-server-vm` (e2-small) | Python HTTP server on port 8080. Serves JSON files from GCS, logs requests to Cloud SQL, publishes forbidden-country alerts to Pub/Sub. Instrumented with `time.perf_counter()` for high-accuracy timing. |
| **Service 2 — Subscriber** | `hw5-subscriber-vm` (e2-micro) | Pub/Sub subscriber that listens for forbidden-country alerts and appends them to a GCS log file. |
| **Client** | `hw5-client-vm` (e2-micro) | Sends HTTP requests to the server with randomized demographic headers (country, gender, age, income). |
| **Cloud SQL** | `hw5-db` (db-f1-micro, PostgreSQL 14) | Stores successful requests in `requests` table and failed requests in `failed_requests` table. Private IP only. |
| **Cloud Function** | `stop-hw5-db` | Runs hourly via Cloud Scheduler to stop the database if it is running, preventing unnecessary charges. |

### Network Diagram

```
Client VM ──HTTP:8080──► Server VM ──private IP──► Cloud SQL (PostgreSQL)
   (no ext IP)          (static IP)                (no ext IP)
                            │
                            ├──► GCS bucket (cs528-jx3onj-hw2/pages/*.json)
                            │
                            └──Pub/Sub──► Subscriber VM ──► GCS log file
                                           (no ext IP)
```

---

## 2. Prerequisites (One-Time Setup)

These are created once by `setup.sh` and persist across start/stop cycles.

### 2.1 Install and Authenticate gcloud CLI

```bash
# Install: https://cloud.google.com/sdk/docs/install
gcloud auth login
gcloud config set project serious-music-485622-t8
```

### 2.2 Run the Full Setup Script

```bash
cd hw5/
bash setup.sh
```

This creates all infrastructure in ~10-15 minutes:

| Step | What It Creates |
|---|---|
| APIs | Enables Compute, Pub/Sub, Logging, Storage, SQL Admin, Cloud Functions, Scheduler, Cloud Build, Cloud Run |
| Service Accounts | `hw5-server-sa`, `hw5-subscriber-sa`, `hw5-db-stopper-sa` |
| IAM Roles | See Section 2.3 below |
| Pub/Sub | Topic `forbidden-requests`, subscription `forbidden-requests-sub` |
| VPC Peering | Private Services Access for Cloud SQL |
| Cloud SQL | `hw5-db` — PostgreSQL 14, db-f1-micro, private IP, HDD |
| Database | `hw5db` database, user `hw5user` |
| Code Bucket | `gs://serious-music-485622-t8-hw5-code/hw5/` with all source files |
| Static IP | `hw5-server-ip` (34.135.208.53) |
| Firewall | `hw5-allow-http-8080` — allows TCP:8080 to tagged VMs |
| VMs | `hw5-server-vm`, `hw5-subscriber-vm`, `hw5-client-vm` |
| Cloud Function | `stop-hw5-db` — HTTP-triggered, stops the DB |
| Cloud Scheduler | `stop-hw5-db-job` — runs every hour (`0 * * * *`) |

### 2.3 Service Account Permissions

| Service Account | IAM Roles |
|---|---|
| `hw5-server-sa` | `roles/storage.objectViewer`, `roles/pubsub.publisher`, `roles/logging.logWriter`, `roles/cloudsql.client` |
| `hw5-subscriber-sa` | `roles/pubsub.subscriber`, `roles/storage.objectViewer`, `roles/logging.logWriter`, plus `roles/storage.objectAdmin` on bucket |
| `hw5-db-stopper-sa` | `roles/cloudsql.admin`, `roles/logging.logWriter` |

---

## 3. Starting All Services

```bash
cd hw5/
bash start_all.sh
```

**What it does (in order):**

1. **Uploads latest code** to `gs://<PROJECT_ID>-hw5-code/hw5/`
2. **Starts Cloud SQL** — sets `activationPolicy=ALWAYS`, waits until `RUNNABLE` (~3-5 min if stopped)
3. **Pauses the hourly DB-stopper** scheduler job so it doesn't kill the DB while in use
4. **Starts or creates the 3 VMs** — if a VM exists but is stopped, it starts it; if missing, it creates it with the startup script
5. **SSHs into server and subscriber VMs** to pull latest code and restart their systemd services

**Expected output:**

```
[1/5] Uploading latest code …
[2/5] Starting Cloud SQL instance 'hw5-db' …
  Already running.  (or waits for RUNNABLE)
[3/5] Pausing Cloud Scheduler stop-db job …
[4/5] Starting VMs …
  hw5-server-vm: already running
  hw5-subscriber-vm: already running
  hw5-client-vm: already running
[5/5] Ensuring services are running on VMs …
  hw5-server restarted
  hw5-subscriber restarted

All services started!
  Server VM: http://34.135.208.53:8080
```

**If VMs were just created**, wait ~3-5 minutes for the startup scripts to install dependencies and launch services.

---

## 4. Testing the Server

### 4.1 Basic Requests (from any machine)

```bash
# Successful request
curl -i -H "X-country: US" -H "X-gender: Male" -H "X-age: 30" \
     -H "X-income: 50k-75k" http://34.135.208.53:8080/pages/page_00001.json

# Forbidden country (returns 400)
curl -i -H "X-country: Iran" http://34.135.208.53:8080/pages/page_00001.json

# Non-existent file (returns 404)
curl -i http://34.135.208.53:8080/pages/nonexistent.json

# Unsupported method (returns 501)
curl -i -X PUT http://34.135.208.53:8080/pages/page_00001.json
```

### 4.2 Stress Test (from client VM)

```bash
gcloud compute ssh hw5-client-vm --zone=us-central1-a --tunnel-through-iap

# On the client VM:
sudo bash /opt/hw5/stress_test.sh 10.128.0.14 42 50000
```

This runs 2 concurrent clients x 50,000 requests each (100,000 total) with seed 42 for reproducibility.

### 4.3 View Timing Output (from server VM)

```bash
gcloud compute ssh hw5-server-vm --zone=us-central1-a \
    --command="sudo journalctl -u hw5-server --no-pager | grep TIMING | tail -10"
```

Example output:
```
TIMING path=/pages/page_04188.json status=200 total=146.580ms |
  parse_headers=0.032ms  gcs_read=69.637ms  db_write=76.807ms  send_response=0.104ms
```

### 4.4 Query Database Statistics

```bash
gcloud compute ssh hw5-server-vm --zone=us-central1-a \
    --command="/opt/hw5/venv/bin/python3 /tmp/query_stats.py"
```

Or copy `query_stats.py` to the server first:
```bash
gcloud compute scp hw5/query_stats.py jasonjiang@hw5-server-vm:/tmp/ --zone=us-central1-a
```

---

## 5. Timing Instrumentation

The server uses Python's `time.perf_counter()` — the highest-accuracy monotonic clock available (sub-microsecond resolution) — to measure four operations, each in its own function:

| Operation | Function | What It Measures |
|---|---|---|
| Parse request & extract headers | `_parse_request_headers()` | URL parsing, reading X-country/X-gender/X-age/X-income headers, banned-country check |
| Read file from Cloud Storage | `_read_from_gcs()` | GCS bucket lookup, blob existence check, file download |
| Write to database | `_db_insert_success()` / `_db_insert_failure()` | PostgreSQL INSERT via pg8000 over private IP |
| Send HTTP response | `_send_response_timed()` | Writing status line, headers, and body to the socket |

**Reporting:** Each request logs a `TIMING` line to stdout (→ systemd journal) and Cloud Logging. Every 1,000 timing events, an aggregate summary (avg/min/max per category) is printed.

### Sample Timing Results

| Operation | Typical Time |
|---|---|
| Parse headers | ~0.03 ms |
| GCS read | ~55–165 ms |
| DB write | ~77–110 ms |
| Send response | ~0.1 ms |

GCS read and DB write dominate request latency. Header parsing and response sending are sub-millisecond local CPU operations.

---

## 6. Stopping All Services

```bash
cd hw5/
bash stop_all.sh
```

**What it does:**

1. **Stops all 3 VMs** in parallel
2. **Stops Cloud SQL** (`activationPolicy=NEVER`) — no charges while stopped
3. **Resumes the hourly DB-stopper** Cloud Scheduler job as a safety net (in case GCP restarts the DB for maintenance)

**Expected output:**

```
[1/3] Stopping VMs …
  Stopping hw5-server-vm …
  Stopping hw5-subscriber-vm …
  Stopping hw5-client-vm …
  All VMs stopped.
[2/3] Stopping Cloud SQL instance 'hw5-db' …
  Stopped (activation-policy=NEVER).
[3/3] Resuming Cloud Scheduler stop-db job (safety net) …

Everything stopped.
```

---

## 7. Cost Protection — Auto-Stop Cloud Function

A Cloud Function (`stop-hw5-db`) runs every hour via Cloud Scheduler. If the Cloud SQL instance is `RUNNABLE`, it sets `activationPolicy=NEVER` to stop it. This prevents surprise charges if GCP restarts the DB for maintenance when it is not in use.

- **Function:** `stop-hw5-db` (Gen2, Python 3.12)
- **Scheduler:** `stop-hw5-db-job` — cron `0 * * * *` (every hour)
- **Service account:** `hw5-db-stopper-sa` with `roles/cloudsql.admin`

The `start_all.sh` script pauses this job while the system is in use. The `stop_all.sh` script resumes it.

---

## 8. File Inventory

| File | Purpose |
|---|---|
| `setup.sh` | One-time full infrastructure provisioning |
| `start_all.sh` | Start DB + VMs + services in one command |
| `stop_all.sh` | Stop DB + VMs in one command |
| `startup.sh` | VM startup script (installs deps, launches services via systemd) |
| `server.py` | Service 1 — HTTP server with timing instrumentation |
| `subscriber.py` | Service 2 — Pub/Sub forbidden-country subscriber |
| `http_client.py` | HTTP client with randomized demographic headers |
| `stress_test.sh` | Launches 2 concurrent clients x 50k requests |
| `query_stats.py` | Queries Cloud SQL for request statistics |
| `requirements_server.txt` | Python dependencies for the server |
| `requirements_subscriber.txt` | Python dependencies for the subscriber |
| `stop_db_function/main.py` | Cloud Function source — auto-stop DB |
| `stop_db_function/requirements.txt` | Cloud Function dependencies |
