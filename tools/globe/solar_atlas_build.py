"""Builds the globe's Solar Atlas layer from Global Solar Atlas data.

Source: Global Solar Atlas 2.0 (Solargis for the World Bank / ESMAP), the
World PVOUT long-term yearly average, "AvgDailyTotals" (kWh/kWp per day of
a typical PV system), AAIGrid. Licence CC BY 4.0, credited in CREDITS.md.

    python tools/globe/solar_atlas_build.py [--zip <World_PVOUT_..._AAIGRID.zip>]
        [--cell 0.05] [--out core/globe/data/gsa_pvout.png]

Without --zip the file (about 300 MB) is downloaded to a temp folder first.
The grid (30 arc-seconds) is block-averaged to --cell degrees and written as
an equirectangular RGB PNG covering the whole globe, north up, longitude
-180 at the left: R = value / MAX_PVOUT (0..255), G = 255 where the atlas has
data, B = 0. The globe's overlay shader reads R as the value and G as the
coverage, like the GHI and GFS layers. A JSON sidecar records the source.
"""
import argparse
import io
import json
import os
import sys
import tempfile
import time
import urllib.request
import zipfile

import numpy as np
from PIL import Image

URL = ("https://api.globalsolaratlas.info/download/World/"
       "World_PVOUT_GISdata_LTAy_AvgDailyTotals_GlobalSolarAtlas-v2_AAIGRID.zip")
MAX_PVOUT = 7.0  # kWh/kWp/day: R = 255 at this value (the atlas tops out near 6.4)


def download(dest: str) -> str:
    print("downloading", URL)
    req = urllib.request.Request(URL, headers={"User-Agent": "SIMbiogenesis solar atlas build"})
    with urllib.request.urlopen(req, timeout=120) as r, open(dest, "wb") as f:
        while True:
            b = r.read(1 << 20)
            if not b:
                break
            f.write(b)
    return dest


def read_header(stream) -> dict:
    h = {}
    while len(h) < 6:
        line = stream.readline()
        k, v = line.split()
        h[k.lower()] = float(v)
    return h


def build(zip_path: str, cell: float, out: str) -> None:
    zf = zipfile.ZipFile(zip_path)
    asc = [n for n in zf.namelist() if n.lower().endswith(".asc")]
    if not asc:
        sys.exit("no .asc grid in %s (members: %s)" % (zip_path, zf.namelist()))
    print("grid:", asc[0])
    with zf.open(asc[0]) as raw:
        s = io.TextIOWrapper(raw, encoding="ascii")
        h = read_header(s)
        ncols, nrows = int(h["ncols"]), int(h["nrows"])
        cs = h["cellsize"]
        x0 = h.get("xllcorner", h.get("xllcenter", 0.0) - cs / 2)
        y0 = h.get("yllcorner", h.get("yllcenter", 0.0) - cs / 2)
        nodata = h["nodata_value"]
        k = max(1, int(round(cell / cs)))
        cell = k * cs
        W = int(round(360.0 / cell))
        H = int(round(180.0 / cell))
        print("ncols %d nrows %d cell %.6f deg -> %d x %d at %.4f deg (block %d)" % (ncols, nrows, cs, W, H, cell, k))
        acc = np.zeros(ncols // k, dtype=np.float64)
        cnt = np.zeros(ncols // k, dtype=np.float64)
        img_v = np.full((H, W), np.nan, dtype=np.float32)
        top = y0 + nrows * cs  # north edge
        col0 = int(round((x0 + 180.0) / cell))
        t0 = time.time()
        for r in range(nrows):
            line = s.readline()
            a = np.fromstring(line, sep=" ", dtype=np.float64)
            if a.size != ncols:
                sys.exit("row %d has %d values, expected %d" % (r, a.size, ncols))
            a = a[: (ncols // k) * k].reshape(-1, k)
            ok = a != nodata
            acc += np.where(ok, a, 0.0).sum(axis=1)
            cnt += ok.sum(axis=1)
            if (r + 1) % k == 0:
                # Only cells with at least a quarter of their samples are data.
                v = np.where(cnt >= 0.25 * k * k, acc / np.maximum(cnt, 1.0), np.nan)
                lat_top = top - (r + 1 - k) * cs
                row = int(round((90.0 - lat_top) / cell))
                if 0 <= row < H:
                    n = min(v.size, W - col0)
                    img_v[row, col0:col0 + n] = v[:n]
                acc[:] = 0.0
                cnt[:] = 0.0
            if r % 2000 == 0:
                print("  row %d / %d  (%.0f s)" % (r, nrows, time.time() - t0))
    valid = ~np.isnan(img_v)
    rgb = np.zeros((H, W, 3), dtype=np.uint8)
    rgb[..., 0] = np.where(valid, np.clip(np.nan_to_num(img_v) / MAX_PVOUT, 0, 1) * 255.0 + 0.5, 0).astype(np.uint8)
    rgb[..., 1] = np.where(valid, 255, 0).astype(np.uint8)
    os.makedirs(os.path.dirname(out), exist_ok=True)
    Image.fromarray(rgb, "RGB").save(out, optimize=True)
    vv = img_v[valid]
    meta = {
        "source": "Global Solar Atlas 2.0 (Solargis / World Bank Group, ESMAP), World PVOUT LTAy AvgDailyTotals",
        "licence": "CC BY 4.0",
        "url": URL,
        "zip": os.path.basename(zip_path),
        "quantity": "PVOUT", "unit": "kWh/kWp/day",
        "encoding": "R = value / max * 255, G = 255 where data",
        "max": MAX_PVOUT, "cell_deg": cell, "width": W, "height": H,
        "built": time.strftime("%Y-%m-%d"),
        "stats": {"min": float(vv.min()), "max": float(vv.max()), "mean": float(vv.mean())},
    }
    with open(os.path.splitext(out)[0] + ".json", "w", encoding="utf-8", newline="\n") as f:
        json.dump(meta, f, indent=1)
    print("wrote %s (%.1f MB), values %.2f..%.2f" % (out, os.path.getsize(out) / 1e6, vv.min(), vv.max()))


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--zip", default="")
    ap.add_argument("--cell", type=float, default=0.05)
    ap.add_argument("--out", default="core/globe/data/gsa_pvout.png")
    a = ap.parse_args()
    z = a.zip or download(os.path.join(tempfile.gettempdir(), "World_PVOUT_LTAy_AAIGRID.zip"))
    build(z, a.cell, a.out)


if __name__ == "__main__":
    main()
