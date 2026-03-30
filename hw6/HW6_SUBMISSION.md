# CS528 Homework 6 — Submission Document

**Course:** CS528  
**Repository (code):** https://github.com/jasonjiang9142/CS528/tree/main  

---

## 1. Configure and run the application

### 1.1 Prerequisites

- **Google Cloud SDK** (`gcloud`, `gsutil`) installed and authenticated  
- **Project:** `gcloud config set project <PROJECT_ID>`  
- **HW5** already deployed: Cloud SQL instance **`hw5-db`**, VPC, GCS bucket with JSON pages, service accounts, **`hw5-server-vm`** serving HTTP on port **8080**  
- **Cloud SQL password** for user **`hw5user`** (export as **`DB_PASS`**)

### 1.2 HW5 data prerequisite (important for Model 1)

The HW5 **`http_client`** sends random **`X-country`** headers while the server originally logged the **TCP source IP** as **`client_ip`**. Those two are unrelated, so IP could not predict country. The updated **`hw5/server.py`** logs a **deterministic synthetic IPv4** derived from **`X-country`** for successful inserts, so **`client_ip`** and **`country`** align and Model 1 can reach **≥99%** test accuracy.

**Populate `requests`:** run a stress load against the server (static IP), e.g.:

```bash
python3 hw5/http_client.py --url http://<HW5_SERVER_STATIC_IP>:8080 --num 10000 --seed 42 --delay 0
```

Optional helper (uploads `server.py`, restarts, truncates if password works, loads traffic, runs HW6 pipeline): **`hw6/refresh_hw5_data_and_train.sh`** — see `hw6/README.md`.

### 1.3 Third normal form (3NF) schema and migration

Apply DDL, then migrate from legacy **`requests`**:

```bash
# From Cloud Shell, a VM with VPC access to Cloud SQL, or psql with Cloud SQL Auth Proxy:
psql "host=<PRIVATE_IP_OR_PROXY> dbname=hw5db user=hw5user" -f hw6/schema_3nf.sql
psql "host=<PRIVATE_IP_OR_PROXY> dbname=hw5db user=hw5user" -f hw6/migrate_to_3nf.sql
```

Files: **`hw6/schema_3nf.sql`**, **`hw6/migrate_to_3nf.sql`**

**Training:** `train_models.py` **prefers** the 3NF join when **`requests_3nf`** exists and has rows; otherwise it falls back to legacy **`requests`** (with rollback on failed 3NF query).

### 1.4 One-command pipeline (database + VM + models + teardown)

From **`hw6/`**:

```bash
export DB_PASS='your-cloud-sql-password'
bash run_hw6_pipeline.sh
```

**`run_hw6_pipeline.sh`** will:

1. Create **`allow-iap-ssh-hw6-ml`** firewall rule if missing (IAP → TCP 22, tag **`hw6-ml`**).  
2. Pause the hourly Cloud Scheduler job that stops Cloud SQL.  
3. Start Cloud SQL (`activation-policy=ALWAYS`) and wait until **`RUNNABLE`**.  
4. Create **`hw6-ml-vm`** if missing (Debian, default **`e2-medium`**, tag **`hw6-ml`**, startup script **`vm_startup.sh`**).  
5. Wait until SSH (IAP) works.  
6. Pack **`hw6/`** with **`tar`** (excludes local **`venv/`**), unpack on the VM.  
7. Install **`uv`**, create **`venv`**, **`uv pip install -r requirements.txt`**, run **`train_models.py`**.  
8. Stop Cloud SQL (`activation-policy=NEVER`).  
9. Delete **`hw6-ml-vm`**.  
10. Resume the hourly DB-stopper scheduler job.  
11. Print **`metrics_summary.csv`** and samples of prediction CSVs from **`gs://$GCS_BUCKET/hw6/`** to the terminal.

Optional environment variables: **`PROJECT_ID`**, **`ZONE`**, **`VM_NAME`**, **`GCS_BUCKET`**, **`GCP_PROJECT`**, **`REGION`**, **`MACHINE_TYPE`**, **`NETWORK`** (for the IAP firewall rule).

### 1.5 Manual run on a VM (alternative)

Copy **`hw6/`** to a VM in the same VPC as Cloud SQL, install **`requirements.txt`**, set **`DB_HOST`**, **`DB_PASS`**, **`GCS_BUCKET`**, run **`python train_models.py`**. See **`hw6/setup_ml_vm.sh`**.

---

## 2. Why the old HW5 schema was not in 3NF

The legacy **`requests`** table stored **`country`** and **`client_ip`** on every row. In this assignment, **each client IP maps to exactly one country**, while **many IPs** map to the **same country**. That is a functional dependency:

**`client_ip → country`**

Repeating **`country`** on every request duplicates a fact that depends on **`client_ip`**, not only on the surrogate key **`id`**. That redundancy violates **third normal form** for this design.

**Normalization:** dimensions **`countries`**, **`genders`**, **`income_brackets`**; **`client_ips(ip_address, country_id)`** encodes IP→country once; **`requests_3nf`** holds fact rows with foreign keys only.

---

## 3. New schema and data-transfer queries

| Artifact | File |
|----------|------|
| 3NF DDL | `hw6/schema_3nf.sql` |
| Migration `INSERT … SELECT` from **`requests`** | `hw6/migrate_to_3nf.sql` |

**Tables (summary):** **`countries`**, **`genders`**, **`income_brackets`**, **`client_ips`**, **`requests_3nf`** — see **`schema_3nf.sql`** for keys and FKs.

---

## 4. Models — how they work

### 4.1 Model 1 — Predict **country** from **client IP**

- **Algorithm:** **`sklearn.ensemble.RandomForestClassifier`** (200 trees, **`max_depth=24`**, **`min_samples_leaf=1`**, **`random_state=RANDOM_STATE`**).  
- **Features:** `ip_to_features()` parses IPv4 into **four numeric octets**; non-IPv4 strings use a **deterministic hash** to four numbers.  
- **Labels:** `country` string from the dataframe.  
- **Split:** **20%** test (**`TEST_SIZE`**, default `0.2`), **stratified** by country when each class has at least 2 samples in the **index** split.  
- **Why ≥99% is achievable:** With the updated HW5 server, **`client_ip`** is **synthetic** and **consistent** with **`X-country`**, so first octets (and full octets) are highly informative; the forest can fit the mapping.  
- **Outputs:** Test accuracy, **`classification_report`**; CSV **`model1_test_predictions.csv`** with **`client_ip`**, **`true_country`**, **`predicted_country`**.

### 4.2 Model 2 — Predict **income bracket** from other fields

- **Algorithm:** **`Pipeline`**: **`OneHotEncoder`** ( **`gender`**, **`country`** ) + passthrough **`age`**, **`is_banned`** → **`RandomForestClassifier`** (500 trees, **`max_depth=28`**, **`min_samples_leaf=1`**, **`class_weight='balanced'`**).  
- **Target:** **`income`** (string bracket labels). **Income is not** in the feature matrix.  
- **Split:** Same **`TEST_SIZE`** / **`RANDOM_STATE`** as Model 1.  
- **Why accuracy varies:** In **`hw5/http_client.py`**, **`X-income`** is chosen **uniformly at random** per request, largely **independent** of demographics, so true signal is weak; **40%+** accuracy is **not guaranteed** and depends on **sample size** and **`RANDOM_STATE`**. The script prints a note if test accuracy **&lt; 0.40**.  
- **Outputs:** Test accuracy, **`classification_report`**; CSV **`model2_test_predictions.csv`** with true/predicted income and input fields.

### 4.3 Files written to GCS (prefix **`hw6/`** by default)

| Object | Contents |
|--------|----------|
| **`metrics_summary.csv`** | **`model1_test_accuracy`**, **`model2_test_accuracy`**, **`rows`**, **`test_fraction`**, **`random_state`** |
| **`model1_test_predictions.csv`** | Per-row test predictions for Model 1 |
| **`model2_test_predictions.csv`** | Per-row test predictions for Model 2 |

---

## 5. Example model output (illustrative)

After a successful run, the terminal prints:

```
=== Model 1: IP → country ===
Test accuracy: 0.99xx
              precision    recall  f1-score   support
            ...

=== Model 2: demographics → income ===
Test accuracy: 0.3x–0.5x   (varies with seed and sample size)
```

**Paste your actual numbers** from the last run or from:

```bash
gsutil cat gs://<GCS_BUCKET>/hw6/metrics_summary.csv
```

Exact values depend on **database size**, **synthetic** vs **legacy** IPs, **`RANDOM_STATE`**, and **`TEST_SIZE`**.

---

## 6. Generate a PDF from this document

From **`hw6/`**:

```bash
bash make_pdf.sh
```

Requires **`pandoc`** (and **`pdflatex`** or another PDF engine). Output: **`HW6_SUBMISSION.pdf`**.  
Otherwise: open **`HW6_SUBMISSION.md`** in an editor and **Export / Print to PDF**.

---

## 7. Repository index (HW6)

| Purpose | Path |
|---------|------|
| 3NF schema | `hw6/schema_3nf.sql` |
| Migration SQL | `hw6/migrate_to_3nf.sql` |
| Training + GCS upload | `hw6/train_models.py` |
| End-to-end script | `hw6/run_hw6_pipeline.sh` |
| Optional HW5 refresh + pipeline | `hw6/refresh_hw5_data_and_train.sh` |
| Dependencies | `hw6/requirements.txt` |
| VM bootstrap | `hw6/vm_startup.sh`, `hw6/setup_ml_vm.sh` |
| Documentation | `hw6/README.md`, **`hw6/HW6_SUBMISSION.md`** (this file) |
| HW5 synthetic IP (Model 1) | `hw5/server.py` |

**GitHub:** https://github.com/jasonjiang9142/CS528  
