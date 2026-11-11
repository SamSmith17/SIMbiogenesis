#!/usr/bin/env python3
"""SIMbiogenesis simulation server for AI tools (Model Context Protocol, stdio).

Lets any MCP client (Claude Desktop / Code, LM Studio, a local Ollama agent,
Open WebUI through mcpo, ...) design a site as data, run it for a year on the
game's own simulation WITHOUT rendering, read a compact report, compare runs,
and hand a design to the game for the player to review.

The AI never touches the game itself:
  * runs happen in a headless kernel (core/simkit/sim_kernel.tscn) started
    with a whitelisted environment and its OWN empty user folder (no worlds,
    no Home Assistant profile, no tokens);
  * every file this server reads or writes is inside one workspace folder,
    named by validated ids (no paths from the client);
  * a design is data checked against limits here and again in the kernel;
  * "submit" only drops a design into the game's inbox; the player opens it
    as an experiment fork and decides.

Standard library only (Python 3.9+). Run `python simbio_sim_mcp.py --help`.
Docs: docs/SIMKIT_MCP.md.
"""
from __future__ import annotations

import argparse
import copy
import hashlib
import json
import os
import re
import shutil
import subprocess
import sys
import threading
import time
from pathlib import Path

SERVER_NAME = "simbiogenesis-sim"
SERVER_VERSION = "1.0.0"
PROTOCOLS = ["2025-06-18", "2025-03-26", "2024-11-05"]
ID_RE = re.compile(r"^[A-Za-z0-9_-]{1,64}$")
NODE_ID_RE = re.compile(r"^[A-Za-z0-9_]{1,48}$")
MAX_DESIGN_BYTES = 600_000
MAX_RUNS_KEPT = 200
KERNEL_SCENE = "res://core/simkit/sim_kernel.tscn"
PROJECT_NAME = "SIMbiogenesis"

# Kept in step with core/simkit/simkit_guard.gd (the kernel checks again).
TOP_KEYS = {"name", "people", "start", "days", "step_min", "start_soc", "infinite_labor",
            "nodes", "solar", "dc", "ac", "wires", "spaces", "note", "description", "world", "base"}
NODE_KEYS = {"id", "preset", "count", "set", "state", "recipe", "recipe_file", "recipe_def",
             "automations", "pos", "sync_reset_level", "note"}
SUMMARY_PARTS = ["summary", "checks", "kpi", "stores", "machines", "monthly", "daily", "bottlenecks", "all"]


def log(*a):
    print("[simkit-mcp]", *a, file=sys.stderr, flush=True)


# --------------------------------------------------------------------------- config

def default_workspace() -> Path:
    if os.name == "nt":
        return Path(os.environ.get("LOCALAPPDATA", Path.home())) / "SIMbiogenesis_simkit"
    if sys.platform == "darwin":
        return Path.home() / "Library/Application Support/SIMbiogenesis_simkit"
    return Path(os.environ.get("XDG_DATA_HOME", Path.home() / ".local/share")) / "SIMbiogenesis_simkit"


def default_player_data() -> Path:
    if os.name == "nt":
        return Path(os.environ.get("APPDATA", Path.home())) / "Godot/app_userdata" / PROJECT_NAME
    if sys.platform == "darwin":
        return Path.home() / "Library/Application Support/Godot/app_userdata" / PROJECT_NAME
    return Path(os.environ.get("XDG_DATA_HOME", Path.home() / ".local/share")) / "godot/app_userdata" / PROJECT_NAME


def kernel_user_dir(root: Path) -> Path:
    """The Godot user:// folder the kernel sees, under its own APPDATA root."""
    if os.name == "nt":
        return root / "Godot/app_userdata" / PROJECT_NAME
    if sys.platform == "darwin":
        return root / "Library/Application Support/Godot/app_userdata" / PROJECT_NAME
    return root / "godot/app_userdata" / PROJECT_NAME


class Config:
    def __init__(self, args):
        self.godot = args.godot or os.environ.get("SIMBIO_GODOT", "")
        self.project = args.project or os.environ.get("SIMBIO_PROJECT", "")
        self.workspace = Path(args.workspace or os.environ.get("SIMBIO_WORKSPACE", "") or default_workspace())
        self.player_data = Path(args.player_data or os.environ.get("SIMBIO_PLAYER_DATA", "") or default_player_data())
        self.allow_download = bool(args.allow_download)
        self.share_place_names = bool(args.share_place_names)
        self.max_parallel = max(1, int(args.max_parallel))
        self.max_wall_s = max(60, int(args.max_wall_s))
        self.allow_submit = not args.no_submit
        if not self.project:
            here = Path(__file__).resolve()
            for up in [here.parent, *here.parents]:
                if (up / "project.godot").exists():
                    self.project = str(up)
                    break


# --------------------------------------------------------------------------- workspace

class Workspace:
    def __init__(self, cfg: Config):
        self.cfg = cfg
        self.root = cfg.workspace.resolve()
        for d in ["sites", "designs", "runs", "kernel_root"]:
            (self.root / d).mkdir(parents=True, exist_ok=True)

    def path(self, sub: str, ident: str, suffix: str = "") -> Path:
        if not ID_RE.match(ident or ""):
            raise ToolError(f"bad id '{str(ident)[:70]}': use letters, digits, - or _ (max 64)")
        p = (self.root / sub / (ident + suffix)).resolve()
        if os.path.commonpath([str(p), str(self.root)]) != str(self.root):
            raise ToolError("path escapes the workspace")
        return p

    # sites: the player's worlds, plus any added by hand (CLI add-site)
    def sites(self) -> dict:
        out = {}
        wroot = self.cfg.player_data / "worlds"
        if wroot.is_dir():
            for wd in sorted(wroot.iterdir()):
                wj = wd / "world.json"
                # "_"-prefixed worlds are the game's own (the multiplayer guest copy).
                if not wj.is_file() or not ID_RE.match(wd.name) or wd.name.startswith("_"):
                    continue
                try:
                    w = json.loads(wj.read_text(encoding="utf-8"))
                except Exception:
                    continue
                m = w.get("map", {}) if isinstance(w.get("map"), dict) else {}
                lat, lon = m.get("lat"), m.get("lon")
                if not isinstance(lat, (int, float)) or not isinstance(lon, (int, float)):
                    continue
                hz = False
                try:
                    snap = json.loads((wd / "snapshot.json").read_text(encoding="utf-8"))
                    hz = bool((snap.get("gameplay_rules") or {}).get("extreme_weather_enabled", False))
                except Exception:
                    pass
                out[wd.name] = {"id": wd.name, "lat": float(lat), "lon": float(lon),
                                "name": str(w.get("name", "")), "source": "world", "hazards": hz}
        for f in sorted((self.root / "sites").glob("*.json")):
            try:
                s = json.loads(f.read_text(encoding="utf-8"))
                if ID_RE.match(f.stem) and isinstance(s.get("lat"), (int, float)):
                    out[f.stem] = {"id": f.stem, "lat": float(s["lat"]), "lon": float(s["lon"]),
                                   "name": str(s.get("name", "")), "source": "manual"}
            except Exception:
                pass
        return out

    def public_site(self, s: dict) -> dict:
        d = {"id": s["id"], "lat_deg": round(s["lat"]), "source": s["source"],
             "hazards": bool(s.get("hazards", False))}
        d["name"] = s["name"] if self.cfg.share_place_names else ("world" if s["source"] == "world" else "site")
        return d

    def designs(self) -> dict:
        out = {}
        # Built-ins: the project's (source checkout) or the copy a release puts
        # beside this script (simkit_mcp/designs/).
        for builtin in [Path(self.cfg.project) / "core/simkit/designs" if self.cfg.project else None,
                        Path(__file__).resolve().parent / "designs"]:
            if builtin and builtin.is_dir():
                for f in sorted(builtin.glob("*.json")):
                    out.setdefault(f.stem, f)
        for f in sorted((self.root / "designs").glob("*.json")):
            if ID_RE.match(f.stem):
                out[f.stem] = f
        return out

    def load_design(self, ident: str) -> dict:
        ds = self.designs()
        if ident not in ds:
            raise ToolError(f"no design '{ident}' (list designs to see them)")
        return json.loads(ds[ident].read_text(encoding="utf-8"))


class ToolError(Exception):
    pass


# --------------------------------------------------------------------------- design checks

def check_design(d) -> list:
    if not isinstance(d, dict):
        return ["the design must be an object"]
    raw = json.dumps(d)
    if len(raw) > MAX_DESIGN_BYTES:
        return [f"the design is {len(raw)} bytes (limit {MAX_DESIGN_BYTES})"]
    out = [f"unknown top-level key '{k}'" for k in d if k not in TOP_KEYS and not str(k).startswith("_")]
    nodes = d.get("nodes", [])
    if not isinstance(nodes, list):
        return out + ["nodes must be a list"]
    if len(nodes) > 300:
        out.append(f"{len(nodes)} nodes (limit 300)")
    seen = set()
    for n in nodes:
        if not isinstance(n, dict):
            out.append("a node is not an object")
            continue
        nid = str(n.get("id", ""))
        if not NODE_ID_RE.match(nid):
            out.append(f"node id '{nid[:60]}' must be letters, digits or _")
        if nid in seen:
            out.append(f"node id '{nid}' used twice")
        seen.add(nid)
        out += [f"node {nid}: unknown key '{k}'" for k in n if k not in NODE_KEYS]
        if not str(n.get("preset", "")):
            out.append(f"node {nid}: no preset label")
        c = n.get("count", 1)
        if not isinstance(c, int) or not 1 <= c <= 60:
            out.append(f"node {nid}: count must be 1..60")
        if "set" in n and not isinstance(n["set"], dict):
            out.append(f"node {nid}: set must be an object")
        if "recipe_file" in n and not re.match(r"^[a-z0-9_]{1,48}$", str(n["recipe_file"])):
            out.append(f"node {nid}: recipe_file must be a bare name")
    for k in ["solar", "dc", "wires", "spaces"]:
        if k in d and not isinstance(d[k], list):
            out.append(f"{k} must be a list")
    days = d.get("days", 366)
    if not isinstance(days, (int, float)) or not 1 <= days <= 3660:
        out.append("days must be 1..3660")
    return out


def apply_patch(base: dict, patch: dict) -> dict:
    """A small edit language so a model can change a design without
    resending it. Keys (all optional):
      top:   {people: 12, days: 366, ...}            top-level fields
      set:   {node_id: {field: value}}               merged into node.set (null deletes)
      nodes: {node_id: {count: 3, preset: "...", state: "on", automations: [...]}}
      add:   [node, ...]                             new nodes
      remove: [node_id, ...]                         nodes (and their wires)
      wires_add: [[a, b, kind], ...]
      wires_remove: [[a, b], [a, b, kind], ...]
      solar: {pv_id: {series: 10, parallel: 2}}      merged into a solar entry
      ac_add: {controller: [node_id, ...]}
    """
    d = copy.deepcopy(base)
    if not isinstance(patch, dict):
        raise ToolError("patch must be an object")
    for k, v in (patch.get("top") or {}).items():
        if k in ("nodes", "wires", "solar", "dc", "ac", "spaces"):
            raise ToolError(f"use the patch's own key for '{k}'")
        d[k] = v
    nodes = d.setdefault("nodes", [])
    by_id = {str(n.get("id")): n for n in nodes if isinstance(n, dict)}
    for nid, fields in (patch.get("set") or {}).items():
        if nid not in by_id:
            raise ToolError(f"set: no node '{nid}'")
        st = by_id[nid].setdefault("set", {})
        for f, v in (fields or {}).items():
            if v is None:
                st.pop(f, None)
            else:
                st[f] = v
    for nid, fields in (patch.get("nodes") or {}).items():
        if nid not in by_id:
            raise ToolError(f"nodes: no node '{nid}'")
        for f, v in (fields or {}).items():
            if f == "id":
                continue
            if v is None:
                by_id[nid].pop(f, None)
            else:
                by_id[nid][f] = v
    for n in patch.get("add") or []:
        if not isinstance(n, dict) or str(n.get("id", "")) in by_id:
            raise ToolError(f"add: node '{n.get('id') if isinstance(n, dict) else n}' is missing an id or already exists")
        nodes.append(n)
        by_id[str(n["id"])] = n
    rm = set(str(x) for x in (patch.get("remove") or []))
    if rm:
        d["nodes"] = [n for n in nodes if str(n.get("id")) not in rm]
        d["wires"] = [w for w in d.get("wires", []) if not (set(map(str, w[:2])) & rm)]
        for c, lst in list((d.get("ac") or {}).items()):
            d["ac"][c] = [x for x in lst if x not in rm]
        d["dc"] = [p for p in d.get("dc", []) if not (set(map(str, p)) & rm)]
    for w in patch.get("wires_add") or []:
        if not (isinstance(w, list) and len(w) == 3):
            raise ToolError("wires_add entries are [from, to, kind]")
        d.setdefault("wires", []).append([str(w[0]), str(w[1]), str(w[2])])
    for w in patch.get("wires_remove") or []:
        if not (isinstance(w, list) and len(w) in (2, 3)):
            raise ToolError("wires_remove entries are [from, to] or [from, to, kind]")
        d["wires"] = [x for x in d.get("wires", [])
                      if not (x[0] == w[0] and x[1] == w[1] and (len(w) == 2 or x[2] == w[2]))]
    for sid, fields in (patch.get("solar") or {}).items():
        hit = [s for s in d.get("solar", []) if str(s.get("id")) == sid]
        if not hit:
            raise ToolError(f"solar: no array '{sid}'")
        hit[0].update(fields or {})
    for c, lst in (patch.get("ac_add") or {}).items():
        d.setdefault("ac", {}).setdefault(c, []).extend(lst)
    return d


def design_hash(d: dict) -> str:
    return hashlib.sha256(json.dumps(d, sort_keys=True).encode()).hexdigest()[:12]


def compact(obj) -> str:
    return json.dumps(obj, separators=(",", ":"), ensure_ascii=False)


# --------------------------------------------------------------------------- runs

class Runner:
    def __init__(self, cfg: Config, ws: Workspace):
        self.cfg = cfg
        self.ws = ws
        self.lock = threading.Lock()
        self.procs = {}       # run_id -> Popen
        self.queue = []       # run ids waiting

    def _kernel_env(self) -> dict:
        kroot = self.ws.root / "kernel_root"
        env = {}
        for k in ["PATH", "SYSTEMROOT", "WINDIR", "TEMP", "TMP", "COMSPEC", "NUMBER_OF_PROCESSORS",
                  "PROCESSOR_ARCHITECTURE", "LANG", "LC_ALL", "DISPLAY", "XDG_RUNTIME_DIR"]:
            if k in os.environ:
                env[k] = os.environ[k]
        # Godot's user:// lives under these; point all of them at the kernel's
        # own folder so the kernel cannot see the player's worlds or secrets.
        env["APPDATA"] = str(kroot)
        env["LOCALAPPDATA"] = str(kroot / "local")
        env["XDG_DATA_HOME"] = str(kroot)
        env["XDG_CONFIG_HOME"] = str(kroot / "config")
        env["XDG_CACHE_HOME"] = str(kroot / "cache")
        env["HOME"] = str(kroot) if sys.platform == "darwin" else os.environ.get("HOME", str(kroot))
        if os.name == "nt":
            env["USERPROFILE"] = str(kroot)
        return env

    def _seed_weather(self, lat: float, lon: float) -> int:
        """Copy the site's Open-Meteo archives from the player's cache (read
        only) into the kernel's. Returns how many files the kernel has."""
        src = self.cfg.player_data / "weather_cache"
        dst = kernel_user_dir(self.ws.root / "kernel_root") / "weather_cache"
        dst.mkdir(parents=True, exist_ok=True)
        tok = f"_{lat:.2f}_{lon:.2f}_"
        n = 0
        if src.is_dir():
            for f in src.glob(f"om_*{tok}*.json"):
                t = dst / f.name
                if not t.exists() or t.stat().st_size != f.stat().st_size:
                    shutil.copyfile(f, t)
        for _ in dst.glob(f"om_*{tok}*.json"):
            n += 1
        # What the hazard layers read (air quality, the NWS zone and its alert
        # history), at the 4-decimal key those services use.
        tok4 = f"_{lat:.4f}_{lon:.4f}"
        if src.is_dir():
            zones = []
            for f in list(src.glob(f"aq_*{tok4}.json")) + list(src.glob(f"nws_zone{tok4}.json"))                     + list(src.glob(f"climate_proj_*{tok}*.json")):
                shutil.copyfile(f, dst / f.name)
                if f.name.startswith("nws_zone"):
                    try:
                        z = json.loads(f.read_text(encoding="utf-8"))
                        zones += [str(z.get("ugc_zone", "")), str(z.get("county_zone", ""))]
                    except Exception:
                        pass
            for z in zones:
                if re.match(r"^[A-Z]{3}[0-9]{3}$", z):
                    for f in src.glob(f"alerts_*{z}.json"):
                        shutil.copyfile(f, dst / f.name)
        # Player settings the simulation reads (none hold a secret): the solar
        # model's numbers, connector losses, the extreme-weather choices.
        kuser = kernel_user_dir(self.ws.root / "kernel_root")
        for name in ["solar_panel_config.cfg", "sim_settings.cfg", "extreme_weather.cfg"]:
            f = self.cfg.player_data / name
            if f.is_file() and f.stat().st_size < 200_000:
                shutil.copyfile(f, kuser / name)
        return n

    def start(self, design_id: str, design: dict, site: dict, opts: dict) -> str:
        if not self.cfg.godot or not Path(self.cfg.godot).exists():
            raise ToolError("the server has no Godot / game binary configured (--godot)")
        base_id = time.strftime("r%Y%m%d_%H%M%S_") + design_hash(design)[:6]
        run_id = base_id
        k = 1
        while self.ws.path("runs", run_id).exists():
            k += 1
            run_id = f"{base_id}_{k}"
        rdir = self.ws.path("runs", run_id)
        rdir.mkdir(parents=True, exist_ok=False)
        n_wx = self._seed_weather(site["lat"], site["lon"])
        job = {"mode": opts.get("mode", "run"), "run_id": run_id, "design": design,
               "site": {"id": site["id"], "lat": site["lat"], "lon": site["lon"]},
               "days": float(opts.get("days", design.get("days", 366))),
               "step_min": float(opts.get("step_min", design.get("step_min", 6))),
               "people": opts.get("people", "agents"),
               "hazards": bool(opts.get("hazards", False)),
               "allow_download": self.cfg.allow_download,
               "max_wall_s": self.cfg.max_wall_s, "out_dir": rdir.as_posix()}
        if opts.get("start"):
            job["start"] = opts["start"]
        (rdir / "job.json").write_text(json.dumps(job), encoding="utf-8")
        meta = {"run": run_id, "design": design_id, "site": site["id"], "mode": job["mode"],
                "days": job["days"], "people": job["people"], "step_min": job["step_min"],
                "hazards": job["hazards"],
                "design_hash": design_hash(design), "queued": time.time(), "weather_files": n_wx}
        (rdir / "meta.json").write_text(json.dumps(meta), encoding="utf-8")
        self._write_status(rdir, {"state": "queued", "progress": 0.0, "run_id": run_id})
        with self.lock:
            self.queue.append(run_id)
        self._pump()
        return run_id

    def _write_status(self, rdir: Path, st: dict):
        (rdir / "status.json").write_text(json.dumps(st), encoding="utf-8")

    def _pump(self):
        with self.lock:
            while self.queue and len(self.procs) < self.cfg.max_parallel:
                rid = self.queue.pop(0)
                self._launch(rid)

    def _launch(self, rid: str):
        rdir = self.ws.path("runs", rid)
        args = [self.cfg.godot, "--headless"]
        # A source checkout runs the project folder; the exported game carries
        # its own pack and needs no --path.
        if self.cfg.project and (Path(self.cfg.project) / "project.godot").exists():
            args += ["--path", self.cfg.project]
        args += [KERNEL_SCENE, "--", "--simkit-job=" + (rdir / "job.json").as_posix()]
        logf = open(rdir / "log.txt", "w", encoding="utf-8", errors="replace")
        flags = 0
        if os.name == "nt":
            flags = getattr(subprocess, "CREATE_NO_WINDOW", 0) | getattr(subprocess, "BELOW_NORMAL_PRIORITY_CLASS", 0)
        p = subprocess.Popen(args, stdout=logf, stderr=subprocess.STDOUT, stdin=subprocess.DEVNULL,
                             env=self._kernel_env(), cwd=str(self.ws.root), creationflags=flags)
        self.procs[rid] = p
        meta = json.loads((rdir / "meta.json").read_text(encoding="utf-8"))
        meta["started"] = time.time()
        (rdir / "meta.json").write_text(json.dumps(meta), encoding="utf-8")
        threading.Thread(target=self._watch, args=(rid, p, logf), daemon=True).start()

    def _watch(self, rid: str, p: subprocess.Popen, logf):
        t0 = time.time()
        rdir = self.ws.path("runs", rid)
        while p.poll() is None:
            if time.time() - t0 > self.cfg.max_wall_s + 120:
                p.kill()
                break
            time.sleep(1.0)
        logf.close()
        st = self.status(rid)
        if st.get("state") not in ("done", "failed"):
            st = {"state": "failed", "progress": st.get("progress", 0), "run_id": rid,
                  "why": "the kernel stopped (exit %s); see the run log" % p.returncode}
            self._write_status(rdir, st)
        with self.lock:
            self.procs.pop(rid, None)
        self._prune()
        self._pump()

    def status(self, rid: str) -> dict:
        rdir = self.ws.path("runs", rid)
        if not rdir.is_dir():
            raise ToolError(f"no run '{rid}'")
        try:
            return json.loads((rdir / "status.json").read_text(encoding="utf-8"))
        except Exception:
            return {"state": "starting", "run_id": rid}

    def cancel(self, rid: str) -> dict:
        rdir = self.ws.path("runs", rid)
        with self.lock:
            if rid in self.queue:
                self.queue.remove(rid)
                self._write_status(rdir, {"state": "failed", "why": "cancelled", "run_id": rid})
                return {"cancelled": rid}
        (rdir / "cancel").write_text("1")
        return {"cancelling": rid}

    def _prune(self):
        runs = sorted((self.ws.root / "runs").iterdir(), key=lambda p: p.stat().st_mtime)
        for old in runs[:-MAX_RUNS_KEPT]:
            if old.name not in self.procs:
                shutil.rmtree(old, ignore_errors=True)


# --------------------------------------------------------------------------- reports

def read_summary(ws: Workspace, rid: str) -> dict:
    p = ws.path("runs", rid) / "summary.json"
    if not p.exists():
        raise ToolError(f"run '{rid}' has no report yet (check status)")
    return json.loads(p.read_text(encoding="utf-8"))


def filter_table(t: dict, ids) -> dict:
    if not ids:
        return t
    want = set(ids)
    return {"cols": t["cols"], "rows": [r for r in t["rows"] if r and (r[0] in want or str(r[0]).rsplit("_", 1)[0] in want)]}


def report_part(ws: Workspace, rid: str, part: str, ids=None, day_range=None, every=1) -> dict:
    s = read_summary(ws, rid)
    head = {k: s.get(k) for k in ["run", "design", "site", "start", "days", "verdict", "fails"]}
    if part == "summary":
        head.update({"kpi": s["kpi"], "bottlenecks": s["bottlenecks"], "fidelity": s.get("fidelity")})
        return head
    if part == "all":
        return s
    if part in ("stores", "machines"):
        head[part] = filter_table(s[part], ids)
        return head
    if part == "checks":
        head["checks"] = s["checks"]
        return head
    if part in ("kpi", "monthly", "bottlenecks"):
        head[part] = s[part]
        return head
    if part == "daily":
        csv_p = ws.path("runs", rid) / "daily_ids.csv"
        lines = csv_p.read_text(encoding="utf-8").splitlines() if csv_p.exists() else []
        if not lines:
            raise ToolError("no daily table for this run")
        cols = lines[0].split(",")
        keep = list(range(len(cols)))
        if ids:
            keep = [i for i, c in enumerate(cols) if i < 7 or c in ids]
        rows = []
        for ln in lines[1:]:
            cells = ln.split(",")
            day = float(cells[0])
            if day_range and not (day_range[0] <= day <= day_range[1]):
                continue
            if int(day) % max(1, int(every)) != 0:
                continue
            rows.append([_num(cells[i]) for i in keep])
        head["daily"] = {"cols": [cols[i] for i in keep], "rows": rows}
        return head
    raise ToolError(f"part must be one of {SUMMARY_PARTS}")


def _num(s: str):
    try:
        f = float(s)
        return int(f) if f.is_integer() else f
    except ValueError:
        return s


def compare_runs(ws: Workspace, rids: list) -> dict:
    if not 2 <= len(rids) <= 6:
        raise ToolError("compare 2 to 6 runs")
    sums = [read_summary(ws, r) for r in rids]
    out = {"runs": rids, "verdict": [s["verdict"] for s in sums], "fails": [s["fails"] for s in sums]}
    kpi = {}
    for k in sums[0]["kpi"]:
        vals = [s["kpi"].get(k) for s in sums]
        if len(set(map(str, vals))) > 1:
            kpi[k] = vals
    out["kpi_differs"] = kpi
    stores = {}
    for i, s in enumerate(sums):
        cols = s["stores"]["cols"]
        for r in s["stores"]["rows"]:
            row = dict(zip(cols, r))
            stores.setdefault(row["id"], [None] * len(sums))[i] = [row["end"], row["min"], row["empty_h"], row["overflow"]]
    out["stores_differ"] = {"cols": ["end", "min", "empty_h", "overflow"],
                            "by_id": {k: v for k, v in stores.items() if len(set(map(str, v))) > 1}}
    out["bottlenecks"] = [s["bottlenecks"][:4] for s in sums]
    return out


# --------------------------------------------------------------------------- inbox

def submit(cfg: Config, ws: Workspace, design_id: str, rid: str, note: str) -> dict:
    if not cfg.allow_submit:
        raise ToolError("this server was started with --no-submit")
    design = ws.load_design(design_id)
    rdir = ws.path("runs", rid)
    gpath = rdir / "graph.json"
    if not gpath.exists():
        raise ToolError("submit needs a run (or validate) of this design that built its graph")
    meta = json.loads((rdir / "meta.json").read_text(encoding="utf-8"))
    if meta.get("design_hash") != design_hash(design):
        raise ToolError("that run was of a different version of the design; run it again first")
    summary = {}
    sp = rdir / "summary.json"
    if sp.exists():
        s = json.loads(sp.read_text(encoding="utf-8"))
        summary = {k: s.get(k) for k in ["verdict", "fails", "kpi", "bottlenecks", "days", "start"]}
    inbox = cfg.player_data / "simkit" / "inbox"
    inbox.mkdir(parents=True, exist_ok=True)
    sid = f"{design_id}_{int(time.time())}"
    entry = {"v": 1, "id": sid, "name": str(design.get("name", design_id))[:120],
             "note": str(note or "")[:2000], "site": meta.get("site", ""), "run": rid,
             "created": time.time(), "summary": summary, "design": design,
             "graph": json.loads(gpath.read_text(encoding="utf-8"))}
    (inbox / (sid + ".json")).write_text(json.dumps(entry), encoding="utf-8")
    return {"submitted": sid, "where": "the game's AI designs inbox; the player reviews it as an experiment fork"}


# --------------------------------------------------------------------------- tools

TOOLS = [
    {"name": "list",
     "description": "List sites (the player's worlds), designs, or recent runs. Start here.",
     "inputSchema": {"type": "object", "properties": {
         "kind": {"type": "string", "enum": ["sites", "designs", "runs", "all"]}}}},
    {"name": "catalog",
     "description": "Library modules a design may use (by label). Filter with q / category; give label for one module's ports and settable fields.",
     "inputSchema": {"type": "object", "properties": {
         "q": {"type": "string"}, "category": {"type": "string"}, "label": {"type": "string"},
         "limit": {"type": "integer"}}}},
    {"name": "design_get",
     "description": "A design: an outline by default (nodes, counts, settings, solar); view=full for the whole JSON with wires and automations.",
     "inputSchema": {"type": "object", "required": ["id"], "properties": {
         "id": {"type": "string"}, "view": {"type": "string", "enum": ["outline", "full"]}}}},
    {"name": "design_put",
     "description": "Save a design: a whole `design`, or `base` (design id) + `patch` {top,set,nodes,add,remove,wires_add,wires_remove,solar,ac_add}. Returns problems if invalid.",
     "inputSchema": {"type": "object", "required": ["id"], "properties": {
         "id": {"type": "string"}, "design": {"type": "object"}, "base": {"type": "string"},
         "patch": {"type": "object"}}}},
    {"name": "run",
     "description": "Simulate a saved design at a site (default 366 days, people as agents). Returns a run id; poll status. people=rates is several times faster.",
     "inputSchema": {"type": "object", "required": ["design", "site"], "properties": {
         "design": {"type": "string"}, "site": {"type": "string"},
         "days": {"type": "number"}, "people": {"type": "string", "enum": ["agents", "rates"]},
         "step_min": {"type": "number"}, "validate_only": {"type": "boolean"},
         "hazards": {"type": "string", "enum": ["site", "on", "off"],
                     "description": "extreme weather (dust, smoke, wind): as the world has it (default), on, off"},
         "start": {"type": "object", "description": "{year, month, day, hour}"},
         "wait_s": {"type": "number", "description": "wait up to this long for it to finish (max 600)"}}}},
    {"name": "status",
     "description": "A run's progress (state, progress 0-1, day, eta_s).",
     "inputSchema": {"type": "object", "required": ["run"], "properties": {"run": {"type": "string"}}}},
    {"name": "report",
     "description": "A finished run's report. part: summary (default: verdict, failed checks, KPIs, ranked bottlenecks) | checks | kpi | stores | machines | monthly | bottlenecks | daily | all. ids filters rows to node ids; daily takes day_range [a,b] and every N.",
     "inputSchema": {"type": "object", "required": ["run"], "properties": {
         "run": {"type": "string"}, "part": {"type": "string", "enum": SUMMARY_PARTS},
         "ids": {"type": "array", "items": {"type": "string"}},
         "day_range": {"type": "array", "items": {"type": "number"}}, "every": {"type": "integer"}}}},
    {"name": "compare",
     "description": "Compare 2-6 finished runs: verdicts, failed checks, only the KPIs and stores that differ.",
     "inputSchema": {"type": "object", "required": ["runs"], "properties": {
         "runs": {"type": "array", "items": {"type": "string"}}}}},
    {"name": "cancel",
     "description": "Stop a queued or running run.",
     "inputSchema": {"type": "object", "required": ["run"], "properties": {"run": {"type": "string"}}}},
    {"name": "submit",
     "description": "Send a design (with a finished run of it) to the game's inbox. The player reviews it as an experiment fork; nothing changes in their world until they choose.",
     "inputSchema": {"type": "object", "required": ["design", "run"], "properties": {
         "design": {"type": "string"}, "run": {"type": "string"}, "note": {"type": "string"}}}},
]


class Server:
    def __init__(self, cfg: Config):
        self.cfg = cfg
        self.ws = Workspace(cfg)
        self.runner = Runner(cfg, self.ws)
        self._catalog = None

    # ---- tool bodies
    def t_list(self, a):
        kind = a.get("kind", "all")
        out = {}
        if kind in ("sites", "all"):
            out["sites"] = [self.ws.public_site(s) for s in self.ws.sites().values()]
        if kind in ("designs", "all"):
            rows = []
            for did, p in self.ws.designs().items():
                try:
                    d = json.loads(p.read_text(encoding="utf-8"))
                    rows.append([did, str(d.get("name", ""))[:80], len(d.get("nodes", [])), d.get("people", 0)])
                except Exception:
                    rows.append([did, "(unreadable)", 0, 0])
            out["designs"] = {"cols": ["id", "name", "nodes", "people"], "rows": rows}
        if kind in ("runs", "all"):
            rows = []
            for rd in sorted((self.ws.root / "runs").iterdir(), key=lambda p: p.stat().st_mtime, reverse=True)[:30]:
                try:
                    m = json.loads((rd / "meta.json").read_text(encoding="utf-8"))
                    st = json.loads((rd / "status.json").read_text(encoding="utf-8"))
                except Exception:
                    continue
                rows.append([rd.name, m.get("design"), m.get("site"), m.get("days"), m.get("people"),
                             st.get("state"), st.get("verdict", "")])
            out["runs"] = {"cols": ["run", "design", "site", "days", "people", "state", "verdict"], "rows": rows}
        return out

    def _load_catalog(self):
        if self._catalog is not None:
            return self._catalog
        p = self.ws.root / "catalog.json"
        if not p.exists():
            # Build it once with the kernel (a few seconds).
            rid = self.runner.start("catalog", {"nodes": []}, {"id": "none", "lat": 0.0, "lon": 0.0},
                                    {"mode": "catalog"})
            for _ in range(240):
                st = self.runner.status(rid)
                if st.get("state") in ("done", "failed"):
                    break
                time.sleep(0.5)
            cp = self.ws.path("runs", rid) / "catalog.json"
            if not cp.exists():
                raise ToolError("could not build the module catalog (see the run log)")
            shutil.copyfile(cp, p)
        self._catalog = json.loads(p.read_text(encoding="utf-8"))
        return self._catalog

    def t_catalog(self, a):
        cat = self._load_catalog()
        if a.get("label"):
            d = cat["detail"].get(a["label"])
            if d is None:
                raise ToolError(f"no module labelled '{a['label']}'")
            return {"label": a["label"], **d}
        q = str(a.get("q", "")).lower().split()
        c = str(a.get("category", ""))
        rows = [r for r in cat["rows"] if (not c or r[1] == c) and all(w in " ".join(map(str, r)).lower() for w in q)]
        lim = max(1, min(int(a.get("limit", 60)), 400))
        cats = sorted({r[1] for r in cat["rows"]})
        return {"cols": cat["cols"], "rows": rows[:lim], "more": max(0, len(rows) - lim), "categories": cats}

    def t_design_get(self, a):
        d = self.ws.load_design(str(a["id"]))
        if str(a.get("view", "outline")) == "full":
            return d
        # The outline: enough to name what to patch, a fraction of the tokens.
        rows = []
        for n in d.get("nodes", []):
            st = n.get("set", {}) if isinstance(n.get("set"), dict) else {}
            rows.append([n.get("id"), n.get("preset"), n.get("count", 1),
                         {k: v for k, v in st.items() if isinstance(v, (int, float, bool)) or
                          (isinstance(v, str) and len(v) <= 40)},
                         len(n.get("automations", []) or [])])
        return {"id": a["id"], "name": d.get("name"), "people": d.get("people"), "days": d.get("days"),
                "nodes": {"cols": ["id", "preset", "count", "set", "automations"], "rows": rows},
                "solar": [{k: s.get(k) for k in ("id", "panel", "series", "parallel", "controller", "tilt_deg")}
                          for s in d.get("solar", [])],
                "wires": len(d.get("wires", [])), "ac": d.get("ac", {}), "dc": d.get("dc", []),
                "spaces": len(d.get("spaces", [])),
                "hint": "view=full for wires, automations and recipes; patch by node id with design_put"}

    def t_design_put(self, a):
        did = str(a["id"])
        path = self.ws.path("designs", did, ".json")
        if did in self.ws.designs() and not (self.ws.root / "designs" / (did + ".json")).exists():
            raise ToolError(f"'{did}' is a built-in design; save under a new id")
        if a.get("design") is not None:
            d = a["design"]
        elif a.get("base"):
            d = apply_patch(self.ws.load_design(str(a["base"])), a.get("patch") or {})
        else:
            raise ToolError("give design, or base + patch")
        probs = check_design(d)
        if probs:
            return {"ok": False, "problems": probs[:30]}
        path.write_text(json.dumps(d, indent=1), encoding="utf-8")
        return {"ok": True, "id": did, "nodes": len(d.get("nodes", [])), "hash": design_hash(d)}

    def t_run(self, a):
        did = str(a["design"])
        d = self.ws.load_design(did)
        probs = check_design(d)
        if probs:
            return {"ok": False, "problems": probs[:30]}
        sites = self.ws.sites()
        sid = str(a["site"])
        if sid not in sites:
            raise ToolError(f"no site '{sid}' (list sites)")
        opts = {"mode": "validate" if a.get("validate_only") else "run",
                "days": float(a.get("days", d.get("days", 366))),
                "people": a.get("people", "agents") if a.get("people", "agents") in ("agents", "rates") else "agents",
                "step_min": float(a.get("step_min", d.get("step_min", 6)))}
        hz = str(a.get("hazards", "site"))
        opts["hazards"] = bool(sites[sid].get("hazards", False)) if hz == "site" else hz == "on"
        if not 1 <= opts["days"] <= 3660 or not 1 <= opts["step_min"] <= 60:
            raise ToolError("days 1..3660, step_min 1..60")
        if isinstance(a.get("start"), dict):
            opts["start"] = {k: int(a["start"][k]) for k in ("year", "month", "day", "hour") if k in a["start"]}
        rid = self.runner.start(did, d, sites[sid], opts)
        wait = min(float(a.get("wait_s", 0) or 0), 600.0)
        t0 = time.time()
        st = self.runner.status(rid)
        while wait > 0 and time.time() - t0 < wait and st.get("state") not in ("done", "failed"):
            time.sleep(1.0)
            st = self.runner.status(rid)
        return {"run": rid, **st}

    def t_status(self, a):
        return self.runner.status(str(a["run"]))

    def t_report(self, a):
        return report_part(self.ws, str(a["run"]), str(a.get("part", "summary")), a.get("ids"),
                           a.get("day_range"), int(a.get("every", 1) or 1))

    def t_compare(self, a):
        return compare_runs(self.ws, [str(x) for x in a["runs"]])

    def t_cancel(self, a):
        return self.runner.cancel(str(a["run"]))

    def t_submit(self, a):
        return submit(self.cfg, self.ws, str(a["design"]), str(a["run"]), str(a.get("note", "")))

    # ---- JSON-RPC
    def handle(self, msg: dict):
        mid = msg.get("id")
        method = msg.get("method", "")
        params = msg.get("params") or {}
        if method == "initialize":
            want = params.get("protocolVersion", PROTOCOLS[0])
            return self._ok(mid, {"protocolVersion": want if want in PROTOCOLS else PROTOCOLS[0],
                                  "capabilities": {"tools": {"listChanged": False}},
                                  "serverInfo": {"name": SERVER_NAME, "version": SERVER_VERSION},
                                  "instructions": INSTRUCTIONS})
        if method in ("notifications/initialized", "initialized") or mid is None:
            return None
        if method == "ping":
            return self._ok(mid, {})
        if method == "tools/list":
            return self._ok(mid, {"tools": TOOLS})
        if method == "tools/call":
            name = str(params.get("name", ""))
            args = params.get("arguments") or {}
            fn = getattr(self, "t_" + name, None)
            if fn is None or name not in {t["name"] for t in TOOLS}:
                return self._err(mid, -32602, f"unknown tool '{name}'")
            try:
                res = fn(args)
                return self._ok(mid, {"content": [{"type": "text", "text": compact(res)}], "isError": False})
            except KeyError as e:
                req = next((t.get("inputSchema", {}).get("required", []) for t in TOOLS if t["name"] == name), [])
                msg = f"{name} needs argument {e}" + (f" (required: {', '.join(req)})" if req else "")
                return self._ok(mid, {"content": [{"type": "text", "text": compact({"error": msg})}], "isError": True})
            except (ToolError, ValueError, TypeError) as e:
                return self._ok(mid, {"content": [{"type": "text", "text": compact({"error": str(e)})}], "isError": True})
            except Exception as e:  # never leak a traceback path to the client
                log("tool error", name, repr(e))
                return self._ok(mid, {"content": [{"type": "text", "text": compact({"error": "internal error"})}], "isError": True})
        return self._err(mid, -32601, f"method '{method}' not found")

    @staticmethod
    def _ok(mid, result):
        return {"jsonrpc": "2.0", "id": mid, "result": result}

    @staticmethod
    def _err(mid, code, message):
        return {"jsonrpc": "2.0", "id": mid, "error": {"code": code, "message": message}}

    def serve_stdio(self):
        # MCP's stdio transport is UTF-8, one JSON message per line, whatever
        # the console's code page is.
        for stream in (sys.stdin, sys.stdout):
            if hasattr(stream, "reconfigure"):
                stream.reconfigure(encoding="utf-8", newline="\n" if stream is sys.stdout else None)
        out_lock = threading.Lock()
        for line in sys.stdin:
            line = line.strip()
            if not line:
                continue
            try:
                msg = json.loads(line)
            except json.JSONDecodeError:
                continue
            if len(line) > 4_000_000:
                continue
            msgs = msg if isinstance(msg, list) else [msg]
            for m in msgs:
                if not isinstance(m, dict):
                    continue
                resp = self.handle(m)
                if resp is not None:
                    with out_lock:
                        sys.stdout.write(compact(resp) + "\n")
                        sys.stdout.flush()


INSTRUCTIONS = (
    "Simulates off-grid sites in SIMbiogenesis for a year without rendering. Loop: list -> design_get "
    "(start from a built-in such as bombay_ten) -> design_put with base+patch under a new id -> run "
    "(people=rates for a fast first look, agents to confirm) -> report (summary first; stores / machines "
    "with ids for detail) -> compare -> submit the best one for the player to review. A run is SUSTAINED "
    "only if every check passes. Node ids in reports are the design's own ids, so a patch can name them.")


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--godot", help="Godot 4.7 binary (source checkout) or the exported game (env SIMBIO_GODOT)")
    ap.add_argument("--project", help="project folder with project.godot (found from this file if omitted)")
    ap.add_argument("--workspace", help="where designs, runs and the kernel's folder live")
    ap.add_argument("--player-data", help="the game's user data folder (its worlds, weather cache, inbox)")
    ap.add_argument("--allow-download", action="store_true", help="let the kernel fetch missing weather archives")
    ap.add_argument("--share-place-names", action="store_true", help="show world names (may be addresses) to the AI")
    ap.add_argument("--max-parallel", type=int, default=1)
    ap.add_argument("--max-wall-s", type=int, default=7200)
    ap.add_argument("--no-submit", action="store_true", help="never write to the game's inbox")
    sub = ap.add_subparsers(dest="cmd")
    s1 = sub.add_parser("add-site", help="add a site by hand: add-site <id> <lat> <lon> [name]")
    s1.add_argument("id")
    s1.add_argument("lat", type=float)
    s1.add_argument("lon", type=float)
    s1.add_argument("name", nargs="?", default="")
    sub.add_parser("check", help="print the configuration and exit")
    args = ap.parse_args(argv)
    cfg = Config(args)
    srv = Server(cfg)
    if args.cmd == "add-site":
        if not ID_RE.match(args.id) or not (-90 <= args.lat <= 90 and -180 <= args.lon <= 180):
            sys.exit("bad id or coordinates")
        p = srv.ws.path("sites", args.id, ".json")
        p.write_text(json.dumps({"lat": args.lat, "lon": args.lon, "name": args.name}), encoding="utf-8")
        print("added", p)
        return
    if args.cmd == "check":
        print(json.dumps({"godot": cfg.godot, "godot_found": bool(cfg.godot) and Path(cfg.godot).exists(),
                          "project": cfg.project, "workspace": str(srv.ws.root),
                          "player_data": str(cfg.player_data), "sites": len(srv.ws.sites()),
                          "designs": list(srv.ws.designs().keys()), "allow_download": cfg.allow_download},
                         indent=1))
        return
    log("ready; workspace", srv.ws.root)
    srv.serve_stdio()


if __name__ == "__main__":
    main()
