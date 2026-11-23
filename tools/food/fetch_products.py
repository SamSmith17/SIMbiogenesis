#!/usr/bin/env python3
"""Fetch the curated Open Food Facts products into tools/food/cache/.

Developer tool (plans/FOOD_WASTE_REALISM_PLAN.md Phase 2) - never runs in
the game or in tests. The game-side parser lives in GDScript
(FoodProducts.parse_off_product); this script only downloads raw v2
replies, so there is exactly ONE parser. After fetching, run:

    Godot --headless --path . --script tools/food/build_catalog.gd

Rate limits per OFF docs: product reads <= 15/min (we sleep 4.5 s), with
exponential backoff on 429/5xx. Data is ODbL - see CREDITS.md
(data-openfoodfacts).

Usage:
    python tools/food/fetch_products.py [--only CODE,CODE] [--force]
"""

import argparse
import json
import sys
import time
import urllib.error
import urllib.request
from pathlib import Path

HERE = Path(__file__).resolve().parent
SOURCES = HERE / "catalog_sources.json"
CACHE = HERE / "cache"

# OFF asks for AppName/Version (contact). The project's public repository
# is the contact point for this developer tool.
USER_AGENT = "SIMbiogenesis/1.0 (https://github.com/SamSmith17/SIMbiogenesis)"

FIELDS = ",".join([
    "code", "product_name", "brands", "categories_tags", "quantity",
    "product_quantity", "serving_size", "serving_quantity", "nutriments",
    "packagings", "packaging_tags", "rev",
])

URL = "https://world.openfoodfacts.org/api/v2/product/{code}.json?fields=" + FIELDS

SLEEP_S = 4.5          # <= 15 product reads / minute
MAX_RETRIES = 4
BACKOFF_S = 10.0


def fetch(code: str) -> bytes | None:
    url = URL.format(code=code)
    req = urllib.request.Request(url, headers={"User-Agent": USER_AGENT})
    delay = BACKOFF_S
    for attempt in range(MAX_RETRIES):
        try:
            with urllib.request.urlopen(req, timeout=30) as resp:
                return resp.read()
        except urllib.error.HTTPError as e:
            if e.code in (429, 500, 502, 503, 504) and attempt < MAX_RETRIES - 1:
                print(f"  {code}: HTTP {e.code}, retrying in {delay:.0f} s")
                time.sleep(delay)
                delay *= 2
                continue
            print(f"  {code}: HTTP {e.code} - giving up")
            return None
        except (urllib.error.URLError, TimeoutError) as e:
            if attempt < MAX_RETRIES - 1:
                print(f"  {code}: {e}, retrying in {delay:.0f} s")
                time.sleep(delay)
                delay *= 2
                continue
            print(f"  {code}: {e} - giving up")
            return None
    return None


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--only", default="", help="comma-separated barcodes to (re)fetch")
    ap.add_argument("--force", action="store_true", help="refetch even when cached")
    args = ap.parse_args()

    sources = json.loads(SOURCES.read_text(encoding="utf-8"))
    codes = [str(p["code"]) for p in sources.get("products", []) if p.get("code")]
    if args.only:
        wanted = {c.strip() for c in args.only.split(",") if c.strip()}
        codes = [c for c in codes if c in wanted]
    CACHE.mkdir(parents=True, exist_ok=True)

    fetched = skipped = failed = 0
    for i, code in enumerate(codes):
        out = CACHE / f"off_{code}.json"
        if out.exists() and not args.force:
            skipped += 1
            continue
        if fetched:
            time.sleep(SLEEP_S)
        print(f"[{i + 1}/{len(codes)}] {code}")
        body = fetch(code)
        if body is None:
            failed += 1
            continue
        try:
            reply = json.loads(body)
        except json.JSONDecodeError:
            print(f"  {code}: not JSON - skipped")
            failed += 1
            continue
        if int(reply.get("status", 0)) != 1:
            print(f"  {code}: status {reply.get('status')} ({reply.get('status_verbose')})")
            failed += 1
            continue
        out.write_bytes(body)
        fetched += 1

    print(f"done: {fetched} fetched, {skipped} cached, {failed} failed of {len(codes)}")
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
