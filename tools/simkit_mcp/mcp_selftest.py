#!/usr/bin/env python3
"""End-to-end check of the simulation MCP server, the way a client uses it.

Offline part (always): the design guard and the patch language.
Live part (with --godot): starts the server over stdio in a TEMP workspace,
  initialize -> tools/list -> list -> catalog -> design_put (base + patch) ->
  run (rates, a few days) -> report -> compare -> submit to a TEMP inbox,
and checks each answer. Prints PASS / FAIL lines and exits non-zero on a fail.

  python tools/simkit_mcp/mcp_selftest.py
  python tools/simkit_mcp/mcp_selftest.py --godot <Godot console exe> --days 3
"""
import argparse
import json
import os
import subprocess
import sys
import tempfile
import time
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
import simbio_sim_mcp as S  # noqa: E402

FAILS = []


def check(ok, what):
    print(("PASS " if ok else "FAIL ") + what, flush=True)
    if not ok:
        FAILS.append(what)


def offline():
    base = json.loads((HERE.parents[1] / "core/simkit/designs/bombay_ten.json").read_text(encoding="utf-8"))
    check(S.check_design(base) == [], "the built-in design passes the guard")
    check(any("unknown top-level" in p for p in S.check_design({"nodes": [], "exec": "x"})), "an unknown key is refused")
    check(any("must be letters" in p for p in S.check_design({"nodes": [{"id": "../x", "preset": "Kitchen"}]})),
          "a node id with a path in it is refused")
    check(any("bytes" in p for p in S.check_design({"nodes": [], "note": "x" * 700000})), "an oversized design is refused")
    d = S.apply_patch(base, {"top": {"people": 12}, "set": {"cistern": {"capacity_qty": 500000}},
                             "remove": ["awg"], "add": [{"id": "extra_tank", "preset": "Water Tank (1000 L)"}]})
    cis = [n for n in d["nodes"] if n["id"] == "cistern"]
    check(d["people"] == 12, "patch: top-level field")
    check(bool(cis) and cis[0].get("set", {}).get("capacity_qty") == 500000, "patch: set merges a field")
    check(not any(n["id"] == "awg" for n in d["nodes"]), "patch: remove drops the node")
    check(not any("awg" in w[:2] for w in d.get("wires", [])), "patch: remove drops its wires")
    check(any(n["id"] == "extra_tank" for n in d["nodes"]), "patch: add")
    check(base["people"] == 10, "patch does not change the base")
    try:
        S.apply_patch(base, {"set": {"nope": {"a": 1}}})
        check(False, "patch: unknown node refused")
    except S.ToolError:
        check(True, "patch: unknown node refused")
    ws = tempfile.mkdtemp(prefix="simkit_ws_")
    args = S.argparse.Namespace(godot="", project=str(HERE.parents[1]), workspace=ws, player_data=ws,
                                allow_download=False, share_place_names=False, max_parallel=1,
                                max_wall_s=600, no_submit=False)
    w = S.Workspace(S.Config(args))
    for bad in ["..", "a/b", "c:\\x", "", "x" * 70]:
        try:
            w.path("runs", bad)
            check(False, f"workspace refuses id {bad!r}")
        except S.ToolError:
            check(True, f"workspace refuses id {bad[:12]!r}")


class Client:
    def __init__(self, cmd, env):
        self.p = subprocess.Popen(cmd, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=sys.stderr,
                                  text=True, encoding="utf-8", env=env)
        self.n = 0

    def call(self, method, params=None):
        self.n += 1
        self.p.stdin.write(json.dumps({"jsonrpc": "2.0", "id": self.n, "method": method, "params": params or {}}) + "\n")
        self.p.stdin.flush()
        line = self.p.stdout.readline()
        return json.loads(line)

    def tool(self, name, **a):
        r = self.call("tools/call", {"name": name, "arguments": a})
        res = r.get("result", {})
        text = res.get("content", [{}])[0].get("text", "{}")
        return json.loads(text), bool(res.get("isError")), len(text)

    def close(self):
        self.p.stdin.close()
        self.p.wait(10)


def live(godot, days):
    ws = Path(tempfile.mkdtemp(prefix="simkit_ws_"))
    player = Path(tempfile.mkdtemp(prefix="simkit_player_"))
    # The player's real weather cache, read only (the server copies from it).
    real = S.default_player_data()
    (player / "worlds" / "wbombay").mkdir(parents=True)
    (player / "worlds" / "wbombay" / "world.json").write_text(json.dumps(
        {"name": "Somewhere secret", "map": {"lat": 33.3560147, "lon": -115.7266354}}), encoding="utf-8")
    if (real / "weather_cache").is_dir():
        os.symlink if False else None
        (player / "weather_cache").mkdir()
        for f in (real / "weather_cache").glob("om_v5_33.36_-115.73_*.json"):
            (player / "weather_cache" / f.name).write_bytes(f.read_bytes())
    cmd = [sys.executable, str(HERE / "simbio_sim_mcp.py"), "--godot", godot, "--workspace", str(ws),
           "--player-data", str(player)]
    c = Client(cmd, dict(os.environ))
    init = c.call("initialize", {"protocolVersion": "2025-06-18", "capabilities": {},
                                 "clientInfo": {"name": "selftest", "version": "1"}})
    check(init.get("result", {}).get("serverInfo", {}).get("name") == S.SERVER_NAME, "initialize")
    c.p.stdin.write(json.dumps({"jsonrpc": "2.0", "method": "notifications/initialized"}) + "\n")
    tl = c.call("tools/list")
    names = [t["name"] for t in tl["result"]["tools"]]
    check(set(names) >= {"list", "catalog", "design_put", "run", "report", "compare", "submit"}, "tools/list")
    lst, err, n = c.tool("list")
    check(not err and any(s["id"] == "wbombay" for s in lst["sites"]), "list shows the world as a site")
    check(all("lat" not in s and "Somewhere" not in json.dumps(s) for s in lst["sites"]), "list hides coordinates and names")
    cat, err, n = c.tool("catalog", q="kitchen")
    check(not err and any("Kitchen" in r[0] for r in cat["rows"]), f"catalog search ({n} chars)")
    one, err, n = c.tool("catalog", label="Kitchen")
    check(not err and "specs" in one, "catalog detail for one module")
    put, err, n = c.tool("design_put", id="bt_more_water", base="bombay_ten",
                         patch={"set": {"cistern": {"capacity_qty": 500000}}})
    check(put.get("ok") is True, "design_put base+patch")
    bad, err, n = c.tool("design_put", id="../evil", design={"nodes": []})
    check(err and "bad id" in bad.get("error", ""), "design_put refuses a path id")
    t0 = time.time()
    r1, err, n = c.tool("run", design="bombay_ten", site="wbombay", days=days, people="rates", wait_s=600)
    check(r1.get("state") == "done", f"run base ({time.time() - t0:.0f} s): {r1}")
    r2, err, n = c.tool("run", design="bt_more_water", site="wbombay", days=days, people="rates", wait_s=600)
    check(r2.get("state") == "done", "run patched design")
    rep, err, n = c.tool("report", run=r1["run"])
    check(not err and rep.get("verdict") in ("SUSTAINED", "NOT_SUSTAINED") and "kpi" in rep,
          f"report summary ({n} chars)")
    st, err, n = c.tool("report", run=r1["run"], part="stores", ids=["cistern", "potable"])
    check(not err and {r[0] for r in st["stores"]["rows"]} == {"cistern", "potable"}, "report stores filtered by id")
    dl, err, n = c.tool("report", run=r1["run"], part="daily", ids=["potable"])
    check(not err and "potable" in dl["daily"]["cols"], f"report daily ({n} chars)")
    cmp_, err, n = c.tool("compare", runs=[r1["run"], r2["run"]])
    check(not err and "cistern" in cmp_["stores_differ"]["by_id"], f"compare shows the changed store ({n} chars)")
    sub, err, n = c.tool("submit", design="bt_more_water", run=r2["run"], note="bigger cistern")
    inbox = list((player / "simkit" / "inbox").glob("*.json"))
    check(not err and len(inbox) == 1, "submit writes one inbox entry")
    if inbox:
        e = json.loads(inbox[0].read_text(encoding="utf-8"))
        check("graph" in e and "items" in e["graph"], "the inbox entry carries the built graph")
    wrong, err, n = c.tool("submit", design="bt_more_water", run=r1["run"])
    check(err, "submit refuses a run of a different design version")
    c.close()


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--godot", default=os.environ.get("SIMBIO_GODOT", ""))
    ap.add_argument("--days", type=float, default=3)
    a = ap.parse_args()
    offline()
    if a.godot:
        live(a.godot, a.days)
    else:
        print("SKIP live part (no --godot)")
    print("mcp selftest: %s (%d failures)" % ("FAIL" if FAILS else "PASS", len(FAILS)))
    sys.exit(1 if FAILS else 0)


if __name__ == "__main__":
    main()
