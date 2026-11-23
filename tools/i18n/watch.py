"""Watch a translation run live in a browser.

    python tools/i18n/watch.py            # then open http://127.0.0.1:8765
    python tools/i18n/watch.py --port 9000

translate.py rewrites locale/.progress.json after every batch; this serves a
page that reads it every two seconds: a card per language (progress, speed,
time left), the strings it just translated beside their English, anything it
refused to keep, and what Ollama is running on (GPU or CPU). Read-only: it
never touches the .po files. Standard library only; listens on 127.0.0.1.
"""

from __future__ import annotations

import argparse
import http.server
import json
import os
import sys
import urllib.request

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
PROGRESS = os.path.join(ROOT, "locale", ".progress.json")
COVERAGE = os.path.join(ROOT, "locale", "coverage.json")
OLLAMA = os.environ.get("OLLAMA_HOST_URL", "http://127.0.0.1:11434")

PAGE = r"""<!doctype html>
<html lang="en"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>Translation run</title>
<style>
:root{--bg:#0f1628;--card:#17203a;--line:#26314f;--text:#e6ebf5;--muted:#8f9bb8;--ok:#4cc38a;--warn:#e0a13a;--bad:#e05a5a;--accent:#4aa8ff}
*{box-sizing:border-box}body{margin:0;background:var(--bg);color:var(--text);font:14px/1.45 system-ui,"Segoe UI",sans-serif}
header{display:flex;flex-wrap:wrap;gap:8px 24px;align-items:baseline;padding:16px 20px;border-bottom:1px solid var(--line)}
h1{font-size:18px;margin:0}.muted{color:var(--muted)}.pill{display:inline-block;padding:2px 9px;border-radius:99px;background:var(--line);font-size:12px}
.pill.ok{background:#1d4a36;color:#9be3bf}.pill.warn{background:#4d3a15;color:#f2cd85}.pill.bad{background:#4d1f1f;color:#f2a3a3}
main{display:grid;grid-template-columns:repeat(auto-fit,minmax(320px,1fr));gap:14px;padding:16px 20px}
.card{background:var(--card);border:1px solid var(--line);border-radius:10px;padding:14px;min-width:0}
.card h2{margin:0 0 2px;font-size:16px;display:flex;justify-content:space-between;gap:8px}
.bar{height:10px;border-radius:6px;background:var(--line);overflow:hidden;margin:10px 0 6px}
.bar i{display:block;height:100%;background:var(--accent);transition:width .6s}
.card.done .bar i{background:var(--ok)}
.stats{display:flex;flex-wrap:wrap;gap:4px 14px;font-size:12px;color:var(--muted)}
.stats b{color:var(--text);font-weight:600;font-variant-numeric:tabular-nums}
ol{list-style:none;margin:10px 0 0;padding:0;max-height:340px;overflow:auto}
li{padding:6px 0;border-top:1px solid var(--line)}li:first-child{border-top:0}
.src{color:var(--muted);font-size:12px}.out{font-size:15px;overflow-wrap:anywhere}
.where{color:#5d6a8a;font-size:11px}.fail{color:#f2a3a3;font-size:12px;overflow-wrap:anywhere}
li.new{animation:flash 1.4s ease-out}@keyframes flash{from{background:#24406b}to{background:transparent}}
details{margin-top:8px}summary{cursor:pointer;color:var(--muted);font-size:12px}
@media (max-width:420px){header,main{padding-left:16px;padding-right:16px}}
</style></head><body>
<header><h1>Translation run</h1><span id="model" class="muted"></span><span id="gpu" class="pill">Ollama …</span>
<span id="age" class="muted"></span></header>
<main id="cards"><p class="muted">Waiting for translate.py to start (locale/.progress.json)…</p></main>
<script>
const seen = {};
function fmtTime(s){ if(s==null) return "–"; s=Math.round(s); if(s<60) return s+" s";
  const m=Math.round(s/60); return m<60? m+" min" : Math.floor(m/60)+" h "+(m%60)+" min"; }
function esc(t){ return String(t).replace(/[&<>"]/g,c=>({"&":"&amp;","<":"&lt;",">":"&gt;","\"":"&quot;"}[c])); }
async function tick(){
  try{
    const r = await fetch("/progress.json",{cache:"no-store"}); const p = await r.json();
    const cov = await (await fetch("/coverage.json",{cache:"no-store"})).json();
    document.getElementById("model").textContent = p.model ? (p.model+" · "+(p.jobs||1)+" at once") : "";
    const age = p.updated ? (Date.now()/1000 - p.updated) : null;
    document.getElementById("age").textContent = age==null? "" : "updated "+fmtTime(age)+" ago";
    const box = document.getElementById("cards"); const langs = p.langs||{};
    if(!Object.keys(langs).length) return;
    box.innerHTML = "";
    for(const [code,st] of Object.entries(langs)){
      const tot = st.total||0, done = st.done||0, pct = tot? Math.round(100*done/tot) : (st.state=="done"?100:0);
      const cv = cov[code];
      const card = document.createElement("section"); card.className = "card"+(st.state=="done"?" done":"");
      const rtl = ["ar","fa","ur","he"].includes(code.split("_")[0]);
      let items = (st.recent||[]).map(x=>{ const k=code+"|"+x.src; const n=!seen[k]; seen[k]=1;
        return `<li class="${n?"new":""}"><div class="src">${esc(x.src)}</div><div class="out" dir="${rtl?"rtl":"auto"}">${esc(x.out)}</div><div class="where">${esc(x.where||"")}</div></li>`; }).join("");
      const fails = (st.failed||[]).map(f=>`<li class="fail">${esc(f.why)}</li>`).join("");
      card.innerHTML = `<h2><span>${esc(st.name||code)} <span class="muted">${esc(code)}</span></span>
        <span class="pill ${st.state=="done"?"ok":st.state=="translating"?"warn":""}">${esc(st.state||"")}</span></h2>
        <div class="bar"><i style="width:${pct}%"></i></div>
        <div class="stats"><span><b>${done}</b> / ${tot} this run (${pct} %)</span>
        <span><b>${st.rate? (st.rate*60).toFixed(0) : "–"}</b> strings/min</span>
        <span>left <b>${fmtTime(st.eta_s)}</b></span><span>refused <b>${st.failed_n||0}</b></span>
        ${cv!=null? `<span>whole game before this run <b>${Math.round(cv*100)} %</b></span>`:""}</div>
        <ol>${items||'<li class="muted">nothing yet</li>'}</ol>
        ${fails? `<details><summary>Refused (${st.failed_n})</summary><ol>${fails}</ol></details>`:""}`;
      box.appendChild(card);
    }
  }catch(e){ /* file mid-write or server restarting */ }
}
async function gpu(){
  try{ const g = await (await fetch("/ollama.json",{cache:"no-store"})).json(); const el=document.getElementById("gpu");
    if(!g.ok){ el.className="pill bad"; el.textContent="Ollama not reachable"; return; }
    if(!g.models.length){ el.className="pill"; el.textContent="Ollama idle"; return; }
    const m=g.models[0], pct = m.size? Math.round(100*(m.size_vram||0)/m.size) : 0;
    el.className = "pill "+(pct>=90?"ok":pct>0?"warn":"bad");
    el.textContent = m.name+" · "+(pct>=90?"GPU":pct>0?pct+" % GPU":"CPU only"); }catch(e){}
}
tick(); gpu(); setInterval(tick,2000); setInterval(gpu,5000);
</script></body></html>"""


class Handler(http.server.BaseHTTPRequestHandler):
    def log_message(self, *a) -> None:  # quiet
        pass

    def _send(self, body: bytes, ctype: str) -> None:
        self.send_response(200)
        self.send_header("Content-Type", ctype)
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self) -> None:  # noqa: N802
        path = self.path.split("?")[0]
        if path in ("/", "/index.html"):
            self._send(PAGE.encode("utf-8"), "text/html; charset=utf-8")
        elif path == "/progress.json":
            self._send(_read(PROGRESS, b"{}"), "application/json")
        elif path == "/coverage.json":
            self._send(_read(COVERAGE, b"{}"), "application/json")
        elif path == "/ollama.json":
            try:
                ps = json.load(urllib.request.urlopen(OLLAMA.rstrip("/") + "/api/ps", timeout=2))
                out = {"ok": True, "models": [{"name": m.get("name"), "size": m.get("size", 0),
                                               "size_vram": m.get("size_vram", 0)} for m in ps.get("models", [])]}
            except Exception:  # noqa: BLE001
                out = {"ok": False, "models": []}
            self._send(json.dumps(out).encode("utf-8"), "application/json")
        else:
            self.send_error(404)


def _read(path: str, default: bytes) -> bytes:
    try:
        with open(path, "rb") as fh:
            return fh.read()
    except OSError:
        return default


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--port", type=int, default=8765)
    args = ap.parse_args()
    srv = http.server.ThreadingHTTPServer(("127.0.0.1", args.port), Handler)
    print(f"watch: http://127.0.0.1:{args.port}  (Ctrl+C to stop)", flush=True)
    try:
        srv.serve_forever()
    except KeyboardInterrupt:
        pass
    return 0


if __name__ == "__main__":
    sys.exit(main())
