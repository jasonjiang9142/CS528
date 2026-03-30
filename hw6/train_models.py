#!/usr/bin/env python3
"""
CS528 HW6 — Train two models on requests data (3NF or legacy), evaluate on held-out
test sets, and upload prediction CSVs to GCS.

Model 1: client IP → country (RandomForest on IPv4 octets; high accuracy when IP→country is stable).
Model 2: gender, age, country, is_banned → income bracket (RandomForest multi-class).

Environment (same as HW5 server):
  DB_HOST, DB_PORT, DB_NAME, DB_USER, DB_PASS
  GCP_PROJECT (optional, for default credentials)
  GCS_BUCKET — bucket for output files (default: cs528-jx3onj-hw2)
"""

from __future__ import annotations

import os
import sys
import warnings

import numpy as np
import pandas as pd
import pg8000
from google.cloud import storage
from sklearn.compose import ColumnTransformer
from sklearn.ensemble import RandomForestClassifier
from sklearn.metrics import accuracy_score, classification_report
from sklearn.model_selection import train_test_split
from sklearn.pipeline import Pipeline
from sklearn.preprocessing import OneHotEncoder

warnings.filterwarnings("ignore", category=UserWarning)

DB_HOST = os.environ.get("DB_HOST", "127.0.0.1")
DB_PORT = int(os.environ.get("DB_PORT", "5432"))
DB_NAME = os.environ.get("DB_NAME", "hw5db")
DB_USER = os.environ.get("DB_USER", "hw5user")
DB_PASS = os.environ.get("DB_PASS", "")
GCP_PROJECT = os.environ.get("GCP_PROJECT", os.environ.get("GOOGLE_CLOUD_PROJECT", ""))
GCS_BUCKET = os.environ.get("GCS_BUCKET", "cs528-jx3onj-hw2")
GCS_PREFIX = os.environ.get("GCS_PREFIX", "hw6")
TEST_SIZE = float(os.environ.get("TEST_SIZE", "0.2"))
RANDOM_STATE = int(os.environ.get("RANDOM_STATE", "42"))


def connect():
    return pg8000.connect(
        host=DB_HOST,
        port=DB_PORT,
        database=DB_NAME,
        user=DB_USER,
        password=DB_PASS,
    )


def load_frame(conn) -> pd.DataFrame:
    """Prefer normalized 3NF view; fall back to legacy `requests`."""
    q3 = """
    SELECT
        ci.ip_address AS client_ip,
        c.name AS country,
        g.name AS gender,
        r.age,
        ib.label AS income,
        r.is_banned
    FROM requests_3nf r
    JOIN client_ips ci ON ci.ip_id = r.client_ip_id
    JOIN countries c ON c.country_id = ci.country_id
    JOIN genders g ON g.gender_id = r.gender_id
    JOIN income_brackets ib ON ib.income_id = r.income_id
    """
    try:
        df = pd.read_sql(q3, conn)
        if len(df) > 0:
            print(f"Loaded {len(df)} rows from requests_3nf (3NF).", flush=True)
            return df
    except Exception as exc:
        print(f"3NF query failed ({exc}); trying legacy `requests`.", flush=True)
        # Failed query leaves PostgreSQL transaction aborted (25P02) until rollback.
        try:
            conn.rollback()
        except Exception:
            pass

    q_legacy = """
    SELECT
        client_ip,
        country,
        gender,
        age,
        income,
        is_banned
    FROM requests
    WHERE country IS NOT NULL AND TRIM(country) <> ''
    """
    df = pd.read_sql(q_legacy, conn)
    print(f"Loaded {len(df)} rows from legacy `requests`.", flush=True)
    return df


def ip_to_features(ip: str) -> np.ndarray:
    """IPv4 → 4 octets; IPv6 / other → deterministic 4 floats from hash."""
    s = str(ip).strip()
    parts = s.split(".")
    if len(parts) == 4:
        try:
            return np.array([float(int(p)) for p in parts], dtype=np.float64)
        except ValueError:
            pass
    h = hash(s) & 0xFFFFFFFFFFFFFFFF
    return np.array(
        [
            float((h >> 48) & 0xFFFF),
            float((h >> 32) & 0xFFFF),
            float((h >> 16) & 0xFFFF),
            float(h & 0xFFFF),
        ],
        dtype=np.float64,
    )


#model 1 
def train_model_country_from_ip(df: pd.DataFrame):
    """Model 1: IP → country."""
    df = df.reset_index(drop=True)
    X = np.vstack([ip_to_features(ip) for ip in df["client_ip"]])
    y = df["country"].astype(str).values
    fac = pd.factorize(y)[0]
    strat = y if len(np.unique(y)) > 1 and np.min(np.bincount(fac)) >= 2 else None

    idx = np.arange(len(df))
    idx_train, idx_test = train_test_split(
        idx, test_size=TEST_SIZE, random_state=RANDOM_STATE, stratify=strat
    )
    X_train, X_test = X[idx_train], X[idx_test]
    y_train, y_test = y[idx_train], y[idx_test]
    test_ips = df["client_ip"].iloc[idx_test].values

    # HW5 server logs synthetic IPs derived from X-country (see server.py); no class_weight
    # so the forest is not biased toward one label when IP octets encode country.
    clf = RandomForestClassifier(
        n_estimators=200,
        max_depth=24,
        min_samples_leaf=1,
        random_state=RANDOM_STATE,
        n_jobs=-1,
    )
    clf.fit(X_train, y_train)
    pred = clf.predict(X_test)
    acc = accuracy_score(y_test, pred)
    print("\n=== Model 1: IP → country ===", flush=True)
    print(f"Test accuracy: {acc:.4f}", flush=True)
    print(classification_report(y_test, pred, zero_division=0), flush=True)

    out = pd.DataFrame(
        {"client_ip": test_ips, "true_country": y_test, "predicted_country": pred}
    )
    return acc, out


#model 2 
def train_model_income(df: pd.DataFrame):
    """Model 2: demographics → income (exclude income from features)."""
    X = df[["gender", "age", "country", "is_banned"]].copy()
    X["is_banned"] = X["is_banned"].astype(int)
    X["gender"] = X["gender"].fillna("Unknown").astype(str)
    X["country"] = X["country"].astype(str)
    y = df["income"].astype(str).values

    strat = y if len(np.unique(y)) > 1 and np.min(np.bincount(pd.factorize(y)[0])) >= 2 else None
    X_train, X_test, y_train, y_test = train_test_split(
        X, y, test_size=TEST_SIZE, random_state=RANDOM_STATE, stratify=strat
    )

    cat_cols = ["gender", "country"]
    num_cols = ["age", "is_banned"]
    try:
        ohe = OneHotEncoder(handle_unknown="ignore", sparse_output=False)
    except TypeError:
        ohe = OneHotEncoder(handle_unknown="ignore", sparse=False)
    pre = ColumnTransformer(
        [
            ("cat", ohe, cat_cols),
            ("num", "passthrough", num_cols),
        ]
    )
    pipe = Pipeline(
        [
            ("prep", pre),
            (
                "clf",
                RandomForestClassifier(
                    n_estimators=500,
                    max_depth=28,
                    min_samples_leaf=1,
                    random_state=RANDOM_STATE,
                    n_jobs=-1,
                    class_weight="balanced",
                ),
            ),
        ]
    )
    pipe.fit(X_train, y_train)
    pred = pipe.predict(X_test)
    acc = accuracy_score(y_test, pred)
    print("\n=== Model 2: demographics → income ===", flush=True)
    print(f"Test accuracy: {acc:.4f} (random baseline ~{1.0 / max(len(np.unique(y)), 1):.3f} for uniform classes)", flush=True)
    print(classification_report(y_test, pred, zero_division=0), flush=True)
    if acc < 0.40:
        print(
            "\nNote: Income was randomly sampled per request in HW5; weak correlation with "
            "demographics is expected. Try a different RANDOM_STATE or more data.",
            flush=True,
        )

    out = pd.DataFrame(
        {
            "true_income": y_test,
            "predicted_income": pred,
            "gender": X_test["gender"].values,
            "age": X_test["age"].values,
            "country": X_test["country"].values,
            "is_banned": X_test["is_banned"].values,
        }
    )
    return acc, out


def upload_csv(bucket_name: str, blob_path: str, text: str) -> None:
    client = storage.Client(project=GCP_PROJECT or None)
    bucket = client.bucket(bucket_name)
    blob = bucket.blob(blob_path)
    blob.upload_from_string(text, content_type="text/csv; charset=utf-8")
    print(f"Uploaded gs://{bucket_name}/{blob_path}", flush=True)


def main() -> int:
    if not DB_PASS:
        print("ERROR: DB_PASS is not set.", file=sys.stderr)
        return 1

    conn = connect()
    try:
        df = load_frame(conn)
    finally:
        conn.close()

    if len(df) < 20:
        print("ERROR: Not enough rows to train (need at least ~20). Run HW5 stress test first.", file=sys.stderr)
        return 1

    acc1, pred1 = train_model_country_from_ip(df)
    acc2, pred2 = train_model_income(df)

    summary = (
        f"model1_test_accuracy,{acc1}\n"
        f"model2_test_accuracy,{acc2}\n"
        f"rows,{len(df)}\n"
        f"test_fraction,{TEST_SIZE}\n"
        f"random_state,{RANDOM_STATE}\n"
    )

    upload_csv(GCS_BUCKET, f"{GCS_PREFIX}/model1_test_predictions.csv", pred1.to_csv(index=False))
    upload_csv(GCS_BUCKET, f"{GCS_PREFIX}/model2_test_predictions.csv", pred2.to_csv(index=False))
    upload_csv(GCS_BUCKET, f"{GCS_PREFIX}/metrics_summary.csv", summary)

    print("\nDone.", flush=True)
    return 0


if __name__ == "__main__":
    sys.exit(main())
