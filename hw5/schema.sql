-- CS528 HW5 – Database schema (reference only; server.py creates tables on startup)

CREATE TABLE IF NOT EXISTS requests (
    id             SERIAL PRIMARY KEY,
    country        VARCHAR(100),
    client_ip      VARCHAR(45),
    gender         VARCHAR(20),
    age            INTEGER,
    income         VARCHAR(50),
    is_banned      BOOLEAN DEFAULT FALSE,
    time_of_day    TIMESTAMP DEFAULT NOW(),
    requested_file VARCHAR(500)
);

CREATE TABLE IF NOT EXISTS failed_requests (
    id              SERIAL PRIMARY KEY,
    time_of_request TIMESTAMP DEFAULT NOW(),
    requested_file  VARCHAR(500),
    error_code      INTEGER
);
