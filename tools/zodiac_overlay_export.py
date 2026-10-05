"""Build the zodiac constellation overlay for the SIMbiogenesis sky.

Output: assets/sky/zodiac_overlay_8k.png (+ .json sidecar), an 8192x4096
plate-carree RGB mask in EXACTLY the registration of the star map
(assets/sky/starmap_equirect_8k.json), so the sky shader can sample both with
one UV:
    R = stick figures of the 12 classical zodiac constellations
    G = their Latin names
    B = Ophiuchus, lines + name (the ecliptic crosses it too; the 13th)
The J2000 ecliptic is NOT baked in: it is one great circle, cheaper and
sharper computed in the shader.

Why this is data-driven rather than a Stellarium screenshot: Stellarium's
"isolate selected" constellation filter did not accumulate a multi-selection
from a script (26.2 drew one constellation, then all 88), and its labels use
common English names ("Lion"). So Stellarium supplies the DATA instead:
  * the stick figures come from its own "modern" sky culture
    (skycultures/modern/index.json: HIP polylines + IAU Latin names;
    CC BY-SA 4.0 — so this overlay is share-alike, see CREDITS.md);
  * every line star's J2000 position comes from a Stellarium run
    (core.getObjectInfo, dated 2000-01-01 12:00 UTC like the star map);
and we rasterise with the sidecar's own mapping. Registration is therefore
exact by construction, and the tool still PROVES it: each bright line star
must sit on a star blob in the star map image, or nothing is written.

Lines are drawn as great-circle arcs (curved in plate carree), stopped short
of each star so the star stays visible, with a width constant ON THE SKY
(the brush widens horizontally by 1/cos(dec)); labels are widened the same
way so they read at their true shape once the shader wraps them onto the
sphere. Everything is rendered at 2x and box-filtered down.

Pillow only (no numpy on the author's machine).

Usage:
    python tools/zodiac_overlay_export.py [--stellarium "C:/Program Files/Stellarium"]
        [--dump <cached positions json>]   # skip the Stellarium run
"""

import argparse
import json
import math
import os
import shutil
import subprocess
import sys
import tempfile

from PIL import Image, ImageChops, ImageDraw, ImageFont, ImageStat

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SKY = os.path.join(REPO, "assets", "sky")
STAR_MAP = os.path.join(SKY, "starmap_equirect_8k.png")
STAR_SIDECAR = os.path.join(SKY, "starmap_equirect_8k.json")
OUT_PNG = os.path.join(SKY, "zodiac_overlay_8k.png")
OUT_JSON = os.path.join(SKY, "zodiac_overlay_8k.json")

ZODIAC12 = ["Ari", "Tau", "Gem", "Cnc", "Leo", "Vir", "Lib", "Sco", "Sgr", "Cap", "Aqr", "Psc"]
OPHIUCHUS = "Oph"

LINE_WIDTH_DEG = 0.12      # full width on the sky
STAR_GAP_DEG = 0.30        # lines stop this far short of each star
LABEL_HEIGHT_DEG = 1.5     # cap-to-baseline-ish height of a label on the sky
LABEL_DROP_DEG = 2.2       # preferred label spot: this far south of the centroid
LABEL_MARGIN_DEG = 0.5     # clear space kept between a label and any line
SS = 2                     # supersampling factor
VERIFY_MAG = 3.0           # line stars at least this bright must sit on a blob
VERIFY_MAX_PX = 2.0


# ---------------------------------------------------------------- mapping

class Registration:
    """The star map's measured plate-carree registration (its sidecar)."""

    def __init__(self, sidecar, width, height):
        self.ra0 = float(sidecar["ra_deg_at_u0"])
        self.ra_dir = int(sidecar["ra_direction"])
        self.north_up = bool(sidecar["north_up"])
        self.w = width
        self.h = height

    def uv(self, ra, dec):
        u = ((ra - self.ra0) * self.ra_dir / 360.0) % 1.0
        v = (90.0 - dec) / 180.0 if self.north_up else (dec + 90.0) / 180.0
        return u, v

    def radec(self, x, y, scale=1):
        u, v = x / (self.w * scale), y / (self.h * scale)
        ra = (self.ra0 + u * 360.0 / self.ra_dir) % 360.0
        dec = 90.0 - v * 180.0 if self.north_up else v * 180.0 - 90.0
        return ra, dec

    def px(self, ra, dec, scale=1):
        u, v = self.uv(ra, dec)
        return u * self.w * scale, v * self.h * scale


def to_vec(ra, dec):
    a, d = math.radians(ra), math.radians(dec)
    return (math.cos(d) * math.cos(a), math.cos(d) * math.sin(a), math.sin(d))


def to_radec(v):
    x, y, z = v
    n = math.sqrt(x * x + y * y + z * z)
    return math.degrees(math.atan2(y, x)) % 360.0, math.degrees(math.asin(max(-1.0, min(1.0, z / n))))


def slerp(a, b, t):
    dot = max(-1.0, min(1.0, sum(p * q for p, q in zip(a, b))))
    om = math.acos(dot)
    if om < 1e-9:
        return a
    s = math.sin(om)
    fa, fb = math.sin((1 - t) * om) / s, math.sin(t * om) / s
    return tuple(fa * p + fb * q for p, q in zip(a, b))


# ---------------------------------------------------------------- data

def load_culture(stel_dir):
    path = os.path.join(stel_dir, "skycultures", "modern", "index.json")
    with open(path, encoding="utf-8") as f:
        d = json.load(f)
    out = {}
    for c in d["constellations"]:
        abbr = c["id"].split()[-1]
        if abbr in ZODIAC12 or abbr == OPHIUCHUS:
            out[abbr] = {
                "name": c["common_name"].get("native") or c["common_name"]["english"],
                "lines": c["lines"],
            }
    missing = [a for a in ZODIAC12 + [OPHIUCHUS] if a not in out]
    if missing:
        sys.exit("sky culture lacks: %s" % missing)
    return out


def dump_positions(stel_dir, hips):
    """Ask Stellarium for each star's J2000 RA/Dec (and V mag)."""
    work = tempfile.mkdtemp(prefix="stel_zodiac_")
    user = os.path.join(work, "user")
    os.makedirs(user)
    # A copy of the player's config: a minimal hand-written one crashed 26.2 at
    # startup (memory/star-field-realism). Their real config is never touched.
    appdata_cfg = os.path.join(os.environ.get("APPDATA", ""), "Stellarium", "config.ini")
    if os.path.isfile(appdata_cfg):
        shutil.copy(appdata_cfg, os.path.join(user, "config.ini"))
    script = os.path.join(work, "dump.ssc")
    ids = ",".join(str(h) for h in sorted(hips))
    with open(script, "w", encoding="utf-8") as f:
        f.write(
            'core.setGuiVisible(false);\n'
            'core.setTimeRate(0);\n'
            'core.setDate("2000-01-01T12:00:00", "utc");\n'
            'var ids = [%s];\n'
            'var s = "";\n'
            'for (var i = 0; i < ids.length; i++) {\n'
            '  var m = core.getObjectInfo("HIP " + ids[i]);\n'
            '  s += "STAR," + ids[i] + "," + m["found"] + "," + m["raJ2000"] + "," + m["decJ2000"] + "," + m["vmag"] + "\\n";\n'
            '}\n'
            'core.output(s);\n'
            'core.quitStellarium();\n' % ids)
    exe = os.path.join(stel_dir, "stellarium.exe")
    print("running Stellarium for %d star positions ..." % len(hips))
    subprocess.run([exe, "--user-dir", user, "--startup-script", script, "--fullscreen", "no"],
                   cwd=stel_dir, timeout=300, check=False,
                   stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    pos = {}
    with open(os.path.join(user, "output.txt"), encoding="utf-8") as f:
        for line in f:
            p = line.strip().split(",")
            if len(p) == 6 and p[0] == "STAR":
                if p[2] != "true":
                    sys.exit("Stellarium could not find HIP %s" % p[1])
                pos[int(p[1])] = {"ra": float(p[3]), "dec": float(p[4]), "vmag": float(p[5])}
    shutil.rmtree(work, ignore_errors=True)
    missing = sorted(set(hips) - set(pos))
    if missing:
        sys.exit("no position returned for HIP %s" % missing)
    return pos


# ---------------------------------------------------------------- drawing

def stamp(draw, reg, ra, dec, half_w_deg):
    """Ellipse brush whose footprint is a circle ON THE SKY."""
    x, y = reg.px(ra, dec, SS)
    ry = half_w_deg / 180.0 * reg.h * SS
    rx = ry / max(0.05, math.cos(math.radians(dec)))
    wrap = reg.w * SS
    for dx in (0.0, -wrap, wrap):
        cx = x + dx
        if cx + rx < 0 or cx - rx > wrap:
            continue
        draw.ellipse((cx - rx, y - ry, cx + rx, y + ry), fill=255)


def draw_lines(draw, reg, lines, pos):
    total_deg = 0.0
    step_deg = 0.35 / (reg.h * SS / 180.0)  # ~0.35 supersampled px between stamps
    for poly in lines:
        for a, b in zip(poly[:-1], poly[1:]):
            va = to_vec(pos[a]["ra"], pos[a]["dec"])
            vb = to_vec(pos[b]["ra"], pos[b]["dec"])
            arc = math.degrees(math.acos(max(-1.0, min(1.0, sum(p * q for p, q in zip(va, vb))))))
            if arc <= 2 * STAR_GAP_DEG:
                continue
            total_deg += arc
            t0, t1 = STAR_GAP_DEG / arc, 1.0 - STAR_GAP_DEG / arc
            n = max(2, int(math.ceil(arc * (t1 - t0) / step_deg)))
            for i in range(n + 1):
                ra, dec = to_radec(slerp(va, vb, t0 + (t1 - t0) * i / n))
                stamp(draw, reg, ra, dec, LINE_WIDTH_DEG / 2.0)
    return total_deg


def label_anchor(lines, pos):
    """Normalised mean of the figure's stars, dropped a little to the south
    (draw_label then slides it to the nearest spot clear of any line)."""
    hs = {h for poly in lines for h in poly}
    sx = sy = sz = 0.0
    for h in hs:
        x, y, z = to_vec(pos[h]["ra"], pos[h]["dec"])
        sx, sy, sz = sx + x, sy + y, sz + z
    ra, dec = to_radec((sx, sy, sz))
    return ra, dec - LABEL_DROP_DEG


def draw_label(canvas, reg, text, ra, dec, font_path, avoid=None):
    px_per_deg = reg.h * SS / 180.0
    size = max(8, int(round(LABEL_HEIGHT_DEG * px_per_deg / 0.72)))
    font = ImageFont.truetype(font_path, size)
    l, t, r, b = font.getbbox(text)
    tw, th = r - l + 4, b - t + 4
    glyphs = Image.new("L", (tw, th), 0)
    ImageDraw.Draw(glyphs).text((2 - l, 2 - t), text, fill=255, font=font)
    # Widen by 1/cos(dec): the shader wraps each image row around a circle of
    # radius cos(dec), so this is what makes the letters their true shape.
    stretch = 1.0 / max(0.05, math.cos(math.radians(dec)))
    glyphs = glyphs.resize((max(1, int(round(tw * stretch))), th), Image.LANCZOS)
    x, y = reg.px(ra, dec, SS)
    if avoid is not None:
        x, y = _clear_spot(avoid, reg, x, y, glyphs.size, dec)
    ox, oy = int(round(x - glyphs.width / 2)), int(round(y - glyphs.height / 2))
    wrap = reg.w * SS
    for dx in (0, -wrap, wrap):
        if ox + dx + glyphs.width < 0 or ox + dx > wrap:
            continue
        canvas.paste(255, (ox + dx, oy), glyphs)
    return reg.radec(x, y, SS)


def _clear_spot(avoid, reg, x, y, size, dec):
    """Nearest spot to (x, y) where the label box (+ margin) covers the least
    line ink: a centroid often lands ON the figure (Cancer, Gemini)."""
    px_per_deg = reg.h * SS / 180.0
    xs = px_per_deg / max(0.05, math.cos(math.radians(dec)))   # px per sky-degree E-W
    m = LABEL_MARGIN_DEG * px_per_deg
    w, h = size[0] + 2 * m * xs / px_per_deg, size[1] + 2 * m
    best = None
    for ddec in [i * 0.5 for i in range(-8, 13)]:          # -4 .. +6 deg (south +)
        for dra in [i * 0.75 for i in range(-8, 9)]:       # -6 .. +6 deg
            cx, cy = x + dra * xs, y + ddec * px_per_deg
            box = (int(cx - w / 2), int(cy - h / 2), int(cx + w / 2), int(cy + h / 2))
            ink = ImageStat.Stat(avoid.crop(box)).sum[0]
            score = ink * 1000.0 + dra * dra + ddec * ddec
            if best is None or score < best[0]:
                best = (score, cx, cy)
    return best[1], best[2]


# ---------------------------------------------------------------- verify

def verify_on_star_map(reg, pos, hips):
    """Every bright line star must sit on a star blob in the shipped map."""
    img = Image.open(STAR_MAP).convert("L")
    w, h = img.size
    worst, rows = 0.0, []
    for hip in sorted(hips):
        p = pos[hip]
        if p["vmag"] > VERIFY_MAG:
            continue
        x, y = reg.px(p["ra"], p["dec"])
        r = 6
        box = img.crop((int(x) - r, int(y) - r, int(x) + r + 1, int(y) + r + 1))
        peak = box.getextrema()[1]
        if peak < 64:
            sys.exit("HIP %d (V %.1f) has no star in the map near (%.1f, %.1f)" % (hip, p["vmag"], x, y))
        # Centroid of the pixels near the peak = the blob centre (Stellarium
        # saturates cores, so the argmax alone ties across the disc).
        sx = sy = sw = 0.0
        for j in range(box.height):
            for i in range(box.width):
                v = box.getpixel((i, j))
                if v >= peak * 0.6:
                    sx += (i + int(x) - r) * v
                    sy += (j + int(y) - r) * v
                    sw += v
        cx, cy = sx / sw + 0.5, sy / sw + 0.5  # pixel centres
        d = math.hypot(cx - x, cy - y)
        worst = max(worst, d)
        rows.append((hip, p["vmag"], round(d, 2)))
    if worst > VERIFY_MAX_PX:
        sys.exit("registration check FAILED: worst %.2f px > %.1f\n%s" % (worst, VERIFY_MAX_PX, rows))
    return worst, len(rows)


# ---------------------------------------------------------------- main

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--stellarium", default=r"C:\Program Files\Stellarium")
    ap.add_argument("--dump", help="cached star positions JSON (skips the Stellarium run)")
    args = ap.parse_args()

    culture = load_culture(args.stellarium)
    hips = {h for c in culture.values() for poly in c["lines"] for h in poly}
    if args.dump and os.path.isfile(args.dump):
        with open(args.dump, encoding="utf-8") as f:
            pos = {int(k): v for k, v in json.load(f).items()}
    else:
        pos = dump_positions(args.stellarium, hips)
        if args.dump:
            with open(args.dump, "w", encoding="utf-8") as f:
                json.dump(pos, f)

    with open(STAR_SIDECAR, encoding="utf-8") as f:
        sidecar = json.load(f)
    reg = Registration(sidecar, int(sidecar["width"]), int(sidecar["height"]))
    worst, n_checked = verify_on_star_map(reg, pos, hips)
    print("registration vs star map: %d bright line stars, worst %.2f px" % (n_checked, worst))

    font_path = os.path.join(args.stellarium, "data", "NotoSans-Regular.ttf")
    size = (reg.w * SS, reg.h * SS)
    layers, anchors, arc_deg = [], {}, {}

    lines12 = Image.new("L", size, 0)
    d = ImageDraw.Draw(lines12)
    for a in ZODIAC12:
        arc_deg[a] = round(draw_lines(d, reg, culture[a]["lines"], pos), 2)
    layers.append(lines12)

    labels12 = Image.new("L", size, 0)
    for a in ZODIAC12:
        ra, dec = label_anchor(culture[a]["lines"], pos)
        ra, dec = draw_label(labels12, reg, culture[a]["name"], ra, dec, font_path, avoid=lines12)
        anchors[a] = {"name": culture[a]["name"], "ra": round(ra, 4), "dec": round(dec, 4)}
    layers.append(labels12)

    oph = Image.new("L", size, 0)
    arc_deg[OPHIUCHUS] = round(draw_lines(ImageDraw.Draw(oph), reg, culture[OPHIUCHUS]["lines"], pos), 2)
    ra, dec = label_anchor(culture[OPHIUCHUS]["lines"], pos)
    ra, dec = draw_label(oph, reg, culture[OPHIUCHUS]["name"], ra, dec, font_path,
                         avoid=ImageChops.lighter(oph, lines12))
    anchors[OPHIUCHUS] = {"name": culture[OPHIUCHUS]["name"], "ra": round(ra, 4), "dec": round(dec, 4)}
    layers.append(oph)

    out = Image.merge("RGB", [im.resize((reg.w, reg.h), Image.BOX) for im in layers])
    out.save(OUT_PNG, optimize=True)

    meta = {
        "schema": 1,
        "file": os.path.basename(OUT_PNG),
        "width": reg.w,
        "height": reg.h,
        "projection": "plate-carree",
        "frame": "equatorial",
        "epoch": "J2000",
        "north_up": reg.north_up,
        "ra_direction": reg.ra_dir,
        "ra_deg_at_u0": reg.ra0,
        "registration_from": os.path.basename(STAR_SIDECAR),
        "channels": {
            "r": "zodiac-12 stick figures",
            "g": "zodiac-12 names",
            "b": "Ophiuchus stick figure + name",
        },
        "line_width_deg": LINE_WIDTH_DEG,
        "star_gap_deg": STAR_GAP_DEG,
        "label_height_deg": LABEL_HEIGHT_DEG,
        "verification": {
            "bright_line_stars_checked": n_checked,
            "vmag_limit": VERIFY_MAG,
            "worst_offset_px_vs_star_map": round(worst, 3),
        },
        "sources": {
            "figures": "Stellarium sky culture 'modern' (index.json), CC BY-SA 4.0",
            "positions": "Stellarium core.getObjectInfo, J2000 at 2000-01-01T12:00Z",
            "font": "Noto Sans Regular (SIL OFL 1.1), as bundled with Stellarium",
        },
        "arc_length_deg": arc_deg,
        "labels": anchors,
    }
    with open(OUT_JSON, "w", encoding="utf-8") as f:
        json.dump(meta, f, indent=2)
    print("wrote %s (+ .json)" % os.path.relpath(OUT_PNG, REPO))


if __name__ == "__main__":
    main()
