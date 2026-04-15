"""
CS528 HW8 – Load-balancer client.

Sends one request per second to the load balancer and prints the
X-Server-Zone response header to observe which backend is serving.
Reports errors immediately so you can see when the LB detects a
downed server and when it re-routes.

Usage:
  python3 lb_client.py --url http://LB_IP:8080 --duration 120

  While running:
    - SSH into one VM and run: sudo systemctl stop hw8-server
    - Watch this client's output for errors / zone changes
    - Then: sudo systemctl start hw8-server
    - Watch for zone recovery
"""

import argparse
import sys
import time
import http.client
from urllib.parse import urlparse


def send_request(host, port, path, country=None):
    """Send one GET and return (status, zone_header, latency_ms) or error info."""
    t0 = time.time()
    try:
        conn = http.client.HTTPConnection(host, port, timeout=5)
        headers = {}
        if country:
            headers["X-country"] = country
        conn.request("GET", path, headers=headers)
        resp = conn.getresponse()
        resp.read()
        latency = (time.time() - t0) * 1000
        zone = resp.getheader("X-Server-Zone", "???")
        status = resp.status
        conn.close()
        return status, zone, latency, None
    except Exception as exc:
        latency = (time.time() - t0) * 1000
        return None, None, latency, str(exc)


def main():
    ap = argparse.ArgumentParser(description="HW8 load-balancer client")
    ap.add_argument("--url", required=True, help="LB URL  (e.g. http://IP:8080)")
    ap.add_argument("--duration", type=int, default=60,
                    help="How many seconds to run (default 60)")
    ap.add_argument("--path", default="/pages/page_00001.json",
                    help="Request path (default /pages/page_00001.json)")
    ap.add_argument("--country", default=None,
                    help="X-country header value (for forbidden-country testing)")
    args = ap.parse_args()

    parsed = urlparse(args.url)
    host = parsed.hostname
    port = parsed.port or 8080

    print(f"Sending 1 req/s to {host}:{port}{args.path} for {args.duration}s")
    print(f"{'#':>4}  {'Status':>6}  {'Zone':<20}  {'Latency':>8}  Notes")
    print("-" * 65)

    prev_zone = None
    error_count = 0
    zone_changes = []

    for i in range(1, args.duration + 1):
        status, zone, latency_ms, err = send_request(host, port, args.path, args.country)
        ts = time.strftime("%H:%M:%S")

        if err:
            error_count += 1
            print(f"{i:4d}  {'ERR':>6}  {'---':<20}  {latency_ms:7.0f}ms  {ts} ERROR: {err}")
        else:
            note = ""
            if prev_zone is not None and zone != prev_zone:
                note = f"{ts} ** ZONE CHANGED from {prev_zone} **"
                zone_changes.append((i, prev_zone, zone, ts))
            elif i == 1:
                note = f"{ts} (first request)"
            else:
                note = ts
            prev_zone = zone
            print(f"{i:4d}  {status:>6}  {zone:<20}  {latency_ms:7.0f}ms  {note}")

        if i < args.duration:
            time.sleep(1)

    print("-" * 65)
    print(f"Done. {args.duration} requests, {error_count} errors.")
    if zone_changes:
        print("Zone transitions:")
        for seq, old, new, timestamp in zone_changes:
            print(f"  req #{seq} at {timestamp}: {old} -> {new}")

    return 0


if __name__ == "__main__":
    sys.exit(main())
