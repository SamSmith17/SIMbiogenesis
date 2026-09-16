#!/usr/bin/env python3
"""Prepare a Stellarium all-sky export for SIMbiogenesis and MEASURE its registration.

    python tools/starmap_prepare.py <screenshot.png> [--out assets/sky/starmap_equirect_8k.png]
        [--floor 6] [--gamma 1.0] [--blank-rows N] [--blank-box x0,y0,x1,y1 ...]
        [--max-residual-px 8] [--search-px 48] [--note "Stellarium 25.1 ..."] [--dry-run]

What it does, in order:
  1. Asserts the image is 2:1 and at least 4096 wide (plate-carrée, whole sphere).
  2. Blanks optional regions (rows at the poles, or boxes given as FRACTIONS of
     the image — used to erase a baked-in Stellarium toolbar) WITHOUT cropping or
     stretching, so the declination scale is untouched.
  3. Black-floors the background: every pixel's RGB is scaled by
     max(0, (L - floor) / (255 - floor)) where L is ITU-R 601 luminance. That
     zeroes airglow/JPEG noise below the floor and keeps the Milky Way (rendered
     at Stellarium intensity >= 1.5 it sits around 30-80/255).
  4. REGISTRATION: for each hypothesis (RA increases leftward/rightward x north
     pole is top/bottom row) it uses the brightest catalog stars as anchors to
     solve which RA sits at the left edge, then checks all ten catalog stars —
     brightest blob within +-search-px of the predicted pixel, luminance-weighted
     centroid, residual in pixels. A hypothesis PASSES with >= 8/10 stars found
     and max residual <= --max-residual-px. The winner is the smallest median
     residual. Nothing is written if none passes, or if two pass within 1 px of
     each other (ambiguous) — a wrong sidecar is worse than none, because the
     sky shader trusts it.
  5. Writes the PNG and the sidecar JSON (same basename, .json) that
     StarSkyMath.load_registration() reads, and prints the per-star table.

Pixel convention: pixel (i, j) covers [i, i+1) x [j, j+1); its centre is
(i + 0.5, j + 0.5). Predicted positions are continuous (u*w, v*h). The same
convention lives in StarSkyMath.pixel_from_equatorial.

Pillow only (no numpy): all the heavy lifting is Pillow C ops (convert/point/
multiply); Python touches only the small search windows.
"""

import argparse
import json
import math
import os
import sys
from collections import deque
from datetime import datetime, timezone

try:
    from PIL import Image, ImageChops
except ImportError:  # pragma: no cover
    print("starmap_prepare: Pillow is required (pip install pillow)", file=sys.stderr)
    sys.exit(1)

Image.MAX_IMAGE_PIXELS = None  # 8k x 4k is fine; silence the decompression-bomb guard

# J2000 (degrees). Bright, spread over RA and both hemispheres. Anchors first.
CATALOG = [
    ("sirius",     101.287, -16.716),
    ("vega",       279.235,  38.784),
    ("arcturus",   213.915,  19.182),
    ("canopus",     95.988, -52.696),
    ("capella",     79.172,  45.998),
    ("rigel",       78.634,  -8.202),
    ("procyon",    114.825,   5.225),
    ("achernar",    24.429, -57.237),
    ("betelgeuse",  88.793,   7.407),
    ("altair",     297.696,   8.868),
]
ANCHORS = ("sirius", "vega", "arcturus")

SCHEMA = 1


# ------------------------------------------------------------------ geometry

def uv_from_equatorial(ra, dec, ra0, ra_dir, north_up):
    u = ((ra - ra0) * ra_dir / 360.0) % 1.0
    v = 0.5 - dec / 180.0
    if not north_up:
        v = 1.0 - v
    return u, v


def pixel_from_equatorial(ra, dec, ra0, ra_dir, north_up, w, h):
    u, v = uv_from_equatorial(ra, dec, ra0, ra_dir, north_up)
    return u * w, v * h


def circular_mean_deg(angles):
    sx = sum(math.cos(math.radians(a)) for a in angles)
    sy = sum(math.sin(math.radians(a)) for a in angles)
    return math.degrees(math.atan2(sy, sx)) % 360.0


def wrapped_dx(a, b, w):
    d = (a - b) % w
    if d > w / 2:
        d -= w
    return d


# ------------------------------------------------------------------ blobs

# A star is a COMPACT disc: Stellarium's brightest stars are ~20 px across at 8k
# (a few hundred pixels of area) and saturated. The Milky Way's core, rendered
# at intensity 1.6, is far brighter in TOTAL — thousands of pixels around
# 60-180/255 — and out-sums every star. These two filters are what keep the
# fit on stars: an area cap and a minimum mean brightness.
MAX_STAR_AREA_PX = 1500
MIN_STAR_MEAN = 170.0


def _star_blobs(px, w, x0, x1, y0, y1, thr):
    """_components() restricted to star-like discs; yields (sum, cx, cy, peak, area)."""
    seen = set()
    for yy in range(y0, y1 + 1):
        for xx in range(x0, x1 + 1):
            if (xx, yy) in seen or px[xx % w, yy] < thr:
                continue
            seen.add((xx, yy))
            queue = deque([(xx, yy)])
            sw = sx = sy = 0.0
            peak = 0
            area = 0
            while queue:
                x, y = queue.popleft()
                v = px[x % w, y]
                sw += v
                sx += v * (x + 0.5)
                sy += v * (y + 0.5)
                area += 1
                if v > peak:
                    peak = v
                for nx, ny in ((x + 1, y), (x - 1, y), (x, y + 1), (x, y - 1)):
                    if ny < y0 or ny > y1 or nx < x0 or nx > x1 or (nx, ny) in seen:
                        continue
                    if px[nx % w, ny] >= thr:
                        seen.add((nx, ny))
                        queue.append((nx, ny))
            if area <= MAX_STAR_AREA_PX and sw / area >= MIN_STAR_MEAN:
                yield sw, sx / sw, sy / sw, peak, area


def blob_centroid(px, w, h, cx, cy, radius, min_peak):
    """The star-like blob with the largest integrated brightness within
    +-radius of (cx, cy) (x wraps, y clips). The threshold is the higher of
    60% of the window's peak and the window's median + 60, so a bright Milky
    Way background under the window never joins the disc.
    Returns (x, y, peak) in continuous pixel coordinates, or None."""
    x0 = int(math.floor(cx)) - radius
    x1 = int(math.floor(cx)) + radius
    y0 = max(0, int(math.floor(cy)) - radius)
    y1 = min(h - 1, int(math.floor(cy)) + radius)
    if y1 < y0:
        return None
    vals = [px[xx % w, yy] for yy in range(y0, y1 + 1) for xx in range(x0, x1 + 1)]
    best = max(vals)
    if best < min_peak:
        return None
    median = sorted(vals)[len(vals) // 2]
    thr = max(min_peak, 0.6 * best, median + 60)
    comps = list(_star_blobs(px, w, x0, x1, y0, y1, thr))
    if not comps:
        return None
    sw, bx, by, peak, area = max(comps, key=lambda c: c[0])
    return bx, by, peak


def band_brightest(lum, w, h, cy, band):
    """Centre (x, y) and peak of the biggest STAR disc (largest integrated
    brightness among compact blobs) in the full-width row band around cy —
    the anchor star. Thresholded at 80% of the band's peak so the Milky Way
    (rarely above ~180/255) is not even traversed."""
    y0 = max(0, int(cy) - band)
    y1 = min(h - 1, int(cy) + band)
    if y1 < y0:
        return None
    strip = lum.crop((0, y0, w, y1 + 1))
    lo, hi = strip.getextrema()
    if hi <= 0:
        return None
    thr = max(1, int(0.8 * hi))
    sp = strip.load()
    best = None
    for sw, cx, cy2, peak, area in _star_blobs(sp, w, 0, w - 1, 0, y1 - y0, thr):
        if best is None or sw > best[0]:
            best = (sw, cx, cy2 + y0, peak)
    if best is None:
        return None
    return best[1], best[2], best[3]


# ------------------------------------------------------------------ registration

def evaluate(lum, px, w, h, ra_dir, north_up, ra0, search_px, min_peak):
    rows = []
    found_ra0 = []
    for name, ra, dec in CATALOG:
        pxx, pyy = pixel_from_equatorial(ra, dec, ra0, ra_dir, north_up, w, h)
        hit = blob_centroid(px, w, h, pxx, pyy, search_px, min_peak)
        if hit is None:
            rows.append({"star": name, "pred": [pxx, pyy], "found": None, "residual_px": None})
            continue
        fx, fy, peak = hit
        fx %= w
        found_ra0.append((ra - ra_dir * 360.0 * (fx / w)) % 360.0)
        rows.append({"star": name, "pred": [pxx, pyy], "found": [fx, fy], "peak": peak,
                     "residual_px": math.hypot(wrapped_dx(fx, pxx, w), fy - pyy)})
    return rows, found_ra0


def solve_hypothesis(lum, px, w, h, ra_dir, north_up, search_px, min_peak):
    """Anchor on each bright star's row band to get a candidate ra0, then refine
    over every found star. Returns the best (ra0, rows) for this hypothesis."""
    best = None
    for anchor in ANCHORS:
        ra_a, dec_a = next((ra, dec) for n, ra, dec in CATALOG if n == anchor)
        _, vy = uv_from_equatorial(ra_a, dec_a, 0.0, ra_dir, north_up)
        hit = band_brightest(lum, w, h, vy * h, search_px)
        if hit is None or hit[2] < min_peak:
            continue
        bx = hit[0]  # already a blob centroid in continuous coordinates
        ra0 = (ra_a - ra_dir * 360.0 * (bx / w)) % 360.0
        # two refinement passes: predict -> find -> circular-mean the implied ra0
        rows = []
        for _ in range(2):
            rows, implied = evaluate(lum, px, w, h, ra_dir, north_up, ra0, search_px, min_peak)
            if len(implied) < 2:
                break
            ra0 = circular_mean_deg(implied)
        rows, _ = evaluate(lum, px, w, h, ra_dir, north_up, ra0, search_px, min_peak)
        res = sorted(r["residual_px"] for r in rows if r["residual_px"] is not None)
        n_found = len(res)
        median = res[len(res) // 2] if res else float("inf")
        worst = res[-1] if res else float("inf")
        cand = {"ra_dir": ra_dir, "north_up": north_up, "ra_deg_at_u0": ra0, "anchor": anchor,
                "rows": rows, "found": n_found, "median": median, "max": worst}
        if best is None or (cand["found"], -cand["median"]) > (best["found"], -best["median"]):
            best = cand
    return best


def register(lum, w, h, search_px, min_peak, max_residual):
    px = lum.load()
    results = []
    for ra_dir in (-1, 1):
        for north_up in (True, False):
            c = solve_hypothesis(lum, px, w, h, ra_dir, north_up, search_px, min_peak)
            if c is None:
                c = {"ra_dir": ra_dir, "north_up": north_up, "ra_deg_at_u0": float("nan"),
                     "anchor": None, "rows": [], "found": 0, "median": float("inf"), "max": float("inf")}
            c["passes"] = c["found"] >= 8 and c["max"] <= max_residual
            results.append(c)
    return results


# ------------------------------------------------------------------ image ops

def blank_regions(img, rows, boxes):
    w, h = img.size
    black = (0, 0, 0)
    if rows > 0:
        img.paste(black, (0, 0, w, rows))
        img.paste(black, (0, h - rows, w, h))
    for (x0, y0, x1, y1) in boxes:
        img.paste(black, (int(x0 * w), int(y0 * h), int(math.ceil(x1 * w)), int(math.ceil(y1 * h))))


def black_floor(img, floor):
    if floor <= 0:
        return img
    lum = img.convert("L")
    lut = [max(0, min(255, round((v - floor) * 255.0 / (255.0 - floor)))) for v in range(256)]
    scale = lum.point(lut)
    return ImageChops.multiply(img, Image.merge("RGB", (scale, scale, scale)))


def apply_gamma(img, gamma):
    if abs(gamma - 1.0) < 1e-6:
        return img
    lut = [max(0, min(255, round(255.0 * (v / 255.0) ** gamma))) for v in range(256)]
    return img.point(lut * 3)


def disc_radius_px(lum, px, w, h, x, y, search_px):
    """Radius (px) of the star disc at (x, y): sqrt(area / pi) of its blob."""
    x0 = int(x) - search_px
    x1 = int(x) + search_px
    y0 = max(0, int(y) - search_px)
    y1 = min(h - 1, int(y) + search_px)
    best = None
    for sw, cx, cy, peak, area in _star_blobs(px, w, x0, x1, y0, y1, 128):
        if best is None or sw > best[0]:
            best = (sw, area)
    if best is None:
        return 0.0
    return math.sqrt(best[1] / math.pi)


def pole_bands(step_ratio=1.12):
    """Declination breakpoints for the pole-footprint bands: finer toward the
    pole so the dilation radius never changes by more than step_ratio across a
    band (a coarse band over-spreads its low rows and under-spreads its high)."""
    edges = [45.0]
    while edges[-1] < 89.9:
        lo = edges[-1]
        target = (1.0 / math.cos(math.radians(lo)) - 1.0) * step_ratio
        hi = math.degrees(math.acos(1.0 / (target + 1.0)))
        hi = min(max(hi, lo + 0.05), 89.9)
        edges.append(round(hi, 3))
    edges.append(90.0)
    return edges


POLE_BANDS = pole_bands()


def _cone_dilate_h(band, r):
    """Horizontal grayscale CONE dilation of radius r (x wraps like RA):
    out(x) = max_k [ in(x - k) - (255 / r) * |k| ]. A full-bright disc spreads
    the whole r; a star of peak p spreads only r * p / 255. Stellarium's disc
    radius grows with brightness, so a plain max filter (same r for every
    star) turned every FAINT high-dec star into a dash — this keeps them round.
    Composed from doubling shifts: max-plus convolution of linear kernels is a
    linear kernel, so the composition IS the cone."""
    out = band
    slope = 255.0 / max(r, 1)
    reach = 0
    k = 1
    while reach + k <= r:
        drop = int(round(slope * k))
        shifted = ImageChops.offset(out, k, 0)
        shifted_n = ImageChops.offset(out, -k, 0)
        if drop > 0:
            shifted = shifted.point(lambda v, d=drop: max(0, v - d))
            shifted_n = shifted_n.point(lambda v, d=drop: max(0, v - d))
        out = ImageChops.lighter(out, ImageChops.lighter(shifted, shifted_n))
        reach += k
        k *= 2
    rem = r - reach
    if rem > 0:
        drop = int(round(slope * rem))
        shifted = ImageChops.offset(out, rem, 0)
        shifted_n = ImageChops.offset(out, -rem, 0)
        if drop > 0:
            shifted = shifted.point(lambda v, d=drop: max(0, v - d))
            shifted_n = shifted_n.point(lambda v, d=drop: max(0, v - d))
        out = ImageChops.lighter(out, ImageChops.lighter(shifted, shifted_n))
    return out


def pole_footprint_dilate(img, disc_px, north_up):
    """Make image-space star discs into SKY-space discs near the poles.

    Stellarium draws every star as a round disc of up to ~disc_px radius in the
    IMAGE, but a plate carrée squeezes 1 px of x into 360/w * cos(dec) degrees
    of sky: at Polaris (dec 89.26) a 10 px disc is 0.006 deg of sky wide and the
    game renders it as a sub-pixel sliver — the pole star vanishes. Dilating
    each row horizontally by
        r(dec) = disc_px * (1 / cos(dec) - 1)
    restores a round footprint on the sky. The dilation is a brightness-
    proportional CONE (see _cone_dilate_h) so faint stars, whose discs are
    smaller, spread less. Only |dec| >= 45 deg needs it; the last rows become
    a small polar cap. The Milky Way is dark at both celestial poles, so
    nothing else gets smeared. Returns (image, bands [dec_lo, dec_hi, r])."""
    w, h = img.size
    bands = []
    for i in range(len(POLE_BANDS) - 1):
        lo, hi = POLE_BANDS[i], POLE_BANDS[i + 1]
        mid = min(0.5 * (lo + hi), 89.95)
        r = int(round(disc_px * (1.0 / math.cos(math.radians(mid)) - 1.0)))
        if r < 1:
            continue
        r = min(r, w // 2)
        bands.append([lo, hi, r])
        for sign in (1, -1):
            d_top, d_bot = (hi, lo) if sign > 0 else (-lo, -hi)
            v_top = 0.5 - d_top / 180.0
            v_bot = 0.5 - d_bot / 180.0
            if not north_up:
                v_top, v_bot = 1.0 - v_bot, 1.0 - v_top
            y0 = max(0, int(math.floor(v_top * h)))
            y1 = min(h, int(math.ceil(v_bot * h)))
            if y1 <= y0:
                continue
            img.paste(_cone_dilate_h(img.crop((0, y0, w, y1)), r), (0, y0))
    return img, bands


def parse_box(s):
    parts = [float(p) for p in s.split(",")]
    if len(parts) != 4 or not all(0.0 <= p <= 1.0 for p in parts):
        raise argparse.ArgumentTypeError("box must be x0,y0,x1,y1 as fractions of the image")
    return tuple(parts)


# ------------------------------------------------------------------ main

def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("source")
    ap.add_argument("--out", default="assets/sky/starmap_equirect_8k.png")
    ap.add_argument("--floor", type=int, default=6, help="luminance floor 0-255 (default 6)")
    ap.add_argument("--gamma", type=float, default=1.0)
    ap.add_argument("--blank-rows", type=int, default=0, help="black out N rows at top AND bottom")
    ap.add_argument("--blank-box", type=parse_box, action="append", default=[],
                    help="black out a box x0,y0,x1,y1 in image FRACTIONS (repeatable)")
    ap.add_argument("--max-residual-px", type=float, default=8.0)
    ap.add_argument("--search-px", type=int, default=48)
    ap.add_argument("--min-peak", type=int, default=40, help="a blob needs a pixel this bright (0-255)")
    ap.add_argument("--note", default="", help="free text recorded in the sidecar (Stellarium version, knobs)")
    ap.add_argument("--no-pole-dilate", action="store_true",
                    help="skip the pole-footprint dilation (stars near the poles will render as slivers)")
    ap.add_argument("--dry-run", action="store_true", help="measure and report, write nothing")
    args = ap.parse_args(argv)
    # The Windows console defaults to cp1252 and would choke on the em-dashes below.
    for stream in (sys.stdout, sys.stderr):
        if hasattr(stream, "reconfigure"):
            stream.reconfigure(errors="replace")

    img = Image.open(args.source)
    img = img.convert("RGB")
    w, h = img.size
    if w != 2 * h or w < 4096:
        print("starmap_prepare: expected a 2:1 image at least 4096 wide, got %dx%d" % (w, h), file=sys.stderr)
        return 1

    blank_regions(img, args.blank_rows, args.blank_box)
    img = black_floor(img, args.floor)
    img = apply_gamma(img, args.gamma)
    lum = img.convert("L")

    top_max = lum.crop((0, 0, w, 1)).getextrema()[1]
    bot_max = lum.crop((0, h - 1, w, h)).getextrema()[1]

    results = register(lum, w, h, args.search_px, args.min_peak, args.max_residual_px)
    passing = [r for r in results if r["passes"]]
    passing.sort(key=lambda r: r["median"])

    print("registration hypotheses (image %dx%d, floor %d, search +-%d px):" % (w, h, args.floor, args.search_px))
    print("  %-6s %-9s %-10s %-8s %5s %8s %8s  %s" % ("RAdir", "north_up", "RA@u0", "anchor", "found", "median", "max", "verdict"))
    for r in results:
        print("  %-6s %-9s %-10s %-8s %5d %8s %8s  %s" % (
            "left" if r["ra_dir"] < 0 else "right", str(r["north_up"]),
            "nan" if math.isnan(r["ra_deg_at_u0"]) else "%.3f" % r["ra_deg_at_u0"],
            r["anchor"] or "-", r["found"],
            "inf" if math.isinf(r["median"]) else "%.2f" % r["median"],
            "inf" if math.isinf(r["max"]) else "%.2f" % r["max"],
            "PASS" if r["passes"] else "fail"))

    if not passing:
        print("starmap_prepare: no hypothesis passed — nothing written. Is this an EQUATORIAL plate-carrée "
              "export at J2000 with the GUI hidden? Try --search-px 96 or --min-peak 25.", file=sys.stderr)
        return 2
    if len(passing) > 1 and abs(passing[0]["median"] - passing[1]["median"]) < 1.0:
        print("starmap_prepare: ambiguous — two hypotheses pass within 1 px of each other; nothing written.",
              file=sys.stderr)
        return 2
    win = passing[0]

    print("winner: RA increases %s, north %s, RA at u=0 = %.3f deg, %d/10 stars, median %.2f px, max %.2f px" % (
        "LEFTWARD" if win["ra_dir"] < 0 else "RIGHTWARD", "UP" if win["north_up"] else "DOWN",
        win["ra_deg_at_u0"], win["found"], win["median"], win["max"]))
    print("  %-11s %9s %9s   %9s %9s   %s" % ("star", "pred x", "pred y", "found x", "found y", "residual"))
    per_star = {}
    for r in win["rows"]:
        if r["found"] is None:
            print("  %-11s %9.1f %9.1f   %9s %9s   not found" % (r["star"], r["pred"][0], r["pred"][1], "-", "-"))
            per_star[r["star"]] = {"pred": [round(r["pred"][0], 2), round(r["pred"][1], 2)], "found": None, "residual_px": None}
        else:
            print("  %-11s %9.1f %9.1f   %9.1f %9.1f   %.2f px" % (
                r["star"], r["pred"][0], r["pred"][1], r["found"][0], r["found"][1], r["residual_px"]))
            per_star[r["star"]] = {"pred": [round(r["pred"][0], 2), round(r["pred"][1], 2)],
                                   "found": [round(r["found"][0], 2), round(r["found"][1], 2)],
                                   "residual_px": round(r["residual_px"], 3)}

    # Pole-footprint correction (see pole_footprint_dilate): measured from the
    # anchor star's own disc so no magic number is baked in.
    pole = {"applied": False}
    if not args.no_pole_dilate:
        anchor_row = next((r for r in win["rows"] if r["star"] == win["anchor"] and r["found"]), None)
        if anchor_row is not None:
            disc = disc_radius_px(lum, lum.load(), w, h, anchor_row["found"][0], anchor_row["found"][1], args.search_px)
            if disc >= 1.0:
                img, bands = pole_footprint_dilate(img, disc, win["north_up"])
                lum = img.convert("L")
                top_max = lum.crop((0, 0, w, 1)).getextrema()[1]
                bot_max = lum.crop((0, h - 1, w, h)).getextrema()[1]
                pole = {"applied": True, "disc_px": round(disc, 2), "bands": bands}
                print("pole footprint: anchor disc radius %.2f px -> dilation up to %d px at |dec| >= %.0f" % (
                    disc, bands[-1][2], POLE_BANDS[0]))

    if top_max > 0 or bot_max > 0:
        print("starmap_prepare: pole rows are not black after the floor (top max %d, bottom max %d) — "
              "use --blank-rows or a higher --floor; nothing written." % (top_max, bot_max), file=sys.stderr)
        return 2

    sidecar = {
        "schema": SCHEMA,
        "file": os.path.basename(args.out),
        "width": w, "height": h,
        "projection": "plate-carree", "frame": "equatorial", "epoch": "J2000",
        "north_up": bool(win["north_up"]),
        "ra_direction": int(win["ra_dir"]),
        "ra_deg_at_u0": round(win["ra_deg_at_u0"], 4),
        "registration": {
            "method": "bright-star blob fit (tools/starmap_prepare.py)",
            "anchor": win["anchor"],
            "stars_found": win["found"],
            "median_residual_px": round(win["median"], 3),
            "max_residual_px": round(win["max"], 3),
            "search_px": args.search_px,
            "per_star": per_star,
        },
        "source": {
            "file": os.path.basename(args.source),
            "note": args.note,
            "script": "tools/stellarium_starmap_export.ssc",
            "prepared_utc": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
        },
        "prepare": {
            "tool": "tools/starmap_prepare.py",
            "floor": args.floor, "gamma": args.gamma,
            "blank_rows": args.blank_rows,
            "blank_boxes": [list(b) for b in args.blank_box],
            "pole_footprint": pole,
        },
    }
    if args.dry_run:
        print("dry run — sidecar would be:")
        print(json.dumps(sidecar, indent=2))
        return 0

    out_dir = os.path.dirname(args.out)
    if out_dir:
        os.makedirs(out_dir, exist_ok=True)
    img.save(args.out, format="PNG", optimize=False, compress_level=6)
    json_path = os.path.splitext(args.out)[0] + ".json"
    with open(json_path, "w", encoding="utf-8") as f:
        json.dump(sidecar, f, indent=2)
        f.write("\n")
    print("wrote %s (%d bytes) and %s" % (args.out, os.path.getsize(args.out), json_path))
    return 0


if __name__ == "__main__":
    sys.exit(main())
