-- CS528 HW6 — Third normal form schema (PostgreSQL)
-- Run after HW5 `requests` table exists and is populated.

-- Dimension: countries (one row per country name)
CREATE TABLE IF NOT EXISTS countries (
    country_id SERIAL PRIMARY KEY,
    name       VARCHAR(100) NOT NULL UNIQUE
);

-- Dimension: genders
CREATE TABLE IF NOT EXISTS genders (
    gender_id SERIAL PRIMARY KEY,
    name      VARCHAR(20) NOT NULL UNIQUE
);

-- Dimension: income brackets (categorical labels from HW5 client)
CREATE TABLE IF NOT EXISTS income_brackets (
    income_id SERIAL PRIMARY KEY,
    label     VARCHAR(50) NOT NULL UNIQUE
);

-- client_ip → country (many IPs per country; each IP appears once)
CREATE TABLE IF NOT EXISTS client_ips (
    ip_id       SERIAL PRIMARY KEY,
    ip_address  VARCHAR(45) NOT NULL UNIQUE,
    country_id  INTEGER NOT NULL REFERENCES countries (country_id)
);

CREATE INDEX IF NOT EXISTS idx_client_ips_country ON client_ips (country_id);

-- Fact: one row per successful request (no redundant country column)
CREATE TABLE IF NOT EXISTS requests_3nf (
    request_id      SERIAL PRIMARY KEY,
    client_ip_id    INTEGER NOT NULL REFERENCES client_ips (ip_id),
    gender_id       INTEGER NOT NULL REFERENCES genders (gender_id),
    age             INTEGER,
    income_id       INTEGER NOT NULL REFERENCES income_brackets (income_id),
    is_banned       BOOLEAN DEFAULT FALSE,
    time_of_day     TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
    requested_file  VARCHAR(500)
);

CREATE INDEX IF NOT EXISTS idx_requests_3nf_ip ON requests_3nf (client_ip_id);
CREATE INDEX IF NOT EXISTS idx_requests_3nf_time ON requests_3nf (time_of_day);
