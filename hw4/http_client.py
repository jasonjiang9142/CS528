"""
CS528 HW4 – HTTP client for testing the web server (Service 1).

Usage examples
  # 100 random-page GET requests
  python3 http_client.py --url http://SERVER_IP:8080 --num 100

  # Single file request
  python3 http_client.py --url http://SERVER_IP:8080 --file pages/page_00001.json

  # Forbidden-country demo
  python3 http_client.py --url http://SERVER_IP:8080 --file pages/page_00001.json --x-country Iran

  # Stress test (no delay)
  python3 http_client.py --url http://SERVER_IP:8080 --num 500 --delay 0
"""

import argparse
import random
import sys
import time
import urllib.request
import urllib.error

PAGE_RANGE = (0, 19999)


def make_request(url, path="", method="GET", x_country=None):
    """Fire one HTTP request; returns (status_code, body_preview)."""
    full_url = url.rstrip("/") + "/" + path.lstrip("/") if path else url
    req = urllib.request.Request(full_url, method=method)
    if x_country:
        req.add_header("X-country", x_country)
    try:
        with urllib.request.urlopen(req, timeout=30) as resp:
            body = resp.read().decode("utf-8", errors="replace")
            return resp.status, body[:200] + ("…" if len(body) > 200 else "")
    except urllib.error.HTTPError as exc:
        return exc.code, exc.read().decode("utf-8", errors="replace")[:200]
    except Exception as exc:
        return -1, str(exc)


def main():
    ap = argparse.ArgumentParser(description="HW4 HTTP client")
    ap.add_argument("--url", required=True, help="Base URL  (e.g. http://IP:8080)")
    ap.add_argument("--num", type=int, default=100, help="Number of requests (default 100)")
    ap.add_argument("--file", help="Single file path (e.g. pages/page_00001.json)")
    ap.add_argument("--x-country", help="X-country header value, or 'random'")
    ap.add_argument("--method", default="GET", help="HTTP method (default GET)")
    ap.add_argument("--delay", type=float, default=0.05,
                    help="Seconds between requests (default 0.05, use 0 for stress test)")
    args = ap.parse_args()

    # --- single request mode -----------------------------------------------
    if args.file:
        path = args.file if args.file.startswith("pages/") else f"pages/{args.file}"
        country = args.x_country
        if country and country.lower() == "random":
            country = random.choice(["United States", "Iran", "Germany", "Syria"])
        status, body = make_request(args.url, path, method=args.method, x_country=country)
        print(f"Status: {status}\nBody: {body}")
        return 0 if 200 <= status < 300 else 1

    # --- batch mode --------------------------------------------------------
    countries = None
    if args.x_country and args.x_country.lower() == "random":
        countries = ["United States", "Germany", "Japan", "Iran", "Syria", "Cuba", None]
    country_val = args.x_country if (args.x_country and args.x_country.lower() != "random") else None

    ok = 0
    errors = 0
    start = time.time()

    for i in range(args.num):
        page_id = random.randint(*PAGE_RANGE)
        path = f"pages/page_{page_id:05d}.json"
        if countries is not None:
            country_val = random.choice(countries)
        status, _ = make_request(args.url, path, x_country=country_val)
        if 200 <= status < 300:
            ok += 1
        else:
            errors += 1
        if (i + 1) % 20 == 0:
            print(f"  {i+1}/{args.num} done  (OK={ok}, other={errors})", flush=True)
        if args.delay > 0:
            time.sleep(args.delay)

    elapsed = time.time() - start
    rps = args.num / elapsed if elapsed > 0 else 0
    print(f"\nDone: {ok} OK, {errors} non-2xx out of {args.num} requests  "
          f"({elapsed:.1f}s, ~{rps:.1f} req/s)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
