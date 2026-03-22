-- CS528 HW5 – Statistics queries

-- 1. Successful vs unsuccessful requests
SELECT
    (SELECT COUNT(*) FROM requests)        AS successful,
    (SELECT COUNT(*) FROM failed_requests) AS unsuccessful;

-- 2. Requests from banned countries
SELECT COUNT(*) AS banned_requests
FROM requests
WHERE is_banned = TRUE;

-- 3. Male vs Female
SELECT gender, COUNT(*) AS cnt
FROM requests
GROUP BY gender
ORDER BY cnt DESC;

-- 4. Top 5 countries
SELECT country, COUNT(*) AS cnt
FROM requests
GROUP BY country
ORDER BY cnt DESC
LIMIT 5;

-- 5. Age group with the most requests
SELECT
    CASE
        WHEN age BETWEEN  0 AND 17 THEN 'Under 18'
        WHEN age BETWEEN 18 AND 24 THEN '18-24'
        WHEN age BETWEEN 25 AND 34 THEN '25-34'
        WHEN age BETWEEN 35 AND 44 THEN '35-44'
        WHEN age BETWEEN 45 AND 54 THEN '45-54'
        WHEN age BETWEEN 55 AND 64 THEN '55-64'
        ELSE '65+'
    END AS age_group,
    COUNT(*) AS cnt
FROM requests
GROUP BY age_group
ORDER BY cnt DESC;

-- 6. Income group with the most requests
SELECT income, COUNT(*) AS cnt
FROM requests
GROUP BY income
ORDER BY cnt DESC;
