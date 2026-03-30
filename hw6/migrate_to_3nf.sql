-- CS528 HW6 — Migrate legacy HW5 `requests` into 3NF tables.
-- Prerequisites: schema_3nf.sql applied; `requests` contains data.
--
-- Re-run safely: uncomment the TRUNCATE block below (destroys 3NF copies only).

-- TRUNCATE TABLE requests_3nf RESTART IDENTITY CASCADE;
-- TRUNCATE TABLE client_ips RESTART IDENTITY CASCADE;
-- TRUNCATE TABLE countries, genders, income_brackets RESTART IDENTITY CASCADE;

BEGIN;

-- 1) Countries from distinct non-empty country strings
INSERT INTO countries (name)
SELECT DISTINCT TRIM(country)
FROM requests
WHERE country IS NOT NULL AND TRIM(country) <> ''
ON CONFLICT (name) DO NOTHING;

-- 2) Genders
INSERT INTO genders (name)
SELECT DISTINCT COALESCE(NULLIF(TRIM(gender), ''), 'Unknown')
FROM requests
ON CONFLICT (name) DO NOTHING;

-- Ensure Unknown exists for NULL genders
INSERT INTO genders (name) VALUES ('Unknown')
ON CONFLICT (name) DO NOTHING;

-- 3) Income brackets
INSERT INTO income_brackets (label)
SELECT DISTINCT COALESCE(NULLIF(TRIM(income), ''), 'Unknown')
FROM requests
ON CONFLICT (label) DO NOTHING;

INSERT INTO income_brackets (label) VALUES ('Unknown')
ON CONFLICT (label) DO NOTHING;

-- 4) client_ips: one row per IP with a single canonical country_id
--    If the same IP appears with different countries in legacy data, keep the
--    lexicographically smallest country_id for determinism.
INSERT INTO client_ips (ip_address, country_id)
SELECT r.client_ip, c.country_id
FROM (
    SELECT DISTINCT ON (client_ip)
        client_ip,
        TRIM(country) AS country_name
    FROM requests
    WHERE country IS NOT NULL AND TRIM(country) <> ''
    ORDER BY client_ip, TRIM(country)
) r
JOIN countries c ON c.name = r.country_name
ON CONFLICT (ip_address) DO NOTHING;

-- 5) requests_3nf: copy all legacy rows that resolve through dimensions
INSERT INTO requests_3nf (
    client_ip_id, gender_id, age, income_id, is_banned, time_of_day, requested_file
)
SELECT
    ci.ip_id,
    g.gender_id,
    r.age,
    ib.income_id,
    r.is_banned,
    r.time_of_day,
    r.requested_file
FROM requests r
JOIN client_ips ci ON ci.ip_address = r.client_ip
JOIN genders g ON g.name = COALESCE(NULLIF(TRIM(r.gender), ''), 'Unknown')
JOIN income_brackets ib ON ib.label = COALESCE(NULLIF(TRIM(r.income), ''), 'Unknown');

COMMIT;

-- Optional: row counts for verification
-- SELECT 'legacy' AS src, COUNT(*) FROM requests
-- UNION ALL SELECT '3nf', COUNT(*) FROM requests_3nf;
