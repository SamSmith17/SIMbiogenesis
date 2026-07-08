#!/usr/bin/env python3
"""Generate tileable facade textures for SIMbiogenesis hero buildings via the
Google Gemini API (Imagen), writing PNGs straight into the game's facade folder
(user://maps/facade_textures/ -> %APPDATA%/Godot/app_userdata/SIMbiogenesis/maps/facade_textures).

Usage:
    set GEMINI_API_KEY=...          (never commit the key)
    python tools/generate_facades.py [prompts_file] [--out DIR] [--model MODEL]

The prompts file (default tools/facade_prompts.txt) has one texture per line:
    <output_name>|<prompt text>
Lines starting with # are skipped. Each output is a 1024px-class PNG named
<output_name>.png. After download the script scores horizontal tileability
(mean absolute difference between the left and right edge columns, 0-255) and
prints a warning above WARN_EDGE_DIFF — regenerate or hand-crop those.

Workflow: pick a building in the Building Builder's Reference tab (real
Mapillary photos), describe its facade in a prompt line here, run the script,
then assign the texture in the modal's "Facade tex" dropdown (Tile W/H set the
real-world metres one tile covers). Photos are reference only — the generated
textures are original synthetic images, so no imagery-licence issues.

No third-party deps (urllib + base64 + struct only). Requires Python 3.9+.
"""

from __future__ import annotations

import base64
import json
import os
import struct
import sys
import urllib.error
import urllib.request
import zlib
from pathlib import Path

DEFAULT_MODEL = "imagen-4.0-generate-001"
ENDPOINT = "https://generativelanguage.googleapis.com/v1beta/models/{model}:predict"
WARN_EDGE_DIFF = 26.0  # 0-255 mean abs diff between left/right edges

STYLE_SUFFIX = (
    ", seamless horizontally tileable texture, flat orthographic front view, "
    "even overcast lighting, no shadows of other objects, no people, no text, "
    "photorealistic, high detail"
)


def default_out_dir() -> Path:
    appdata = os.environ.get("APPDATA", "")
    if appdata:
        p = Path(appdata) / "Godot" / "app_userdata" / "SIMbiogenesis" / "maps" / "facade_textures"
    else:
        p = Path.home() / "facade_textures"
    p.mkdir(parents=True, exist_ok=True)
    return p


def generate(prompt: str, model: str, api_key: str) -> bytes:
    """One Imagen predict call -> PNG/JPEG bytes."""
    body = json.dumps({
        "instances": [{"prompt": prompt + STYLE_SUFFIX}],
        "parameters": {"sampleCount": 1, "aspectRatio": "4:3",
                       "personGeneration": "dont_allow"},
    }).encode("utf-8")
    req = urllib.request.Request(
        ENDPOINT.format(model=model),
        data=body,
        headers={"Content-Type": "application/json", "x-goog-api-key": api_key},
        method="POST",
    )
    try:
        with urllib.request.urlopen(req, timeout=120) as resp:
            payload = json.loads(resp.read().decode("utf-8"))
    except urllib.error.HTTPError as exc:
        detail = exc.read().decode("utf-8", errors="replace")
        raise RuntimeError(f"HTTP {exc.code}: {detail[:600]}") from None
    preds = payload.get("predictions") or []
    if not preds or "bytesBase64Encoded" not in preds[0]:
        raise RuntimeError(f"unexpected response: {json.dumps(payload)[:400]}")
    return base64.b64decode(preds[0]["bytesBase64Encoded"])


# --- minimal PNG decode (RGB/RGBA, 8-bit, non-interlaced) for the edge check ---

def _png_edges(data: bytes):
    """Return (left_column, right_column) as lists of (r,g,b), or None if the
    file isn't a PNG we can cheaply parse (e.g. JPEG) — then the check is skipped."""
    if data[:8] != b"\x89PNG\r\n\x1a\n":
        return None
    pos, width, height, bit_depth, color_type, idat = 8, 0, 0, 0, 0, b""
    while pos < len(data):
        length, ctype = struct.unpack(">I4s", data[pos:pos + 8])
        chunk = data[pos + 8:pos + 8 + length]
        if ctype == b"IHDR":
            width, height, bit_depth, color_type = struct.unpack(">IIBB", chunk[:10])
            if bit_depth != 8 or color_type not in (2, 6):
                return None
        elif ctype == b"IDAT":
            idat += chunk
        elif ctype == b"IEND":
            break
        pos += 12 + length
    raw = zlib.decompress(idat)
    ch = 3 if color_type == 2 else 4
    stride = width * ch + 1
    left, right = [], []
    prev = bytearray(width * ch)
    for y in range(height):
        row = bytearray(raw[y * stride + 1:(y + 1) * stride])
        filt = raw[y * stride]
        # Undo PNG filters (0 none, 1 sub, 2 up, 3 avg, 4 paeth).
        for x in range(len(row)):
            a = row[x - ch] if x >= ch else 0
            b = prev[x]
            c = prev[x - ch] if x >= ch else 0
            if filt == 1:
                row[x] = (row[x] + a) & 0xFF
            elif filt == 2:
                row[x] = (row[x] + b) & 0xFF
            elif filt == 3:
                row[x] = (row[x] + (a + b) // 2) & 0xFF
            elif filt == 4:
                p = a + b - c
                pa, pb, pc = abs(p - a), abs(p - b), abs(p - c)
                pr = a if (pa <= pb and pa <= pc) else (b if pb <= pc else c)
                row[x] = (row[x] + pr) & 0xFF
        prev = row
        left.append(tuple(row[0:3]))
        right.append(tuple(row[(width - 1) * ch:(width - 1) * ch + 3]))
    return left, right


def edge_diff(data: bytes):
    edges = _png_edges(data)
    if edges is None:
        return None
    left, right = edges
    total = sum(abs(l[i] - r[i]) for l, r in zip(left, right) for i in range(3))
    return total / (len(left) * 3.0)


def main() -> int:
    api_key = os.environ.get("GEMINI_API_KEY", "").strip()
    if not api_key:
        print("ERROR: set GEMINI_API_KEY in the environment (do not commit it).")
        return 1

    args = sys.argv[1:]
    model = DEFAULT_MODEL
    out_dir = default_out_dir()
    prompts_file = Path(__file__).parent / "facade_prompts.txt"
    it = iter(range(len(args)))
    i = 0
    while i < len(args):
        if args[i] == "--out" and i + 1 < len(args):
            out_dir = Path(args[i + 1]); out_dir.mkdir(parents=True, exist_ok=True); i += 2
        elif args[i] == "--model" and i + 1 < len(args):
            model = args[i + 1]; i += 2
        else:
            prompts_file = Path(args[i]); i += 1

    if not prompts_file.exists():
        print(f"ERROR: prompts file not found: {prompts_file}")
        return 1

    lines = [ln.strip() for ln in prompts_file.read_text(encoding="utf-8").splitlines()]
    jobs = []
    for ln in lines:
        if not ln or ln.startswith("#") or "|" not in ln:
            continue
        name, prompt = ln.split("|", 1)
        jobs.append((name.strip(), prompt.strip()))
    if not jobs:
        print("No prompt lines found (format: name|prompt).")
        return 1

    print(f"Generating {len(jobs)} texture(s) with {model} -> {out_dir}")
    failures = 0
    for name, prompt in jobs:
        out_path = out_dir / f"{name}.png"
        if out_path.exists():
            print(f"  skip {name} (exists)")
            continue
        try:
            data = generate(prompt, model, api_key)
        except (urllib.error.URLError, RuntimeError) as exc:
            print(f"  FAIL {name}: {exc}")
            failures += 1
            continue
        out_path.write_bytes(data)
        diff = edge_diff(data)
        note = ""
        if diff is not None and diff > WARN_EDGE_DIFF:
            note = f"  << edge diff {diff:.0f} — poor tiling, consider regenerating"
        elif diff is not None:
            note = f"  (edge diff {diff:.0f}, tiles OK)"
        print(f"  wrote {out_path.name}{note}")
    print("Done." + (f" {failures} failure(s)." if failures else ""))
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
