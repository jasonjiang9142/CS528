# CS528 Homework 6 — Submission Document

**Course:** CS528  
**Repository (code):** https://github.com/jasonjiang9142/CS528/tree/hw6  

*(Replace branch name if your HW6 work lives on a different branch.)*

---

## 1. Configure and run the application

### 1.1 Prerequisites

- Google Cloud SDK (`gcloud`, `gsutil`) installed and authenticated  
- Project ID set: `gcloud config set project <PROJECT_ID>`  
- HW5 infrastructure already deployed (`setup.sh`): Cloud SQL `hw5-db`, VPC, GCS bucket with page data, service accounts  
- Cloud SQL user password available as `DB_PASS`

### 1.2 Third normal form schema

Apply the DDL, then migrate legacy `requests` data:

```bash
psql "host=... dbname=hw5db user=hw5user" -f hw6/schema_3nf.sql
psql "host=... dbname=hw5db user=hw5user" -f hw6/migrate_to_3nf.sql
```

Files: **`hw6/schema_3nf.sql`**, **`hw6/migrate_to_3nf.sql`**

### 1.3 One-command pipeline (database + VM + models + teardown)

From the **`hw6/`** directory:

```bash
export DB_PASS='your-cloud-sql-password'
bash run_hw6_pipeline.sh
```

**`run_hw6_pipeline.sh`** will:

1. Pause the hourly Cloud Scheduler job that stops Cloud SQL (so the DB stays up).  
2. Start Cloud SQL (`activationPolicy=ALWAYS`) and wait until `RUNNABLE`.  
3. Create **`hw6-ml-vm`** if it does not exist (Debian, `e2-small`, `hw5-server-sa`).  
4. Wait until SSH (IAP) works.  
5. Copy the local **`hw6/`** tree to **`~/hw6`** on the VM.  
6. Create a venv, `pip install -r requirements.txt`, run **`train_models.py`** (connects to Cloud SQL private IP, uploads CSVs to GCS).  
7. **Stop** Cloud SQL (`activationPolicy=NEVER`).  
8. **Delete** **`hw6-ml-vm`**.  
9. Resume the hourly DB-stopper scheduler job.  
10. **Print** `metrics_summary.csv` and the first 25 lines of each prediction file from **`gs://$GCS_BUCKET/hw6/`** to the terminal.

Optional environment variables: `PROJECT_ID`, `ZONE`, `VM_NAME`, `GCS_BUCKET`, `GCP_PROJECT`, `REGION`.

### 1.4 Manual run on a VM (alternative)

See **`hw6/README.md`**: copy `hw6/` to the VM, install **`requirements.txt`**, set **`DB_*`** and **`GCS_BUCKET`**, run **`python train_models.py`**.

---

## 2. Why the old HW5 schema was not in 3NF

The legacy **`requests`** table stored **`country`** and **`client_ip`** on every row. In this assignment, **each client IP maps to exactly one country**, while **many IPs** map to the **same country**. That is a functional dependency:

**`client_ip → country`**

Repeating **`country`** on every request duplicates a fact that depends on **`client_ip`**, not on the surrogate key **`id`**. That is a **transitive / redundant** dependency on non-key attributes, so the table was **not** in third normal form.

**Normalization:** move IP→country into **`client_ips(ip_address, country_id)`** and reference **`countries`**. Request facts live in **`requests_3nf`** with foreign keys only (no stored country string).

---

## 3. New schema and data-transfer queries

The full definitions are in the repository:

| Artifact | File |
|----------|------|
| 3NF DDL | `hw6/schema_3nf.sql` |
| `INSERT … SELECT` migration from **`requests`** | `hw6/migrate_to_3nf.sql` |

**Tables (summary):**

- **`countries`** — `country_id`, `name` (unique)  
- **`genders`** — `gender_id`, `name`  
- **`income_brackets`** — `income_id`, `label`  
- **`client_ips`** — `ip_id`, `ip_address` (unique), `country_id` FK  
- **`requests_3nf`** — `client_ip_id`, `gender_id`, `age`, `income_id`, `is_banned`, `time_of_day`, `requested_file`

Migration order: populate dimensions → **`client_ips`** (one row per IP, canonical country) → **`requests_3nf`** joining legacy **`requests`** to dimensions.

---

## 4. Models — how they work and expected outputs

### 4.1 Model 1 — Predict **country** from **client IP**

**Implementation:** `sklearn.ensemble.RandomForestClassifier`  
**Features:** For IPv4, the four octets are used as numeric features. Non-IPv4 addresses are mapped to four numeric features via a stable hash (so the forest can still split).

**Why this works:** After normalization, **each IP has a single country** in **`client_ips`**. The training distribution is (IP features → country). With a typical HW5 stress-test dataset, many requests share the same IPs, so the forest can fit the mapping and **test accuracy is often very high (≥ 99%)** when the train/test split is over **rows** (the assignment’s target).

**Test set:** 20% holdout (`TEST_SIZE`, default `0.2`), stratified when possible.

**Output file (GCS):** `hw6/model1_test_predictions.csv` — columns include **`client_ip`**, **`true_country`**, **`predicted_country`**.

### 4.2 Model 2 — Predict **income bracket** from other fields

**Implementation:** **RandomForestClassifier** inside a **`Pipeline`**: **`OneHotEncoder`** for **gender** and **country**; passthrough for **age** and **is_banned** (integer). **Income** is **not** included in features.

**Why this is hard:** In HW5, **`http_client.py`** draws **income** uniformly at random per request, largely **independent** of country/gender/age. Accuracy above a **random baseline** (~1/6 for six brackets) depends on finite-sample noise. The code prints a **note** if test accuracy is below **40%** and suggests changing **`RANDOM_STATE`** or collecting more rows.

**Test set:** Same **`train_test_split`** convention as model 1.

**Output file (GCS):** `hw6/model2_test_predictions.csv` — true vs predicted income plus key input columns.

### 4.3 Metrics file

**`hw6/metrics_summary.csv`** — contains **`model1_test_accuracy`**, **`model2_test_accuracy`**, row count, **`TEST_SIZE`**, **`RANDOM_STATE`**.

---

## 5. Example model output (illustrative)

After a successful run, the pipeline prints something like:

```
=== Model 1: IP → country ===
Test accuracy: 0.99xx

=== Model 2: demographics → income ===
Test accuracy: 0.3x–0.5x   (varies with seed and sample size)
```

Exact numbers depend on your database contents and **`RANDOM_STATE`**.

---

## 6. Files to submit / link

| Purpose | Path in repo |
|---------|----------------|
| 3NF schema | `hw6/schema_3nf.sql` |
| Migration SQL | `hw6/migrate_to_3nf.sql` |
| Training + GCS upload | `hw6/train_models.py` |
| End-to-end script | `hw6/run_hw6_pipeline.sh` |
| Dependencies | `hw6/requirements.txt` |
| VM bootstrap | `hw6/vm_startup.sh`, `hw6/setup_ml_vm.sh` |
| Documentation | `hw6/README.md`, **`hw6/HW6_SUBMISSION.md`** (this file) |

**GitHub:** https://github.com/jasonjiang9142/CS528/tree/hw6  

---

## 7. Generate a PDF from this document

From **`hw6/`**:

```bash
bash make_pdf.sh
```

If **`pandoc`** is installed, **`HW6_SUBMISSION.pdf`** is created. Otherwise, open **`HW6_SUBMISSION.md`** in an editor and export or print to PDF.
