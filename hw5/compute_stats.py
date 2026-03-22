"""
CS528 HW5 – Compute and print request statistics from Cloud SQL.
Run on the server VM (pg8000 is already installed):

    /opt/hw5/venv/bin/python /opt/hw5/compute_stats.py

Reads DB connection info from the same environment variables as server.py.
"""

import os
import pg8000

DB_HOST = os.environ.get("DB_HOST", "127.0.0.1")
DB_PORT = int(os.environ.get("DB_PORT", "5432"))
DB_NAME = os.environ.get("DB_NAME", "hw5db")
DB_USER = os.environ.get("DB_USER", "hw5user")
DB_PASS = os.environ.get("DB_PASS", "hw5pass123")


def run():
    conn = pg8000.connect(
        host=DB_HOST, port=DB_PORT,
        database=DB_NAME, user=DB_USER, password=DB_PASS,
    )
    cur = conn.cursor()

    print("=" * 60)
    print(" CS528 HW5 – Request Statistics")
    print("=" * 60)

    # 1 ─ Successful vs unsuccessful
    cur.execute("SELECT COUNT(*) FROM requests")
    ok = cur.fetchone()[0]
    cur.execute("SELECT COUNT(*) FROM failed_requests")
    fail = cur.fetchone()[0]
    print(f"\n1) Successful: {ok}   Unsuccessful: {fail}   Total: {ok + fail}")

    # 2 ─ Banned country requests
    cur.execute("SELECT COUNT(*) FROM failed_requests WHERE error_code = 400")
    banned = cur.fetchone()[0]
    print(f"\n2) Requests from banned countries: {banned}")

    # 3 ─ Male vs Female
    cur.execute("SELECT gender, COUNT(*) FROM requests GROUP BY gender ORDER BY COUNT(*) DESC")
    print("\n3) Gender breakdown:")
    for row in cur.fetchall():
        print(f"   {row[0] or 'N/A':10s} {row[1]}")

    # 4 ─ Top 5 countries
    cur.execute("SELECT country, COUNT(*) AS c FROM requests GROUP BY country ORDER BY c DESC LIMIT 5")
    print("\n4) Top 5 countries:")
    for rank, row in enumerate(cur.fetchall(), 1):
        print(f"   {rank}. {row[0] or 'N/A':20s} {row[1]}")

    # 5 ─ Age groups
    cur.execute("""
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
            COUNT(*) AS c
        FROM requests GROUP BY age_group ORDER BY c DESC
    """)
    print("\n5) Age groups:")
    for row in cur.fetchall():
        print(f"   {row[0]:10s} {row[1]}")

    # 6 ─ Income groups
    cur.execute("SELECT income, COUNT(*) AS c FROM requests GROUP BY income ORDER BY c DESC")
    print("\n6) Income groups:")
    for row in cur.fetchall():
        print(f"   {row[0] or 'N/A':10s} {row[1]}")

    print("\n" + "=" * 60)
    cur.close()
    conn.close()


if __name__ == "__main__":
    run()
