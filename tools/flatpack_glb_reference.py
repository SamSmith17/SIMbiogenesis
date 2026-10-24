"""Measure a slotted-plywood furniture GLB into a flat-pack reference fixture.

The flat-pack designer (core/flatpack/) is pinned against a real PlayaTech
design: a SketchUp model exported through SimLab, in inches, holding one flat
cut layout (a component whose children are the parts laid on the sheet) and
one or more assembled copies. This reads the GLB with the standard library
only and writes what the selftest compares against:

  - every part in the cut layout: its name, plan size, thickness and outline
    (the boundary of its top face, in the part's own frame);
  - the notches cut into each outline: which side, where along it, how deep;
  - the parts grouped by name with quantities;
  - each assembled copy's parts as world boxes (inches).

The GLB is NOT committed (it carries a third-party scale figure); the fixture
holds only measured numbers.

    python tools/flatpack_glb_reference.py "C:/path/Playa Tech.glb" \
        core/flatpack/testdata/playatech_daybed_ref.json
"""

import json
import struct
import sys

EPS = 1e-3


def load_glb(path):
    data = open(path, "rb").read()
    magic, _ver, _length = struct.unpack("<III", data[:12])
    if magic != 0x46546C67:
        raise SystemExit("not a GLB: %s" % path)
    clen, _ctype = struct.unpack("<II", data[12:20])
    doc = json.loads(data[20:20 + clen])
    bin_off = 20 + clen + 8
    return doc, data, bin_off


def accessor(doc, data, bin_off, idx, ncomp, fmt):
    a = doc["accessors"][idx]
    bv = doc["bufferViews"][a["bufferView"]]
    size = struct.calcsize("<" + fmt)
    stride = bv.get("byteStride", size * ncomp)
    off = bin_off + bv.get("byteOffset", 0) + a.get("byteOffset", 0)
    out = []
    for i in range(a["count"]):
        o = off + i * stride
        out.append(struct.unpack("<" + fmt * ncomp, data[o:o + size * ncomp]))
    return out


def mesh_tris(doc, data, bin_off, mi):
    prim = doc["meshes"][mi]["primitives"][0]
    pos = accessor(doc, data, bin_off, prim["attributes"]["POSITION"], 3, "f")
    if "indices" in prim:
        ia = doc["accessors"][prim["indices"]]
        fmt = {5121: "B", 5123: "H", 5125: "I"}[ia["componentType"]]
        idx = [v[0] for v in accessor(doc, data, bin_off, prim["indices"], 1, fmt)]
    else:
        idx = list(range(len(pos)))
    return pos, [idx[i:i + 3] for i in range(0, len(idx) - 2, 3)]


def qrot(q, p):
    x, y, z, w = q
    px, py, pz = p
    ix = w * px + y * pz - z * py
    iy = w * py + z * px - x * pz
    iz = w * pz + x * py - y * px
    iw = -x * px - y * py - z * pz
    return (ix * w - iw * x - iy * z + iz * y,
            iy * w - iw * y - iz * x + ix * z,
            iz * w - iw * z - ix * y + iy * x)


def top_outline(pos, tris):
    """The boundary loop of the face at max Z, as [(x, y), ...]."""
    zmax = max(p[2] for p in pos)
    key = lambda i: (round(pos[i][0], 4), round(pos[i][1], 4))
    count = {}
    for t in tris:
        if not all(abs(pos[i][2] - zmax) < EPS for i in t):
            continue
        ks = [key(i) for i in t]
        for a, b in ((ks[0], ks[1]), (ks[1], ks[2]), (ks[2], ks[0])):
            if a == b:
                continue
            e = (a, b) if a < b else (b, a)
            count[e] = count.get(e, 0) + 1
    edges = [e for e, n in count.items() if n == 1]
    adj = {}
    for a, b in edges:
        adj.setdefault(a, []).append(b)
        adj.setdefault(b, []).append(a)
    if not adj:
        return []
    start = min(adj)
    loop = [start]
    prev, cur = None, start
    while True:
        nxt = [n for n in adj[cur] if n != prev]
        if not nxt:
            break
        prev, cur = cur, nxt[0]
        if cur == start:
            break
        loop.append(cur)
        if len(loop) > len(adj) + 2:
            break
    # Drop collinear points.
    out = []
    n = len(loop)
    for i in range(n):
        a, b, c = loop[i - 1], loop[i], loop[(i + 1) % n]
        cross = (b[0] - a[0]) * (c[1] - b[1]) - (b[1] - a[1]) * (c[0] - b[0])
        if abs(cross) > 1e-6:
            out.append(b)
    return out


def notches(outline, w, h):
    """Runs of the outline that leave a side of the bounding box and come back
    to the SAME side: the slots and arches. Corner fillets leave one side and
    come back to another, so they are not counted."""
    def side(p):
        if abs(p[1]) < EPS:
            return "bottom"
        if abs(p[1] - h) < EPS:
            return "top"
        if abs(p[0]) < EPS:
            return "left"
        if abs(p[0] - w) < EPS:
            return "right"
        return None

    n = len(outline)
    sides = [side(p) for p in outline]
    found = []
    for i in range(n):
        if sides[i] is None or sides[(i + 1) % n] is not None:
            continue
        j = (i + 1) % n
        run = []
        while sides[j] is None and len(run) < n:
            run.append(outline[j])
            j = (j + 1) % n
        if sides[j] != sides[i]:
            continue
        s = sides[i]
        a, b = outline[i], outline[j]
        along = 0 if s in ("bottom", "top") else 1
        lo, hi = sorted((a[along], b[along]))
        if s == "bottom":
            depth = max(p[1] for p in run)
        elif s == "top":
            depth = h - min(p[1] for p in run)
        elif s == "left":
            depth = max(p[0] for p in run)
        else:
            depth = w - min(p[0] for p in run)
        found.append({"side": s, "from": round(lo, 3), "to": round(hi, 3),
                      "width": round(hi - lo, 3), "depth": round(depth, 3),
                      "rect": len(run) == 2})
    found.sort(key=lambda d: (d["side"], d["from"]))
    return found


def main():
    if len(sys.argv) < 3:
        raise SystemExit(__doc__)
    doc, data, bin_off = load_glb(sys.argv[1])
    nodes = doc["nodes"]

    def mesh_of(ni):
        n = nodes[ni]
        if "mesh" in n:
            return n["mesh"]
        for c in n.get("children", []):
            if "mesh" in nodes[c]:
                return nodes[c]["mesh"]
        return None

    # The cut layout: the node whose children are named parts lying flat.
    layout = None
    for i, n in enumerate(nodes):
        if str(n.get("name", "")).startswith("Component") and len(n.get("children", [])) > 4:
            layout = i
            break
    if layout is None:
        raise SystemExit("no cut-layout component found")

    parts = []
    groups = {}
    for c in nodes[layout]["children"]:
        name = str(nodes[c].get("name", "")).strip()
        mi = mesh_of(c)
        if mi is None or not name or name.startswith("Geom3D"):
            continue
        pos, tris = mesh_tris(doc, data, bin_off, mi)
        xs = [p[0] for p in pos]
        ys = [p[1] for p in pos]
        zs = [p[2] for p in pos]
        w, h, t = max(xs) - min(xs), max(ys) - min(ys), max(zs) - min(zs)
        outline = [(round(x - min(xs), 3), round(y - min(ys), 3)) for x, y in top_outline(pos, tris)]
        base = name.rstrip("_0123456789 ").strip()
        groups[base] = groups.get(base, 0) + 1
        parts.append({"name": name, "group": base, "w": round(w, 3), "h": round(h, 3),
                      "t": round(t, 3), "outline": outline,
                      "notches": notches(outline, w, h)})

    # Assembled copies: nameless groups of named parts beside the layout.
    assemblies = []
    for c in nodes[layout]["children"]:
        n = nodes[c]
        if n.get("name") or len(n.get("children", [])) == 0:
            continue
        for g in n["children"]:
            boxes = []
            for pc in nodes[g].get("children", []):
                pn = nodes[pc]
                mi = mesh_of(pc)
                if mi is None:
                    continue
                pos, _tris = mesh_tris(doc, data, bin_off, mi)
                t = pn.get("translation", [0, 0, 0])
                q = pn.get("rotation", [0, 0, 0, 1])
                pts = [qrot(q, p) for p in pos]
                mn = [round(min(p[k] for p in pts) + t[k], 2) for k in range(3)]
                mx = [round(max(p[k] for p in pts) + t[k], 2) for k in range(3)]
                boxes.append({"name": str(pn.get("name", "")).strip(), "min": mn, "max": mx})
            if boxes:
                assemblies.append(boxes)

    area = sum(p["w"] * p["h"] for p in parts)
    out = {
        "source": sys.argv[1].replace("\\", "/").split("/")[-1],
        "units": "in",
        "thickness": parts[0]["t"] if parts else 0.0,
        "part_count": len(parts),
        "groups": groups,
        "total_area_in2": round(area, 2),
        "sheets_4x8_at_zero_kerf": round(area / (48.0 * 96.0), 3),
        "parts": parts,
        "assemblies": assemblies,
    }
    with open(sys.argv[2], "w", encoding="utf-8", newline="\n") as f:
        json.dump(out, f, indent=1)
        f.write("\n")
    print("wrote %s: %d parts, %d assemblies, %.2f sheets of 4x8"
          % (sys.argv[2], len(parts), len(assemblies), out["sheets_4x8_at_zero_kerf"]))


if __name__ == "__main__":
    main()
