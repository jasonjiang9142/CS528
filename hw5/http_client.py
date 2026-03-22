"""
CS528 HW5 – HTTP client with demographic headers.

Sends X-country, X-gender, X-age, X-income on every request so the
server can log them to Cloud SQL.

Usage:
  # 100 requests (default)
  python3 http_client.py --url http://SERVER_IP:8080 --num 100

  # 50 000 requests, reproducible randomness, no delay (stress test)
  python3 http_client.py --url http://SERVER_IP:8080 --num 50000 --seed 42 --delay 0

  # Single request
  python3 http_client.py --url http://SERVER_IP:8080 --file pages/page_00001.json
"""

import argparse
import random
import sys
import time
import urllib.request
import urllib.error

PAGE_RANGE = (0, 19999)

COUNTRIES = [
    "United States", "Canada", "United Kingdom", "Germany", "France",
    "Japan", "Australia", "Brazil", "India", "China",
    "Mexico", "South Korea", "Italy", "Spain", "Netherlands",
    "Russia", "Turkey", "Argentina", "Nigeria", "Egypt",
    # Banned countries (~9/29 ≈ 31 % chance per request)
    "North Korea", "Iran", "Cuba", "Myanmar", "Iraq",
    "Libya", "Sudan", "Zimbabwe", "Syria",
]

GENDERS = ["Male", "Female"]

INCOME_BRACKETS = [
    "0-10k", "10k-25k", "25k-50k", "50k-75k", "75k-100k", "100k+",
]


def random_headers(rng):
    """Return a dict of demographic headers using the given RNG."""
    return {
        "X-country": rng.choice(COUNTRIES),
        "X-gender":  rng.choice(GENDERS),
        "X-age":     str(rng.randint(18, 85)),
        "X-income":  rng.choice(INCOME_BRACKETS),
    }


def make_request(url, path="", method="GET", extra_headers=None):
    full_url = url.rstrip("/") + "/" + path.lstrip("/") if path else url
    req = urllib.request.Request(full_url, method=method)
    for k, v in (extra_headers or {}).items():
        req.add_header(k, v)
    try:
        with urllib.request.urlopen(req, timeout=30) as resp:
            body = resp.read().decode("utf-8", errors="replace")
            return resp.status, body[:200]
    except urllib.error.HTTPError as exc:
        return exc.code, exc.read().decode("utf-8", errors="replace")[:200]
    except Exception as exc:
        return -1, str(exc)


def main():
    ap = argparse.ArgumentParser(description="HW5 HTTP client")
    ap.add_argument("--url", required=True)
    ap.add_argument("--num", type=int, default=100)
    ap.add_argument("--file", help="Single file (e.g. pages/page_00001.json)")
    ap.add_argument("--method", default="GET")
    ap.add_argument("--seed", type=int, default=None, help="Random seed for reproducibility")
    ap.add_argument("--delay", type=float, default=0.05,
                    help="Seconds between requests (0 for stress test)")
    args = ap.parse_args()

    rng = random.Random(args.seed)

    # -- single request mode ------------------------------------------------
    if args.file:
        path = args.file if args.file.startswith("pages/") else f"pages/{args.file}"
        hdrs = random_headers(rng)
        status, body = make_request(args.url, path, method=args.method, extra_headers=hdrs)
        print(f"Headers sent: {hdrs}")
        print(f"Status: {status}\nBody: {body}")
        return 0 if 200 <= status < 300 else 1

    # -- batch mode ---------------------------------------------------------
    ok = errors = 0
    start = time.time()

    for i in range(args.num):
        page_id = rng.randint(*PAGE_RANGE)
        path = f"pages/page_{page_id:05d}.json"
        hdrs = random_headers(rng)
        status, _ = make_request(args.url, path, extra_headers=hdrs)
        if 200 <= status < 300:
            ok += 1
        else:
            errors += 1
        if (i + 1) % 5000 == 0 or (i + 1) == args.num:
            print(f"  {i+1}/{args.num}  OK={ok}  other={errors}", flush=True)
        if args.delay > 0:
            time.sleep(args.delay)

    elapsed = time.time() - start
    rps = args.num / elapsed if elapsed else 0
    print(f"\nDone: {ok} OK, {errors} non-2xx out of {args.num}  "
          f"({elapsed:.1f}s, ~{rps:.1f} req/s)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
