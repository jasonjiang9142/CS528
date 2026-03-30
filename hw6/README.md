# CS528 Homework 6 — 3NF Schema, Migration, and ML Models

This homework builds on HW5. It normalizes the request data to third normal form (3NF), migrates existing rows, trains two supervised models on a VM, and writes test-set predictions to Google Cloud Storage.

## 1. Why the HW5 schema was not in 3NF

The original `requests` table stored `(country, client_ip, …)` on every row. In the real world, **each client IP address is associated with exactly one country** (the hint in the assignment). That is a functional dependency:

`client_ip → country`

Storing `country` again on every request duplicates that fact and creates **transitive redundancy**: given `client_ip`, `country` is determined without needing the rest of the row. In 3NF, non-key attributes must not depend on other non-key attributes. Here `country` depends on `client_ip`, not on the primary key `id` alone (unless `client_ip` were part of the key). So the design violated 3NF.

**Normalization:**

| Table | Role |
|-------|------|
| `countries` | One row per distinct country name |
| `client_ips` | One row per IP; `country_id` FK (IP → country, many IPs per country) |
| `genders` | One row per gender label |
| `income_brackets` | One row per income bracket label |
| `requests_3nf` | Fact table: each request references `client_ip_id`, `gender_id`, `income_id`; **no** redundant `country` column |

## 2. Files

| File | Purpose |
|------|---------|
| `schema_3nf.sql` | DDL for 3NF tables |
| `migrate_to_3nf.sql` | `INSERT … SELECT` migration from legacy `requests` |
| `train_models.py` | Load data, train/test split, two models, GCS upload |
| `requirements.txt` | Python dependencies for the ML VM |
| `setup_ml_vm.sh` | Example `gcloud` commands to create a Debian VM and run training |
| `run_hw6_pipeline.sh` | Start DB → create VM → train → stop DB → delete VM → print GCS output |
| `HW6_SUBMISSION.md` | PDF-ready write-up (schema, models, GitHub link) |
| `make_pdf.sh` | Build `HW6_SUBMISSION.pdf` with `pandoc` (if installed) |

## 3. Apply schema and migration (Cloud SQL)

Run against your HW5 database (from Cloud Shell or a VM with Cloud SQL access):

```bash
export PGHOST=/cloudsql/PROJECT:REGION:INSTANCE   # or private IP + Cloud SQL Proxy
psql "host=$DB_HOST dbname=hw5db user=hw5user" -f schema_3nf.sql
psql "host=$DB_HOST dbname=hw5db user=hw5user" -f migrate_to_3nf.sql
```

Or use `psql` through the [Cloud SQL Auth proxy](https://cloud.google.com/sql/docs/postgres/connect-auth-proxy).

## 4. Train models on a VM

1. Create a small Compute Engine VM in the **same VPC** as Cloud SQL (or use the proxy from your laptop).
2. Install Python 3, copy `hw6/` and `requirements.txt`, `pip install -r requirements.txt`.
3. Set environment variables:

```bash
export DB_HOST=10.x.x.x        # Cloud SQL private IP
export DB_PORT=5432
export DB_NAME=hw5db
export DB_USER=hw5user
export DB_PASS='...'
export GCP_PROJECT=your-project-id
export GCS_BUCKET=your-bucket-name   # e.g. cs528-jx3onj-hw2
```

4. Run:

```bash
python3 train_models.py
```

Outputs:

- **Model 1** — Predict **country** from **client IP** (features: IPv4 octets / IPv6 hashed features). Uses `RandomForestClassifier`; with enough data where IP maps cleanly to country, test accuracy is typically **≥ 99%** when the same IPs recur (as in stress tests).
- **Model 2** — Predict **income bracket** from **gender, age, country, is_banned** (no income in features). Uses `RandomForestClassifier`; target is multi-class income label. **≥ 40%** accuracy is reported when possible; random baseline is ~1/6 ≈ 16.7% for six brackets.

5. Prediction files are uploaded to:

`gs://$GCS_BUCKET/hw6/model1_test_predictions.csv`  
`gs://$GCS_BUCKET/hw6/model2_test_predictions.csv`

Each file includes true labels, predicted labels, and a short accuracy summary in the run log.

## 5. One-shot pipeline (for grading)

From `hw6/` (requires `DB_PASS`):

```bash
export DB_PASS='your-cloud-sql-password'
bash run_hw6_pipeline.sh
```

Starts Cloud SQL, creates `hw6-ml-vm`, copies this directory, runs `train_models.py`, **stops** Cloud SQL, **deletes** the VM, prints GCS outputs. See **`HW6_SUBMISSION.md`** for the full write-up and **`make_pdf.sh`** to build a PDF.

## 6. Stop resources after grading

Use your HW5 `stop_all.sh` (or equivalent) to stop VMs and Cloud SQL so you do not incur unnecessary charges.
