"""Query the database for HW5 statistics."""
import pg8000

conn = pg8000.connect(
    host="10.61.0.3", port=5432,
    database="hw5db", user="hw5user", password="hw5pass123",
)
cur = conn.cursor()

sep = "=" * 65
print(sep)
print(" CS528 HW5 - Request Statistics")
print(sep)

# 1. Successful vs Unsuccessful
cur.execute("SELECT count(*) FROM requests")
ok = cur.fetchone()[0]
cur.execute("SELECT count(*) FROM failed_requests")
fail = cur.fetchone()[0]
print("\n1. SUCCESSFUL vs UNSUCCESSFUL REQUESTS")
print("   Successful (200):   %6d" % ok)
print("   Unsuccessful:       %6d" % fail)
print("   Total:              %6d" % (ok + fail))

# 2. Banned countries
cur.execute("SELECT count(*) FROM requests WHERE is_banned = TRUE")
banned_ok = cur.fetchone()[0]
cur.execute("SELECT count(*) FROM failed_requests WHERE error_code = 400")
banned_fail = cur.fetchone()[0]
print("\n2. REQUESTS FROM BANNED COUNTRIES")
print("   Banned (in requests table):       %d" % banned_ok)
print("   Banned (400 in failed_requests):  %d" % banned_fail)
print("   Total from banned countries:      %d" % (banned_ok + banned_fail))

# 3. Male vs Female
cur.execute("SELECT gender, count(*) AS cnt FROM requests GROUP BY gender ORDER BY cnt DESC")
print("\n3. MALE vs FEMALE")
for row in cur.fetchall():
    print("   %-12s  %6d" % (row[0] or "Unknown", row[1]))

# 4. Top 5 countries
cur.execute("SELECT country, count(*) AS cnt FROM requests GROUP BY country ORDER BY cnt DESC LIMIT 5")
print("\n4. TOP 5 COUNTRIES")
for i, row in enumerate(cur.fetchall(), 1):
    print("   %d. %-25s  %6d" % (i, row[0] or "Unknown", row[1]))

# 5. Age groups
cur.execute("""
  SELECT CASE
    WHEN age BETWEEN 18 AND 24 THEN '18-24'
    WHEN age BETWEEN 25 AND 34 THEN '25-34'
    WHEN age BETWEEN 35 AND 44 THEN '35-44'
    WHEN age BETWEEN 45 AND 54 THEN '45-54'
    WHEN age BETWEEN 55 AND 64 THEN '55-64'
    WHEN age >= 65             THEN '65+'
    ELSE 'Unknown'
  END AS age_group, count(*) AS cnt
  FROM requests GROUP BY age_group ORDER BY cnt DESC
""")
print("\n5. AGE GROUP WITH MOST REQUESTS")
rows = cur.fetchall()
for row in rows:
    print("   %-12s  %6d" % (row[0], row[1]))
if rows:
    print("   >> Most requests: %s (%d requests)" % (rows[0][0], rows[0][1]))

# 6. Income groups
cur.execute("SELECT income, count(*) AS cnt FROM requests GROUP BY income ORDER BY cnt DESC")
print("\n6. INCOME GROUP WITH MOST REQUESTS")
rows = cur.fetchall()
for row in rows:
    print("   %-15s  %6d" % (row[0] or "Unknown", row[1]))
if rows:
    print("   >> Most requests: %s (%d requests)" % (rows[0][0], rows[0][1]))

print("\n" + sep)
cur.close()
conn.close()
