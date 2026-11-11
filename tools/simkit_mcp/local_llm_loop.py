#!/usr/bin/env python3
"""Let a LOCAL model optimise a site through the simulation server.

Any OpenAI-compatible chat endpoint with tool calling works: Ollama
(http://localhost:11434/v1), LM Studio (http://localhost:1234/v1), llama.cpp's
server, vLLM. Nothing leaves the machine unless you point --base-url
elsewhere. Standard library only.

  python tools/simkit_mcp/local_llm_loop.py --model qwen3:14b \
      --godot <Godot console exe> --site <world id> --base bombay_ten \
      --goal "Keep it SUSTAINED with the smallest battery." --turns 30

It starts simbio_sim_mcp.py as a child over stdio (the same server any MCP
client uses), hands the model its tools, and runs the conversation until the
model stops calling tools or --turns is reached. Every tool call and a short
result is printed, and the whole transcript is saved to --log.
"""
import argparse
import json
import os
import subprocess
import sys
import time
import urllib.request
from pathlib import Path

HERE = Path(__file__).resolve().parent

SYSTEM = """You optimise an off-grid site in the SIMbiogenesis simulator.
Tools run the game's own simulation for a year without rendering and return compact JSON.
Work in small steps:
1. report on a baseline run (or run the base design) and read its bottlenecks;
2. make ONE change with design_put (base + patch, a new id each time);
3. run it (people="rates" for speed; confirm the best with people="agents");
4. compare against the previous best; keep what helps.
A run passes only if verdict is SUSTAINED. Prefer smaller, cheaper systems that still pass.
When you are done, submit the best design with a short note on why, then stop calling tools."""


class Mcp:
    def __init__(self, cmd):
        self.p = subprocess.Popen(cmd, stdin=subprocess.PIPE, stdout=subprocess.PIPE, text=True,
                                  encoding="utf-8")
        self.n = 0
        self.rpc("initialize", {"protocolVersion": "2025-06-18", "capabilities": {},
                                "clientInfo": {"name": "local_llm_loop", "version": "1"}})
        self.p.stdin.write(json.dumps({"jsonrpc": "2.0", "method": "notifications/initialized"}) + "\n")
        self.p.stdin.flush()

    def rpc(self, method, params):
        self.n += 1
        self.p.stdin.write(json.dumps({"jsonrpc": "2.0", "id": self.n, "method": method, "params": params}) + "\n")
        self.p.stdin.flush()
        return json.loads(self.p.stdout.readline())

    def tools(self):
        return self.rpc("tools/list", {})["result"]["tools"]

    def call(self, name, args):
        r = self.rpc("tools/call", {"name": name, "arguments": args}).get("result", {})
        return r.get("content", [{}])[0].get("text", "{}")


def chat(base_url, api_key, model, messages, tools):
    body = json.dumps({"model": model, "messages": messages, "tools": tools, "temperature": 0.2}).encode()
    req = urllib.request.Request(base_url.rstrip("/") + "/chat/completions", data=body,
                                 headers={"Content-Type": "application/json",
                                          "Authorization": "Bearer " + (api_key or "local")})
    with urllib.request.urlopen(req, timeout=900) as r:
        return json.loads(r.read().decode())["choices"][0]["message"]


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--base-url", default="http://localhost:11434/v1")
    ap.add_argument("--api-key", default=os.environ.get("LLM_API_KEY", ""))
    ap.add_argument("--model", required=True)
    ap.add_argument("--godot", default=os.environ.get("SIMBIO_GODOT", ""))
    ap.add_argument("--site", required=True, help="a site id from the server's list")
    ap.add_argument("--base", default="bombay_ten", help="design to start from")
    ap.add_argument("--goal", default="Keep the site SUSTAINED for a year while making the system smaller.")
    ap.add_argument("--turns", type=int, default=30)
    ap.add_argument("--log", default="local_llm_loop_log.json")
    ap.add_argument("server_args", nargs="*", help="extra args for simbio_sim_mcp.py after --")
    a = ap.parse_args()
    cmd = [sys.executable, str(HERE / "simbio_sim_mcp.py")]
    if a.godot:
        cmd += ["--godot", a.godot]
    cmd += a.server_args
    mcp = Mcp(cmd)
    tools = [{"type": "function", "function": {"name": t["name"], "description": t["description"],
                                                 "parameters": t["inputSchema"]}} for t in mcp.tools()]
    messages = [{"role": "system", "content": SYSTEM},
                {"role": "user", "content": f"Site: {a.site}. Start from design '{a.base}'. Goal: {a.goal}"}]
    nudges = 0
    submitted = False
    for turn in range(a.turns):
        msg = chat(a.base_url, a.api_key, a.model, messages, tools)
        messages.append({k: v for k, v in msg.items() if k in ("role", "content", "tool_calls")})
        calls = msg.get("tool_calls") or []
        if msg.get("content"):
            print(f"[{turn}] model: {str(msg['content'])[:400]}", flush=True)
        if not calls:
            # Small models often say what they will do and stop. Ask twice.
            if submitted or nudges >= 2:
                break
            nudges += 1
            messages.append({"role": "user", "content": "Do it now: call the next tool. Start with list if unsure."})
            continue
        submitted = submitted or any(c.get("function", {}).get("name") == "submit" for c in calls)
        for c in calls:
            fn = c.get("function", {})
            try:
                args = json.loads(fn.get("arguments") or "{}")
            except json.JSONDecodeError:
                args = {}
            # A long run: wait for it here instead of letting the model poll.
            if fn.get("name") == "run" and "wait_s" not in args:
                args["wait_s"] = 600
            t0 = time.time()
            out = mcp.call(fn.get("name", ""), args)
            if fn.get("name") == "run":
                rid = json.loads(out).get("run")
                while rid and json.loads(mcp.call("status", {"run": rid})).get("state") not in ("done", "failed"):
                    time.sleep(10)
                out = mcp.call("status", {"run": rid}) if rid else out
            print(f"[{turn}] {fn.get('name')}({json.dumps(args)[:160]}) -> {out[:200]} ({time.time() - t0:.0f} s)", flush=True)
            messages.append({"role": "tool", "tool_call_id": c.get("id", ""), "content": out})
        Path(a.log).write_text(json.dumps(messages, indent=1), encoding="utf-8")
    Path(a.log).write_text(json.dumps(messages, indent=1), encoding="utf-8")


if __name__ == "__main__":
    main()
